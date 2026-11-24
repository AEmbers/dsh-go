/**
 * @file 外部 CLI 非交互执行与运行态管理（支持 Antigravity / Claude / Codex）。
 */
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { resolveAntigravityWireModel } from './models.js';
import { CLI_ENGINES, isSafeSessionId, resolveExecutable } from './scanners/common.js';

const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
const UPLOAD_TTL_MS = 2 * 60 * 60 * 1000;
const IMAGE_MIME_RE = /^image\//i;
const IMAGE_EXT_RE = /\.(png|jpe?g|webp|gif|bmp|heic|heif)$/i;

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
      return {
        sessionId: typeof sid === 'string' && isSafeSessionId(sid) ? sid : undefined,
        textDelta,
        reasoningDelta,
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
    /** @type {Map<string, object>} key: "engine:rawId" */
    this._runs = new Map();
    /** @type {Map<string, string>} key: "engine:pendingRawId" -> resolvedRawId */
    this._resolvedIds = new Map();
    /** @type {Map<string, { uploadId: string, path: string, dir: string, name: string, mediaType: string, bytes: number, done: boolean, createdAt: number }>} */
    this._uploads = new Map();
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

    const displayPrompt = rawPrompt || attachments.map((a) => `[附件: ${a.name}]`).join(' ');
    const addDirs = [...new Set(attachments.map((a) => a.dir))];
    const imagePaths = attachments
      .filter((a) => IMAGE_MIME_RE.test(a.mediaType) || IMAGE_EXT_RE.test(a.name))
      .map((a) => a.path);

    let effectivePrompt = rawPrompt || '请查看并分析用户附带的图片或文件。';
    if (attachments.length > 0) {
      const nonCodexImages = engine === 'codex'
        ? attachments.filter((a) => !imagePaths.includes(a.path))
        : attachments;
      if (nonCodexImages.length > 0) {
        const list = nonCodexImages.map((a) => `- ${a.name} (${a.mediaType}): ${a.path}`).join('\n');
        effectivePrompt = `${effectivePrompt}\n\n[用户附带的本地文件，请直接读取分析]\n${list}`;
      }
    }

    const { binCandidates, args } = buildCliCommand(engine, {
      rawSessionId: requestedId,
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

    const rawId = requestedId || `pending-${crypto.randomUUID()}`;
    const key = `${engine}:${rawId}`;
    const existing = this._runs.get(key);
    if (existing?.running) {
      throw Object.assign(new Error(`${engine} session ${rawId} is already running`), {
        status: 409,
        code: 'already_running',
      });
    }

    const runId = crypto.randomUUID();
    const cwd = input.cwd && fs.existsSync(input.cwd) ? input.cwd : os.homedir();
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
      resolvedRawId: requestedId,
      sessionId: `cli:${engine}:${rawId}`,
      cwd,
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
      assistantText: '',
      assistantReasoning: '',
      errorText: '',
      exitCode: null,
      child,
    };
    this._runs.set(key, state);

    let lineBuffer = '';
    const applyParsed = (parsed) => {
      if (!parsed) return;
      if (parsed.sessionId && !state.resolvedRawId) {
        state.resolvedRawId = parsed.sessionId;
        this._resolvedIds.set(`${engine}:${rawId}`, parsed.sessionId);
      }
      if (parsed.reasoningDelta) state.assistantReasoning += parsed.reasoningDelta;
      if (parsed.reasoning) {
        state.assistantReasoning += (state.assistantReasoning && !state.assistantReasoning.endsWith('\n') ? '\n' : '') + parsed.reasoning;
      }
      if (parsed.textDelta) state.assistantText += parsed.textDelta;
      if (parsed.text) {
        state.assistantText += (state.assistantText && !state.assistantText.endsWith('\n') ? '\n' : '') + parsed.text;
      }
      if (parsed.finalText && !state.assistantText.trim()) {
        state.assistantText = parsed.finalText;
      }
      state.updatedAt = Date.now();
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
    });

    const finish = (code) => {
      if (lineBuffer.trim()) {
        applyParsed(parseCliStreamLine(lineBuffer));
        lineBuffer = '';
      }
      state.running = false;
      state.exitCode = code;
      state.updatedAt = Date.now();
      state.child = null;
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
    };
  }

  /**
   * 停止正在运行的 CLI 子进程。
   *
   * @param {string} engine
   * @param {string} rawId
   * @returns {boolean}
   */
  abortRun(engine, rawId) {
    const state = this._runs.get(`${engine}:${rawId}`);
    if (!state || !state.running || !state.child) return false;
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
   * 销毁时清理全部尚未退出的子进程。
   */
  dispose() {
    for (const state of this._runs.values()) {
      if (state.running && state.child) {
        try {
          state.child.kill();
        } catch {
          // ignore
        }
      }
    }
    this._runs.clear();
  }
}
