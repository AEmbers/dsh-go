/**
 * @file 外部智能体会话工作区与附件文件的宿主机读取、文本分页与目录枚举接口。
 */
import fs from 'node:fs';
import path from 'node:path';

import { CLI_ENGINES, decodeFileUri, isSafeSessionId } from './scanners/common.js';
import { scanAllCliSessions } from './scanners/index.js';

const MAX_READ_BYTES_WINDOW = 1024 * 1024;
const DEFAULT_READ_BYTES_WINDOW = 512 * 1024;
const MAX_TEXT_FILE_BYTES = 16 * 1024 * 1024;
const MAX_TEXT_PAGE_BYTES = 2 * 1024 * 1024;
const MAX_TEXT_PAGE_LINES = 5000;
const MAX_LIST_ENTRIES = 2000;

/**
 * 构造统一错误对象，供 HTTP 与 E2EE RPC 路由透传 `workspace-file/*` 错误码。
 *
 * @param {number} status
 * @param {string} code
 * @param {string} message
 * @returns {Error & { status: number, code: string }}
 */
function fileError(status, code, message) {
  const err = new Error(message);
  err.status = status;
  err.code = code;
  return err;
}

/**
 * 规范化客户端传入的宿主机文件路径（兼容 `file://`、`/C:/...` 与相对路径）。
 *
 * @param {unknown} rawPath
 * @param {{ cwd?: string | null }} [options]
 * @returns {string}
 */
