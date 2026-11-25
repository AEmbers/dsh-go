/**
 * @file Antigravity 会话摘要与对话记录解析器。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import {
  decodeFileUri,
  extractBridgeAttachmentsFromText,
  isSafeSessionId,
  normalizeCliToolName,
  readJsonlSafe,
  stripBridgeAttachmentBlock,
  toEpochMs,
  unwrapUserRequest,
} from './common.js';

/**
 * 解析 Antigravity 工作区 URI JSON 数组并取首个工作区路径。
 *
 * @param {string} rawUris
 * @returns {string | null}
 */
function parseWorkspaceUri(rawUris) {
  if (typeof rawUris !== 'string' || !rawUris.trim()) return null;
  try {
    const arr = JSON.parse(rawUris);
    if (Array.isArray(arr) && typeof arr[0] === 'string') {
      const decoded = decodeFileUri(arr[0]);
      return decoded || null;
    }
  } catch {
    // 忽略非 JSON 格式
  }
  return null;
}

/**
 * 从 transcript.jsonl 头部快速提取首条用户输入作为标题回退（不读取完整大文件）。
 *
 * @param {string} rootDir
 * @param {string} conversationId
 * @returns {string | null}
 */
function readTitleFromTranscriptHead(rootDir, conversationId) {
  const logPath = path.join(rootDir, 'brain', conversationId, '.system_generated', 'logs', 'transcript.jsonl');
  if (!fs.existsSync(logPath)) return null;
  let fd;
  try {
    fd = fs.openSync(logPath, 'r');
    const buf = Buffer.alloc(64 * 1024);
    const bytesRead = fs.readSync(fd, buf, 0, buf.length, 0);
    const lines = buf.toString('utf8', 0, bytesRead).split(/\r?\n/);
    for (const line of lines) {
      if (!line.trim()) continue;
      let row;
      try {
        row = JSON.parse(line);
      } catch {
        continue;
      }
      if (row && row.type === 'USER_INPUT' && row.source === 'USER_EXPLICIT') {
        const text = stripBridgeAttachmentBlock(unwrapUserRequest(row.content)).split(/\r?\n/)[0].trim();
        if (text) return text.slice(0, 80);
      }
    }
  } catch {
    // 忽略读取异常
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {
        // ignore
      }
    }
  }
  return null;
}

/**
 * 解析需要扫描的 Antigravity 根目录列表（同时兼容 IDE 与 `agy` CLI 双目录）。
 *
 * @param {{ rootDir?: string, cliRootDir?: string }} [options]
 * @returns {string[]}
 */
function resolveAntigravityRoots(options = {}) {
  if (typeof options.rootDir === 'string' && options.rootDir.trim()) {
    const out = [options.rootDir.trim()];
    if (typeof options.cliRootDir === 'string' && options.cliRootDir.trim()) {
      const cli = options.cliRootDir.trim();
      if (!out.includes(cli)) out.push(cli);
    }
    return out;
  }
  const home = os.homedir();
  return [path.join(home, '.gemini', 'antigravity'), path.join(home, '.gemini', 'antigravity-cli')];
}

/**
 * 扫描单个 Antigravity 根目录下的会话摘要（优先读只读 SQLite，失败时回退扫描 brain 目录）。
 *
 * @param {string} rootDir
 * @param {number} limit
 * @returns {Array<object>}
 */
