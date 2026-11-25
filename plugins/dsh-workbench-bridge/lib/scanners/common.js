/**
 * @file 多 CLI 扫描器共用工具函数（路径安全、时间解析、ETag 计算、文本清洗）。
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

/** 支持的外部 CLI 引擎标识 */
export const CLI_ENGINES = new Set(['antigravity', 'claude', 'codex']);

/** 桥接层发送附件时注入到 CLI prompt 末尾的固定标记 */
export const BRIDGE_ATTACHMENT_MARKER = '[用户附带的本地文件，请直接读取分析]';
/** 纯发图/附件无正文时桥接层自动填充的默认占位句 */
export const BRIDGE_DEFAULT_IMAGE_PROMPT = '请查看并分析用户附带的图片或文件。';

const IMAGE_MIME_RE = /^image\//i;
const IMAGE_EXT_RE = /\.(png|jpe?g|webp|gif|bmp|heic|heif)$/i;
const ATTACHMENT_LINE_RE = /^-\s+(.+?)\s+\(([^()]+)\):\s+(.+)$/;

/**
 * 清洗外部 CLI 工具名前缀（如 `default_api:read_file` -> `read_file`）。
 *
 * @param {unknown} rawName
 * @returns {string}
 */
export function normalizeCliToolName(rawName) {
  const s = typeof rawName === 'string' ? rawName.trim() : '';
  if (!s) return 'tool';
  return s.replace(/^(?:default_api|functions|tools):/i, '');
}

/**
 * 从用户消息正文中剥离桥接层注入的 `[用户附带的本地文件，请直接读取分析]` 块，
 * 并将其还原为标准图片/文件附件 part 列表，避免聊天界面暴露裸路径文本。
 *
 * @param {unknown} rawText
 * @returns {{ text: string, attachments: Array<object> }}
 */
export function extractBridgeAttachmentsFromText(rawText) {
  if (typeof rawText !== 'string' || !rawText) {
    return { text: '', attachments: [] };
  }
  const idx = rawText.indexOf(BRIDGE_ATTACHMENT_MARKER);
  if (idx < 0) {
    return { text: rawText, attachments: [] };
  }
  let cleanText = rawText.slice(0, idx).trim();
  if (cleanText === BRIDGE_DEFAULT_IMAGE_PROMPT) {
    cleanText = '';
  }
  const block = rawText.slice(idx + BRIDGE_ATTACHMENT_MARKER.length);
  const attachments = [];
  for (const line of block.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const m = ATTACHMENT_LINE_RE.exec(trimmed);
    if (!m) continue;
    const name = m[1].trim();
    const mediaType = m[2].trim();
    let filePath = m[3].trim();
    if (/^file:\/\//i.test(filePath)) filePath = decodeFileUri(filePath);
    if (/^\/[A-Za-z]:[\\/]/.test(filePath)) filePath = filePath.slice(1);
    if (!filePath) continue;
    let bytes;
    try {
      if (fs.existsSync(filePath)) {
        bytes = fs.statSync(filePath).size;
      }
    } catch {
      // 忽略 stat 异常
    }
    const isImage = IMAGE_MIME_RE.test(mediaType) || IMAGE_EXT_RE.test(name);
    if (isImage) {
      attachments.push({
        type: 'image',
        attachment: {
          attachmentId: `wb-file:${filePath}`,
          mediaType: IMAGE_MIME_RE.test(mediaType) ? mediaType : 'image/jpeg',
          name: name || path.basename(filePath),
          ...(bytes !== undefined ? { bytes } : {}),
        },
      });
    } else {
      attachments.push({
        type: 'file',
        attachment: {
          attachmentId: `wb-file:${filePath}`,
          name: name || path.basename(filePath),
          ...(bytes !== undefined ? { bytes } : {}),
        },
      });
    }
  }
  return { text: cleanText, attachments };
}

/**
 * 仅剥离桥接层附件注入块，返回纯净用户输入正文（用于标题提取与去重比对）。
 *
 * @param {unknown} rawText
 * @returns {string}
 */
export function stripBridgeAttachmentBlock(rawText) {
  return extractBridgeAttachmentsFromText(rawText).text;
}

/**
 * 校验外部会话 rawId，防止路径穿越或非法字符注入。
 *
 * @param {unknown} rawId
 * @returns {boolean}
 */
export function isSafeSessionId(rawId) {
  return typeof rawId === 'string' && /^[A-Za-z0-9._-]{1,128}$/.test(rawId) && !rawId.includes('..');
}

/**
 * 将 `file:///...` URI 解码为本地系统路径。
 *
 * @param {string} uri
 * @returns {string}
 */
export function decodeFileUri(uri) {
  if (typeof uri !== 'string' || !uri) return '';
  if (!uri.startsWith('file://')) return uri;
  try {
    const parsed = new URL(uri);
    let p = decodeURIComponent(parsed.pathname || '');
    // Windows 下 /d:/dev/... 去掉前导斜杠
    if (/^\/[A-Za-z]:/.test(p)) p = p.slice(1);
    return p;
  } catch {
    return uri;
  }
}

/**
 * 将各种时间格式转为毫秒时间戳，失败时返回 0。
 *
 * @param {unknown} value
 * @returns {number}
 */
export function toEpochMs(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value > 1e12 ? Math.trunc(value) : Math.trunc(value * 1000);
  }
  if (typeof value === 'string' && value.trim()) {
    const num = Number(value);
    if (Number.isFinite(num) && num > 0) return toEpochMs(num);
    // 兼容 SQLite datetime 字符串（如 "2026-11-23 10:18:13.9291599+00:00"）
    const normalized = value.trim().replace(/^(\d{4}-\d{2}-\d{2})\s+/, '$1T');
    const ms = Date.parse(normalized);
    if (Number.isFinite(ms)) return ms;
  }
  return 0;
}

