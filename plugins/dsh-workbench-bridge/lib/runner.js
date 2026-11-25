/**
 * @file 外部 CLI 非交互执行与运行态管理（支持 Antigravity / Claude / Codex）。
 */
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { AntigravityAcpClient } from './acp.js';
import { AntigravityDesktopCdpClient } from './desktop_cdp.js';
import { resolveAntigravityWireModel } from './models.js';
import { readAntigravityMessages, scanAntigravitySessions } from './scanners/antigravity.js';
import { CLI_ENGINES, isSafeSessionId, normalizeCliToolName, resolveExecutable } from './scanners/common.js';

const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
const UPLOAD_TTL_MS = 2 * 60 * 60 * 1000;
const IMAGE_MIME_RE = /^image\//i;
const IMAGE_EXT_RE = /\.(png|jpe?g|webp|gif|bmp|heic|heif)$/i;
export const IDE_READONLY_MESSAGE =
  '该会话由桌面端 Antigravity IDE 独占管理，移动端当前仅支持实时查看；请点击顶部「+」在 Antigravity 标签页新开会话进行对话。';

/**
 * 清洗上传文件名，防止路径穿越或非法控制字符。
 *
 * @param {string} rawName
 * @returns {string}
 */
function sanitizeUploadName(rawName) {
  const base = path.basename(String(rawName || 'attachment.bin')).replace(/[^\w.\-()\u4e00-\u9fa5]+/g, '_');
  const trimmed = base.replace(/^\.+/, '') || 'attachment.bin';
  return trimmed.slice(0, 96);
}

/**
 * 为指定 CLI 引擎构造命令行与参数列表。
 *
 * @param {'antigravity' | 'claude' | 'codex'} engine
 * @param {{
 *   rawSessionId?: string | null,
 *   prompt: string,
 *   model?: string | null,
 *   reasoningEffort?: string | null,
 *   addDirs?: string[],
 *   imagePaths?: string[],
 * }} req
 * @returns {{ binCandidates: string[], args: string[] }}
 */
export function buildCliCommand(engine, req) {
  const prompt = req.prompt;
  const rawId = req.rawSessionId && isSafeSessionId(req.rawSessionId) ? req.rawSessionId : null;
  const model = typeof req.model === 'string' && req.model.trim() ? req.model.trim() : null;
  const effort = typeof req.reasoningEffort === 'string' && req.reasoningEffort.trim() ? req.reasoningEffort.trim() : null;
  const addDirs = Array.isArray(req.addDirs) ? req.addDirs.filter((d) => typeof d === 'string' && d) : [];
  const imagePaths = Array.isArray(req.imagePaths) ? req.imagePaths.filter((p) => typeof p === 'string' && p) : [];

  switch (engine) {
    case 'antigravity': {
      const resolved = resolveAntigravityWireModel(model, effort);
      const args = ['--output-format', 'stream-json'];
      if (rawId) args.push('--conversation', rawId);
      if (resolved.model) args.push('--model', resolved.model);
      if (resolved.effort) args.push('--effort', resolved.effort);
      for (const dir of addDirs) args.push('--add-dir', dir);
      // agy 的 --print 为带值 flag，需通过 `--print=<prompt>` 传值避免吞掉后续参数
      args.push(`--print=${prompt}`);
      return { binCandidates: ['agy'], args };
    }
    case 'claude': {
      const args = ['-p', '--output-format', 'stream-json', '--verbose'];
      if (rawId) args.push('--resume', rawId);
      if (model) args.push('--model', model);
      for (const dir of addDirs) args.push('--add-dir', dir);
      args.push(prompt);
      return { binCandidates: ['claude'], args };
    }
    case 'codex': {
      const args = ['exec', '--json'];
      if (model) args.push('-m', model);
      if (effort) args.push('-c', `model_reasoning_effort="${effort}"`);
      for (const imgPath of imagePaths) args.push('-i', imgPath);
      if (rawId) {
        args.push('resume', rawId, prompt);
      } else {
        args.push(prompt);
      }
      return { binCandidates: ['codex'], args };
    }
    default:
      throw new Error(`Unsupported CLI engine: ${engine}`);
  }
}

/**
 * 尝试从 CLI stream-json 单行输出中提取文本、增量片段、会话 ID 或思考内容。
 *
 * @param {string} line
 * @returns {{
 *   sessionId?: string,
 *   text?: string,
 *   textDelta?: string,
 *   reasoning?: string,
 *   reasoningDelta?: string,
 *   finalText?: string,
 * } | null}
 */
