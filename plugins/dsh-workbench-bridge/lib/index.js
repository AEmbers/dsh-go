/**
 * @file DSH Workbench Bridge 插件入口：向 DSH webServer 注册多 CLI 聚合路由。
 */
import { makeBridgeGuard } from './guard.js';
import { CliRunManager } from './runner.js';
import { CLI_ENGINES, computeEtag, isSafeSessionId } from './scanners/common.js';
import { probeCliEngines, readCliSessionMessages, scanAllCliSessions } from './scanners/index.js';

export const name = 'dsh-workbench-bridge';
export const BASE = '/plugins/dsh-workbench-bridge';

const MAX_BODY_BYTES = 1024 * 1024;

/**
 * 读取 JSON 请求体（带大小限制，兼容 Fetch Request 或 Node IncomingMessage）。
 *
 * @param {any} req
 * @returns {Promise<Record<string, unknown>>}
 */
async function readJsonBody(req) {
  if (req && typeof req.json === 'function') {
    const rawText = await req.text();
    if (Buffer.byteLength(rawText, 'utf8') > MAX_BODY_BYTES) {
      throw Object.assign(new Error('Request body too large'), { status: 413, code: 'payload_too_large' });
    }
    if (!rawText.trim()) return {};
    const parsed = JSON.parse(rawText);
    return parsed && typeof parsed === 'object' ? parsed : {};
  }
  if (req?.body && typeof req.body === 'object') return req.body;
  return {};
}

function jsonResponse(status, data, extraHeaders = {}) {
  const text = JSON.stringify(data);
  return new Response(text, {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      ...extraHeaders,
    },
  });
}

/**
 * 合并静态扫描的会话列表与当前进程管理器中的实时运行态。
 *
 * @param {Array<object>} scanned
 * @param {CliRunManager} runner
 * @returns {Array<object>}
 */
export function mergeScannedWithRuns(scanned, runner) {
  const activeRuns = runner.listActiveRuns();
  const activeByKey = new Map(activeRuns.map((r) => [`${r.engine}:${r.rawId}`, r]));
  const result = scanned.map((item) => {
    const active = activeByKey.get(`${item.engine}:${item.rawId}`);
    if (!active) return item;
    activeByKey.delete(`${item.engine}:${item.rawId}`);
    return {
      ...item,
      running: true,
      updatedAt: Math.max(item.updatedAt, active.updatedAt),
    };
  });
  for (const pending of activeByKey.values()) {
    result.unshift({
      engine: pending.engine,
      rawId: pending.rawId,
      sessionId: pending.sessionId,
      title: pending.prompt.split(/\r?\n/)[0].slice(0, 80),
      cwd: pending.cwd,
      updatedAt: pending.updatedAt,
      running: true,
      blank: false,
      model: pending.model,
    });
  }
  result.sort((a, b) => b.updatedAt - a.updatedAt);
  return result;
}

/**
 * 创建全部路由处理函数（同时供插件注册与独立测试使用）。
 *
 * @param {object} ctx
 * @param {{ roots?: object, binaries?: object, runner?: CliRunManager, requireConnection?: boolean }} [options]
 */