/**
 * 提取 Antigravity 用户输入正文（剥离 <USER_REQUEST> 与 <ADDITIONAL_METADATA> 外壳）。
 *
 * @param {string} raw
 * @returns {string}
 */
export function unwrapUserRequest(raw) {
  if (typeof raw !== 'string') return '';
  const match = raw.match(/<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/);
  const inner = match
    ? match[1]
    : raw.replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/g, '');
  return inner.replace(/<HANDOFF_CONTEXT>[\s\S]*?<\/HANDOFF_CONTEXT>\s*/g, '').trim();
}

/**
 * 安全逐行读取 UTF-8 JSONL 文件；跳过空行与损坏行，不抛异常。
 *
 * @param {string} filePath
 * @returns {Array<object>}
 */
export function readJsonlSafe(filePath) {
  let content;
  try {
    content = fs.readFileSync(filePath, 'utf8');
  } catch {
    return [];
  }
  const rows = [];
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const parsed = JSON.parse(trimmed);
      if (parsed && typeof parsed === 'object') rows.push(parsed);
    } catch {
      // 忽略写入中的半行或损坏 JSON
    }
  }
  return rows;
}

/**
 * 递归查找目录下的匹配文件。
 *
 * @param {string} rootDir
 * @param {(fullPath: string, name: string) => boolean} matcher
 * @param {number} [maxDepth=5]
 * @returns {string[]}
 */
export function walkFiles(rootDir, matcher, maxDepth = 5) {
  const out = [];
  if (!rootDir || !fs.existsSync(rootDir)) return out;
  function visit(dir, depth) {
    if (depth > maxDepth) return;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        visit(full, depth + 1);
      } else if (entry.isFile() && matcher(full, entry.name)) {
        out.push(full);
      }
    }
  }
  visit(rootDir, 0);
  return out;
}

/**
 * 根据字符串内容生成强 ETag。
 *
 * @param {string} text
 * @returns {string}
 */
export function computeEtag(text) {
  return `"${crypto.createHash('sha256').update(text).digest('hex').slice(0, 24)}"`;
}

/**
 * 在 PATH 及常见系统路径中定位可执行文件。
 *
 * @param {string[]} candidates
 * @returns {string | null}
 */
export function resolveExecutable(candidates) {
  const pathEnv = process.env.PATH || '';
  const dirs = pathEnv.split(path.delimiter).filter(Boolean);
  const exts = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
  for (const candidate of candidates) {
    if (path.isAbsolute(candidate) && fs.existsSync(candidate)) return candidate;
    for (const dir of dirs) {
      for (const ext of exts) {
        const full = path.join(dir, candidate.endsWith(ext) ? candidate : `${candidate}${ext}`);
        try {
          if (fs.statSync(full).isFile()) return full;
        } catch {
          // 忽略不存在的路径
        }
      }
    }
  }
  return null;
}