export function parseCliStreamLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    const obj = JSON.parse(trimmed);
    if (!obj || typeof obj !== 'object') return { text: trimmed };

    // Antigravity `agy --output-format stream-json` 事件流
    if (obj.event === 'init') {
      const sid = obj.conversation_id;
      return typeof sid === 'string' && isSafeSessionId(sid) ? { sessionId: sid } : null;
    }
    if (obj.event === 'step_update' && obj.step_update && typeof obj.step_update === 'object') {
      const su = obj.step_update;
      const sid = su.conversation_id;
      const textDelta = typeof su.text_delta === 'string' ? su.text_delta : undefined;
      const reasoningDelta = typeof su.thinking_delta === 'string' ? su.thinking_delta : undefined;
      const stepIndex = typeof su.step_index === 'number' ? su.step_index : undefined;
      const stepState = typeof su.state === 'string' ? su.state : undefined;
      const stepType = typeof su.step_type === 'string' ? su.step_type : undefined;
      return {
        sessionId: typeof sid === 'string' && isSafeSessionId(sid) ? sid : undefined,
        textDelta,
        reasoningDelta,
        stepIndex,
        stepState,
        stepType,
      };
    }
    if (obj.event === 'result' && obj.result && typeof obj.result === 'object') {
      const res = obj.result;
      const sid = res.conversation_id;
      const finalText = typeof res.response === 'string' ? res.response : undefined;
      return {
        sessionId: typeof sid === 'string' && isSafeSessionId(sid) ? sid : undefined,
        finalText,
      };
    }

    const sessionId = obj.session_id || obj.conversation_id || obj.thread_id || obj.sessionId;
    let text = '';
    let reasoning = '';

    if (typeof obj.delta?.text === 'string') text += obj.delta.text;
    if (typeof obj.text === 'string') text += obj.text;
    if (typeof obj.content === 'string') text += obj.content;
    if (typeof obj.result === 'string' && !text) text += obj.result;
    if (obj.type === 'assistant' && Array.isArray(obj.message?.content)) {
      for (const block of obj.message.content) {
        if (block?.type === 'text' && typeof block.text === 'string') text += block.text;
        if (block?.type === 'thinking' && typeof block.thinking === 'string') reasoning += block.thinking;
      }
    }
    if (obj.type === 'item.completed' && obj.item?.type === 'agent_message' && typeof obj.item.text === 'string') {
      text += obj.item.text;
    }

    return {
      sessionId: typeof sessionId === 'string' && isSafeSessionId(sessionId) ? sessionId : undefined,
      text: text || undefined,
      reasoning: reasoning || undefined,
    };
  } catch {
    return { text: trimmed };
  }
}

/**
 * 管理所有外部 CLI 正在运行与最近完成的任务，以及临时附件落盘。
 */
export class CliRunManager {
  /**
   * @param {{ spawnFn?: typeof spawn, resolveBinFn?: typeof resolveExecutable, uploadRoot?: string }} [deps]
   */
  constructor(deps = {}) {
    this._spawn = deps.spawnFn || spawn;
    this._resolveBin = deps.resolveBinFn || resolveExecutable;
    this._uploadRoot = deps.uploadRoot || path.join(os.homedir(), '.dsh', 'tmp', 'workbench-bridge-uploads');
    const hasCustomRoots = Boolean(deps.antigravityIdeRoot || deps.antigravityCliRoot);
    this._checkIdeReadonly = !deps.spawnFn || hasCustomRoots;
    this._antigravityIdeRoot = deps.antigravityIdeRoot || path.join(os.homedir(), '.gemini', 'antigravity');
    this._antigravityCliRoot = deps.antigravityCliRoot || path.join(os.homedir(), '.gemini', 'antigravity-cli');
    // 生产环境（未注入自定义 spawnFn）或显式指定 useAcp/acpClient 时，Antigravity 默认走常驻 agy acp 进程。
    this._useAcp = deps.useAcp !== undefined ? Boolean(deps.useAcp) : (!deps.spawnFn || Boolean(deps.acpClient));
    this._acp = deps.acpClient || (this._useAcp
      ? new AntigravityAcpClient({
          spawnFn: this._spawn,
          resolveBinFn: this._resolveBin,
        })
      : null);
    this._newAntigravitySessionMode = String(
      deps.newAntigravitySessionMode || process.env.DSH_ANTIGRAVITY_NEW_SESSION_MODE || 'desktop',
    ).trim().toLowerCase();
    const enableDefaultDesktopCdp = deps.useDesktopCdp !== undefined
      ? Boolean(deps.useDesktopCdp)
      : (!deps.spawnFn && !deps.acpClient);
    this._desktopCdp = deps.desktopCdpClient !== undefined
      ? deps.desktopCdpClient
      : (enableDefaultDesktopCdp
          ? new AntigravityDesktopCdpClient({ cdpUrl: deps.desktopCdpUrl })
          : null);
    if (this._desktopCdp && typeof this._desktopCdp.probeAvailability === 'function') {
      void this._desktopCdp.probeAvailability().catch(() => {});
    }
    /** @type {Map<string, object>} key: "engine:rawId" */
    this._runs = new Map();
    /** @type {Map<string, string>} key: "engine:pendingRawId" -> resolvedRawId */
    this._resolvedIds = new Map();
    /** @type {Map<string, { uploadId: string, path: string, dir: string, name: string, mediaType: string, bytes: number, done: boolean, createdAt: number }>} */
    this._uploads = new Map();
    /** @type {Map<string, Set<() => void>>} key: "engine:rawId" */
    this._listeners = new Map();
    /** @type {Map<string, ReturnType<typeof setTimeout>>} */
    this._notifyTimers = new Map();
  }

  /**
   * 订阅指定外部 CLI 会话的实时流式增量与状态变更（用于长轮询即时唤醒）。
   *
   * @param {string} engine
   * @param {string} rawId
   * @param {() => void} listener
   * @returns {() => void}
   */
  subscribe(engine, rawId, listener) {
    const key = `${engine}:${rawId}`;
    let set = this._listeners.get(key);
    if (!set) {
      set = new Set();
      this._listeners.set(key, set);
    }
    set.add(listener);
    return () => {
      const current = this._listeners.get(key);
      if (!current) return;
      current.delete(listener);
      if (current.size === 0) {
        this._listeners.delete(key);
      }
    };
  }

