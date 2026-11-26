/**
 * @file 通过本机回环 HTTP(S) 将 `workbench.bridge.agentTeams.*` E2EE RPC 转发至
 * 宿主 `@nanmicoder/dsh-agent-teams` 插件接口（`/plugins/dsh-agent-teams/{state,halt,plan}`）。
 */
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';

const AGENT_TEAMS_PATHS = Object.freeze({
  state: '/plugins/dsh-agent-teams/state',
  halt: '/plugins/dsh-agent-teams/halt',
  plan: '/plugins/dsh-agent-teams/plan',
});

const DEFAULT_READ_TIMEOUT_MS = 20_000;
const DEFAULT_MUTATION_TIMEOUT_MS = 60_000;
const DEFAULT_AUTH_TIMEOUT_MS = 10_000;
const MAX_REPLY_BYTES = 4 * 1024 * 1024;
const CONTROL_CHAR_RE = /[\x00-\x1f\x7f]/;

/**
 * 校验会话或团队 ID 是否为非空安全字符串。
 *
 * @param {unknown} value
 * @returns {value is string}
 */
function isSafeId(value) {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= 256 &&
    !CONTROL_CHAR_RE.test(value)
  );
}

/**
 * 安全读取 Cordis 上下文或纯对象上的属性。
 *
 * @param {any} target
 * @param {string} key
 * @returns {any}
 */
function safeGet(target, key) {
  if (!target || typeof target !== 'object') return undefined;
  try {
    if (typeof target.get === 'function') {
      const value = target.get(key);
      if (value !== undefined) return value;
    }
    return target[key];
  } catch {
    return undefined;
  }
}

/**
 * 从响应头 `set-cookie` 提取 `Cookie` 请求头字符串。
 *
 * @param {string | string[] | undefined} setCookieHeader
 * @returns {string | null}
 */
function extractCookieHeader(setCookieHeader) {
  const entries = Array.isArray(setCookieHeader)
    ? setCookieHeader
    : typeof setCookieHeader === 'string'
      ? [setCookieHeader]
      : [];
  const pairs = [];
  for (const entry of entries) {
    if (typeof entry !== 'string') continue;
    const firstPart = entry.split(';')[0]?.trim();
    if (firstPart && firstPart.includes('=')) {
      pairs.push(firstPart);
    }
  }
  return pairs.length > 0 ? pairs.join('; ') : null;
}

/**
 * 尝试将响应文本解析为纯 JSON 对象。
 *
 * @param {string} rawText
 * @returns {Record<string, unknown> | null}
 */
function tryParseJsonObject(rawText) {
  if (typeof rawText !== 'string' || !rawText.trim()) return null;
  try {
    const parsed = JSON.parse(rawText);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * 归一化超时时间到安全范围。
 *
 * @param {unknown} raw
 * @param {number} fallbackMs
 * @returns {number}
 */
function resolveTimeoutMs(raw, fallbackMs) {
  if (typeof raw === 'number' && Number.isFinite(raw) && raw > 0) {
    return Math.min(Math.max(Math.round(raw), 500), 120_000);
  }
  return fallbackMs;
}

/**
 * 使用 Node 原生 `http`/`https` 发起单次请求，支持可选自签名 CA 与响应体积上限。
 *
 * @param {string} targetUrl
 * @param {{
 *   method?: string,
 *   headers?: Record<string, string>,
 *   body?: string,
 *   ca?: string | Buffer,
 *   timeoutMs?: number,
 *   maxBytes?: number,
 * }} [opts]
 * @returns {Promise<{ status: number, headers: Record<string, string | string[] | undefined>, rawText: string }>}
 */
function requestText(targetUrl, opts = {}) {
  const url = new URL(targetUrl);
  const isHttps = url.protocol === 'https:';
  if (!isHttps && url.protocol !== 'http:') {
    throw new Error(`Unsupported agent-teams proxy scheme: ${url.protocol}`);
  }
  const client = isHttps ? https : http;
  const maxBytes = opts.maxBytes ?? MAX_REPLY_BYTES;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_READ_TIMEOUT_MS;
  const payload = typeof opts.body === 'string' ? Buffer.from(opts.body, 'utf8') : null;
  const headers = { ...(opts.headers || {}) };
  if (payload && headers['content-length'] === undefined) {
    headers['content-length'] = String(payload.length);
  }

  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (err, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (err) reject(err);
      else resolve(value);
    };

    const reqOptions = {
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port ? Number(url.port) : isHttps ? 443 : 80,
      path: `${url.pathname}${url.search}`,
      method: opts.method || 'GET',
      headers,
      ...(isHttps && opts.ca ? { ca: opts.ca } : {}),
    };

    const req = client.request(reqOptions, (res) => {
      const chunks = [];
      let total = 0;
      res.on('data', (chunk) => {
        if (settled) return;
        const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        total += buf.length;
        if (total > maxBytes) {
          req.destroy();
          finish(
            Object.assign(new Error(`agent-teams proxy response exceeds ${maxBytes} bytes`), {
              status: 502,
              code: 'response_too_large',
            }),
          );
          return;
        }
        chunks.push(buf);
      });
      res.on('end', () => {
        finish(null, {
          status: res.statusCode ?? 502,
          headers: res.headers,
          rawText: Buffer.concat(chunks).toString('utf8'),
        });
      });
      res.on('error', (err) => finish(err));
    });

    const timer = setTimeout(() => {
      req.destroy(Object.assign(new Error(`agent-teams proxy timed out after ${timeoutMs}ms`), { status: 504 }));
    }, timeoutMs);
    timer.unref?.();

    req.on('error', (err) => finish(err));
    if (payload) req.write(payload);
    req.end();
  });
}

