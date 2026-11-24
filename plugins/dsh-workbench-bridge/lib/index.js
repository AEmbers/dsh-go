/**
 * @file DSH Workbench Bridge 插件入口：向 DSH webServer 注册多 CLI 聚合路由，并可选挂载到 ds-harness-remote E2EE RPC 通道。
 */
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  listBridgeDirectory,
  readBridgeFileBytes,
  readBridgeFileText,
  statBridgeFile,
} from './files.js';
import { makeBridgeGuard } from './guard.js';
import { listCliEngineModels } from './models.js';
import { CliRunManager } from './runner.js';
import { CLI_ENGINES, computeEtag, isSafeSessionId } from './scanners/common.js';
import { probeCliEngines, readCliSessionMessages, scanAllCliSessions } from './scanners/index.js';

export const name = 'dsh-workbench-bridge';
export const BASE = '/plugins/dsh-workbench-bridge';

const MAX_BODY_BYTES = 16 * 1024 * 1024;
const MAX_MESSAGES_BYTES = 2 * 1024 * 1024;
const RPC_BRIDGE_PATCH_KEY = Symbol.for('dsh-workbench-bridge.rpc-patch');

/**
 * 读取 Node.js IncomingMessage 的 UTF-8 请求体，并在超出上限时报错。
 *
 * @param {any} req
 * @param {number} maxBytes
 * @returns {Promise<string>}
 */
function readNodeTextBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let settled = false;
    const fail = (err) => {
      if (settled) return;
      settled = true;
      reject(err);
    };
    req.on('data', (chunk) => {
      if (settled) return;
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += buf.length;
      if (total > maxBytes) {
        req.resume?.();
        fail(Object.assign(new Error('Request body too large'), { status: 413, code: 'payload_too_large' }));
        return;
      }
      chunks.push(buf);
    });
    req.on('end', () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks).toString('utf8'));
    });
    req.on('error', fail);
  });
}

/**
 * 读取 JSON 请求体（带大小限制，兼容 Fetch Request 与 Node IncomingMessage）。
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
  if (req && typeof req.on === 'function') {
    const rawText = await readNodeTextBody(req, MAX_BODY_BYTES);
    if (!rawText.trim()) return {};
    const parsed = JSON.parse(rawText);
    return parsed && typeof parsed === 'object' ? parsed : {};
  }
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
 * 按字节预算从尾部保留最新消息，避免超出远程 RPC 单帧响应限制。
 *
 * @param {Array<object>} messages
 * @param {number} maxBytes
 * @returns {Array<object>}
 */
function boundMessagesBySize(messages, maxBytes = MAX_MESSAGES_BYTES) {
  if (!Array.isArray(messages) || messages.length === 0) return [];
  const totalBytes = Buffer.byteLength(JSON.stringify(messages), 'utf8');
  if (totalBytes <= maxBytes) return messages;
  const kept = [];
  let bytes = 2; // []
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const item = messages[i];
    const encodedLen = Buffer.byteLength(JSON.stringify(item), 'utf8') + (kept.length > 0 ? 1 : 0);
    if (bytes + encodedLen > maxBytes && kept.length > 0) break;
    kept.push(item);
    bytes += encodedLen;
  }
  kept.reverse();
  return kept;
}