  /**
   * 触发指定会话的变更通知（流式增量默认 60ms 节流合并，启停事件立即唤醒）。
   *
   * @param {string} engine
   * @param {string} rawId
   * @param {{ immediate?: boolean }} [opts]
   */
  _emitChange(engine, rawId, opts = {}) {
    if (!rawId) return;
    const key = `${engine}:${rawId}`;
    const fire = () => {
      const t = this._notifyTimers.get(key);
      if (t) {
        clearTimeout(t);
        this._notifyTimers.delete(key);
      }
      const listeners = this._listeners.get(key);
      if (!listeners || listeners.size === 0) return;
      for (const fn of [...listeners]) {
        try {
          fn();
        } catch {
          // ignore listener error
        }
      }
    };
    if (opts.immediate) {
      fire();
      return;
    }
    if (this._notifyTimers.has(key)) return;
    this._notifyTimers.set(key, setTimeout(fire, 60));
  }

  _notifyState(state, opts = {}) {
    state.version = (state.version || 0) + 1;
    this._emitChange(state.engine, state.rawId, opts);
    if (state.resolvedRawId && state.resolvedRawId !== state.rawId) {
      this._emitChange(state.engine, state.resolvedRawId, opts);
    }
  }

  /**
   * 判断 Antigravity 会话是否仅存在于桌面 IDE 目录而不被 `agy` CLI 轨迹存储识别。
   *
   * @param {string} rawId
   * @returns {boolean}
   */
  _isIdeOnlyAntigravitySession(rawId) {
    if (!this._checkIdeReadonly || !rawId || rawId.startsWith('pending-')) return false;
    const cliDb = path.join(this._antigravityCliRoot, 'conversations', `${rawId}.db`);
    if (fs.existsSync(cliDb)) return false;
    const ideDb = path.join(this._antigravityIdeRoot, 'conversations', `${rawId}.db`);
    const ideBrain = path.join(this._antigravityIdeRoot, 'brain', rawId);
    return fs.existsSync(ideDb) || fs.existsSync(ideBrain);
  }

  /**
   * 检查 Antigravity 桌面版通道当前是否可用（供健康检查输出）。
   *
   * @returns {boolean}
   */
  isAntigravityDesktopAvailable() {
    return Boolean(this._desktopCdp?.enabled !== false && this._desktopCdp?.isAvailableSync?.());
  }

  /**
   * 返回当前配置的桌面版 CDP 地址。
   *
   * @returns {string | null}
   */
  get antigravityDesktopCdpUrl() {
    return this._desktopCdp?.cdpUrl || null;
  }