function scanSingleAntigravityRoot(rootDir, limit) {
  const dbPath = path.join(rootDir, 'conversation_summaries.db');

  if (fs.existsSync(dbPath)) {
    let db;
    try {
      db = new DatabaseSync(dbPath, { readOnly: true });
      const rows = db
        .prepare(
          `SELECT conversation_id, title, preview, workspace_uris, last_modified_time, not_fully_idle, killed
           FROM conversation_summaries
           ORDER BY last_modified_time DESC
           LIMIT ?`,
        )
        .all(limit);

      const items = [];
      for (const row of rows) {
        if (!isSafeSessionId(row.conversation_id)) continue;
        const rawSummary = String(row.title || row.preview || '').trim();
        const summaryTitle = rawSummary.startsWith('<HANDOFF_CONTEXT>') ? '' : rawSummary;
        const transcriptTitle = summaryTitle ? null : readTitleFromTranscriptHead(rootDir, String(row.conversation_id));
        const title = summaryTitle || transcriptTitle;
        // 无摘要且无用户显式提问（通常为后台子智能体会话）时跳过，避免侧栏充斥 UUID
        if (!title) continue;
        const updatedAt = toEpochMs(row.last_modified_time);
        const running = Boolean(row.not_fully_idle) && !row.killed;
        items.push({
          engine: 'antigravity',
          rawId: String(row.conversation_id),
          sessionId: `cli:antigravity:${row.conversation_id}`,
          title,
          cwd: parseWorkspaceUri(row.workspace_uris),
          updatedAt,
          running,
          blank: false,
          model: null,
        });
      }
      return items;
    } catch {
      // SQLite 被独占锁或损坏时回退目录扫描
    } finally {
      try {
        db?.close();
      } catch {
        // ignore
      }
    }
  }

  // 回退扫描 brain/<id>/.system_generated/logs/transcript.jsonl
  const brainDir = path.join(rootDir, 'brain');
  if (!fs.existsSync(brainDir)) return [];
  let entries = [];
  try {
    entries = fs.readdirSync(brainDir, { withFileTypes: true });
  } catch {
    return [];
  }
  const results = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !isSafeSessionId(entry.name)) continue;
    const logPath = path.join(brainDir, entry.name, '.system_generated', 'logs', 'transcript.jsonl');
    if (!fs.existsSync(logPath)) continue;
    let stat;
    try {
      stat = fs.statSync(logPath);
    } catch {
      continue;
    }
    const rows = readJsonlSafe(logPath);
    const firstUser = rows.find((r) => r.type === 'USER_INPUT');
    const title = firstUser ? unwrapUserRequest(firstUser.content).split(/\r?\n/)[0].slice(0, 80) : entry.name;
    results.push({
      engine: 'antigravity',
      rawId: entry.name,
      sessionId: `cli:antigravity:${entry.name}`,
      title: title || entry.name,
      cwd: null,
      updatedAt: Math.trunc(stat.mtimeMs),
      running: false,
      blank: rows.length === 0,
      model: null,
    });
  }
  results.sort((a, b) => b.updatedAt - a.updatedAt);
  return results.slice(0, limit);
}

/**
 * 扫描 Antigravity 会话摘要列表（合并 IDE 与 `agy` CLI 双目录，按 `rawId` 去重）。
 *
 * @param {{ rootDir?: string, cliRootDir?: string, limit?: number }} [options]
 * @returns {Array<object>}
 */
export function scanAntigravitySessions(options = {}) {
  const roots = resolveAntigravityRoots(options);
  const limit = options.limit ?? 80;
  const byId = new Map();

  for (const rootDir of roots) {
    for (const item of scanSingleAntigravityRoot(rootDir, limit)) {
      const prev = byId.get(item.rawId);
      if (!prev) {
        byId.set(item.rawId, item);
        continue;
      }
      byId.set(item.rawId, {
        ...prev,
        ...item,
        title: (item.updatedAt >= prev.updatedAt ? item.title : prev.title) || prev.title || item.title,
        cwd: item.cwd || prev.cwd,
        updatedAt: Math.max(prev.updatedAt, item.updatedAt),
        running: Boolean(prev.running || item.running),
      });
    }
  }

  const merged = [...byId.values()];
  merged.sort((a, b) => b.updatedAt - a.updatedAt);
  return merged.slice(0, limit);
}

/**
 * 检查指定 Antigravity 会话当前是否在桌面端或本地进程中活跃运行。
 *
 * @param {string} rootDir
 * @param {string} rawId
 * @param {string} logPath
 * @param {Array<object>} rows
 * @returns {boolean}
 */
function isAntigravityRunning(rootDir, rawId, logPath, rows) {
  const dbPath = path.join(rootDir, 'conversation_summaries.db');
  if (fs.existsSync(dbPath)) {
    let db;
    try {
      db = new DatabaseSync(dbPath, { readOnly: true });
      const row = db
        .prepare('SELECT not_fully_idle, killed FROM conversation_summaries WHERE conversation_id = ? LIMIT 1')
        .get(rawId);
      if (row) {
        return Boolean(row.not_fully_idle) && !row.killed;
      }
    } catch {
      // 忽略 SQLite 锁/异常并回退文件时间判定
    } finally {
      try {
        db?.close();
      } catch {
        // ignore
      }
    }
  }
  try {
    if (fs.existsSync(logPath)) {
      const stat = fs.statSync(logPath);
      if (Date.now() - stat.mtimeMs < 12_000 && rows.length > 0) {
        const last = rows[rows.length - 1];
        if (last?.type === 'USER_INPUT' || (typeof last?.status === 'string' && last.status !== 'DONE')) {
          return true;
        }
      }
    }
  } catch {
    // ignore
  }
  return false;
}