/**
 * 创建全部路由处理函数（同时供 HTTP 路由、ds-harness-remote RPC 与独立测试使用）。
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

  function buildHealthPayload() {
    const engines = probeCliEngines({ binaries: options.binaries });
    return { ok: true, plugin: name, engines };
  }

  function buildSessionsPayload() {
    const scanned = scanAllCliSessions({ roots: options.roots });
    const sessions = mergeScannedWithRuns(scanned, runner);
    const payload = { ok: true, sessions };
    const etag = computeEtag(JSON.stringify(payload));
    return { payload, etag };
  }

  function buildMessagesPayload(engine, rawId) {
    if (!CLI_ENGINES.has(engine) || !isSafeSessionId(rawId)) {
      const err = new Error('Invalid engine or session id');
      err.status = 400;
      err.code = 'invalid_target';
      throw err;
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
        const userParts = [{ type: 'text', text: overlay.prompt }];
        if (Array.isArray(overlay.attachments)) {
          for (const att of overlay.attachments) {
            const isImg =
              /^image\//i.test(att.mediaType || '') ||
              /\.(png|jpe?g|webp|gif|bmp|heic|heif)$/i.test(att.name || '');
            if (isImg) {
              userParts.push({
                type: 'image',
                attachment: {
                  attachmentId: `wb-upload:${att.uploadId}`,
                  mediaType: att.mediaType || 'image/jpeg',
                  name: att.name,
                  bytes: att.bytes,
                },
              });
            } else {
              userParts.push({
                type: 'file',
                attachment: {
                  attachmentId: att.uploadId,
                  name: att.name,
                  bytes: att.bytes,
                },
              });
            }
          }
        }
        messages.push({
          messageId: `run-user-${overlay.runId}`,
          role: 'user',
          createdAt: overlay.startedAt,
          parts: userParts,
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

    return {
      ok: true,
      engine,
      rawId,
      sessionId: `cli:${engine}:${rawId}`,
      resolvedSessionId:
        overlay?.resolvedRawId && overlay.resolvedRawId !== rawId
          ? `cli:${engine}:${overlay.resolvedRawId}`
          : null,
      model: overlay?.model || read.model || null,
      cwd: overlay?.cwd || read.cwd || null,
      running: Boolean(overlay?.running || read.running),
      messages: boundMessagesBySize(messages),
    };
  }

  async function buildModelsPayload(engine, opts = {}) {
    return listCliEngineModels(String(engine || ''), {
      refresh: opts.refresh === true,
      binaries: options.binaries,
      roots: options.roots,
    });
  }

  function runUploadPayload(body) {
    const safeBody = body && typeof body === 'object' ? body : {};
    return runner.saveUploadChunk({
      uploadId: typeof safeBody.uploadId === 'string' ? safeBody.uploadId : null,
      name: typeof safeBody.name === 'string' ? safeBody.name : 'attachment.bin',
      mediaType: typeof safeBody.mediaType === 'string' ? safeBody.mediaType : 'application/octet-stream',
      offset: typeof safeBody.offset === 'number' ? safeBody.offset : 0,
      chunkBase64: typeof safeBody.chunkBase64 === 'string' ? safeBody.chunkBase64 : '',
      done: safeBody.done !== false,
    });
  }

  function runPromptPayload(body) {
    const safeBody = body && typeof body === 'object' ? body : {};
    return runner.startRun({
      engine: safeBody.engine,
      rawSessionId: safeBody.rawSessionId ?? safeBody.sessionId ?? null,
      cwd: typeof safeBody.cwd === 'string' ? safeBody.cwd : null,
      prompt: safeBody.prompt,
      model: typeof safeBody.model === 'string' ? safeBody.model : null,
      reasoningEffort: typeof safeBody.reasoningEffort === 'string' ? safeBody.reasoningEffort : null,
      attachmentIds: Array.isArray(safeBody.attachmentIds) ? safeBody.attachmentIds : undefined,
      attachments: Array.isArray(safeBody.attachments) ? safeBody.attachments : undefined,
    });
  }

  function runAbortPayload(body) {
    const safeBody = body && typeof body === 'object' ? body : {};
    const engine = String(safeBody.engine || '');
    const rawId = String(safeBody.rawSessionId ?? safeBody.rawId ?? safeBody.sessionId ?? '');
    if (!CLI_ENGINES.has(engine) || !isSafeSessionId(rawId)) {
      const err = new Error('Invalid engine or session id');
      err.status = 400;
      err.code = 'invalid_target';
      throw err;
    }
    const aborted = runner.abortRun(engine, rawId);
    return { ok: true, aborted };
  }

  async function handleHealth(req) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    return jsonResponse(200, buildHealthPayload());
  }

  async function handleSessions(req) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    const { payload, etag } = buildSessionsPayload();
    const ifNoneMatch = typeof req?.headers?.get === 'function' ? req.headers.get('if-none-match') : req?.headers?.['if-none-match'];
    if (ifNoneMatch && ifNoneMatch === etag) {
      return new Response(null, { status: 304, headers: { etag } });
    }
    return jsonResponse(200, payload, { etag });
  }

  async function handleMessages(req, engine, rawId) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    try {
      return jsonResponse(200, buildMessagesPayload(engine, rawId));
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'invalid_target', message: err.message });
    }
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
      return jsonResponse(200, runPromptPayload(body));
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
    try {
      return jsonResponse(200, runAbortPayload(body));
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'invalid_target', message: err.message });
    }
  }

  async function handleModels(req, engine, refresh = false) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    try {
      return jsonResponse(200, await buildModelsPayload(engine, { refresh }));
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'invalid_engine', message: err.message });
    }
  }

  async function handleUpload(req) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    let body;
    try {
      body = await readJsonBody(req);
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'bad_json', message: err.message });
    }
    try {
      return jsonResponse(200, runUploadPayload(body));
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'upload_failed', message: err.message });
    }
  }

  function buildFileStatPayload(body) {
    const safeBody = body && typeof body === 'object' ? body : {};
    return statBridgeFile(
      {
        engine: safeBody.engine,
        rawId: safeBody.rawId ?? safeBody.rawSessionId ?? safeBody.sessionId,
        path: safeBody.path,
      },
      { roots: options.roots, runner },
    );
  }

  function buildFileReadBytesPayload(body) {
    const safeBody = body && typeof body === 'object' ? body : {};
    return readBridgeFileBytes(
      {
        engine: safeBody.engine,
        rawId: safeBody.rawId ?? safeBody.rawSessionId ?? safeBody.sessionId,
        path: safeBody.path,
        offset: safeBody.offset,
        length: safeBody.length,
      },
      { roots: options.roots, runner },
    );
  }

  function buildFileReadTextPayload(body) {
    const safeBody = body && typeof body === 'object' ? body : {};
    return readBridgeFileText(
      {
        engine: safeBody.engine,
        rawId: safeBody.rawId ?? safeBody.rawSessionId ?? safeBody.sessionId,
        path: safeBody.path,
        offset: safeBody.offset,
        limit: safeBody.limit,
      },
      { roots: options.roots, runner },
    );
  }

  function buildFileListPayload(body) {
    const safeBody = body && typeof body === 'object' ? body : {};
    return listBridgeDirectory(
      {
        engine: safeBody.engine,
        rawId: safeBody.rawId ?? safeBody.rawSessionId ?? safeBody.sessionId,
        path: safeBody.path,
      },
      { roots: options.roots, runner },
    );
  }

  async function handleFileAction(req, fn) {
    const blocked = rejectIfNeeded(req);
    if (blocked) return blocked;
    let body;
    try {
      body = await readJsonBody(req);
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'bad_json', message: err.message });
    }
    try {
      return jsonResponse(200, fn(body));
    } catch (err) {
      return jsonResponse(err.status || 400, { code: err.code || 'workspace-file/read-failed', message: err.message });
    }
  }

  return {
    runner,
    buildHealthPayload,
    buildSessionsPayload,
    buildMessagesPayload,
    buildModelsPayload,
    runUploadPayload,
    runPromptPayload,
    runAbortPayload,
    buildFileStatPayload,
    buildFileReadBytesPayload,
    buildFileReadTextPayload,
    buildFileListPayload,
    handleHealth,
    handleSessions,
    handleMessages,
    handleModels,
    handleUpload,
    handlePrompt,
    handleAbort,
    handleFileStat: (req) => handleFileAction(req, buildFileStatPayload),
    handleFileReadBytes: (req) => handleFileAction(req, buildFileReadBytesPayload),
    handleFileReadText: (req) => handleFileAction(req, buildFileReadTextPayload),
    handleFileList: (req) => handleFileAction(req, buildFileListPayload),
  };
}

async function writeNodeResponse(res, response) {
  const headers = {};
  response.headers.forEach((value, key) => {
    headers[key] = value;
  });
  res.writeHead(response.status, headers);
  if (response.status === 204 || response.status === 304) {
    res.end();
    return;
  }
  res.end(await response.text());
}

/**
 * 构建适配真实 DSH Node.js webServer (`kind: 'prefix'`) 的请求处理器。
 *
 * @param {ReturnType<typeof createWorkbenchRoutes>} routes
 * @returns {(req: any, res: any) => Promise<void>}
 */
