/**
 * @file 通过 Electron 标准 CDP（仅允许本机回环地址）后台静默远程控制 Antigravity 桌面版。
 *
 * 严格遵循安全边界：
 * 1. 只连接本机回环地址（127.0.0.1 / localhost / ::1）；
 * 2. 只操作官方前端公开可见的 UI DOM（不触碰 Cookie、localStorage、Token 或私有 RPC）；
 * 3. 绝不调用 Page.bringToFront，绝不占用或污染 Windows 系统剪贴板，绝不触发整页 reload。
 */
import fs from 'node:fs';
import path from 'node:path';

export const DEFAULT_ANTIGRAVITY_CDP_URL = 'http://127.0.0.1:19222';
const PROBE_TIMEOUT_MS = 800;
const PROBE_CACHE_MS = 2500;
const CDP_CMD_TIMEOUT_MS = 15_000;
const STREAM_POLL_MS = 220;
const MAX_OBSERVE_MS = 30 * 60 * 1000;

const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '::1']);
const SAFE_CONV_ID_RE = /^[A-Za-z0-9._-]{1,128}$/;

const EFFORT_SUFFIX_RE = /^(.*?)[-_ ](low|medium|high|xhigh|extra[-_ ]?high|max)$/i;
const DESKTOP_EFFORT_LABEL = {
  low: 'Low',
  medium: 'Medium',
  high: 'High',
  xhigh: 'Extra High',
  'extra high': 'Extra High',
  extrahigh: 'Extra High',
  max: 'Extra High',
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * 校验 CDP URL 是否严格为本机 HTTP 回环地址。
 *
 * @param {unknown} rawUrl
 * @returns {boolean}
 */
export function isLoopbackCdpUrl(rawUrl) {
  if (typeof rawUrl !== 'string' || !rawUrl.trim()) return false;
  try {
    const parsed = new URL(rawUrl.trim());
    if (parsed.protocol !== 'http:') return false;
    const host = parsed.hostname.replace(/^\[|\]$/g, '').toLowerCase();
    return LOOPBACK_HOSTS.has(host);
  } catch {
    return false;
  }
}

/**
 * 规范化模型/菜单项文本为纯空格分隔小写词元，剥离末尾桌面端状态徽章（New / Leaving Soon / Notice）。
 *
 * @param {unknown} text
 * @returns {string}
 */
function normalizeModelWords(text) {
  let s = String(text || '')
    .replace(/\(([^()]+)\)/g, ' $1 ')
    .replace(/[·._-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
  s = s.replace(/\s+(?:new|leaving soon|notice)$/i, '').trim();
  return s;
}

/**
 * 解析请求侧模型 ID 与思考深度，分解出基础模型名、是否编排模型及桌面菜单深度文案。
 *
 * @param {string | null | undefined} model
 * @param {string | null | undefined} effort
 * @returns {{
 *   rawModel: string,
 *   isOrchestrator: boolean,
 *   baseWords: string,
 *   desiredEffort: string | null,
 *   desiredEffortLabel: string | null,
 * }}
 */
export function parseModelSpec(model, effort) {
  const rawModel = typeof model === 'string' ? model.trim() : '';
  const cleanEffort = typeof effort === 'string' ? effort.trim().toLowerCase() : '';
  let baseRaw = rawModel;
  let inferredEffort = cleanEffort || null;

  const isOrchestrator = /orchestrator/i.test(rawModel);
  if (!isOrchestrator) {
    const m = EFFORT_SUFFIX_RE.exec(rawModel);
    if (m) {
      baseRaw = m[1].trim();
      if (!inferredEffort) {
        inferredEffort = m[2].toLowerCase().replace(/[-_\s]+/g, '');
      }
    }
  } else {
    // Orchestrator 在 CLI wire ID 中可能形如 gemini-pro-orchestrator-neon / gemini-pro-orchestrator
    inferredEffort = null;
  }

  let baseWords = normalizeModelWords(baseRaw).replace(/\s+(?:low|medium|high|extra high|xhigh|max)$/i, '').trim();
  if (isOrchestrator) {
    // 桌面端菜单显示为 "Orchestrator Gemini 4 Neon High New" (data-model-label="Orchestrator")
    baseWords = baseWords
      .replace(/^gemini\s+pro\s+orchestrator/i, 'orchestrator')
      .trim();
  }

  const normalizedEffortKey = inferredEffort ? inferredEffort.replace(/[-_\s]+/g, '') : '';
  const desiredEffortLabel = normalizedEffortKey
    ? DESKTOP_EFFORT_LABEL[normalizedEffortKey] || DESKTOP_EFFORT_LABEL[inferredEffort] || null
    : null;

  return {
    rawModel,
    isOrchestrator,
    baseWords,
    desiredEffort: normalizedEffortKey || null,
    desiredEffortLabel,
  };
}

function stripTailEffort(normalizedText) {
  return normalizedText.replace(/\s+(?:extra\s+high|xhigh|medium|high|low|max)$/i, '').trim();
}

function extractTailEffortLabel(normalizedText) {
  const m = /\b(extra\s+high|xhigh|medium|high|low|max)$/i.exec(normalizedText);
  if (!m) return null;
  const key = m[1].toLowerCase().replace(/\s+/g, '');
  return DESKTOP_EFFORT_LABEL[key] || null;
}

/**
 * 判断桌面端触发器当前的 `data-model-label` 是否已命中目标模型与思考深度。
 *
 * @param {string | null | undefined} currentLabel
 * @param {string | null | undefined} targetModel
 * @param {string | null | undefined} targetEffort
 * @returns {boolean}
 */
export function matchesCurrentModelLabel(currentLabel, targetModel, targetEffort) {
  const spec = parseModelSpec(targetModel, targetEffort);
  if (!spec.rawModel) return true;
  const curNorm = normalizeModelWords(currentLabel);
  if (!curNorm) return false;

  const curIsOrch = /\borchestrator\b/.test(curNorm);
  if (spec.isOrchestrator !== curIsOrch) return false;

  if (spec.isOrchestrator) {
    const variantTokens = spec.baseWords
      .split(/\s+/)
      .filter((t) => t && t !== 'orchestrator');
    return variantTokens.every((tok) => curNorm.includes(tok));
  }

  const curBase = stripTailEffort(curNorm);
  if (curBase !== spec.baseWords) {
    const tokens = spec.baseWords.split(/\s+/).filter(Boolean);
    if (tokens.length === 0 || !tokens.every((t) => curBase.split(/\s+/).includes(t))) {
      return false;
    }
  }

  if (spec.desiredEffortLabel) {
    const curEffort = extractTailEffortLabel(curNorm);
    if (!curEffort) return false;
    return curEffort.toLowerCase() === spec.desiredEffortLabel.toLowerCase();
  }
  return true;
}

/**
 * 从桌面端 `[role="menu"]` 中匹配最佳一级模型选项与期望的二级思考深度标签。
 *
 * @param {string | null | undefined} targetModel
 * @param {string | null | undefined} targetEffort
 * @param {Array<{ index: number, text?: string, modelLabel?: string, testid?: string, cx?: number, cy?: number }>} menuItems
 * @returns {{ item: object, desiredEffortLabel: string | null } | null}
 */
export function matchDesktopModelOption(targetModel, targetEffort, menuItems) {
  const spec = parseModelSpec(targetModel, targetEffort);
  if (!spec.rawModel || !Array.isArray(menuItems) || menuItems.length === 0) return null;

  let best = null;
  let bestScore = -1;

  for (const item of menuItems) {
    if (!item || typeof item !== 'object') continue;
    const rawLabel = `${item.modelLabel || ''} ${item.text || ''}`.trim();
    const norm = normalizeModelWords(item.text || item.modelLabel || '');
    if (!norm || norm === 'view usage') continue;

    const itemIsOrch = item.testid === 'model-selector-orchestrator' || /\borchestrator\b/.test(norm);
    if (spec.isOrchestrator !== itemIsOrch) continue;

    let score = 0;
    if (spec.isOrchestrator) {
      score += 50;
      const variantTokens = spec.baseWords.split(/\s+/).filter((t) => t && t !== 'orchestrator');
      for (const tok of variantTokens) {
        if (norm.includes(tok)) score += 20;
      }
      if (item.testid === 'model-selector-orchestrator') score += 30;
    } else {
      const itemBase = stripTailEffort(norm);
      if (itemBase === spec.baseWords) {
        score += 100;
      } else {
        const wantTokens = spec.baseWords.split(/\s+/).filter(Boolean);
        const haveTokens = itemBase.split(/\s+/).filter(Boolean);
        if (wantTokens.length > 0 && wantTokens.every((t) => haveTokens.includes(t))) {
          score += 60 - Math.abs(haveTokens.length - wantTokens.length) * 5;
        } else {
          continue;
        }
      }
    }

    // 如果同一模型在列表中恰好带有相同思考深度展示，稍微加分
    if (spec.desiredEffortLabel) {
      const tail = extractTailEffortLabel(norm);
      if (tail && tail.toLowerCase() === spec.desiredEffortLabel.toLowerCase()) {
        score += 5;
      }
    }

    if (score > bestScore) {
      bestScore = score;
      best = item;
    }
    void rawLabel;
  }

  if (!best || bestScore <= 0) return null;
  return {
    item: best,
    desiredEffortLabel: spec.desiredEffortLabel,
  };
}

/**
 * 通过本机 CDP 操控 Antigravity 桌面版的静默远程控制客户端。
 */
export class AntigravityDesktopCdpClient {
  /**
   * @param {{
   *   cdpUrl?: string,
   *   enabled?: boolean,
   *   fetchFn?: typeof fetch,
   *   WebSocketCtor?: typeof WebSocket,
   *   probeCacheMs?: number,
   *   opTimeoutMs?: number,
   *   streamPollMs?: number,
   *   maxObserveMs?: number,
   * }} [deps]
   */
  constructor(deps = {}) {
    const rawUrl = typeof deps.cdpUrl === 'string' && deps.cdpUrl.trim()
      ? deps.cdpUrl.trim().replace(/\/+$/, '')
      : (process.env.DSH_ANTIGRAVITY_CDP_URL || DEFAULT_ANTIGRAVITY_CDP_URL).trim().replace(/\/+$/, '');
    this._cdpUrl = rawUrl;
    const validLoopback = isLoopbackCdpUrl(rawUrl);
    this._enabled = deps.enabled !== undefined ? (Boolean(deps.enabled) && validLoopback) : validLoopback;
    this._fetch = deps.fetchFn || globalThis.fetch;
    this._WebSocket = deps.WebSocketCtor || globalThis.WebSocket;
    this._probeCacheMs = deps.probeCacheMs ?? PROBE_CACHE_MS;
    this._opTimeoutMs = deps.opTimeoutMs ?? CDP_CMD_TIMEOUT_MS;
    this._streamPollMs = deps.streamPollMs ?? STREAM_POLL_MS;
    this._maxObserveMs = deps.maxObserveMs ?? MAX_OBSERVE_MS;

    this._lastAvailable = this._enabled ? null : false;
    this._lastProbeAt = 0;
    this._probePromise = null;

    this._ws = null;
    this._connectedTargetUrl = null;
    this._connectPromise = null;
    this._nextId = 1;
    /** @type {Map<number, { resolve: Function, reject: Function, timer: ReturnType<typeof setTimeout> | null }>} */
    this._pending = new Map();
    /** @type {Promise<any>} */
    this._opChain = Promise.resolve();
    this._disposed = false;
  }

  get cdpUrl() {
    return this._cdpUrl;
  }

  get enabled() {
    return this._enabled;
  }

  /**
   * 同步读取最近一次探针缓存状态（尚未探测时为 `null`，禁用或确认离线为 `false`）。
   *
   * @returns {boolean | null}
   */
  isAvailableSync() {
    if (!this._enabled || this._disposed) return false;
    return this._lastAvailable;
  }

  /**
   * 探测本机 Antigravity 桌面版 CDP 调试端口及主页面是否就绪。
   *
   * @param {{ force?: boolean }} [opts]
   * @returns {Promise<boolean>}
   */
  async probeAvailability(opts = {}) {
    if (!this._enabled || this._disposed || typeof this._fetch !== 'function') {
      this._lastAvailable = false;
      return false;
    }
    const now = Date.now();
    if (!opts.force && this._lastAvailable !== null && now - this._lastProbeAt < this._probeCacheMs) {
      return this._lastAvailable;
    }
    if (this._probePromise) {
      return this._probePromise;
    }
    this._probePromise = (async () => {
      try {
        const target = await this._findMainPageTarget();
        const ok = Boolean(target?.webSocketDebuggerUrl);
        this._lastAvailable = ok;
        this._lastProbeAt = Date.now();
        return ok;
      } catch {
        this._lastAvailable = false;
        this._lastProbeAt = Date.now();
        return false;
      } finally {
        this._probePromise = null;
      }
    })();
    return this._probePromise;
  }

  async _findMainPageTarget() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);
    timer.unref?.();
    try {
      const res = await this._fetch(`${this._cdpUrl}/json/list`, { signal: controller.signal });
      if (!res?.ok) return null;
      const list = await res.json();
      if (!Array.isArray(list)) return null;
      const page =
        list.find((t) => t?.type === 'page' && t.title === 'Antigravity' && t.webSocketDebuggerUrl) ||
        list.find((t) => t?.type === 'page' && typeof t.url === 'string' && !t.url.startsWith('data:') && t.webSocketDebuggerUrl);
      return page || null;
    } finally {
      clearTimeout(timer);
    }
  }

  async _ensureConnection() {
    if (this._disposed || !this._enabled) {
      throw Object.assign(new Error('Antigravity Desktop CDP is disabled or disposed'), {
        status: 503,
        code: 'desktop_cdp_unavailable',
      });
    }
    if (this._ws && this._ws.readyState === 1) {
      return this._ws;
    }
    if (this._connectPromise) {
      return this._connectPromise;
    }
    this._connectPromise = (async () => {
      const target = await this._findMainPageTarget();
      const wsUrl = target?.webSocketDebuggerUrl;
      if (!wsUrl) {
        this._lastAvailable = false;
        this._lastProbeAt = Date.now();
        throw Object.assign(new Error('Antigravity Desktop window not available on local CDP port'), {
          status: 503,
          code: 'desktop_cdp_unavailable',
        });
      }
      if (typeof this._WebSocket !== 'function') {
        throw new Error('Global WebSocket is required for Antigravity Desktop CDP');
      }
      const ws = new this._WebSocket(wsUrl);
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          reject(new Error('CDP WebSocket connect timeout'));
          try {
            ws.close();
          } catch {
            // ignore
          }
        }, 5000);
        timer.unref?.();

        const handleOpen = () => {
          clearTimeout(timer);
          resolve();
        };
        const handleError = (err) => {
          clearTimeout(timer);
          reject(new Error(err?.message || 'CDP WebSocket connection error'));
        };
        ws.addEventListener('open', handleOpen, { once: true });
        ws.addEventListener('error', handleError, { once: true });
      });

      this._ws = ws;
      this._connectedTargetUrl = wsUrl;
      this._lastAvailable = true;
      this._lastProbeAt = Date.now();

      const cleanupSocket = (reasonMsg) => {
        if (this._ws !== ws) return;
        this._ws = null;
        this._connectedTargetUrl = null;
        this._lastAvailable = false;
        this._lastProbeAt = Date.now();
        const reason = new Error(reasonMsg || 'CDP WebSocket closed');
        for (const [id, entry] of this._pending.entries()) {
          if (entry.timer) clearTimeout(entry.timer);
          this._pending.delete(id);
          entry.reject(reason);
        }
      };

      ws.addEventListener('message', (ev) => {
        let msg;
        try {
          msg = JSON.parse(String(ev.data));
        } catch {
          return;
        }
        if (msg && msg.id !== undefined && this._pending.has(msg.id)) {
          const entry = this._pending.get(msg.id);
          if (entry.timer) clearTimeout(entry.timer);
          this._pending.delete(msg.id);
          if (msg.error) {
            entry.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
          } else {
            entry.resolve(msg.result);
          }
        }
      });
      ws.addEventListener('close', () => cleanupSocket('CDP WebSocket closed'));
      ws.addEventListener('error', () => cleanupSocket('CDP WebSocket errored'));

      await this._callCdpOnSocket(ws, 'Runtime.enable', {});
      await this._callCdpOnSocket(ws, 'DOM.enable', {});
      return ws;
    })().finally(() => {
      this._connectPromise = null;
    });
    return this._connectPromise;
  }

  _callCdpOnSocket(ws, method, params = {}) {
    if (!ws || ws.readyState !== 1) {
      return Promise.reject(new Error('CDP WebSocket is not open'));
    }
    const id = this._nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(`CDP timeout: ${method}`));
      }, this._opTimeoutMs);
      timer.unref?.();
      this._pending.set(id, { resolve, reject, timer });
      try {
        ws.send(JSON.stringify({ id, method, params }));
      } catch (err) {
        clearTimeout(timer);
        this._pending.delete(id);
        reject(err);
      }
    });
  }

  async _callCdp(method, params = {}) {
    const ws = await this._ensureConnection();
    return this._callCdpOnSocket(ws, method, params);
  }

  async _eval(expression) {
    const out = await this._callCdp('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (out?.exceptionDetails) {
      const msg = out.exceptionDetails.exception?.description || out.exceptionDetails.text || 'CDP Runtime.evaluate exception';
      throw new Error(msg);
    }
    return out?.result?.value;
  }

  async _dispatchKey(key, code, vk, modifiers = 0) {
    await this._callCdp('Input.dispatchKeyEvent', {
      type: 'keyDown',
      key,
      code,
      windowsVirtualKeyCode: vk,
      modifiers,
    });
    await this._callCdp('Input.dispatchKeyEvent', {
      type: 'keyUp',
      key,
      code,
      windowsVirtualKeyCode: vk,
      modifiers,
    });
  }

  _enqueueUiOp(fn) {
    const next = this._opChain.then(fn, fn);
    this._opChain = next.catch(() => {});
    return next;
  }

  /**
   * 后台无刷新切换到指定桌面会话（或切回新建对话首页并可选匹配项目）。
   *
   * @param {string | null | undefined} rawId
   * @param {{ cwd?: string | null }} [opts]
   */
  async ensureConversation(rawId, opts = {}) {
    const cleanId = typeof rawId === 'string' && rawId.trim() ? rawId.trim() : null;
    if (cleanId) {
      if (!SAFE_CONV_ID_RE.test(cleanId)) {
        throw new Error(`Invalid conversation id: ${cleanId}`);
      }
      const alreadyThere = await this._eval(`(() => {
        const expected = '/c/' + ${JSON.stringify(cleanId)};
        return location.pathname === expected
          && !!document.querySelector('[data-testid="conversation-view"]')
          && !!document.querySelector('div[data-lexical-editor="true"][aria-label="Message input"]');
      })()`);
      if (!alreadyThere) {
        await this._eval(`(() => {
          const target = '/c/' + ${JSON.stringify(cleanId)};
          if (location.pathname !== target) {
            history.pushState({}, '', target);
            window.dispatchEvent(new PopStateEvent('popstate'));
          }
        })()`);
        const deadline = Date.now() + 6000;
        let ready = false;
        while (Date.now() < deadline) {
          ready = await this._eval(`(() => {
            const target = '/c/' + ${JSON.stringify(cleanId)};
            return location.pathname === target
              && !!document.querySelector('[data-testid="conversation-view"]')
              && !!document.querySelector('div[data-lexical-editor="true"][aria-label="Message input"]');
          })()`);
          if (ready) break;
          await sleep(100);
        }
        if (!ready) {
          throw new Error(`Desktop conversation view did not load for ${cleanId}`);
        }
        await sleep(250);
      }
      return cleanId;
    }

    // 新建桌面版会话
    await this._eval(`(() => {
      if (location.pathname !== '/' || !document.querySelector('div[data-lexical-editor="true"][aria-label="Message input"]')) {
        const btn = document.querySelector('[data-testid="app-icon-new-conversation-button"]');
        if (btn) btn.click();
      }
    })()`);
    const deadline = Date.now() + 5000;
    let ready = false;
    while (Date.now() < deadline) {
      ready = await this._eval(`(() => {
        return location.pathname === '/'
          && !!document.querySelector('div[data-lexical-editor="true"][aria-label="Message input"]');
      })()`);
      if (ready) break;
      await sleep(100);
    }
    if (!ready) {
      throw new Error('Desktop new conversation editor did not become ready');
    }

    if (typeof opts.cwd === 'string' && opts.cwd.trim()) {
      const folderName = path.basename(opts.cwd.trim());
      if (folderName) {
        await this._selectProjectByName(folderName);
      }
    }
    return null;
  }

  async _selectProjectByName(projectName) {
    const targetLower = projectName.toLowerCase();
    const state = await this._eval(`(() => {
      const btn = document.querySelector('[data-testid="project-selector-trigger"]');
      if (!btn || btn.disabled) return { skip: true };
      const cur = (btn.innerText || '').trim().toLowerCase();
      if (cur === ${JSON.stringify(targetLower)}) return { skip: true };
      btn.click();
      return { skip: false };
    })()`);
    if (state?.skip) return;

    await sleep(220);
    const picked = await this._eval(`(() => {
      const want = ${JSON.stringify(targetLower)};
      const items = Array.from(document.querySelectorAll('[role="menu"] [data-testid="project-selector-item"]'));
      const exact = items.find((el) => (el.innerText || '').trim().toLowerCase() === want);
      if (exact) {
        exact.click();
        return true;
      }
      return false;
    })()`);
    if (!picked) {
      await this._dispatchKey('Escape', 'Escape', 27);
    }
    await sleep(150);
  }

  /**
   * 后台切换桌面版模型与思考深度（若已是目标配置或按钮当前锁定则自动跳过）。
   *
   * @param {string | null | undefined} model
   * @param {string | null | undefined} effort
   * @returns {Promise<boolean>}
   */
  async selectModel(model, effort) {
    if (!model || typeof model !== 'string' || !model.trim()) return false;
    const triggerInfo = await this._eval(`(() => {
      const btn = document.querySelector('[data-testid="model-selector-trigger"]');
      if (!btn) return { exists: false };
      const aria = btn.getAttribute('aria-label') || '';
      const disabled = Boolean(btn.disabled) || btn.getAttribute('aria-disabled') === 'true' || /cannot be changed/i.test(aria);
      return {
        exists: true,
        disabled,
        label: btn.getAttribute('data-model-label') || btn.innerText || '',
      };
    })()`);
    if (!triggerInfo?.exists || triggerInfo.disabled) return false;
    if (matchesCurrentModelLabel(triggerInfo.label, model, effort)) return false;

    await this._eval(`document.querySelector('[data-testid="model-selector-trigger"]')?.click()`);
    await sleep(240);

    const menuItems = await this._eval(`(() => {
      const menu = document.querySelector('[role="menu"]');
      if (!menu) return [];
      return Array.from(menu.querySelectorAll('[role="menuitem"]')).map((el, index) => {
        const r = el.getBoundingClientRect();
        return {
          index,
          testid: el.getAttribute('data-testid') || '',
          modelLabel: el.getAttribute('data-model-label') || '',
          text: (el.innerText || '').trim().replace(/\\s+/g, ' '),
          cx: Math.round(r.x + r.width / 2),
          cy: Math.round(r.y + r.height / 2),
        };
      });
    })()`);

    const match = matchDesktopModelOption(model, effort, menuItems);
    if (!match) {
      await this._dispatchKey('Escape', 'Escape', 27);
      await sleep(100);
      return false;
    }

    if (match.desiredEffortLabel && match.item.cx && match.item.cy) {
      await this._callCdp('Input.dispatchMouseEvent', {
        type: 'mouseMoved',
        x: match.item.cx,
        y: match.item.cy,
      });
      await sleep(240);

      let radioCount = await this._eval(`document.querySelectorAll('[role="menuitemradio"]').length`);
      if (!radioCount) {
        await this._eval(`(() => {
          const items = Array.from(document.querySelectorAll('[role="menu"] [role="menuitem"]'));
          items[${match.item.index}]?.focus?.();
        })()`);
        await this._dispatchKey('ArrowRight', 'ArrowRight', 39);
        await sleep(220);
      }

      const clickedRadio = await this._eval(`(() => {
        const want = ${JSON.stringify(match.desiredEffortLabel.toLowerCase())};
        const radios = Array.from(document.querySelectorAll('[role="menuitemradio"]'));
        const hit = radios.find((el) => (el.innerText || '').trim().toLowerCase() === want);
        if (hit) {
          hit.click();
          return true;
        }
        return false;
      })()`);

      if (clickedRadio) {
        await sleep(160);
        const stillOpen = await this._eval(`Boolean(document.querySelector('[data-testid="model-selector-trigger"]')?.getAttribute('aria-expanded') === 'true')`);
        if (stillOpen) {
          await this._dispatchKey('Escape', 'Escape', 27);
          await sleep(100);
        }
        return true;
      }
    }

    // 兜底或无独立思考深度子菜单（如 Orchestrator）：直接点击主模型项
    await this._eval(`(() => {
      const items = Array.from(document.querySelectorAll('[role="menu"] [role="menuitem"]'));
      items[${match.item.index}]?.click();
    })()`);
    await sleep(180);
    return true;
  }

  /**
   * 通过 CDP `DOM.setFileInputFiles` 静默挂载本地图片/文件附件（绝不弹窗、绝不碰剪贴板）。
   *
   * @param {string[] | null | undefined} filePaths
   * @returns {Promise<number>}
   */
  async attachFiles(filePaths) {
    // 若编辑器框里残留着上次意外遗留的未发送附件，先行清理
    await this._eval(`(() => {
      const stale = document.querySelectorAll('.surface-composer [data-testid="input-attachment-remove"]');
      for (const btn of stale) btn.click();
    })()`);

    const existing = Array.isArray(filePaths)
      ? filePaths
          .filter((p) => typeof p === 'string' && p.trim() && fs.existsSync(p))
          .map((p) => path.resolve(p))
      : [];
    if (existing.length === 0) return 0;

    const doc = await this._callCdp('DOM.getDocument', { depth: -1 });
    const rootNodeId = doc?.root?.nodeId;
    if (!rootNodeId) throw new Error('DOM root unavailable for file attach');

    const q = await this._callCdp('DOM.querySelector', {
      nodeId: rootNodeId,
      selector: '.agy-composer-footer input[type="file"], input[type="file"]',
    });
    if (!q?.nodeId) {
      throw new Error('Desktop composer file input not found');
    }

    await this._callCdp('DOM.setFileInputFiles', {
      nodeId: q.nodeId,
      files: existing,
    });

    const deadline = Date.now() + 2500;
    let attached = 0;
    while (Date.now() < deadline) {
      attached = await this._eval(`document.querySelectorAll('.surface-composer [data-testid="input-attachment-remove"], .surface-composer img').length`);
      if (attached >= existing.length) break;
      await sleep(100);
    }
    await sleep(150);
    return existing.length;
  }

  /**
   * 后台静默聚焦 Lexical 输入框（绝不 bringToFront），分段写入多行文本并点击发送按钮。
   *
   * @param {string} text
   */
  async submitPrompt(text) {
    const cleanText = typeof text === 'string' ? text : '';
    const prevLen = await this._eval(`(() => {
      const ed = document.querySelector('div[data-lexical-editor="true"][aria-label="Message input"]');
      if (!ed) throw new Error('Desktop Message input editor not found');
      ed.focus();
      return (ed.innerText || '').trim().length;
    })()`);

    if (prevLen > 0) {
      await this._dispatchKey('a', 'KeyA', 65, 2);
      await this._dispatchKey('Backspace', 'Backspace', 8);
      await sleep(80);
    }

    if (cleanText) {
      const lines = cleanText.split(/\r?\n/);
      for (let i = 0; i < lines.length; i += 1) {
        if (i > 0) {
          await this._dispatchKey('Enter', 'Enter', 13, 8); // Shift+Enter 换行不触发发送
        }
        if (lines[i]) {
          await this._callCdp('Input.insertText', { text: lines[i] });
        }
      }
      await sleep(120);
    }

    // 等待发送按钮就绪并点击
    const readyDeadline = Date.now() + 2000;
    let canSend = false;
    while (Date.now() < readyDeadline) {
      canSend = await this._eval(`(() => {
        const btn = document.querySelector('[data-testid="send-button"]');
        return Boolean(btn && !btn.disabled && btn.getAttribute('aria-disabled') !== 'true');
      })()`);
      if (canSend) break;
      await sleep(80);
    }
    if (!canSend) {
      throw new Error('Desktop send button did not become enabled');
    }

    await this._eval(`document.querySelector('[data-testid="send-button"]')?.click()`);

    // 确认已真正提交（出现停止按钮、loading，或输入框清空）；必要时 Enter 兜底一次
    let submitted = false;
    let fallbackEnterTried = false;
    const submitDeadline = Date.now() + 3000;
    while (Date.now() < submitDeadline) {
      const status = await this._eval(`(() => {
        const ed = document.querySelector('div[data-lexical-editor="true"][aria-label="Message input"]');
        const txt = (ed?.innerText || '').trim();
        const sendBtn = document.querySelector('[data-testid="send-button"]');
        const cancelBtn = document.querySelector('[data-testid="input-cancel-button"]');
        const loading = document.querySelector('[data-testid="agent-loading"]');
        return {
          emptyInput: txt.length === 0,
          hasSendBtn: Boolean(sendBtn),
          hasRunningSignal: Boolean(cancelBtn || loading),
        };
      })()`);
      if (status?.hasRunningSignal || (status?.emptyInput && !status?.hasSendBtn)) {
        submitted = true;
        break;
      }
      if (!fallbackEnterTried && Date.now() > submitDeadline - 2200) {
        fallbackEnterTried = true;
        await this._eval(`document.querySelector('div[data-lexical-editor="true"][aria-label="Message input"]')?.focus()`);
        await this._dispatchKey('Enter', 'Enter', 13, 0);
      }
      await sleep(100);
    }
    if (!submitted) {
      throw new Error('Desktop prompt submit did not clear composer or start run');
    }
  }

  /**
   * 采集桌面版当前会话在 DOM 中的基线计数，用于严格隔离历史轮次与本轮新增助手回复。
   *
   * @param {string} targetId
   * @returns {Promise<{ userCount: number, respCount: number }>}
   */
  async _captureConversationBaseline(targetId) {
    return this._eval(`(() => {
      const expected = '/c/' + ${JSON.stringify(targetId)};
      if (location.pathname !== expected) return { userCount: 0, respCount: 0 };
      return {
        userCount: document.querySelectorAll('[data-testid="user-message"]').length,
        respCount: document.querySelectorAll('[data-testid="agent-response"]').length,
      };
    })()`);
  }

  /**
   * 读取桌面版当前激活会话（若仍停留在目标会话）的最新助手输出摘要与运行态。
   *
   * @param {string} targetId
   * @param {{ userCount: number, respCount: number }} baseline
   * @returns {Promise<{ onPage: boolean, domRunning: boolean, text: string }>}
   */
  async _readConversationDomProgress(targetId, baseline) {
    return this._eval(`(() => {
      const expected = '/c/' + ${JSON.stringify(targetId)};
      if (location.pathname !== expected) {
        return { onPage: false, domRunning: false, text: '' };
      }
      const domRunning = Boolean(
        document.querySelector('[data-testid="input-cancel-button"]') ||
        document.querySelector('[data-testid="agent-loading"]'),
      );
      const users = Array.from(document.querySelectorAll('[data-testid="user-message"]'));
      const responses = Array.from(document.querySelectorAll('[data-testid="agent-response"]'));
      const lastResp = responses[responses.length - 1];
      if (!lastResp) {
        return { onPage: true, domRunning, text: '' };
      }
      // 仅当本轮新回复确实出现在最新一条用户消息之后（或比基线新增了响应节点）时才提取，绝不误读上一轮旧回复
      const lastUser = users[users.length - 1] || null;
      const followsLatestUser = !lastUser || Boolean(lastUser.compareDocumentPosition(lastResp) & Node.DOCUMENT_POSITION_FOLLOWING);
      const hasNewResponse = responses.length > ${Number(baseline?.respCount || 0)} || users.length > ${Number(baseline?.userCount || 0)};
      if (!followsLatestUser || (!hasNewResponse && ${Number(baseline?.respCount || 0)} > 0)) {
        return { onPage: true, domRunning, text: '' };
      }
      const blocks = Array.from(lastResp.querySelectorAll('[data-markdown-root]'));
      const parts = [];
      for (const block of blocks) {
        const clone = block.cloneNode(true);
        for (const rm of clone.querySelectorAll('style, script, [aria-hidden="true"], .sr-only')) {
          rm.remove();
        }
        const txt = (clone.innerText || clone.textContent || '').trim();
        if (txt) parts.push(txt);
      }
      return {
        onPage: true,
        domRunning,
        text: parts.join('\\n\\n'),
      };
    })()`);
  }

  /**
   * 完整执行一轮桌面版发消息并后台实时观测输出直到该轮结束。
   *
   * @param {{
   *   rawId?: string | null,
   *   cwd?: string | null,
   *   prompt?: string,
   *   model?: string | null,
   *   reasoningEffort?: string | null,
   *   filePaths?: string[],
   *   signal?: AbortSignal,
   *   onResolvedId?: (resolvedId: string) => void,
   *   onStreamUpdate?: (update: { text: string, domRunning: boolean }) => void,
   *   isDiskRunning?: (id: string) => boolean,
   * }} req
   * @returns {Promise<{ resolvedRawId: string | null }>}
   */
  async sendPrompt(req) {
    const { resolvedId, baseline } = await this._enqueueUiOp(async () => {
      if (req.signal?.aborted) {
        throw new Error('Aborted before sending');
      }
      await this.ensureConversation(req.rawId, { cwd: req.cwd });
      const initialBaseline = req.rawId
        ? await this._captureConversationBaseline(req.rawId).catch(() => ({ userCount: 0, respCount: 0 }))
        : { userCount: 0, respCount: 0 };
      await this.selectModel(req.model, req.reasoningEffort);
      await this.attachFiles(req.filePaths);
      await this.submitPrompt(req.prompt || '');

      let targetId = typeof req.rawId === 'string' && req.rawId.trim() ? req.rawId.trim() : null;
      if (!targetId) {
        const deadline = Date.now() + 10_000;
        while (Date.now() < deadline) {
          const pathNow = await this._eval(`location.pathname`);
          const m = typeof pathNow === 'string' ? /^\/c\/([A-Za-z0-9._-]+)$/.exec(pathNow) : null;
          if (m) {
            targetId = m[1];
            break;
          }
          await sleep(100);
        }
      }
      if (targetId) {
        req.onResolvedId?.(targetId);
      }
      return { resolvedId: targetId, baseline: initialBaseline };
    });

    if (!resolvedId) {
      return { resolvedRawId: null };
    }

    let lastEmittedText = '';
    let sawRunning = false;
    let idleStreak = 0;
    const startedAt = Date.now();

    while (!this._disposed && !req.signal?.aborted && Date.now() - startedAt < this._maxObserveMs) {
      await sleep(this._streamPollMs);
      if (this._disposed || req.signal?.aborted) break;

      let snap;
      try {
        snap = await this._readConversationDomProgress(resolvedId, baseline);
      } catch {
        // 如果连接瞬断，借助磁盘状态决定是否继续或结束
        const diskStillRunning = req.isDiskRunning ? req.isDiskRunning(resolvedId) : false;
        if (!diskStillRunning && Date.now() - startedAt > 2000) break;
        continue;
      }

      if (snap.onPage) {
        if (snap.domRunning) sawRunning = true;
        const currentText = snap.text || '';
        if (currentText && currentText !== lastEmittedText) {
          lastEmittedText = currentText;
          req.onStreamUpdate?.({ text: currentText, domRunning: snap.domRunning });
        }

        const diskRunning = req.isDiskRunning ? req.isDiskRunning(resolvedId) : false;
        if (snap.domRunning || diskRunning) {
          sawRunning = true;
          idleStreak = 0;
        } else if (sawRunning || Date.now() - startedAt > 1500) {
          idleStreak += 1;
          if (idleStreak >= 3) {
            break;
          }
        }
      } else {
        // 用户主动在桌面端切走了对话：绝不抢回桌面页面，仅依靠磁盘运行态等待结束
        const diskRunning = req.isDiskRunning ? req.isDiskRunning(resolvedId) : false;
        if (diskRunning) {
          sawRunning = true;
          idleStreak = 0;
        } else if (sawRunning || Date.now() - startedAt > 2500) {
          idleStreak += 1;
          if (idleStreak >= 4) {
            break;
          }
        }
      }
    }

    return { resolvedRawId: resolvedId };
  }

  /**
   * 后台停止指定 Antigravity 桌面版会话正在执行的生成任务。
   *
   * @param {string | null | undefined} rawId
   * @returns {Promise<boolean>}
   */
  async abort(rawId) {
    if (!this._enabled || this._disposed) return false;
    const ok = await this.probeAvailability({ force: true });
    if (!ok) return false;

    return this._enqueueUiOp(async () => {
      const cleanId = typeof rawId === 'string' && rawId.trim() ? rawId.trim() : null;
      if (cleanId && SAFE_CONV_ID_RE.test(cleanId)) {
        const onPage = await this._eval(`location.pathname === ('/c/' + ${JSON.stringify(cleanId)})`);
        if (!onPage) {
          await this._eval(`(() => {
            history.pushState({}, '', '/c/' + ${JSON.stringify(cleanId)});
            window.dispatchEvent(new PopStateEvent('popstate'));
          })()`);
          await sleep(300);
        }
      }
      return Boolean(await this._eval(`(() => {
        const btn = document.querySelector('[data-testid="input-cancel-button"]');
        if (!btn) return false;
        btn.click();
        return true;
      })()`));
    });
  }

  /**
   * 断开 CDP 连接并拒绝所有挂起调用。
   */
  dispose() {
    this._disposed = true;
    const ws = this._ws;
    this._ws = null;
    this._connectedTargetUrl = null;
    this._lastAvailable = false;
    for (const [id, entry] of this._pending.entries()) {
      if (entry.timer) clearTimeout(entry.timer);
      this._pending.delete(id);
      entry.reject(new Error('AntigravityDesktopCdpClient disposed'));
    }
    if (ws) {
      try {
        ws.close();
      } catch {
        // ignore
      }
    }
  }
}