function buildErrorResult(status, message) {
  const body = { error: message };
  return {
    status,
    etag: null,
    body,
    rawText: JSON.stringify(body),
  };
}

/**
 * 创建 Agent Teams 代理转发器，供 `workbench.bridge.agentTeams.*` RPC 使用。
 *
 * @param {any} ctx
 * @param {{ webServer?: any, connection?: any, agentTeamsOrigin?: string }} [options]
 */
export function createAgentTeamsProxy(ctx, options = {}) {
  let cachedOrigin = null;
  let cachedCookie = null;
  let pendingCookiePromise = null;
  let cachedCaPath = null;
  let cachedCaPem;

  function getWebServer() {
    return options.webServer ?? safeGet(ctx, 'webServer') ?? safeGet(ctx, 'httpServer');
  }

  function getConnection() {
    return options.connection ?? safeGet(ctx, 'connection');
  }

  function resolveOrigin() {
    const rawOrigin =
      typeof options.agentTeamsOrigin === 'string' && options.agentTeamsOrigin.trim()
        ? options.agentTeamsOrigin.trim()
        : (() => {
            const ws = getWebServer();
            return typeof ws?.getOrigin === 'function' ? ws.getOrigin() : null;
          })();
    if (typeof rawOrigin !== 'string' || !rawOrigin.trim()) return null;
    try {
      const parsed = new URL(rawOrigin);
      if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
      return parsed.origin;
    } catch {
      return null;
    }
  }

  function resolveCa(origin) {
    if (!origin.startsWith('https://')) return undefined;
    const certFile = getWebServer()?.tlsConfig?.certFile;
    if (typeof certFile !== 'string' || !certFile.trim()) return undefined;
    if (cachedCaPath === certFile && cachedCaPem !== undefined) {
      return cachedCaPem;
    }
    try {
      cachedCaPem = fs.readFileSync(certFile, 'utf8');
      cachedCaPath = certFile;
      return cachedCaPem;
    } catch {
      return undefined;
    }
  }

  /**
   * 通过宿主官方 `connection.authenticatedUrl` 换取已签名的本地会话 Cookie。
   * 先请求 `/`（`authorizeIndex`），若未返回 Cookie 则回退至 `/connect`（`authorizeConnect`）。
   */
  async function acquireAuthCookie(origin, ca, { force = false } = {}) {
    if (cachedOrigin !== origin) {
      cachedOrigin = origin;
      cachedCookie = null;
      pendingCookiePromise = null;
    }
    if (!force && cachedCookie) return cachedCookie;
    const connection = getConnection();
    if (!connection || typeof connection.authenticatedUrl !== 'function') {
      return null;
    }
    if (pendingCookiePromise && !force) {
      return pendingCookiePromise;
    }

    const loader = (async () => {
      const candidates = [`${origin}/`, `${origin}/connect`];
      for (const baseUrl of candidates) {
        let authUrl;
        try {
          authUrl = connection.authenticatedUrl(baseUrl);
        } catch {
          continue;
        }
        if (typeof authUrl !== 'string' || !authUrl) continue;
        try {
          const res = await requestText(authUrl, {
            method: 'GET',
            ca,
            timeoutMs: DEFAULT_AUTH_TIMEOUT_MS,
          });
          const cookie = extractCookieHeader(res.headers['set-cookie']);
          if (cookie) {
            cachedCookie = cookie;
            return cookie;
          }
        } catch {
          // 当前候选路径不可用或超时，继续尝试下一个认证端点
        }
      }
      return null;
    })().finally(() => {
      if (pendingCookiePromise === loader) {
        pendingCookiePromise = null;
      }
    });

    pendingCookiePromise = loader;
    return loader;
  }

  /**
   * 仅转发至 `/plugins/dsh-agent-teams/*` 固定白名单路径，401/403 时自动刷新 Cookie 并重试 1 次。
   */
  async function forwardRequest({ path, method, query, headers = {}, body, timeoutMs }) {
    const origin = resolveOrigin();
    if (!origin) {
      return buildErrorResult(503, 'host webServer unavailable');
    }
    const ca = resolveCa(origin);
    const url = new URL(path, origin);
    if (query) {
      for (const [key, val] of Object.entries(query)) {
        if (val !== undefined && val !== null && val !== '') {
          url.searchParams.set(key, String(val));
        }
      }
    }

    const executeOnce = async (cookie) => {
      const reqHeaders = {
        accept: 'application/json',
        ...headers,
        ...(cookie ? { cookie } : {}),
      };
      return requestText(url.href, {
        method,
        headers: reqHeaders,
        body,
        ca,
        timeoutMs,
        maxBytes: MAX_REPLY_BYTES,
      });
    };

    try {
      let cookie = await acquireAuthCookie(origin, ca);
      let res = await executeOnce(cookie);

      // 若凭据失效且宿主提供官方鉴权通道，清空缓存刷新一次 Cookie 后重放 1 次
      if ((res.status === 401 || res.status === 403) && getConnection()?.authenticatedUrl) {
        cachedCookie = null;
        cookie = await acquireAuthCookie(origin, ca, { force: true });
        if (cookie) {
          res = await executeOnce(cookie);
        }
      }

      const rawEtag = res.headers.etag;
      const etag = Array.isArray(rawEtag) ? rawEtag[0] : typeof rawEtag === 'string' ? rawEtag : null;
      if (res.status === 304) {
        return {
          status: 304,
          etag: etag || headers['if-none-match'] || null,
        };
      }

      const parsedBody = tryParseJsonObject(res.rawText);
      if (res.status === 200 && parsedBody) {
        return {
          status: 200,
          etag,
          body: parsedBody,
        };
      }
      return {
        status: res.status,
        etag,
        body: parsedBody,
        rawText: res.rawText,
      };
    } catch (err) {
      const status = typeof err?.status === 'number' ? err.status : 502;
      return buildErrorResult(status, String(err?.message || err || 'agent-teams proxy request failed'));
    }
  }

  /**
   * 对应 `GET /plugins/dsh-agent-teams/state`。
   *
   * @param {Record<string, unknown>} [params]
   */
  async function readState(params = {}) {
    const p = params && typeof params === 'object' ? params : {};
    const session = typeof p.session === 'string' ? p.session.trim() : '';
    const archived = p.archived === true || p.archived === 1 || p.archived === '1';
    const summary = p.summary === true || p.summary === 1 || p.summary === '1';
    const ifNoneMatch = typeof p.ifNoneMatch === 'string' && p.ifNoneMatch ? p.ifNoneMatch : null;

    return forwardRequest({
      path: AGENT_TEAMS_PATHS.state,
      method: 'GET',
      query: {
        ...(session ? { session } : {}),
        ...(archived ? { archived: '1' } : {}),
        ...(summary ? { summary: '1' } : {}),
      },
      headers: ifNoneMatch ? { 'if-none-match': ifNoneMatch } : {},
      timeoutMs: resolveTimeoutMs(p.timeoutMs, DEFAULT_READ_TIMEOUT_MS),
    });
  }

  /**
   * 对应 `POST /plugins/dsh-agent-teams/halt`。
   *
   * @param {Record<string, unknown>} [params]
   */
  async function haltTeam(params = {}) {
    const p = params && typeof params === 'object' ? params : {};
    if (!isSafeId(p.sessionId) || !isSafeId(p.teamId)) {
      return buildErrorResult(400, 'sessionId and teamId are required');
    }
    return forwardRequest({
      path: AGENT_TEAMS_PATHS.halt,
      method: 'POST',
      headers: { 'content-type': 'application/json; charset=utf-8' },
      body: JSON.stringify({ sessionId: p.sessionId, teamId: p.teamId }),
      timeoutMs: resolveTimeoutMs(p.timeoutMs, DEFAULT_MUTATION_TIMEOUT_MS),
    });
  }

  /**
   * 对应 `POST /plugins/dsh-agent-teams/plan`。
   *
   * @param {Record<string, unknown>} [params]
   */
  async function planTeam(params = {}) {
    const p = params && typeof params === 'object' ? params : {};
    if (!isSafeId(p.sessionId) || !isSafeId(p.teamId) || !isSafeId(p.action)) {
      return buildErrorResult(400, 'sessionId, teamId, and action are required');
    }
    const payload = {
      sessionId: p.sessionId,
      teamId: p.teamId,
      action: p.action,
    };
    for (const [key, value] of Object.entries(p)) {
      if (key === 'sessionId' || key === 'teamId' || key === 'action' || key === 'timeoutMs') continue;
      if (value !== undefined && value !== null) {
        payload[key] = value;
      }
    }
    return forwardRequest({
      path: AGENT_TEAMS_PATHS.plan,
      method: 'POST',
      headers: { 'content-type': 'application/json; charset=utf-8' },
      body: JSON.stringify(payload),
      timeoutMs: resolveTimeoutMs(p.timeoutMs, DEFAULT_MUTATION_TIMEOUT_MS),
    });
  }

  return {
    readState,
    haltTeam,
    planTeam,
  };
}