export function normalizeHostFilePath(rawPath, options = {}) {
  if (typeof rawPath !== 'string') {
    throw fileError(400, 'workspace-file/not-found', 'File path is required');
  }
  let clean = rawPath.trim();
  if (!clean || clean.includes('\0')) {
    throw fileError(400, 'workspace-file/not-found', 'Invalid file path');
  }
  if (clean.startsWith('file://')) {
    clean = decodeFileUri(clean);
  }
  if (!clean || clean.includes('\0')) {
    throw fileError(400, 'workspace-file/not-found', 'Invalid file URI');
  }
  if (/^\/[A-Za-z]:[\\/]/.test(clean)) {
    clean = clean.slice(1);
  }
  // 处理不带 file:// 的行号锚点或查询串（仅当按字面路径不存在时尝试剥离）
  if (!fs.existsSync(clean) && /[?#]/.test(clean)) {
    const stripped = clean.replace(/[?#].*$/, '');
    if (stripped) clean = stripped;
  }

  const isWinAbs = /^[A-Za-z]:[\\/]/.test(clean) || /^\\\\/.test(clean);
  const isPosixAbs = clean.startsWith('/');
  if (!isWinAbs && !isPosixAbs) {
    const cwd = typeof options.cwd === 'string' ? options.cwd.trim() : '';
    if (cwd) {
      clean = path.resolve(cwd, clean);
    } else {
      clean = path.resolve(clean);
    }
  }
  return path.normalize(clean);
}

/**
 * 解析指定外部 CLI 会话的工作区根目录。
 *
 * @param {string} engine
 * @param {string} rawId
 * @param {{ roots?: object, runner?: object }} [deps]
 * @returns {string | null}
 */
export function resolveSessionCwd(engine, rawId, deps = {}) {
  const overlayCwd = deps.runner?.getOverlay?.(engine, rawId)?.cwd;
  if (typeof overlayCwd === 'string' && overlayCwd.trim()) {
    return overlayCwd.trim();
  }
  const sessions = scanAllCliSessions({ roots: deps.roots, limit: 120 });
  const hit = sessions.find((s) => s.engine === engine && s.rawId === rawId);
  return typeof hit?.cwd === 'string' && hit.cwd.trim() ? hit.cwd.trim() : null;
}

/**
 * 解析目标文件的宿主机绝对路径（支持 `wb-upload:`、`wb-file:` 与常规工作区/绝对路径）。
 *
 * @param {{ engine: string, rawId: string, path: unknown }} input
 * @param {{ roots?: object, runner?: object }} [deps]
 * @returns {string}
 */
export function resolveTargetFilePath(input, deps = {}) {
  const engine = String(input?.engine || '');
  const rawId = String(input?.rawId || '');
  if (!CLI_ENGINES.has(engine) || !isSafeSessionId(rawId)) {
    throw fileError(400, 'invalid_target', 'Invalid engine or session id');
  }
  const rawPath = typeof input?.path === 'string' ? input.path.trim() : '';
  if (!rawPath) {
    throw fileError(400, 'workspace-file/not-found', 'File path is required');
  }
  if (rawPath.startsWith('wb-upload:')) {
    const uploadId = rawPath.slice('wb-upload:'.length).trim();
    const upload = deps.runner?.getUpload?.(uploadId);
    if (!upload || typeof upload.path !== 'string' || !fs.existsSync(upload.path)) {
      throw fileError(404, 'workspace-file/not-found', `Upload not found: ${uploadId}`);
    }
    return upload.path;
  }
  if (rawPath.startsWith('wb-file:')) {
    const inner = rawPath.slice('wb-file:'.length);
    return normalizeHostFilePath(inner, { cwd: resolveSessionCwd(engine, rawId, deps) });
  }
  const cwd = resolveSessionCwd(engine, rawId, deps);
  return normalizeHostFilePath(rawPath, { cwd });
}

/**
 * 生成与客户端 `modifiedFromVersion` 兼容的 5 段纯数字文件版本标识。
 *
 * @param {fs.Stats} stat
 * @returns {string}
 */
export function fileVersionToken(stat) {
  const dev = Math.max(0, Math.trunc(Number(stat.dev) || 0));
  const ino = Math.max(0, Math.trunc(Number(stat.ino) || 0));
  const size = Math.max(0, Math.trunc(Number(stat.size) || 0));
  const mtimeNs = Math.max(0, Math.trunc((Number(stat.mtimeMs) || 0) * 1e6));
  const ctimeNs = Math.max(0, Math.trunc((Number(stat.ctimeMs) || 0) * 1e6));
  return `${dev}:${ino}:${size}:${mtimeNs}:${ctimeNs}`;
}

/**
 * 将 Node `fs` 错误映射为标准的 `workspace-file/*` 异常。
 *
 * @param {any} err
 * @param {string} targetPath
 * @returns {Error}
 */
function mapFsError(err, targetPath) {
  const code = err?.code;
  if (code === 'ENOENT' || code === 'ENOTDIR') {
    return fileError(404, 'workspace-file/not-found', `File not found: ${targetPath}`);
  }
  if (code === 'EACCES' || code === 'EPERM') {
    return fileError(403, 'workspace-file/not-allowed', `Permission denied: ${targetPath}`);
  }
  return fileError(500, 'workspace-file/read-failed', String(err?.message || err));
}

function statRegularFile(targetPath) {
  let stat;
  try {
    stat = fs.statSync(targetPath);
  } catch (err) {
    throw mapFsError(err, targetPath);
  }
  if (!stat.isFile()) {
    throw fileError(400, 'workspace-file/not-regular-file', `Not a regular file: ${targetPath}`);
  }
  return stat;
}

/**
 * 读取文件元信息（`workspaceFiles/stat` 等价实现）。
 *
 * @param {{ engine: string, rawId: string, path: unknown }} input
 * @param {{ roots?: object, runner?: object }} [deps]
 */
export function statBridgeFile(input, deps = {}) {
  const absolutePath = resolveTargetFilePath(input, deps);
  const stat = statRegularFile(absolutePath);
  return {
    ok: true,
    absolutePath,
    version: fileVersionToken(stat),
    bytes: stat.size,
  };
}

/**
 * 按字节窗口分页读取文件（`workspaceFiles/readBytes` 等价实现）。
 *
 * @param {{ engine: string, rawId: string, path: unknown, offset?: number, length?: number }} input
 * @param {{ roots?: object, runner?: object }} [deps]
 */
export function readBridgeFileBytes(input, deps = {}) {
  const absolutePath = resolveTargetFilePath(input, deps);
  const stat = statRegularFile(absolutePath);
  const rawOffset = Number(input?.offset ?? 0);
  const offset = Number.isFinite(rawOffset) && rawOffset >= 0 ? Math.trunc(rawOffset) : 0;
  const rawLength = Number(input?.length ?? DEFAULT_READ_BYTES_WINDOW);
  const length = Number.isFinite(rawLength)
    ? Math.max(1, Math.min(MAX_READ_BYTES_WINDOW, Math.trunc(rawLength)))
    : DEFAULT_READ_BYTES_WINDOW;

  if (offset >= stat.size) {
    return {
      ok: true,
      data: '',
      eof: true,
      offset,
      absolutePath,
      version: fileVersionToken(stat),
      bytes: stat.size,
    };
  }

  const toRead = Math.min(length, stat.size - offset);
  const buf = Buffer.allocUnsafe(toRead);
  let fd;
  let bytesRead = 0;
  try {
    fd = fs.openSync(absolutePath, 'r');
    while (bytesRead < toRead) {
      const n = fs.readSync(fd, buf, bytesRead, toRead - bytesRead, offset + bytesRead);
      if (n <= 0) break;
      bytesRead += n;
    }
  } catch (err) {
    throw mapFsError(err, absolutePath);
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {
        // ignore
      }
    }
  }

  const slice = bytesRead === toRead ? buf : buf.subarray(0, bytesRead);
  return {
    ok: true,
    data: slice.toString('base64'),
    eof: offset + bytesRead >= stat.size,
    offset,
    absolutePath,
    version: fileVersionToken(stat),
    bytes: stat.size,
  };
}

/**
 * 按行分页读取 UTF-8 文本文件（`workspaceFiles/read` 等价实现）。
 *
 * @param {{ engine: string, rawId: string, path: unknown, offset?: number, limit?: number }} input
 * @param {{ roots?: object, runner?: object }} [deps]
 */
export function readBridgeFileText(input, deps = {}) {
  const absolutePath = resolveTargetFilePath(input, deps);
  const stat = statRegularFile(absolutePath);
  if (stat.size > MAX_TEXT_FILE_BYTES) {
    throw fileError(413, 'workspace-file/too-large', `File too large to read as text: ${stat.size} bytes`);
  }

  let buf;
  try {
    buf = fs.readFileSync(absolutePath);
  } catch (err) {
    throw mapFsError(err, absolutePath);
  }

  const probeLen = Math.min(buf.length, 8192);
  for (let i = 0; i < probeLen; i += 1) {
    if (buf[i] === 0) {
      throw fileError(400, 'workspace-file/not-text', `Binary file cannot be read as text: ${absolutePath}`);
    }
  }

  const rawOffset = Number(input?.offset ?? 1);
  const offset = Number.isFinite(rawOffset) && rawOffset >= 1 ? Math.trunc(rawOffset) : 1;
  const rawLimit = Number(input?.limit ?? 500);
  const limit = Number.isFinite(rawLimit)
    ? Math.max(1, Math.min(MAX_TEXT_PAGE_LINES, Math.trunc(rawLimit)))
    : 500;

  const content = buf.toString('utf8');
  if (content.length === 0) {
    return {
      ok: true,
      text: '',
      lines: 0,
      eof: true,
      offset,
      absolutePath,
      version: fileVersionToken(stat),
      bytes: stat.size,
    };
  }

  const allLines = content.split(/\r?\n/);
  // 去掉文件末尾由最后一行换行符产生的多余空元素
  if (allLines.length > 1 && allLines[allLines.length - 1] === '') {
    allLines.pop();
  }
  const startIndex = offset - 1;
  if (startIndex >= allLines.length) {
    return {
      ok: true,
      text: '',
      lines: 0,
      eof: true,
      offset,
      absolutePath,
      version: fileVersionToken(stat),
      bytes: stat.size,
    };
  }

  const picked = [];
  let pageBytes = 0;
  let endIndex = startIndex;
  for (let i = startIndex; i < allLines.length && picked.length < limit; i += 1) {
    const line = allLines[i];
    const addedBytes = Buffer.byteLength(line, 'utf8') + (picked.length > 0 ? 1 : 0);
    if (pageBytes + addedBytes > MAX_TEXT_PAGE_BYTES) {
      if (picked.length === 0) {
        throw fileError(413, 'workspace-file/too-large', 'Line exceeds 2 MiB text page limit');
      }
      break;
    }
    picked.push(line);
    pageBytes += addedBytes;
    endIndex = i + 1;
  }

  return {
    ok: true,
    text: picked.join('\n'),
    lines: picked.length,
    eof: endIndex >= allLines.length,
    offset,
    absolutePath,
    version: fileVersionToken(stat),
    bytes: stat.size,
  };
}

/**
 * 枚举工作区目录直接子项（`workspaceFiles/list` 等价实现）。
 *
 * @param {{ engine: string, rawId: string, path?: unknown }} input
 * @param {{ roots?: object, runner?: object }} [deps]
 */
export function listBridgeDirectory(input, deps = {}) {
  const engine = String(input?.engine || '');
  const rawId = String(input?.rawId || '');
  if (!CLI_ENGINES.has(engine) || !isSafeSessionId(rawId)) {
    throw fileError(400, 'invalid_target', 'Invalid engine or session id');
  }
  const cwd = resolveSessionCwd(engine, rawId, deps);
  const rawPath = typeof input?.path === 'string' ? input.path.trim() : '';
  const targetDir =
    !rawPath || rawPath === '.'
      ? cwd
        ? path.normalize(cwd)
        : process.cwd()
      : normalizeHostFilePath(rawPath, { cwd });

  let stat;
  try {
    stat = fs.statSync(targetDir);
  } catch (err) {
    throw mapFsError(err, targetDir);
  }
  if (!stat.isDirectory()) {
    throw fileError(400, 'workspace-file/not-regular-file', `Not a directory: ${targetDir}`);
  }

  let dirents;
  try {
    dirents = fs.readdirSync(targetDir, { withFileTypes: true });
  } catch (err) {
    throw mapFsError(err, targetDir);
  }

  const truncated = dirents.length > MAX_LIST_ENTRIES;
  const entries = [];
  for (const dirent of dirents.slice(0, MAX_LIST_ENTRIES)) {
    let type = 'other';
    let size;
    if (dirent.isDirectory()) {
      type = 'directory';
    } else if (dirent.isFile()) {
      type = 'file';
      try {
        size = fs.statSync(path.join(targetDir, dirent.name)).size;
      } catch {
        // ignore stat failure on entry
      }
    } else if (dirent.isSymbolicLink()) {
      try {
        const s = fs.statSync(path.join(targetDir, dirent.name));
        if (s.isDirectory()) type = 'directory';
        else if (s.isFile()) {
          type = 'file';
          size = s.size;
        }
      } catch {
        // broken symlink stays 'other'
      }
    }
    entries.push({ name: dirent.name, type, ...(size !== undefined ? { size } : {}) });
  }

  return {
    ok: true,
    path: rawPath && rawPath !== '.' ? targetDir : '',
    entries,
    truncated,
  };
}
