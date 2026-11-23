/**
 * @file 多 CLI 扫描器统一汇总入口。
 */
import { readAntigravityMessages, scanAntigravitySessions } from './antigravity.js';
import { readClaudeMessages, scanClaudeSessions } from './claude.js';
import { readCodexMessages, scanCodexSessions } from './codex.js';
import { resolveExecutable } from './common.js';

/**
 * 检测本机各 CLI 可执行程序与数据目录是否可用。
 *
 * @param {{ binaries?: Partial<Record<string, string[]>> }} [options]
 * @returns {Record<string, { installed: boolean, executable: string | null }>}
 */
export function probeCliEngines(options = {}) {
  const bins = options.binaries || {};
  const agy = resolveExecutable(bins.antigravity || ['agy']);
  const claude = resolveExecutable(bins.claude || ['claude']);
  const codex = resolveExecutable(bins.codex || ['codex']);
  return {
    antigravity: { installed: Boolean(agy), executable: agy },
    claude: { installed: Boolean(claude), executable: claude },
    codex: { installed: Boolean(codex), executable: codex },
  };
}

/**
 * 扫描全部支持的外部 CLI 会话并按最近更新时间降序合并。
 *
 * @param {{ roots?: { antigravity?: string, claude?: string, codex?: string }, limit?: number }} [options]
 * @returns {Array<object>}
 */
export function scanAllCliSessions(options = {}) {
  const roots = options.roots || {};
  const limit = options.limit ?? 80;
  const all = [
    ...scanAntigravitySessions({ rootDir: roots.antigravity, limit }),
    ...scanClaudeSessions({ rootDir: roots.claude, limit }),
    ...scanCodexSessions({ rootDir: roots.codex, limit }),
  ];
  all.sort((a, b) => b.updatedAt - a.updatedAt);
  return all.slice(0, limit);
}

/**
 * 读取指定引擎与会话 ID 的历史消息。
 *
 * @param {'antigravity' | 'claude' | 'codex'} engine
 * @param {string} rawId
 * @param {{ roots?: { antigravity?: string, claude?: string, codex?: string } }} [options]
 * @returns {{ messages: Array<object>, model: string | null, cwd?: string | null }}
 */
export function readCliSessionMessages(engine, rawId, options = {}) {
  const roots = options.roots || {};
  switch (engine) {
    case 'antigravity':
      return readAntigravityMessages(rawId, { rootDir: roots.antigravity });
    case 'claude':
      return readClaudeMessages(rawId, { rootDir: roots.claude });
    case 'codex':
      return readCodexMessages(rawId, { rootDir: roots.codex });
    default:
      return { messages: [], model: null, cwd: null };
  }
}
