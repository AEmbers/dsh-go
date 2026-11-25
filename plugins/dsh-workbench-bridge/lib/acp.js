/**
 * @file 常驻 Antigravity ACP（Agent Client Protocol）守护客户端。
 *
 * 通过单实例常驻 `agy acp --dangerously-skip-permissions` 子进程与 JSON-RPC 2.0
 * 双向通信，避免每轮对话冷启动 `agy --print`，支持零冷启动续聊（`session/resume`）、
 * 动态切模型（`session/set_model`）、原生多模态图片块、实时 `session/update` 推送
 * 及优雅取消（`session/cancel`）。
 */
import { spawn } from 'node:child_process';
import os from 'node:os';

import { resolveExecutable } from './scanners/common.js';

const DEFAULT_RPC_TIMEOUT_MS = 30_000;
const PROMPT_RPC_TIMEOUT_MS = 30 * 60 * 1000;

/**
 * 从 ACP `session/request_permission` 选项中挑选自动允许项。
 *
 * @param {any} params
 * @returns {object}
 */
function buildAutoAllowPermissionResult(params) {
  const options = Array.isArray(params?.options) ? params.options : [];
  const preferred =
    options.find((o) => o?.kind === 'allow_once' || o?.optionId === 'allow_once') ||
    options.find((o) => o?.kind === 'allow_always' || o?.optionId === 'allow_always') ||
    options.find((o) => typeof o?.optionId === 'string' && /allow/i.test(o.optionId)) ||
    options[0];
  if (preferred?.optionId) {
    return { outcome: { outcome: 'selected', optionId: preferred.optionId } };
  }
  return { outcome: { outcome: 'selected', optionId: 'allow_once' } };
}

/**
 * 常驻 Antigravity ACP 守护客户端。
 */
export class AntigravityAcpClient {
  /**
   * @param {{
   *   spawnFn?: typeof spawn,
   *   resolveBinFn?: (candidates: string[]) => string | null,
   *   cwd?: string,
   *   extraArgs?: string[],
   * }} [deps]
   */
  constructor(deps = {}) {
    this._spawn = deps.spawnFn || spawn;
    this._resolveBin = deps.resolveBinFn || resolveExecutable;
    this._defaultCwd = deps.cwd || os.homedir();
    this._extraArgs = Array.isArray(deps.extraArgs) ? deps.extraArgs : [];

    this._child = null;
    this._readyPromise = null;
    this._disposed = false;
    this._nextId = 1;
    this._lineBuffer = '';

    /** @type {Map<number, { resolve: Function, reject: Function, timer: ReturnType<typeof setTimeout> | null }>} */
    this._pending = new Map();
    /** @type {Map<string, Set<(update: object) => void>>} */
    this._updateHandlers = new Map();
    /** @type {Map<string, { currentModelId: string | null }>} */
    this._sessions = new Map();
    this._capabilities = null;
  }

  /**
   * 返回当前常驻进程是否存活。
   *
   * @returns {boolean}
   */
  get isAlive() {
    return Boolean(this._child && !this._child.killed && this._child.exitCode === null);
  }

  /**
   * 确保常驻 `agy acp` 进程已启动并完成 `initialize` 握手。
   *
   * @returns {Promise<object>}
   */
  async ensureReady() {
    if (this._disposed) {
      throw new Error('AntigravityAcpClient has been disposed');
    }
    if (this._readyPromise && this.isAlive) {
      return this._readyPromise;
    }
    this._readyPromise = this._startAndInitialize().catch((err) => {
      this._readyPromise = null;
      throw err;
    });
    return this._readyPromise;
  }

