/**
 * @file 外部 CLI 智能体（Antigravity / Codex / Claude）专属模型目录探测与映射。
 */
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

import { CLI_ENGINES, resolveExecutable } from './scanners/common.js';

const execFileAsync = promisify(execFile);
const CACHE_TTL_MS = 120_000;
const EFFORT_SUFFIX_RE = /^(.*)-(low|medium|high|xhigh|max)$/i;

const EFFORT_META = {
  low: { id: 'low', name: 'Low' },
  medium: { id: 'medium', name: 'Medium' },
  high: { id: 'high', name: 'High' },
  xhigh: { id: 'xhigh', name: 'XHigh' },
  max: { id: 'max', name: 'Max' },
  ultra: { id: 'ultra', name: 'Ultra' },
};

const ANTIGRAVITY_FALLBACK_LINES = [
  'gemini-4-neon-high\tGemini 4 Neon (High)',
  'gemini-4-neon-xhigh\tGemini 4 Neon (XHigh)',
  'gemini-4-neon-medium\tGemini 4 Neon (Medium)',
  'gemini-4-neon-low\tGemini 4 Neon (Low)',
  'gemini-4-carbon-medium\tGemini 4 Carbon (Medium)',
  'gemini-4-carbon-high\tGemini 4 Carbon (High)',
  'gemini-4-carbon-low\tGemini 4 Carbon (Low)',
  'gemini-4-argon-medium\tGemini 4 Argon (Medium)',
  'gemini-4-argon-high\tGemini 4 Argon (High)',
  'gemini-4-argon-low\tGemini 4 Argon (Low)',
  'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)',
  'gemini-4-hydrogen-xhigh\tGemini 4 Hydrogen (XHigh)',
  'gemini-4-hydrogen-medium\tGemini 4 Hydrogen (Medium)',
  'gemini-4-hydrogen-low\tGemini 4 Hydrogen (Low)',
  'gemini-pro-orchestrator-neon\tOrchestrator (Neon)',
  'gemini-pro-orchestrator\tOrchestrator (Carbon)',
  'gemini-pro-orchestrator-argon\tOrchestrator (Argon)',
  'gemini-3.8-flash-high\tGemini 3.8 Flash (High)',
  'gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)',
  'gemini-3.8-flash-low\tGemini 3.8 Flash (Low)',
  'claude-opus-5-5-low\tClaude Opus 5.5 (Low)',
  'claude-opus-5-5-medium\tClaude Opus 5.5 (Medium)',
  'claude-opus-5-5-high\tClaude Opus 5.5 (High)',
  'claude-sonnet-5-5-low\tClaude Sonnet 5.5 (Low)',
  'claude-sonnet-5-5-medium\tClaude Sonnet 5.5 (Medium)',
  'claude-sonnet-5-5-high\tClaude Sonnet 5.5 (High)',
  'gpt-oss-120b-medium\tGPT-OSS 120B (Medium)',
];

/** @type {Map<string, { at: number, catalog: object }>} */
const modelCatalogCache = new Map();
/** @type {Set<string>} */
const knownAntigravityWireIds = new Set(ANTIGRAVITY_FALLBACK_LINES.map((l) => l.split('\t')[0]));

/**
 * 清理标签中末尾括号里的思考深度字样，例如 `Gemini 4 Neon (High)` -> `Gemini 4 Neon`。
 *
 * @param {string} label
 * @returns {string}
 */
function stripEffortLabel(label) {
  return label.replace(/\s*\((low|medium|high|xhigh|max)\)\s*$/i, '').trim() || label.trim();
}

/**
 * 确定 Antigravity 模型所属分组（与 UI 渠道条对应）。
 *
 * @param {string} id
 * @returns {{ id: string, name: string }}
 */
function antigravityGroupMeta(id) {
  const lower = id.toLowerCase();
  if (lower.includes('orchestrator')) {
    return { id: 'orchestrator', name: 'Orchestrator' };
  }
  if (lower.startsWith('gemini')) {
    return { id: 'gemini', name: 'Gemini' };
  }
  if (lower.startsWith('claude')) {
    return { id: 'claude', name: 'Claude' };
  }
  return { id: 'other', name: '其他' };
}