const MAX_AGY_CACHE = 64;
/** @type {Map<string, { mtimeMs: number, size: number, leftover: string, messages: Array<object>, model: string | null, lastRow: object | null }>} */
const antigravityTranscriptCache = new Map();

/**
 * 将单条 Antigravity `transcript.jsonl` 记录追加到消息列表（供全量与增量读取共用）。
 *
 * @param {object} row
 * @param {{ messages: Array<object>, model: string | null, lastRow: object | null }} acc
 */
function appendAntigravityRow(row, acc) {
  acc.lastRow = row;
  const createdAt = toEpochMs(row.created_at);
  const id = `agy-${row.step_index ?? acc.messages.length}`;

  if (row.type === 'USER_INPUT' && row.source === 'USER_EXPLICIT') {
    const unwrapped = unwrapUserRequest(row.content);
    const extracted = extractBridgeAttachmentsFromText(unwrapped);
    const text = extracted.text;
    const seenAttachmentIds = new Set();
    const mediaParts = [];

    const pushAttachment = (part) => {
      const aid = part?.attachment?.attachmentId;
      if (aid && seenAttachmentIds.has(aid)) return;
      if (aid) seenAttachmentIds.add(aid);
      mediaParts.push(part);
    };

    if (Array.isArray(row.media)) {
      for (const m of row.media) {
        if (!m || typeof m !== 'object') continue;
        const mime = typeof m.mime_type === 'string' ? m.mime_type.trim() : '';
        const rawUri = typeof m.uri === 'string' ? m.uri.trim() : '';
        if (!mime || !/^image\//i.test(mime) || !rawUri) continue;
        let filePath = decodeFileUri(rawUri);
        if (/^\/[A-Za-z]:[\\/]/.test(filePath)) filePath = filePath.slice(1);
        if (!filePath) continue;
        let bytes;
        try {
          if (fs.existsSync(filePath)) {
            bytes = fs.statSync(filePath).size;
          }
        } catch {
          // ignore stat error
        }
        pushAttachment({
          type: 'image',
          attachment: {
            attachmentId: `wb-file:${filePath}`,
            mediaType: mime,
            name: path.basename(filePath),
            ...(bytes !== undefined ? { bytes } : {}),
          },
        });
      }
    }
    for (const part of extracted.attachments) {
      pushAttachment(part);
    }

    if (!text && mediaParts.length === 0) return;
    const parts = [];
    if (text) parts.push({ type: 'text', text });
    parts.push(...mediaParts);
    acc.messages.push({
      messageId: id,
      role: 'user',
      createdAt,
      parts,
    });
    return;
  }

  if (row.type === 'PLANNER_RESPONSE') {
    if (typeof row.model === 'string' && row.model) acc.model = row.model;
    const parts = [];
    if (typeof row.thinking === 'string' && row.thinking.trim()) {
      parts.push({ type: 'reasoning', text: row.thinking });
    }
    if (Array.isArray(row.tool_calls)) {
      for (const call of row.tool_calls) {
        if (!call || typeof call !== 'object') continue;
        const args =
          typeof call.arguments === 'string'
            ? call.arguments
            : JSON.stringify(call.arguments ?? call.args ?? {});
        parts.push({
          type: 'tool-call',
          id: String(call.id || `${id}-tool-${parts.length}`),
          name: normalizeCliToolName(call.name),
          arguments: args,
        });
      }
    }
    if (typeof row.content === 'string' && row.content.trim()) {
      parts.push({ type: 'text', text: row.content });
    }
    if (parts.length === 0) return;
    acc.messages.push({
      messageId: id,
      role: 'assistant',
      createdAt,
      model: typeof row.model === 'string' ? row.model : null,
      parts,
    });
  }
}

/**
 * 增量读取并解析 JSONL 文件：未变化 0ms 命中缓存，末尾追加仅读新增字节，缩短或重建时回退全量读取。
 *
 * @param {string} logPath
 * @returns {{ messages: Array<object>, model: string | null, lastRow: object | null }}
 */
function readAntigravityTranscriptCached(logPath) {
  let stat;
  try {
    stat = fs.statSync(logPath);
  } catch {
    antigravityTranscriptCache.delete(logPath);
    return { messages: [], model: null, lastRow: null };
  }
  const cached = antigravityTranscriptCache.get(logPath);
  if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) {
    return cached;
  }

  const consumeChunk = (acc, rawChunk) => {
    const combined = (acc.leftover || '') + rawChunk;
    const lines = combined.split(/\r?\n/);
    acc.leftover = lines.pop() ?? '';
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const parsed = JSON.parse(trimmed);
        if (parsed && typeof parsed === 'object') appendAntigravityRow(parsed, acc);
      } catch {
        // 忽略半行或损坏 JSON
      }
    }
  };

  if (cached && stat.size > cached.size) {
    let fd;
    try {
      const deltaBytes = stat.size - cached.size;
      const buf = Buffer.allocUnsafe(deltaBytes);
      fd = fs.openSync(logPath, 'r');
      const readBytes = fs.readSync(fd, buf, 0, deltaBytes, cached.size);
      consumeChunk(cached, buf.toString('utf8', 0, readBytes));
      cached.size = cached.size + readBytes;
      cached.mtimeMs = stat.mtimeMs;
      // 如果末尾正好是一条完整 JSON 行且没有尾随换行，也尝试立即解析，避免最后一行迟滞
      if (cached.leftover.trim()) {
        try {
          const parsed = JSON.parse(cached.leftover.trim());
          if (parsed && typeof parsed === 'object') {
            appendAntigravityRow(parsed, cached);
            cached.leftover = '';
          }
        } catch {
          // 仍在写入中的半行，留待下次拼接
        }
      }
      return cached;
    } catch {
      // 增量读取失败则回退全量读取
    } finally {
      if (fd !== undefined) {
        try {
          fs.closeSync(fd);
        } catch {
          // ignore
        }
      }
    }
  }

  const acc = {
    mtimeMs: stat.mtimeMs,
    size: stat.size,
    leftover: '',
    messages: [],
    model: null,
    lastRow: null,
  };
  try {
    const content = fs.readFileSync(logPath, 'utf8');
    consumeChunk(acc, content);
    if (acc.leftover.trim()) {
      try {
        const parsed = JSON.parse(acc.leftover.trim());
        if (parsed && typeof parsed === 'object') {
          appendAntigravityRow(parsed, acc);
          acc.leftover = '';
        }
      } catch {
        // 忽略末尾未写完的半行
      }
    }
  } catch {
    return { messages: [], model: null, lastRow: null };
  }

  antigravityTranscriptCache.delete(logPath);
  antigravityTranscriptCache.set(logPath, acc);
  if (antigravityTranscriptCache.size > MAX_AGY_CACHE) {
    const oldestKey = antigravityTranscriptCache.keys().next().value;
    if (oldestKey) antigravityTranscriptCache.delete(oldestKey);
  }
  return acc;
}