export function createWorkbenchRoutes(ctx, options = {}) {
  const guard = makeBridgeGuard(ctx, { requireConnection: options.requireConnection ?? true });
  const runner = options.runner || new CliRunManager();

  const rejectIfNeeded = (req) => {
    const err = guard(req);
    return err ? jsonResponse(err.status, err.body) : null;
  };

  async function handleHealth(req) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    const engines = probeCliEngines({ binaries: options.binaries });
    return jsonResponse(200, { ok: true, plugin: name, engines });
  }

  async function handleSessions(req) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    const scanned = scanAllCliSessions({ roots: options.roots });
    const sessions = mergeScannedWithRuns(scanned, runner);
    const payload = { ok: true, sessions };
    const etag = computeEtag(JSON.stringify(payload));
    const ifNoneMatch = typeof req?.headers?.get === 'function' ? req.headers.get('if-none-match') : req?.headers?.['if-none-match'];
    if (ifNoneMatch && ifNoneMatch === etag) {
      return new Response(null, { status: 304, headers: { etag } });
    }
    return jsonResponse(200, payload, { etag });
  }

  async function handleMessages(req, engine, rawId) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    if (!CLI_ENGINES.has(engine) || !isSafeSessionId(rawId)) {
      return jsonResponse(400, { code: 'invalid_target', message: 'Invalid engine or session id' });
    }
    const overlay = runner.getOverlay(engine, rawId);
    const targetReadId = overlay?.resolvedRawId || rawId;
    const read = readCliSessionMessages(engine, targetReadId, { roots: options.roots });
    const messages = [...read.messages];

    if (overlay) {
      // 当刚发出的 prompt 尚未落盘时附加到尾部，确保手机端实时看到发送与输出
      const lastUser = [...messages].reverse().find((m) => m.role === 'user');
      const lastUserText = lastUser?.parts?.find((p) => p.type === 'text')?.text?.trim();
      if (lastUserText !== overlay.prompt.trim()) {
        messages.push({
          messageId: `run-user-${overlay.runId}`,
          role: 'user',
          createdAt: overlay.startedAt,
          parts: [{ type: 'text', text: overlay.prompt }],
        });
      }
      if (overlay.running || overlay.assistantText || overlay.assistantReasoning || overlay.errorText) {
        const parts = [];
        if (overlay.assistantReasoning) {
          parts.push({ type: 'reasoning', text: overlay.assistantReasoning });
        }
        if (overlay.assistantText) {
          parts.push({ type: 'text', text: overlay.assistantText });
        } else if (overlay.errorText && !overlay.running) {
          parts.push({ type: 'text', text: overlay.errorText.trim() });
        }
        if (parts.length > 0) {
          messages.push({
            messageId: `run-assistant-${overlay.runId}`,
            role: 'assistant',
            createdAt: overlay.updatedAt,
            model: overlay.model || read.model,
            parts,
          });
        }
      }
    }

    return jsonResponse(200, {
      ok: true,
      engine,
      rawId,
      sessionId: `cli:${engine}:${rawId}`,
      model: overlay?.model || read.model || null,
      cwd: overlay?.cwd || read.cwd || null,
      running: Boolean(overlay?.running),
      messages,
    });
  }

  async function handlePrompt(req) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    let body;
    try {
      body = await readJsonBody(req);
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'bad_json', message: err.message });
    }
    try {
      const result = runner.startRun({
        engine: body.engine,
        rawSessionId: body.rawSessionId ?? body.sessionId ?? null,
        cwd: typeof body.cwd === 'string' ? body.cwd : null,
        prompt: body.prompt,
        model: typeof body.model === 'string' ? body.model : null,
      });
      return jsonResponse(200, result);
    } catch (err) {
      return jsonResponse(err.status || 500, { code: err.code || 'prompt_failed', message: err.message });
    }
  }

  async function handleAbort(req) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    let body;
    try {
      body = await readJsonBody(req);
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'bad_json', message: err.message });
    }
    const engine = String(body.engine || '');
    const rawId = String(body.rawSessionId ?? body.sessionId ?? '');
    if (!CLI_ENGINES.has(engine) || !isSafeSessionId(rawId)) {
      return jsonResponse(400, { code: 'invalid_target', message: 'Invalid engine or session id' });
    }
    const aborted = runner.abortRun(engine, rawId);
    return jsonResponse(200, { ok: true, aborted });
  }

  return {
    runner,
    handleHealth,
    handleSessions,
    handleMessages,
    handlePrompt,
    handleAbort,
  };
}

/**
 * Cordis 插件入口函数。
 *
 * @param {any} ctx
 */
export function apply(ctx) {
  ctx.inject(['webServer'], (webCtx) => {
    const webServer = webCtx.get('webServer');
    if (!webServer || typeof webServer.register !== 'function') return;

    const routes = createWorkbenchRoutes(webCtx);
    const disposers = [];
    const reg = (method, path, handler) => {
      const d = webServer.register({ method, path, handler });
      if (typeof d === 'function') disposers.push(d);
    };

    reg('GET', `${BASE}/health`, routes.handleHealth);
    reg('GET', `${BASE}/sessions`, routes.handleSessions);
    reg('POST', `${BASE}/sessions/prompt`, routes.handlePrompt);
    reg('POST', `${BASE}/sessions/abort`, routes.handleAbort);
    reg('GET', `${BASE}/sessions/:engine/:id/messages`, (req) => {
      const url = new URL(req.url, 'http://localhost');
      const segs = url.pathname.replace(/\/+$/, '').split('/');
      const rawId = decodeURIComponent(segs[segs.length - 2] || '');
      const engine = decodeURIComponent(segs[segs.length - 3] || '');
      return routes.handleMessages(req, engine, rawId);
    });

    webCtx.on?.('dispose', () => {
      routes.runner.dispose();
      for (const d of disposers) d();
    });
  });
}