/**
 * 解析 `agy models` 输出为与 DSH `ModelCatalog` 同构的结构。
 *
 * @param {string} stdout
 * @param {Array<{ provider: string, message: string }>} [failures]
 * @returns {object}
 */
export function parseAntigravityModelsOutput(stdout, failures = []) {
  const lines = String(stdout || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !/^fetching\b/i.test(line));

  /** @type {Map<string, { group: { id: string, name: string }, id: string, name: string, efforts: Set<string>, firstEffort: string | null }>} */
  const byBase = new Map();
  const order = [];

  for (const line of lines) {
    const tabIdx = line.indexOf('\t');
    const rawId = (tabIdx >= 0 ? line.slice(0, tabIdx) : line.split(/\s+/)[0]).trim();
    const rawLabel = (tabIdx >= 0 ? line.slice(tabIdx + 1) : rawId).trim();
    if (!rawId) continue;
    knownAntigravityWireIds.add(rawId);

    const match = EFFORT_SUFFIX_RE.exec(rawId);
    const baseId = match ? match[1] : rawId;
    const effort = match ? match[2].toLowerCase() : null;
    const group = antigravityGroupMeta(baseId);
    const key = `${group.id}:${baseId}`;

    let entry = byBase.get(key);
    if (!entry) {
      entry = {
        group,
        id: baseId,
        name: effort ? stripEffortLabel(rawLabel) : rawLabel,
        efforts: new Set(),
        firstEffort: null,
      };
      byBase.set(key, entry);
      order.push(entry);
    }
    if (effort) {
      entry.efforts.add(effort);
      if (!entry.firstEffort) entry.firstEffort = effort;
    }
  }

  const effortOrder = ['low', 'medium', 'high', 'xhigh', 'max'];
  const groupsMap = new Map();
  for (const entry of order) {
    if (!groupsMap.has(entry.group.id)) {
      groupsMap.set(entry.group.id, { id: entry.group.id, name: entry.group.name, models: [] });
    }
    const efforts = effortOrder
      .filter((e) => entry.efforts.has(e))
      .map((e) => ({ id: e, name: EFFORT_META[e]?.name || e }));
    const defaultEffort = entry.efforts.has('medium')
      ? 'medium'
      : entry.efforts.has('high')
        ? 'high'
        : (entry.firstEffort ?? (efforts[0]?.id || null));

    groupsMap.get(entry.group.id).models.push({
      provider: entry.group.id,
      id: entry.id,
      name: entry.name,
      reasoning: {
        efforts,
        ...(defaultEffort ? { defaultEffort } : {}),
      },
    });
  }

  const groupPriority = ['gemini', 'claude', 'orchestrator', 'other'];
  const groups = groupPriority
    .map((id) => groupsMap.get(id))
    .filter((g) => g && g.models.length > 0);

  const firstModel = groups[0]?.models[0] ?? null;
  const firstDefaultEffort = firstModel?.reasoning?.defaultEffort;
  const defaultSelection = firstModel
    ? {
        provider: firstModel.provider,
        model: firstModel.id,
        ...(firstDefaultEffort ? { reasoningEffort: firstDefaultEffort } : {}),
      }
    : null;

  return {
    ok: true,
    engine: 'antigravity',
    default: defaultSelection,
    defaultSelection,
    routableProviders: groups.map((g) => g.id),
    groups,
    failures,
  };
}

/**
 * 将 UI 选中的模型与思考深度还原为 `agy --model` 期望的完整模型 ID。
 *
 * @param {string | null | undefined} model
 * @param {string | null | undefined} effort
 * @returns {{ model: string | null, effort: string | null }}
 */
export function resolveAntigravityWireModel(model, effort) {
  const cleanModel = typeof model === 'string' && model.trim() ? model.trim() : null;
  const cleanEffort = typeof effort === 'string' && effort.trim() ? effort.trim().toLowerCase() : null;
  if (!cleanModel) return { model: null, effort: cleanEffort };

  const alreadySuffixed = EFFORT_SUFFIX_RE.test(cleanModel);
  if (alreadySuffixed) {
    return { model: cleanModel, effort: null };
  }
  if (cleanEffort) {
    const candidate = `${cleanModel}-${cleanEffort}`;
    if (knownAntigravityWireIds.has(candidate) || !cleanModel.includes('orchestrator')) {
      return { model: candidate, effort: null };
    }
  }
  return { model: cleanModel, effort: cleanEffort };
}

