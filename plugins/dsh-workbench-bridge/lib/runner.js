/**
 * @file 外部 CLI 非交互执行与运行态管理（支持 Antigravity / Claude / Codex）。
 */
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';

import { CLI_ENGINES, isSafeSessionId, resolveExecutable } from './scanners/common.js';

/**
 * 为指定 CLI 引擎构造命令行与参数列表。
 *
 * @param {'antigravity' | 'claude' | 'codex'} engine
 * @param {{ rawSessionId?: string | null, prompt: string, model?: string | null }} req
 * @returns {{ binCandidates: string[], args: string[] }}
 */
export function buildCliCommand(engine, req) {
  const prompt = req.prompt;
  const rawId = req.rawSessionId && isSafeSessionId(req.rawSessionId) ? req.rawSessionId : null;
  const model = typeof req.model === 'string' && req.model.trim() ? req.model.trim() : null;

  switch (engine) {
    case 'antigravity': {
      const args = ['--print', '--output-format', 'stream-json'];
      if (rawId) args.push('--conversation', rawId);
      if (model) args.push('--model', model);
      args.push(prompt);
      return { binCandidates: ['agy'], args };
    }
    case 'claude': {
      const args = ['-p', '--output-format', 'stream-json', '--verbose'];
      if (rawId) args.push('--resume', rawId);
      if (model) args.push('--model', model);
      args.push(prompt);
      return { binCandidates: ['claude'], args };
    }
    case 'codex': {
      const args = ['exec', '--json'];
      if (model) args.push('-m', model);
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
 * 尝试从 CLI stream-json 单行输出中提取文本、会话 ID 或工具活动。
 *
 * @param {string} line
 * @returns {{ sessionId?: string, text?: string, reasoning?: string } | null}
 */
export function parseCliStreamLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    const obj = JSON.parse(trimmed);
    if (!obj || typeof obj !== 'object') return { text: trimmed };
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
 * 管理所有外部 CLI 正在运行与最近完成的任务。
 */
export class CliRunManager {
  /**
   * @param {{ spawnFn?: typeof spawn, resolveBinFn?: typeof resolveExecutable }} [deps]
   */
  constructor(deps = {}) {
    this._spawn = deps.spawnFn || spawn;
    this._resolveBin = deps.resolveBinFn || resolveExecutable;
    /** @type {Map<string, object>} key: "engine:rawId" */
    this._runs = new Map();
  }

  /**
   * 启动一次外部 CLI 对话轮次（非阻塞返回，后台异步推进并维护运行态）。
   *
   * @param {{ engine: string, rawSessionId?: string | null, cwd?: string | null, prompt: string, model?: string | null }} input
   * @returns {{ ok: true, sessionId: string, rawId: string, runId: string, running: true }}
   */
  startRun(input) {
    const engine = String(input.engine || '');
    if (!CLI_ENGINES.has(engine)) {
      throw Object.assign(new Error(`Unsupported engine: ${engine}`), { status: 400, code: 'invalid_engine' });
    }
    const prompt = typeof input.prompt === 'string' ? input.prompt.trim() : '';
    if (!prompt) {
      throw Object.assign(new Error('prompt is required'), { status: 400, code: 'empty_prompt' });
    }
    const requestedId = input.rawSessionId ? String(input.rawSessionId) : null;
    if (requestedId !== null && !isSafeSessionId(requestedId)) {
      throw Object.assign(new Error('invalid sessionId'), { status: 400, code: 'invalid_session' });
    }

    const { binCandidates, args } = buildCliCommand(engine, {
      rawSessionId: requestedId,
      prompt,
      model: input.model,
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
      prompt,
      model: input.model || null,
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
    const handleChunk = (chunk) => {
      lineBuffer += chunk.toString('utf8');
      const lines = lineBuffer.split(/\r?\n/);
      lineBuffer = lines.pop() ?? '';
      for (const line of lines) {
        const parsed = parseCliStreamLine(line);
        if (!parsed) continue;
        if (parsed.sessionId && !state.resolvedRawId) state.resolvedRawId = parsed.sessionId;
        if (parsed.reasoning) state.assistantReasoning += parsed.reasoning;
        if (parsed.text) state.assistantText += (state.assistantText && !state.assistantText.endsWith('\n') ? '\n' : '') + parsed.text;
        state.updatedAt = Date.now();
      }
    };

    child.stdout?.on('data', handleChunk);
    child.stderr?.on('data', (chunk) => {
      state.errorText += chunk.toString('utf8');
      state.updatedAt = Date.now();
    });

    const finish = (code) => {
      if (lineBuffer.trim()) {
        const parsed = parseCliStreamLine(lineBuffer);
        if (parsed?.text) {
          state.assistantText += (state.assistantText ? '\n' : '') + parsed.text;
        }
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