  /**
   * 只读检查桌面端 Antigravity 会话在 SQLite / transcript 中是否仍处于运行态。
   *
   * @param {string} rawId
   * @returns {boolean}
   */
  _isAntigravitySessionRunningOnDisk(rawId) {
    if (!rawId || !isSafeSessionId(rawId)) return false;
    const dbPath = path.join(this._antigravityIdeRoot, 'conversation_summaries.db');
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
        // 忽略瞬时锁异常
      } finally {
        try {
          db?.close();
        } catch {
          // ignore
        }
      }
    }
    const logPath = path.join(this._antigravityIdeRoot, 'brain', rawId, '.system_generated', 'logs', 'transcript.jsonl');
    try {
      if (fs.existsSync(logPath)) {
        const stat = fs.statSync(logPath);
        if (Date.now() - stat.mtimeMs < 6000) {
          return true;
        }
      }
    } catch {
      // ignore
    }
    return false;
  }

  /**
   * 为仅存在于 Antigravity IDE 的会话提取标题、工作区与最近多轮对话摘要，供 CLI 侧无感接续。
   *
   * @param {string} rawId
   * @returns {{ contextBlock: string, cwd: string | null, title: string | null }}
   */
  _buildIdeHandoffContext(rawId) {
    let title = null;
    let cwd = null;
    try {
      const summaries = scanAntigravitySessions({ rootDir: this._antigravityIdeRoot, limit: 100 });
      const hit = summaries.find((s) => s.rawId === rawId);
      if (hit) {
        title = hit.title || null;
        cwd = hit.cwd || null;
      }
    } catch {
      // ignore summary lookup failure
    }

    let historyLines = [];
    try {
      const read = readAntigravityMessages(rawId, { rootDir: this._antigravityIdeRoot });
      const recent = read.messages.slice(-8);
      let totalChars = 0;
      for (const m of recent) {
        const text = (m.parts || [])
          .filter((p) => p.type === 'text' && typeof p.text === 'string' && p.text.trim())
          .map((p) => p.text.trim())
          .join('\n');
        if (!text) continue;
        const snippet = text.length > 600 ? `${text.slice(0, 600)}…` : text;
        if (totalChars + snippet.length > 5000 && historyLines.length > 0) break;
        const label = m.role === 'user' ? '用户' : '助手';
        historyLines.push(`[${label}] ${snippet}`);
        totalChars += snippet.length;
      }
    } catch {
      // ignore history read failure
    }

    const header = [
      '以下是用户此前在 Antigravity IDE 桌面端会话中的历史上下文（移动端当前自动从该 IDE 会话接续对话，请直接基于这些上下文继续回答用户的新问题）：',
      title ? `会话标题：${title}` : null,
      cwd ? `工作区目录：${cwd}` : null,
    ].filter(Boolean);

    const body = historyLines.length > 0 ? historyLines.join('\n\n') : '(无更多文本历史)';
    const contextBlock = `<HANDOFF_CONTEXT>\n${header.join('\n')}\n\n${body}\n</HANDOFF_CONTEXT>`;
    return { contextBlock, cwd, title };
  }

  /**
   * 按 uploadId 获取当前缓存的已上传附件元信息。
   *
   * @param {string} uploadId
   * @returns {{ uploadId: string, path: string, dir: string, name: string, mediaType: string, bytes: number, done: boolean, createdAt: number } | null}
   */
  getUpload(uploadId) {
    this._pruneOldUploads();
    const key = typeof uploadId === 'string' ? uploadId.trim() : '';
    if (!key) return null;
    return this._uploads.get(key) ?? null;
  }

  _pruneOldUploads() {
    const cutoff = Date.now() - UPLOAD_TTL_MS;
    for (const [id, entry] of this._uploads.entries()) {
      if (entry.createdAt < cutoff) {
        this._uploads.delete(id);
        try {
          fs.rmSync(entry.dir, { recursive: true, force: true });
        } catch {
          // ignore
        }
      }
    }
  }

  /**
   * 接收分片或单次上传的附件并落盘，供后续 CLI prompt 引用。
   *
   * @param {{ uploadId?: string | null, name?: string, mediaType?: string, offset?: number, chunkBase64: string, done?: boolean }} input
   * @returns {{ ok: true, uploadId: string, name: string, mediaType: string, bytes: number, done: boolean }}
   */
  saveUploadChunk(input) {
    this._pruneOldUploads();
    const safeId = input.uploadId && isSafeSessionId(String(input.uploadId))
      ? String(input.uploadId)
      : `up-${crypto.randomUUID()}`;
    const chunkBase64 = typeof input.chunkBase64 === 'string' ? input.chunkBase64 : '';
    if (!chunkBase64 && input.done !== true) {
      throw Object.assign(new Error('chunkBase64 is required'), { status: 400, code: 'empty_chunk' });
    }
    const buf = chunkBase64 ? Buffer.from(chunkBase64, 'base64') : Buffer.alloc(0);
    const offset = Number.isInteger(input.offset) && input.offset >= 0 ? input.offset : 0;

    let entry = this._uploads.get(safeId);
    if (!entry) {
      if (offset !== 0) {
        throw Object.assign(new Error('Upload session not found for non-zero offset'), {
          status: 400,
          code: 'invalid_upload_offset',
        });
      }
      const name = sanitizeUploadName(input.name);
      const mediaType = typeof input.mediaType === 'string' && input.mediaType.trim()
        ? input.mediaType.trim()
        : 'application/octet-stream';
      const dir = path.join(this._uploadRoot, safeId);
      fs.mkdirSync(dir, { recursive: true });
      const filePath = path.join(dir, name);
      entry = {
        uploadId: safeId,
        path: filePath,
        dir,
        name,
        mediaType,
        bytes: 0,
        done: false,
        createdAt: Date.now(),
      };
      this._uploads.set(safeId, entry);
    }

    if (offset !== entry.bytes) {
      throw Object.assign(new Error(`Unexpected upload offset ${offset}, expected ${entry.bytes}`), {
        status: 400,
        code: 'invalid_upload_offset',
      });
    }
    if (entry.bytes + buf.length > MAX_UPLOAD_BYTES) {
      throw Object.assign(new Error('Attachment exceeds 10MB limit'), {
        status: 413,
        code: 'payload_too_large',
      });
    }

    if (buf.length > 0) {
      fs.appendFileSync(entry.path, buf);
      entry.bytes += buf.length;
    }
    if (input.done !== false) {
      entry.done = true;
    }

    return {
      ok: true,
      uploadId: entry.uploadId,
      name: entry.name,
      mediaType: entry.mediaType,
      bytes: entry.bytes,
      done: entry.done,
    };
  }

  /**
   * 解析 `attachmentIds` 与内联 `attachments`，返回已落盘附件元信息列表。
   *
   * @param {{ attachmentIds?: string[], attachments?: Array<{ name?: string, mediaType?: string, dataBase64?: string }> }} input
   * @returns {Array<{ uploadId: string, path: string, dir: string, name: string, mediaType: string, bytes: number }>}
   */
  _resolveAttachments(input) {
    const resolved = [];
    if (Array.isArray(input.attachmentIds)) {
      for (const rawId of input.attachmentIds) {
        const id = String(rawId || '');
        const entry = this._uploads.get(id);
        if (entry && fs.existsSync(entry.path)) {
          resolved.push(entry);
        }
      }
    }
    if (Array.isArray(input.attachments)) {
      for (const att of input.attachments) {
        if (!att || typeof att !== 'object' || typeof att.dataBase64 !== 'string' || !att.dataBase64) continue;
        const saved = this.saveUploadChunk({
          name: att.name,
          mediaType: att.mediaType,
          offset: 0,
          chunkBase64: att.dataBase64,
          done: true,
        });
        const entry = this._uploads.get(saved.uploadId);
        if (entry) resolved.push(entry);
      }
    }
    return resolved;
  }

  /**
   * 启动一次外部 CLI 对话轮次（非阻塞返回，后台异步推进并维护运行态）。
   *
   * @param {{
   *   engine: string,
   *   rawSessionId?: string | null,
   *   cwd?: string | null,
   *   prompt?: string,
   *   model?: string | null,
   *   reasoningEffort?: string | null,
   *   attachmentIds?: string[],
   *   attachments?: Array<{ name?: string, mediaType?: string, dataBase64?: string }>,
   * }} input
   * @returns {{ ok: true, sessionId: string, rawId: string, runId: string, running: true }}
   */
  startRun(input) {
    const engine = String(input.engine || '');
    if (!CLI_ENGINES.has(engine)) {
      throw Object.assign(new Error(`Unsupported engine: ${engine}`), { status: 400, code: 'invalid_engine' });
    }
    const rawPrompt = typeof input.prompt === 'string' ? input.prompt.trim() : '';
    const attachments = this._resolveAttachments(input);
    if (!rawPrompt && attachments.length === 0) {
      throw Object.assign(new Error('prompt or attachment is required'), { status: 400, code: 'empty_prompt' });
    }
    const rawRequestedId = input.rawSessionId ? String(input.rawSessionId) : null;
    if (rawRequestedId !== null && !isSafeSessionId(rawRequestedId)) {
      throw Object.assign(new Error('invalid sessionId'), { status: 400, code: 'invalid_session' });
    }
    const requestedId = rawRequestedId
      ? (this._resolvedIds.get(`${engine}:${rawRequestedId}`) || rawRequestedId)
      : null;

    const isIdeSession = engine === 'antigravity' && Boolean(requestedId) && this._isIdeOnlyAntigravitySession(requestedId);
    const desktopCandidate = Boolean(
      this._desktopCdp &&
      this._desktopCdp.enabled !== false &&
      engine === 'antigravity' &&
      (isIdeSession || (!requestedId && this._newAntigravitySessionMode !== 'acp')),
    );

    let handoff = null;
    let cliSessionArgId = requestedId;
    if (isIdeSession && !desktopCandidate) {
      handoff = this._buildIdeHandoffContext(requestedId);
      cliSessionArgId = null;
    }

    const displayPrompt = rawPrompt || attachments.map((a) => `[附件: ${a.name}]`).join(' ');
    const addDirs = [...new Set(attachments.map((a) => a.dir))];
    const imagePaths = attachments
      .filter((a) => IMAGE_MIME_RE.test(a.mediaType) || IMAGE_EXT_RE.test(a.name))
      .map((a) => a.path);

    let effectivePrompt = rawPrompt || '请查看并分析用户附带的图片或文件。';
    if (handoff) {
      effectivePrompt = `${handoff.contextBlock}\n\n${effectivePrompt}`;
    }
    if (attachments.length > 0) {
      const nonCodexImages = engine === 'codex'
        ? attachments.filter((a) => !imagePaths.includes(a.path))
        : attachments;
      if (nonCodexImages.length > 0) {
        const list = nonCodexImages.map((a) => `- ${a.name} (${a.mediaType}): ${a.path}`).join('\n');
        effectivePrompt = `${effectivePrompt}\n\n[用户附带的本地文件，请直接读取分析]\n${list}`;
      }
    }

    const rawId = cliSessionArgId || `pending-${crypto.randomUUID()}`;
    const key = `${engine}:${rawId}`;
    const existing = this._runs.get(key);
    if (existing?.running) {
      throw Object.assign(new Error(`${engine} session ${rawId} is already running`), {
        status: 409,
        code: 'already_running',
      });
    }

    const runId = crypto.randomUUID();
    const resolvedInputCwd = input.cwd && fs.existsSync(input.cwd) ? input.cwd : null;
    const resolvedHandoffCwd = handoff?.cwd && fs.existsSync(handoff.cwd) ? handoff.cwd : null;
    const cwd = resolvedInputCwd || resolvedHandoffCwd || os.homedir();

    // Antigravity 桌面版 CDP 模式（已有 IDE 会话原位续聊；新开会话默认直走桌面版，离线时自动降级到 ACP）。
    if (desktopCandidate) {
      return this._startAntigravityDesktopRun({
        runId,
        rawId,
        key,
        isIdeSession,
        requestedId,
        cwd,
        rawPrompt,
        displayPrompt,
        attachments,
        model: input.model,
        reasoningEffort: input.reasoningEffort,
      });
    }

    // Antigravity 常驻 ACP 模式：零冷启动、原生多模态图片块、实时双向 JSON-RPC 推送。
    if (engine === 'antigravity' && this._acp) {
      return this._startAntigravityAcpRun({
        runId,
        rawId,
        key,
        cliSessionArgId,
        requestedId,
        handoff,
        cwd,
        rawPrompt,
        displayPrompt,
        attachments,
        model: input.model,
        reasoningEffort: input.reasoningEffort,
      });
    }

    const { binCandidates, args } = buildCliCommand(engine, {
      rawSessionId: cliSessionArgId,
      prompt: effectivePrompt,
      model: input.model,
      reasoningEffort: input.reasoningEffort,
      addDirs,
      imagePaths,
    });
    const exe = this._resolveBin(binCandidates);
    if (!exe) {
      throw Object.assign(new Error(`${engine} CLI executable not found on host`), {
        status: 503,
        code: 'cli_unavailable',
      });
    }

    const useShell = process.platform === 'win32' && /\.(cmd|bat)$/i.test(exe);
    const child = this._spawn(exe, args, {
      cwd,
      shell: useShell,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const state = {
      runId,
      engine,
      rawId,
      resolvedRawId: cliSessionArgId,
      sessionId: `cli:${engine}:${rawId}`,
      cwd,
      rawPrompt,
      prompt: displayPrompt,
      attachments: attachments.map((a) => ({
        uploadId: a.uploadId,
        name: a.name,
        mediaType: a.mediaType,
        bytes: a.bytes,
      })),
      model: input.model || null,
      reasoningEffort: input.reasoningEffort || null,
      running: true,
      startedAt: Date.now(),
      updatedAt: Date.now(),
      activeStepIndex: null,
      assistantText: '',
      assistantReasoning: '',
      errorText: '',
      exitCode: null,
      version: 1,
      child,
    };
    this._runs.set(key, state);
    this._notifyState(state, { immediate: true });

    let lineBuffer = '';
    const applyParsed = (parsed) => {
      if (!parsed) return;
      let changed = false;
      if (parsed.sessionId && !state.resolvedRawId) {
        state.resolvedRawId = parsed.sessionId;
        this._resolvedIds.set(`${engine}:${rawId}`, parsed.sessionId);
        changed = true;
      }
      // Antigravity 多步推理：当 step_index 切换到新步骤时清空旧步骤的流式暂存，避免与已落盘的旧步骤重复拼接。
      if (typeof parsed.stepIndex === 'number' && parsed.stepType && parsed.stepType !== 'user_input') {
        if (state.activeStepIndex !== null && parsed.stepIndex !== state.activeStepIndex) {
          state.assistantText = '';
          state.assistantReasoning = '';
          changed = true;
        }
        state.activeStepIndex = parsed.stepIndex;
      }
      if (parsed.reasoningDelta) {
        state.assistantReasoning += parsed.reasoningDelta;
        changed = true;
      }
      if (parsed.reasoning) {
        state.assistantReasoning += (state.assistantReasoning && !state.assistantReasoning.endsWith('\n') ? '\n' : '') + parsed.reasoning;
        changed = true;
      }
      if (parsed.textDelta) {
        state.assistantText += parsed.textDelta;
        changed = true;
      }
      if (parsed.text) {
        state.assistantText += (state.assistantText && !state.assistantText.endsWith('\n') ? '\n' : '') + parsed.text;
        changed = true;
      }
      if (parsed.finalText && !state.assistantText.trim()) {
        state.assistantText = parsed.finalText;
        changed = true;
      }
      if (changed || parsed.stepState === 'DONE') {
        state.updatedAt = Date.now();
        this._notifyState(state, { immediate: parsed.stepState === 'DONE' || Boolean(parsed.finalText) });
      }
    };

    const handleChunk = (chunk) => {
      lineBuffer += chunk.toString('utf8');
      const lines = lineBuffer.split(/\r?\n/);
      lineBuffer = lines.pop() ?? '';
      for (const line of lines) {
        applyParsed(parseCliStreamLine(line));
      }
    };

    child.stdout?.on('data', handleChunk);
    child.stderr?.on('data', (chunk) => {
      state.errorText += chunk.toString('utf8');
      state.updatedAt = Date.now();
      this._notifyState(state);
    });

    const finish = (code) => {
      if (lineBuffer.trim()) {
        applyParsed(parseCliStreamLine(lineBuffer));
        lineBuffer = '';
      }
      if (/trajectory not found/i.test(state.errorText)) {
        state.errorText = IDE_READONLY_MESSAGE;
      }
      state.running = false;
      state.exitCode = code;
      state.updatedAt = Date.now();
      state.child = null;
      this._notifyState(state, { immediate: true });
    };

    child.on('error', (err) => {
      state.errorText += (state.errorText ? '\n' : '') + err.message;
      finish(-1);
    });
    child.on('close', (code) => finish(code ?? 0));

    return {
      ok: true,
      sessionId: state.sessionId,
      rawId: state.rawId,
      runId: state.runId,
      running: true,
      ...(handoff ? { handedOffFrom: requestedId } : {}),
    };
  }

  _buildAcpPromptBlocks({ rawPrompt, handoff, attachments }) {
    const promptBlocks = [];
    const nonImageAttachments = [];
    for (const att of attachments) {
      const isImg = IMAGE_MIME_RE.test(att.mediaType) || IMAGE_EXT_RE.test(att.name);
      if (isImg && att.path && fs.existsSync(att.path)) {
        try {
          const data = fs.readFileSync(att.path).toString('base64');
          const mimeType = IMAGE_MIME_RE.test(att.mediaType) ? att.mediaType : 'image/jpeg';
          promptBlocks.push({ type: 'image', data, mimeType });
          continue;
        } catch {
          // 读图失败则回退本地路径提示
        }
      }
      nonImageAttachments.push(att);
    }

    let textBody = rawPrompt || '请查看并分析用户附带的图片或文件。';
    if (handoff) {
      textBody = `${handoff.contextBlock}\n\n${textBody}`;
    }
    if (nonImageAttachments.length > 0) {
      const list = nonImageAttachments.map((a) => `- ${a.name} (${a.mediaType}): ${a.path}`).join('\n');
      textBody = `${textBody}\n\n[用户附带的本地文件，请直接读取分析]\n${list}`;
    }
    promptBlocks.unshift({ type: 'text', text: textBody });
    return promptBlocks;
  }

  /**
   * 在给定运行态对象上通过常驻 `agy acp` 守护进程推进对话直到结束（供直连与离线降级复用）。
   *
   * @param {object} state
   * @param {{ cliSessionArgId: string | null, handoff: object | null, cwd: string, rawPrompt: string, attachments: Array<object>, model?: string | null, reasoningEffort?: string | null }} opts
   */
  async _executeAntigravityAcpIntoState(state, opts) {
    const { cliSessionArgId, handoff, cwd, rawPrompt, attachments, model, reasoningEffort } = opts;
    const promptBlocks = this._buildAcpPromptBlocks({ rawPrompt, handoff, attachments });
    const resolvedModel = resolveAntigravityWireModel(model, reasoningEffort);

    try {
      const ensured = await this._acp.ensureSession({ rawId: cliSessionArgId, cwd });
      const acpSessionId = ensured.sessionId;
      if (acpSessionId && (!state.resolvedRawId || state.resolvedRawId !== acpSessionId)) {
        state.resolvedRawId = acpSessionId;
        this._resolvedIds.set(`antigravity:${state.rawId}`, acpSessionId);
        this._notifyState(state, { immediate: true });
      }
      if (resolvedModel.model) {
        try {
          await this._acp.setModel(acpSessionId, resolvedModel.model);
        } catch {
          // 忽略不支持的模型切换报错，沿用会话当前模型继续执行
        }
      }

      await this._acp.prompt({
        sessionId: acpSessionId,
        prompt: promptBlocks,
        onUpdate: (u) => {
          if (!u || typeof u !== 'object') return;
          const kind = u.sessionUpdate;
          let changed = false;
          if (kind === 'agent_thought_chunk') {
            const text = typeof u.content?.text === 'string' ? u.content.text : '';
            if (text) {
              state.assistantReasoning += text;
              changed = true;
            }
          } else if (kind === 'agent_message_chunk') {
            const text = typeof u.content?.text === 'string' ? u.content.text : '';
            if (text) {
              state.assistantText += text;
              changed = true;
            }
          } else if (kind === 'tool_call' || kind === 'tool_call_update') {
            const callId = String(u.toolCallId || u.id || `acp-tool-${state.toolCalls.length}`);
            const toolName = normalizeCliToolName(u.name || u.title || 'tool');
            const rawArgs = u.args ?? u.rawInput;
            const argsStr = rawArgs === undefined
              ? undefined
              : (typeof rawArgs === 'string' ? rawArgs : JSON.stringify(rawArgs));
            const idx = state.toolCalls.findIndex((t) => t.id === callId);
            if (idx >= 0) {
              const prev = state.toolCalls[idx];
              state.toolCalls[idx] = {
                ...prev,
                ...(u.name ? { name: toolName } : {}),
                ...(argsStr !== undefined ? { arguments: argsStr } : {}),
                ...(typeof u.status === 'string' ? { status: u.status } : {}),
              };
            } else {
              state.toolCalls.push({
                id: callId,
                name: toolName,
                arguments: argsStr ?? '{}',
                status: typeof u.status === 'string' ? u.status : 'in_progress',
              });
            }
            changed = true;
          }
          if (changed) {
            state.updatedAt = Date.now();
            this._notifyState(state);
          }
        },
      });
      state.exitCode = 0;
    } catch (err) {
      if (state.running) {
        const msg = String(err?.message || err || 'Antigravity ACP prompt failed');
        state.errorText += (state.errorText ? '\n' : '') + msg;
        state.exitCode = -1;
      }
    } finally {
      state.running = false;
      state.updatedAt = Date.now();
      this._notifyState(state, { immediate: true });
    }
  }

  /**
   * 通过本机 CDP 后台静默驱动 Antigravity 桌面版执行对话（若桌面端离线则自动无缝降级到常驻 ACP）。
   *
   * @param {object} ctx
   * @returns {{ ok: true, sessionId: string, rawId: string, runId: string, running: true }}
   */
  _startAntigravityDesktopRun(ctx) {
    const {
      runId,
      rawId,
      key,
      isIdeSession,
      requestedId,
      cwd,
      rawPrompt,
      displayPrompt,
      attachments,
      model,
      reasoningEffort,
    } = ctx;

    const abortController = new AbortController();
    const state = {
      runId,
      engine: 'antigravity',
      mode: 'desktop-cdp',
      rawId,
      resolvedRawId: isIdeSession ? requestedId : null,
      sessionId: `cli:antigravity:${rawId}`,
      cwd,
      rawPrompt,
      prompt: displayPrompt,
      attachments: attachments.map((a) => ({
        uploadId: a.uploadId,
        name: a.name,
        mediaType: a.mediaType,
        bytes: a.bytes,
      })),
      model: model || null,
      reasoningEffort: reasoningEffort || null,
      running: true,
      startedAt: Date.now(),
      updatedAt: Date.now(),
      activeStepIndex: null,
      assistantText: '',
      assistantReasoning: '',
      toolCalls: [],
      errorText: '',
      exitCode: null,
      version: 1,
      child: null,
      _abortController: abortController,
    };
    this._runs.set(key, state);
    this._notifyState(state, { immediate: true });

    const runAsync = async () => {
      const desktopReady = await this._desktopCdp.probeAvailability({ force: true }).catch(() => false);
      if (!desktopReady) {
        if (this._acp) {
          state.mode = 'acp';
          const handoff = isIdeSession ? this._buildIdeHandoffContext(requestedId) : null;
          if (handoff) {
            state.resolvedRawId = null;
          }
          const acpCwd = handoff?.cwd && fs.existsSync(handoff.cwd) ? handoff.cwd : cwd;
          await this._executeAntigravityAcpIntoState(state, {
            cliSessionArgId: null,
            handoff,
            cwd: acpCwd,
            rawPrompt,
            attachments,
            model,
            reasoningEffort,
          });
          return;
        }
        state.errorText = IDE_READONLY_MESSAGE;
        state.exitCode = -1;
        state.running = false;
        state.updatedAt = Date.now();
        this._notifyState(state, { immediate: true });
        return;
      }

      try {
        const filePaths = attachments
          .map((a) => a.path)
          .filter((p) => typeof p === 'string' && p.length > 0 && fs.existsSync(p));
        await this._desktopCdp.sendPrompt({
          rawId: isIdeSession ? requestedId : null,
          cwd,
          prompt: rawPrompt || (filePaths.length > 0 ? '' : displayPrompt),
          model,
          reasoningEffort,
          filePaths,
          signal: abortController.signal,
          onResolvedId: (resolvedId) => {
            if (!resolvedId) return;
            if (!state.resolvedRawId || state.resolvedRawId !== resolvedId) {
              state.resolvedRawId = resolvedId;
              this._resolvedIds.set(`antigravity:${rawId}`, resolvedId);
              state.updatedAt = Date.now();
              this._notifyState(state, { immediate: true });
            }
          },
          onStreamUpdate: ({ text }) => {
            if (typeof text === 'string' && text && text !== state.assistantText) {
              state.assistantText = text;
              state.updatedAt = Date.now();
              this._notifyState(state);
            }
          },
          isDiskRunning: (id) => this._isAntigravitySessionRunningOnDisk(id),
        });
        state.exitCode = 0;
      } catch (err) {
        if (state.running && !abortController.signal.aborted) {
          const msg = String(err?.message || err || 'Antigravity Desktop CDP prompt failed');
          state.errorText += (state.errorText ? '\n' : '') + msg;
          state.exitCode = -1;
        }
      } finally {
        state.running = false;
        state.updatedAt = Date.now();
        this._notifyState(state, { immediate: true });
      }
    };

    void runAsync();

    return {
      ok: true,
      sessionId: state.sessionId,
      rawId: state.rawId,
      runId: state.runId,
      running: true,
    };
  }

  /**
   * 通过常驻 `agy acp` 守护进程发起 Antigravity 对话轮次。
   *
   * @param {object} ctx
   * @returns {{ ok: true, sessionId: string, rawId: string, runId: string, running: true }}
   */
  _startAntigravityAcpRun(ctx) {
    const {
      runId,
      rawId,
      key,
      cliSessionArgId,
      requestedId,
      handoff,
      cwd,
      rawPrompt,
      displayPrompt,
      attachments,
      model,
      reasoningEffort,
    } = ctx;

    const state = {
      runId,
      engine: 'antigravity',
      mode: 'acp',
      rawId,
      resolvedRawId: cliSessionArgId,
      sessionId: `cli:antigravity:${rawId}`,
      cwd,
      rawPrompt,
      prompt: displayPrompt,
      attachments: attachments.map((a) => ({
        uploadId: a.uploadId,
        name: a.name,
        mediaType: a.mediaType,
        bytes: a.bytes,
      })),
      model: model || null,
      reasoningEffort: reasoningEffort || null,
      running: true,
      startedAt: Date.now(),
      updatedAt: Date.now(),
      activeStepIndex: null,
      assistantText: '',
      assistantReasoning: '',
      toolCalls: [],
      errorText: '',
      exitCode: null,
      version: 1,
      child: null,
    };
    this._runs.set(key, state);
    this._notifyState(state, { immediate: true });

    void this._executeAntigravityAcpIntoState(state, {
      cliSessionArgId,
      handoff,
      cwd,
      rawPrompt,
      attachments,
      model,
      reasoningEffort,
    });

    return {
      ok: true,
      sessionId: state.sessionId,
      rawId: state.rawId,
      runId: state.runId,
      running: true,
      ...(handoff ? { handedOffFrom: requestedId } : {}),
    };
  }

  /**
   * 停止正在运行的 CLI / 桌面端任务（ACP 发送优雅取消，Desktop CDP 点击停止按钮）。
   *
   * @param {string} engine
   * @param {string} rawId
   * @returns {boolean}
   */
  abortRun(engine, rawId) {
    let state = this._runs.get(`${engine}:${rawId}`);
    if (!state || !state.running) {
      for (const candidate of this._runs.values()) {
        if (candidate.engine === engine && candidate.running && candidate.resolvedRawId === rawId) {
          state = candidate;
          break;
        }
      }
    }
    if (!state || !state.running) {
      if (
        engine === 'antigravity' &&
        this._desktopCdp &&
        this._desktopCdp.enabled !== false &&
        this._desktopCdp.isAvailableSync() === true &&
        this._isIdeOnlyAntigravitySession(rawId)
      ) {
        void this._desktopCdp.abort(rawId).catch(() => {});
        return true;
      }
      return false;
    }
    if (state.mode === 'desktop-cdp' && this._desktopCdp) {
      state._abortController?.abort();
      void this._desktopCdp.abort(state.resolvedRawId || rawId).catch(() => {});
      state.running = false;
      state.updatedAt = Date.now();
      this._notifyState(state, { immediate: true });
      return true;
    }
    if (state.mode === 'acp' && this._acp) {
      this._acp.cancel(state.resolvedRawId || rawId);
      state.running = false;
      state.updatedAt = Date.now();
      this._notifyState(state, { immediate: true });
      return true;
    }
    if (!state.child) return false;
    try {
      state.child.kill('SIGTERM');
    } catch {
      try {
        state.child.kill();
      } catch {
        // ignore
      }
    }
    state.running = false;
    state.updatedAt = Date.now();
    this._notifyState(state, { immediate: true });
    return true;
  }

  /**
   * 获取正在运行或最近 60 秒内刚结束的任务快照，用于补充实时消息与列表状态。
   *
   * @param {string} engine
   * @param {string} rawId
   * @returns {object | null}
   */
  getOverlay(engine, rawId) {
    const state = this._runs.get(`${engine}:${rawId}`);
    if (!state) return null;
    // 结束超过 60 秒且已有持久化记录可丢弃临时覆盖
    if (!state.running && Date.now() - state.updatedAt > 60_000) {
      this._runs.delete(`${engine}:${rawId}`);
      return null;
    }
    return state;
  }

  /**
   * 列出全部活跃运行中任务。
   *
   * @returns {Array<object>}
   */
  listActiveRuns() {
    const active = [];
    for (const state of this._runs.values()) {
      if (state.running) active.push(state);
    }
    return active;
  }

  /**
   * 销毁时清理全部尚未退出的子进程、常驻 ACP 客户端、桌面 CDP 客户端与事件定时器。
   */
  dispose() {
    for (const timer of this._notifyTimers.values()) {
      clearTimeout(timer);
    }
    this._notifyTimers.clear();
    this._listeners.clear();
    for (const state of this._runs.values()) {
      state._abortController?.abort();
      if (state.running && state.child) {
        try {
          state.child.kill();
        } catch {
          // ignore
        }
      }
    }
    this._acp?.dispose();
    this._desktopCdp?.dispose();
    this._runs.clear();
  }
}
