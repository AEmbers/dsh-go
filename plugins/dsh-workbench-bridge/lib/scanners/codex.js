/**
 * @file Codex 会话索引与 rollout JSONL 解析器。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { isSafeSessionId, readJsonlSafe, toEpochMs, walkFiles } from './common.js';

/**
 * 构建 sessionId -> rollout 文件路径映射。
 *
 * @param {string} rootDir
 * @returns {Map<string, string>}
 */
function buildRolloutMap(rootDir) {
  const map = new Map();
  const sessionsDir = path.join(rootDir, 'sessions');
  const files = walkFiles(sessionsDir, (_full, name) => name.startsWith('rollout-') && name.endsWith('.jsonl'), 5);
  for (const filePath of files) {
    const base = path.basename(filePath, '.jsonl');
    const match = base.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i);
    if (match) {
      map.set(match[1], filePath);
    }
  }
  return map;
}

/**
 * 仅读取 JSONL 首行（用于快速获取 session_meta 的 cwd 与 provider）。
 *
 * @param {string} filePath
 * @returns {object | null}
 */
function readFirstJsonLine(filePath) {
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
    const buf = Buffer.alloc(16 * 1024);
    const bytesRead = fs.readSync(fd, buf, 0, buf.length, 0);
    const text = buf.toString('utf8', 0, bytesRead);
    const firstLine = text.split(/\r?\n/, 1)[0]?.trim();
    if (!firstLine) return null;
    return JSON.parse(firstLine);
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {
        // ignore
      }
    }
  }
}

/**
 * 扫描 Codex 会话列表（基于 session_index.jsonl + sessions 目录元信息）。
 *
 * @param {{ rootDir?: string, limit?: number }} [options]
 * @returns {Array<object>}
 */
export function scanCodexSessions(options = {}) {
  const rootDir = options.rootDir || path.join(os.homedir(), '.codex');
  const limit = options.limit ?? 80;
  const indexPath = path.join(rootDir, 'session_index.jsonl');
  const indexRows = readJsonlSafe(indexPath);
  const rolloutMap = buildRolloutMap(rootDir);

  const byId = new Map();
  for (const row of indexRows) {
    if (!isSafeSessionId(row.id)) continue;
    const updatedAt = toEpochMs(row.updated_at);
    const prev = byId.get(row.id);
    if (!prev || updatedAt >= prev.updatedAt) {
      byId.set(row.id, {
        id: row.id,
        title: String(row.thread_name || '').trim() || row.id,
        updatedAt,
      });
    }
  }

  // 补上尚未写入 session_index 但已有 rollout 文件的会话
  for (const [id, filePath] of rolloutMap.entries()) {
    if (byId.has(id) || !isSafeSessionId(id)) continue;
    try {
      const stat = fs.statSync(filePath);
      byId.set(id, { id, title: id, updatedAt: Math.trunc(stat.mtimeMs) });
    } catch {
      // ignore
    }
  }

  const sorted = [...byId.values()].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, limit);
  return sorted.map((item) => {
    const rolloutPath = rolloutMap.get(item.id);
    const metaRow = rolloutPath ? readFirstJsonLine(rolloutPath) : null;
    const payload = metaRow?.type === 'session_meta' ? metaRow.payload : null;
    return {
      engine: 'codex',
      rawId: item.id,
      sessionId: `cli:codex:${item.id}`,
      title: item.title,
      cwd: typeof payload?.cwd === 'string' ? payload.cwd : null,
      updatedAt: item.updatedAt,
      running: false,
      blank: false,
      model: typeof payload?.model_provider === 'string' ? payload.model_provider : null,
    };
  });
}

/**
 * 读取指定 Codex 会话的标准化消息列表。
 *
 * @param {string} rawId
 * @param {{ rootDir?: string }} [options]
 * @returns {{ messages: Array<object>, model: string | null, cwd: string | null }}
 */
export function readCodexMessages(rawId, options = {}) {
  if (!isSafeSessionId(rawId)) return { messages: [], model: null, cwd: null };
  const rootDir = options.rootDir || path.join(os.homedir(), '.codex');
  const rolloutMap = buildRolloutMap(rootDir);
  const filePath = rolloutMap.get(rawId);
  if (!filePath) return { messages: [], model: null, cwd: null };

  const rows = readJsonlSafe(filePath);
  const messages = [];
  let model = null;
  let cwd = null;

  for (const row of rows) {
    const createdAt = toEpochMs(row.timestamp);
    if (row.type === 'session_meta' && row.payload) {
      if (typeof row.payload.cwd === 'string') cwd = row.payload.cwd;
      if (typeof row.payload.model_provider === 'string') model = row.payload.model_provider;
      continue;
    }

    if (row.type === 'response_item' && row.payload) {
      const p = row.payload;
      if (p.type === 'message' && (p.role === 'user' || p.role === 'assistant')) {
        const parts = [];
        for (const item of Array.isArray(p.content) ? p.content : []) {
          if (!item || typeof item !== 'object') continue;
          if ((item.type === 'input_text' || item.type === 'output_text' || item.type === 'text') && item.text) {
            // 跳过开发者系统指令与环境上下文注入块，避免污染聊天正文
            const text = String(item.text);
            if (p.role === 'user' && /^<(?:environment_context|permissions instructions|INSTRUCTIONS)>/i.test(text.trim())) {
              continue;
            }
            parts.push({ type: 'text', text });
          }
        }
        if (parts.length > 0) {
          messages.push({
            messageId: `codex-${messages.length}`,
            role: p.role,
            createdAt,
            parts,
          });
        }
      } else if (p.type === 'reasoning' && Array.isArray(p.summary)) {
        const summaryText = p.summary.map((s) => s?.text || '').filter(Boolean).join('\n');
        if (summaryText) {
          messages.push({
            messageId: `codex-${messages.length}`,
            role: 'assistant',
            createdAt,
            parts: [{ type: 'reasoning', text: summaryText }],
          });
        }
      } else if (p.type === 'function_call') {
        messages.push({
          messageId: `codex-${messages.length}`,
          role: 'assistant',
          createdAt,
          parts: [
            {
              type: 'tool-call',
              id: String(p.call_id || `codex-call-${messages.length}`),
              name: String(p.name || 'tool'),
              arguments: typeof p.arguments === 'string' ? p.arguments : JSON.stringify(p.arguments ?? {}),
            },
          ],
        });
      }
      continue;
    }

    if (row.type === 'event_msg' && row.payload && messages.length === 0) {
      if (row.payload.type === 'user_message' && row.payload.message) {
        messages.push({
          messageId: `codex-${messages.length}`,
          role: 'user',
          createdAt,
          parts: [{ type: 'text', text: String(row.payload.message) }],
        });
      } else if (row.payload.type === 'agent_message' && row.payload.message) {
        messages.push({
          messageId: `codex-${messages.length}`,
          role: 'assistant',
          createdAt,
          parts: [{ type: 'text', text: String(row.payload.message) }],
        });
      }
    }
  }

  return { messages, model, cwd };
}