function readCodexDefaults(roots = {}) {
  const codexRoot = roots.codexRoot || path.join(os.homedir(), '.codex');
  const configPath = path.join(codexRoot, 'config.toml');
  let configuredModel = null;
  let configuredEffort = null;
  try {
    if (fs.existsSync(configPath)) {
      const content = fs.readFileSync(configPath, 'utf8');
      const m = /^\s*model\s*=\s*["']([^"']+)["']/m.exec(content);
      const e = /^\s*model_reasoning_effort\s*=\s*["']([^"']+)["']/m.exec(content);
      if (m) configuredModel = m[1].trim();
      if (e) configuredEffort = e[1].trim().toLowerCase();
    }
  } catch {
    // 忽略读取异常
  }
  return { configuredModel, configuredEffort };
}

function buildCodexCatalog(options = {}) {
  const codexRoot = options.roots?.codexRoot || path.join(os.homedir(), '.codex');
  const { configuredModel, configuredEffort } = readCodexDefaults(options.roots);
  const fallbackEfforts = ['low', 'medium', 'high', 'xhigh'].map((id) => ({
    id,
    name: EFFORT_META[id].name,
  }));

  let models = [];
  for (const fileName of ['models_cache.json', 'models_cache.codex_work_desktop.json']) {
    const cachePath = path.join(codexRoot, fileName);
    if (!fs.existsSync(cachePath)) continue;
    try {
      const parsed = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
      const rawModels = Array.isArray(parsed?.models) ? parsed.models : [];
      const mapped = [];
      for (const m of rawModels) {
        if (!m || typeof m !== 'object' || typeof m.slug !== 'string' || !m.slug.trim()) continue;
        const slug = m.slug.trim();
        if (m.visibility === 'hide' && slug !== configuredModel) continue;
        const levels = Array.isArray(m.supported_reasoning_levels) ? m.supported_reasoning_levels : [];
        const efforts = levels.length > 0
          ? levels
              .filter((lvl) => lvl && typeof lvl.effort === 'string' && lvl.effort.trim())
              .map((lvl) => {
                const id = lvl.effort.trim().toLowerCase();
                return {
                  id,
                  name: EFFORT_META[id]?.name || id,
                  ...(typeof lvl.description === 'string' && lvl.description.trim()
                    ? { description: lvl.description.trim() }
                    : {}),
                };
              })
          : fallbackEfforts;
        const defEffort = typeof m.default_reasoning_level === 'string' && m.default_reasoning_level.trim()
          ? m.default_reasoning_level.trim().toLowerCase()
          : efforts[0]?.id;
        mapped.push({
          provider: 'codex',
          id: slug,
          name: typeof m.display_name === 'string' && m.display_name.trim() ? m.display_name.trim() : slug,
          ...(typeof m.description === 'string' && m.description.trim() ? { description: m.description.trim() } : {}),
          reasoning: {
            efforts,
            ...(defEffort ? { defaultEffort: defEffort } : {}),
          },
        });
      }
      if (mapped.length > 0) {
        models = mapped;
        break;
      }
    } catch {
      // 忽略损坏的缓存文件并尝试回退
    }
  }

  if (models.length === 0) {
    const baseIds = ['gpt-6.2-sol', 'gpt-6.2-astra', 'gpt-6.1-terra', 'gpt-6.1-sol'];
    models = baseIds.map((id) => ({
      provider: 'codex',
      id,
      name: id,
      reasoning: {
        efforts: fallbackEfforts,
        defaultEffort: configuredEffort || 'medium',
      },
    }));
  }

  if (configuredModel && !models.some((m) => m.id === configuredModel)) {
    models.unshift({
      provider: 'codex',
      id: configuredModel,
      name: configuredModel,
      reasoning: {
        efforts: fallbackEfforts,
        defaultEffort: configuredEffort || 'medium',
      },
    });
  }

  const defaultEntry = (configuredModel ? models.find((m) => m.id === configuredModel) : null) || models[0];
  const defaultEffort = configuredEffort && defaultEntry.reasoning.efforts.some((e) => e.id === configuredEffort)
    ? configuredEffort
    : defaultEntry.reasoning.defaultEffort;
  const defaultSelection = {
    provider: 'codex',
    model: defaultEntry.id,
    ...(defaultEffort ? { reasoningEffort: defaultEffort } : {}),
  };

  return {
    ok: true,
    engine: 'codex',
    default: defaultSelection,
    defaultSelection,
    routableProviders: ['codex'],
    groups: [{ id: 'codex', name: 'Codex', models }],
    failures: [],
  };
}