export function createNodePrefixHandler(routes) {
  return async (req, res) => {
    try {
      const url = new URL(req.url ?? '/', 'http://localhost');
      const pathname = url.pathname.replace(/\/+$/, '') || '/';
      const method = String(req.method || 'GET').toUpperCase();
      let response;

      if (pathname === `${BASE}/health`) {
        response = method === 'GET' ? await routes.handleHealth(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/sessions`) {
        response = method === 'GET' ? await routes.handleSessions(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/models`) {
        const engine = url.searchParams.get('engine') || '';
        const refresh = url.searchParams.get('refresh') === '1' || url.searchParams.get('refresh') === 'true';
        response = method === 'GET' ? await routes.handleModels(req, engine, refresh) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname.startsWith(`${BASE}/models/`)) {
        const engine = decodeURIComponent(pathname.slice(`${BASE}/models/`.length));
        const refresh = url.searchParams.get('refresh') === '1' || url.searchParams.get('refresh') === 'true';
        response = method === 'GET' ? await routes.handleModels(req, engine, refresh) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/uploads`) {
        response = method === 'POST' ? await routes.handleUpload(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/sessions/prompt`) {
        response = method === 'POST' ? await routes.handlePrompt(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/sessions/abort`) {
        response = method === 'POST' ? await routes.handleAbort(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/files/stat`) {
        response = method === 'POST' ? await routes.handleFileStat(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/files/read-bytes`) {
        response = method === 'POST' ? await routes.handleFileReadBytes(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/files/read-text`) {
        response = method === 'POST' ? await routes.handleFileReadText(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname === `${BASE}/files/list`) {
        response = method === 'POST' ? await routes.handleFileList(req) : jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
      } else if (pathname.startsWith(`${BASE}/sessions/`) && pathname.endsWith('/messages')) {
        if (method !== 'GET') {
          response = jsonResponse(405, { code: 'method_not_allowed', message: 'Method not allowed' });
        } else {
          const rest = pathname.slice(`${BASE}/sessions/`.length, -'/messages'.length);
          const parts = rest.split('/');
          if (parts.length !== 2) {
            response = jsonResponse(404, { code: 'not_found', message: 'Route not found' });
          } else {
            response = await routes.handleMessages(req, decodeURIComponent(parts[0]), decodeURIComponent(parts[1]));
          }
        }
      } else {
        response = jsonResponse(404, { code: 'not_found', message: 'Route not found' });
      }
      await writeNodeResponse(res, response);
    } catch (err) {
      if (!res.headersSent) {
        await writeNodeResponse(res, jsonResponse(500, { code: 'internal_error', message: String(err?.message || err) }));
      } else if (!res.writableEnded) {
        res.end();
      }
    }
  };
}

/**
 * 将 `workbench.bridge.*` E2EE RPC 方法挂接到 `ds-harness-remote` 的 `RpcRouter.prototype.invoke`。
 * 仅在已经过 Noise_IK 双向认证与设备配对授权的会话中触发；卸载时完整还原原方法。
 *
 * @param {{ prototype?: { invoke?: Function } }} RpcRouterClass
 * @param {ReturnType<typeof createWorkbenchRoutes>} routes
 * @param {new (code: string, message: string, details?: object) => Error} [RpcErrorClass]
 * @returns {() => void}
 */
export function attachRemoteRpcBridge(RpcRouterClass, routes, RpcErrorClass) {
  const proto = RpcRouterClass?.prototype;
  if (!proto || typeof proto.invoke !== 'function') {
    return () => {};
  }
  const existing = proto[RPC_BRIDGE_PATCH_KEY];
  if (existing && typeof existing.dispose === 'function') {
    existing.dispose();
  }
  const originalInvoke = proto.invoke;
  const originalHandle = typeof proto.handle === 'function' ? proto.handle : null;

  function toRpcError(code, err) {
    const msg = String(err?.message || err || 'Workbench bridge RPC failed');
    const explicitCode =
      typeof err?.code === 'string' && err.code.startsWith('workspace-file/') ? err.code : null;
    const mappedCode = explicitCode || code || (err?.status === 400 ? 'INVALID_MESSAGE' : 'FAILED');
    if (typeof RpcErrorClass === 'function') {
      return new RpcErrorClass(mappedCode, msg, err?.code ? { bridgeCode: err.code } : undefined);
    }
    const e = new Error(msg);
    e.code = mappedCode;
    return e;
  }

  proto.invoke = async function patchedWorkbenchInvoke(method, params) {
    if (typeof method === 'string' && method.startsWith('workbench.bridge.')) {
      const p = params && typeof params === 'object' ? params : {};
      try {
        switch (method) {
          case 'workbench.bridge.health':
            return routes.buildHealthPayload();
          case 'workbench.bridge.sessions': {
            const { payload, etag } = routes.buildSessionsPayload();
            const ifNoneMatch = typeof p.ifNoneMatch === 'string' ? p.ifNoneMatch : null;
            if (ifNoneMatch && ifNoneMatch === etag) {
              return { ok: true, notModified: true, etag };
            }
            return { ...payload, etag };
          }
          case 'workbench.bridge.messages':
            return routes.buildMessagesPayload(String(p.engine || ''), String(p.rawId || ''));
          case 'workbench.bridge.models':
            return await routes.buildModelsPayload(String(p.engine || ''), { refresh: p.refresh === true });
          case 'workbench.bridge.upload':
            return routes.runUploadPayload(p);
          case 'workbench.bridge.prompt':
            return routes.runPromptPayload(p);
          case 'workbench.bridge.abort':
            return routes.runAbortPayload(p);
          case 'workbench.bridge.file.stat':
            return routes.buildFileStatPayload(p);
          case 'workbench.bridge.file.readBytes':
            return routes.buildFileReadBytesPayload(p);
          case 'workbench.bridge.file.readText':
            return routes.buildFileReadTextPayload(p);
          case 'workbench.bridge.file.list':
            return routes.buildFileListPayload(p);
          default:
            break;
        }
      } catch (err) {
        throw toRpcError(err?.status === 400 ? 'INVALID_MESSAGE' : 'FAILED', err);
      }
    }
    return originalInvoke.call(this, method, params);
  };

  if (originalHandle) {
    proto.handle = async function patchedWorkbenchHandle(message) {
      const method = message?.type === 'rpc.request' ? message?.payload?.method : null;
      if (typeof method === 'string' && method.startsWith('workbench.bridge.')) {
        const startedAt = performance.now();
        try {
          const result = await this.invoke(method, message?.payload?.params);
          this.logger?.info?.('host rpc ok', {
            method,
            durationMs: Math.round(performance.now() - startedAt),
          });
          return {
            v: 1,
            id: randomUUID(),
            type: 'rpc.response',
            timestamp: Date.now(),
            payload: { requestId: message.id, result },
          };
        } catch (err) {
          const code = String(err?.code || 'FAILED');
          const msg = String(err?.message || err || 'Workbench bridge RPC failed');
          this.logger?.warn?.('host rpc failed', {
            method,
            durationMs: Math.round(performance.now() - startedAt),
            code,
            retryable: false,
          });
          return {
            v: 1,
            id: randomUUID(),
            type: 'rpc.error',
            timestamp: Date.now(),
            payload: { requestId: message.id, code, message: msg, retryable: false },
          };
        }
      }
      return originalHandle.call(this, message);
    };
  }

  const dispose = () => {
    if (proto[RPC_BRIDGE_PATCH_KEY]?.dispose === dispose) {
      proto.invoke = originalInvoke;
      if (originalHandle) {
        proto.handle = originalHandle;
      }
      delete proto[RPC_BRIDGE_PATCH_KEY];
    }
  };
  proto[RPC_BRIDGE_PATCH_KEY] = { dispose };
  return dispose;
}

/**
 * 解析并挂接宿主环境中的 `ds-harness-remote`（若未安装则安静跳过）。
 *
 * @param {ReturnType<typeof createWorkbenchRoutes>} routes
 * @param {any} ctx
 * @returns {() => void}
 */
export function installRemoteRpcBridge(routes, ctx) {
  let disposed = false;
  let detach = () => {};

  const safeProp = (obj, prop) => {
    try {
      return typeof obj?.get === 'function' ? obj.get(prop) : obj?.[prop];
    } catch {
      return undefined;
    }
  };
  const candidates = [
    safeProp(ctx, 'baseDir'),
    safeProp(safeProp(ctx, 'root'), 'baseDir'),
    process.cwd(),
    path.join(os.homedir(), '.dsh', 'profiles', 'desktop'),
    import.meta.dirname,
  ].filter((dir) => typeof dir === 'string' && dir.length > 0);

  let resolvedPath = null;
  for (const dir of candidates) {
    try {
      const req = createRequire(path.join(dir, 'package.json'));
      resolvedPath = req.resolve('ds-harness-remote');
      if (resolvedPath) break;
    } catch {
      // 当前目录未安装 ds-harness-remote，继续探测下一个候选目录
    }
  }

  if (resolvedPath) {
    import(pathToFileURL(resolvedPath).href)
      .then((mod) => {
        if (disposed) return;
        if (mod?.RpcRouter) {
          detach = attachRemoteRpcBridge(mod.RpcRouter, routes, mod.RpcError);
        }
      })
      .catch(() => {
        // 忽略无法加载 ds-harness-remote 的宿主环境
      });
  }

  return () => {
    disposed = true;
    detach();
  };
}

/**
 * Cordis 插件入口函数。
 *
 * @param {any} ctx
 */
export function apply(ctx) {
  const routes = createWorkbenchRoutes(ctx);
  const disposeRpc = installRemoteRpcBridge(routes, ctx);
  ctx?.on?.('dispose', () => {
    disposeRpc();
    routes.runner.dispose();
  });

  ctx?.inject?.(['webServer'], (webCtx) => {
    const webServer = webCtx.webServer ?? webCtx.get?.('webServer');
    if (!webServer || typeof webServer.register !== 'function') return;

    const handler = createNodePrefixHandler(routes);
    if (typeof webCtx.effect === 'function') {
      webCtx.effect(
        () => webServer.register({ kind: 'prefix', path: BASE, handler }),
        'dsh-workbench-bridge: HTTP routes',
      );
      return;
    }
    const disposeRoute = webServer.register({ kind: 'prefix', path: BASE, handler });
    webCtx.on?.('dispose', () => {
      if (typeof disposeRoute === 'function') disposeRoute();
    });
  });
}