  async _startAndInitialize() {
    const exe = this._resolveBin(['agy']);
    if (!exe) {
      throw Object.assign(new Error('antigravity CLI executable not found on host'), {
        status: 503,
        code: 'cli_unavailable',
      });
    }
    const args = ['acp', '--dangerously-skip-permissions', ...this._extraArgs];
    const useShell = process.platform === 'win32' && /\.(cmd|bat)$/i.test(exe);
    const child = this._spawn(exe, args, {
      cwd: this._defaultCwd,
      shell: useShell,
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this._child = child;
    this._lineBuffer = '';
    this._sessions.clear();

    const onStdout = (chunk) => {
      this._lineBuffer += chunk.toString('utf8');
      const lines = this._lineBuffer.split(/\r?\n/);
      this._lineBuffer = lines.pop() ?? '';
      for (const line of lines) {
        this._handleIncomingLine(line);
      }
    };
    child.stdout?.on('data', onStdout);
    // 消费 stderr 防止缓冲区写满阻塞
    child.stderr?.on('data', () => {});

    const onExit = (errOrCode) => {
      if (this._child !== child) return;
      this._child = null;
      this._readyPromise = null;
      this._sessions.clear();
      const reason = errOrCode instanceof Error
        ? errOrCode
        : new Error(`Antigravity ACP process exited (${errOrCode ?? 'unknown'})`);
      for (const [id, entry] of this._pending.entries()) {
        if (entry.timer) clearTimeout(entry.timer);
        this._pending.delete(id);
        entry.reject(reason);
      }
    };
    child.on('error', onExit);
    child.on('close', onExit);

    const init = await this._request(
      'initialize',
      {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
        clientInfo: { name: 'dsh-workbench-bridge', version: '0.2.0' },
      },
      DEFAULT_RPC_TIMEOUT_MS,
    );
    this._capabilities = init?.agentCapabilities || null;
    return init;
  }

  _handleIncomingLine(line) {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch {
      return;
    }
    if (!msg || typeof msg !== 'object') return;

    // 1) RPC 响应
    if (msg.id !== undefined && msg.method === undefined) {
      const entry = this._pending.get(msg.id);
      if (!entry) return;
      if (entry.timer) clearTimeout(entry.timer);
      this._pending.delete(msg.id);
      if (msg.error) {
        const errMsg = typeof msg.error.message === 'string' ? msg.error.message : JSON.stringify(msg.error);
        entry.reject(Object.assign(new Error(errMsg), { rpcError: msg.error }));
      } else {
        entry.resolve(msg.result);
      }
      return;
    }

    // 2) 服务端主动通知：session/update
    if (msg.method === 'session/update' && msg.params && typeof msg.params === 'object') {
      const sid = msg.params.sessionId;
      const update = msg.params.update && typeof msg.params.update === 'object' ? msg.params.update : msg.params;
      if (typeof sid === 'string') {
        const handlers = this._updateHandlers.get(sid);
        if (handlers && handlers.size > 0) {
          for (const fn of [...handlers]) {
            try {
              fn(update);
            } catch {
              // ignore handler errors
            }
          }
        }
      }
      return;
    }

    // 3) 服务端发起的双向请求（如 session/request_permission）
    if (msg.id !== undefined && typeof msg.method === 'string') {
      if (msg.method === 'session/request_permission') {
        this._writeRaw({
          jsonrpc: '2.0',
          id: msg.id,
          result: buildAutoAllowPermissionResult(msg.params),
        });
      } else {
        this._writeRaw({
          jsonrpc: '2.0',
          id: msg.id,
          error: { code: -32601, message: `Unsupported client method: ${msg.method}` },
        });
      }
    }
  }

  _writeRaw(payload) {
    if (!this._child?.stdin || this._child.stdin.destroyed) {
      throw new Error('Antigravity ACP stdin is not writable');
    }
    this._child.stdin.write(`${JSON.stringify(payload)}\n`);
  }

  _request(method, params, timeoutMs = DEFAULT_RPC_TIMEOUT_MS) {
    const id = this._nextId++;
    return new Promise((resolve, reject) => {
      let timer = null;
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          this._pending.delete(id);
          reject(new Error(`ACP RPC timeout: ${method}`));
        }, timeoutMs);
        timer.unref?.();
      }
      this._pending.set(id, { resolve, reject, timer });
      try {
        this._writeRaw({ jsonrpc: '2.0', id, method, params });
      } catch (err) {
        if (timer) clearTimeout(timer);
        this._pending.delete(id);
        reject(err);
      }
    });
  }

  _notify(method, params) {
    try {
      this._writeRaw({ jsonrpc: '2.0', method, params });
    } catch {
      // ignore notification write error when process is closing
    }
  }

  /**
   * 订阅指定 ACP 会话的 `session/update` 通知。
   *
   * @param {string} sessionId
   * @param {(update: object) => void} handler
   * @returns {() => void}
   */
  onSessionUpdate(sessionId, handler) {
    let set = this._updateHandlers.get(sessionId);
    if (!set) {
      set = new Set();
      this._updateHandlers.set(sessionId, set);
    }
    set.add(handler);
    return () => {
      const current = this._updateHandlers.get(sessionId);
      if (!current) return;
      current.delete(handler);
      if (current.size === 0) this._updateHandlers.delete(sessionId);
    };
  }

  /**
   * 创建新会话或零冷启动恢复已有 CLI 会话。
   *
   * @param {{ rawId?: string | null, cwd: string }} opts
   * @returns {Promise<{ sessionId: string, currentModelId: string | null }>}
   */
  async ensureSession({ rawId, cwd }) {
    await this.ensureReady();
    const safeCwd = cwd || this._defaultCwd;

    if (rawId && this._sessions.has(rawId)) {
      const info = this._sessions.get(rawId);
      return { sessionId: rawId, currentModelId: info.currentModelId };
    }

    if (rawId) {
      let res;
      try {
        res = await this._request('session/resume', { sessionId: rawId, cwd: safeCwd, mcpServers: [] });
      } catch {
        res = await this._request('session/load', { sessionId: rawId, cwd: safeCwd, mcpServers: [] });
      }
      const sid = typeof res?.sessionId === 'string' && res.sessionId ? res.sessionId : rawId;
      const currentModelId = typeof res?.models?.currentModelId === 'string' ? res.models.currentModelId : null;
      this._sessions.set(sid, { currentModelId });
      return { sessionId: sid, currentModelId };
    }

    const created = await this._request('session/new', { cwd: safeCwd, mcpServers: [] });
    const sid = typeof created?.sessionId === 'string' ? created.sessionId : null;
    if (!sid) {
      throw new Error('ACP session/new did not return a sessionId');
    }
    const currentModelId = typeof created?.models?.currentModelId === 'string' ? created.models.currentModelId : null;
    this._sessions.set(sid, { currentModelId });
    return { sessionId: sid, currentModelId };
  }

  /**
   * 切换指定会话的模型（若已处于目标模型则跳过重复 RPC）。
   *
   * @param {string} sessionId
   * @param {string | null | undefined} modelId
   */
  async setModel(sessionId, modelId) {
    if (!sessionId || !modelId) return;
    const entry = this._sessions.get(sessionId);
    if (entry && entry.currentModelId === modelId) return;
    await this._request('session/set_model', { sessionId, modelId });
    if (entry) {
      entry.currentModelId = modelId;
    } else {
      this._sessions.set(sessionId, { currentModelId: modelId });
    }
  }

  /**
   * 向指定会话发送一轮 prompt，实时回调 `session/update` 直到本轮完成。
   *
   * @param {{
   *   sessionId: string,
   *   prompt: Array<object>,
   *   onUpdate?: (update: object) => void,
   * }} req
   * @returns {Promise<object>}
   */
  async prompt({ sessionId, prompt, onUpdate }) {
    const off = typeof onUpdate === 'function' ? this.onSessionUpdate(sessionId, onUpdate) : () => {};
    try {
      return await this._request('session/prompt', { sessionId, prompt }, PROMPT_RPC_TIMEOUT_MS);
    } finally {
      off();
    }
  }

  /**
   * 优雅取消正在执行的会话轮次（不终止常驻 ACP 进程）。
   *
   * @param {string} sessionId
   */
  cancel(sessionId) {
    if (!sessionId || !this.isAlive) return;
    this._notify('session/cancel', { sessionId });
  }

  /**
   * 释放常驻子进程与所有挂起请求。
   */
  dispose() {
    this._disposed = true;
    const child = this._child;
    this._child = null;
    this._readyPromise = null;
    this._sessions.clear();
    this._updateHandlers.clear();
    for (const [id, entry] of this._pending.entries()) {
      if (entry.timer) clearTimeout(entry.timer);
      this._pending.delete(id);
      entry.reject(new Error('AntigravityAcpClient disposed'));
    }
    if (child) {
      try {
        child.kill();
      } catch {
        // ignore
      }
    }
  }
}