/**
 * 读取指定 Antigravity 会话的标准化消息列表。
 *
 * @param {string} rawId
 * @param {{ rootDir?: string }} [options]
 * @returns {{ messages: Array<object>, model: string | null, running: boolean, logPath?: string }}
 */
export function readAntigravityMessages(rawId, options = {}) {
  if (!isSafeSessionId(rawId)) return { messages: [], model: null, running: false };
  const roots = resolveAntigravityRoots(options);
  let rootDir = roots[0];
  let logPath = path.join(rootDir, 'brain', rawId, '.system_generated', 'logs', 'transcript.jsonl');
  let newestMtime = -1;
  for (const candidateRoot of roots) {
    const candidateLog = path.join(candidateRoot, 'brain', rawId, '.system_generated', 'logs', 'transcript.jsonl');
    try {
      if (fs.existsSync(candidateLog)) {
        const mtime = fs.statSync(candidateLog).mtimeMs;
        if (mtime > newestMtime) {
          newestMtime = mtime;
          rootDir = candidateRoot;
          logPath = candidateLog;
        }
      }
    } catch {
      // ignore stat failure
    }
  }
  const parsed = readAntigravityTranscriptCached(logPath);
  const tailRows = parsed.lastRow ? [parsed.lastRow] : [];
  const running = isAntigravityRunning(rootDir, rawId, logPath, tailRows);
  return { messages: parsed.messages, model: parsed.model, running, logPath };
}