function buildClaudeCatalog(options = {}) {
  const claudeRoot = options.roots?.claudeRoot || path.join(os.homedir(), '.claude');
  let configuredModel = null;
  try {
    const settingsPath = path.join(claudeRoot, 'settings.json');
    if (fs.existsSync(settingsPath)) {
      const raw = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
      if (typeof raw?.model === 'string' && raw.model.trim()) {
        configuredModel = raw.model.trim();
      }
    }
  } catch {
    // ignore
  }
  const baseIds = ['claude-sonnet-4-5', 'claude-opus-4-1', 'claude-haiku-4-5'];
  if (configuredModel && !baseIds.includes(configuredModel)) {
    baseIds.unshift(configuredModel);
  }
  const models = baseIds.map((id) => ({
    provider: 'claude',
    id,
    name: id,
    reasoning: { efforts: [] },
  }));
  const defaultSelection = { provider: 'claude', model: configuredModel || models[0].id };
  return {
    ok: true,
    engine: 'claude',
    default: defaultSelection,
    defaultSelection,
    routableProviders: ['claude'],
    groups: [{ id: 'claude', name: 'Claude Code', models }],
    failures: [],
  };
}

/**
 * 探测指定外部 CLI 引擎支持的模型目录。
 *
 * @param {string} engine
 * @param {{ refresh?: boolean, binaries?: Record<string, string | null>, roots?: object, execFileFn?: typeof execFileAsync }} [options]
 * @returns {Promise<object>}
 */
export async function listCliEngineModels(engine, options = {}) {
  if (!CLI_ENGINES.has(engine)) {
    throw Object.assign(new Error(`Unsupported CLI engine: ${engine}`), { status: 400, code: 'invalid_engine' });
  }
  const cacheKey = engine;
  const cached = modelCatalogCache.get(cacheKey);
  if (!options.refresh && cached && Date.now() - cached.at < CACHE_TTL_MS) {
    return cached.catalog;
  }

  let catalog;
  if (engine === 'antigravity') {
    const resolveFn = options.resolveBinFn || resolveExecutable;
    const exe = options.binaries && 'antigravity' in options.binaries ? options.binaries.antigravity : resolveFn(['agy']);
    if (!exe) {
      catalog = parseAntigravityModelsOutput(ANTIGRAVITY_FALLBACK_LINES.join('\n'), [
        { provider: 'antigravity', message: 'agy CLI unavailable, showing fallback models' },
      ]);
    } else {
      try {
        const execFn = options.execFileFn || execFileAsync;
        const { stdout } = await execFn(exe, ['models'], {
          timeout: 12_000,
          windowsHide: true,
          shell: process.platform === 'win32' && /\.(cmd|bat)$/i.test(exe),
        });
        const parsed = parseAntigravityModelsOutput(stdout);
        catalog = parsed.groups.length > 0
          ? parsed
          : parseAntigravityModelsOutput(ANTIGRAVITY_FALLBACK_LINES.join('\n'));
      } catch (err) {
        catalog = parseAntigravityModelsOutput(ANTIGRAVITY_FALLBACK_LINES.join('\n'), [
          { provider: 'antigravity', message: String(err?.message || err) },
        ]);
      }
    }
  } else if (engine === 'codex') {
    catalog = buildCodexCatalog(options);
  } else {
    catalog = buildClaudeCatalog(options);
  }

  modelCatalogCache.set(cacheKey, { at: Date.now(), catalog });
  return catalog;
}
