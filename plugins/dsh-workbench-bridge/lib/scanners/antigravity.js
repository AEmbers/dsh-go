/**
 * @file Antigravity 会话摘要与对话记录解析器。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

import { decodeFileUri, isSafeSessionId, readJsonlSafe, toEpochMs, unwrapUserRequest } from './common.js';

/**
 * 解析 Antigravity 工作区 URI JSON 数组并取首个工作区路径。
 *
 * @param {string} rawUris
 * @returns {string | null}
 */
function parseWorkspaceUri(rawUris) {
  if (typeof rawUris !== 'string' || !rawUris.trim()) return null;
  try {
    const arr = JSON.parse(rawUris);
    if (Array.isArray(arr) && typeof arr[0] === 'string') {
      const decoded = decodeFileUri(arr[0]);
      return decoded || null;
    }
  } catch {
    // 忽略非 JSON 格式
  }
  return null;
}

/**
 * 扫描 Antigravity 会话摘要列表（优先读只读 SQLite，失败时回退扫描 brain 目录）。
 *
 * @param {{ rootDir?: string, limit?: number }} [options]
 * @returns {Array<object>}
 */
export function scanAntigravitySessions(options = {}) {
  const rootDir = options.rootDir || path.join(os.homedir(), '.gemini', 'antigravity');
  const limit = options.limit ?? 80;
  const dbPath = path.join(rootDir, 'conversation_summaries.db');

  if (fs.existsSync(dbPath)) {
    let db;
    try {
      db = new DatabaseSync(dbPath, { readOnly: true });
      const rows = db
        .prepare(
          `SELECT conversation_id, title, preview, workspace_uris, last_modified_time, not_fully_idle, killed
           FROM conversation_summaries
           ORDER BY last_modified_time DESC
           LIMIT ?`,
        )
        .all(limit);

      return rows
        .filter((row) => isSafeSessionId(row.conversation_id))
        .map((row) => {
          const title = String(row.title || row.preview || '').trim() || row.conversation_id;
          const updatedAt = toEpochMs(row.last_modified_time);
          const running = Boolean(row.not_fully_idle) && !row.killed;
          return {
            engine: 'antigravity',
            rawId: String(row.conversation_id),
            sessionId: `cli:antigravity:${row.conversation_id}`,
            title,
            cwd: parseWorkspaceUri(row.workspace_uris),
            updatedAt,
            running,
            blank: false,
            model: null,
          };
        });
    } catch {
      // SQLite 被独占锁或损坏时回退目录扫描
    } finally {
      try {
        db?.close();
      } catch {
        // ignore
      }
    }
  }

  // 回退扫描 brain/<id>/.system_generated/logs/transcript.jsonl
  const brainDir = path.join(rootDir, 'brain');
  if (!fs.existsSync(brainDir)) return [];
  let entries = [];
  try {
    entries = fs.readdirSync(brainDir, { withFileTypes: true });
  } catch {
    return [];
  }
  const results = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !isSafeSessionId(entry.name)) continue;
    const logPath = path.join(brainDir, entry.name, '.system_generated', 'logs', 'transcript.jsonl');
    if (!fs.existsSync(logPath)) continue;
    let stat;
    try {
      stat = fs.statSync(logPath);
    } catch {
      continue;
    }
    const rows = readJsonlSafe(logPath);
    const firstUser = rows.find((r) => r.type === 'USER_INPUT');
    const title = firstUser ? unwrapUserRequest(firstUser.content).split(/\r?\n/)[0].slice(0, 80) : entry.name;
    results.push({
      engine: 'antigravity',
      rawId: entry.name,
      sessionId: `cli:antigravity:${entry.name}`,
      title: title || entry.name,
      cwd: null,
      updatedAt: Math.trunc(stat.mtimeMs),
      running: false,
      blank: rows.length === 0,
      model: null,
    });
  }
  results.sort((a, b) => b.updatedAt - a.updatedAt);
  return results.slice(0, limit);
}

/**
 * 读取指定 Antigravity 会话的标准化消息列表。
 *
 * @param {string} rawId
 * @param {{ rootDir?: string }} [options]
 * @returns {{ messages: Array<object>, model: string | null }}
 */
export function readAntigravityMessages(rawId, options = {}) {
  if (!isSafeSessionId(rawId)) return { messages: [], model: null };
  const rootDir = options.rootDir || path.join(os.homedir(), '.gemini', 'antigravity');
  const logPath = path.join(rootDir, 'brain', rawId, '.system_generated', 'logs', 'transcript.jsonl');
  const rows = readJsonlSafe(logPath);
  const messages = [];
  let latestModel = null;

  for (const row of rows) {
    const createdAt = toEpochMs(row.created_at);
    const id = `agy-${row.step_index ?? messages.length}`;

    if (row.type === 'USER_INPUT' && row.source === 'USER_EXPLICIT') {
      const text = unwrapUserRequest(row.content);
      if (!text) continue;
      messages.push({
        messageId: id,
        role: 'user',
        createdAt,
        parts: [{ type: 'text', text }],
      });
      continue;
    }

    if (row.type === 'PLANNER_RESPONSE') {
      if (typeof row.model === 'string' && row.model) latestModel = row.model;
      const parts = [];
      if (typeof row.thinking === 'string' && row.thinking.trim()) {
        parts.push({ type: 'reasoning', text: row.thinking });
      }
      if (Array.isArray(row.tool_calls)) {
        for (const call of row.tool_calls) {
          if (!call || typeof call !== 'object') continue;
          const args =
            typeof call.arguments === 'string'
              ? call.arguments
              : JSON.stringify(call.arguments ?? call.args ?? {});
          parts.push({
            type: 'tool-call',
            id: String(call.id || `${id}-tool-${parts.length}`),
            name: String(call.name || 'tool'),
            arguments: args,
          });
        }
      }
      if (typeof row.content === 'string' && row.content.trim()) {
        parts.push({ type: 'text', text: row.content });
      }
      if (parts.length === 0) continue;
      messages.push({
        messageId: id,
        role: 'assistant',
        createdAt,
        model: typeof row.model === 'string' ? row.model : null,
        parts,
      });
    }
  }

  return { messages, model: latestModel };
}
