/**
 * @file Claude Code 会话与消息解析器。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { isSafeSessionId, readJsonlSafe, toEpochMs, walkFiles } from './common.js';

/**
 * 提取 Claude 消息 content（字符串或 content block 数组）中的纯文本与富块。
 *
 * @param {unknown} content
 * @returns {Array<object>}
 */
function extractClaudeParts(content) {
  if (typeof content === 'string') {
    return content.trim() ? [{ type: 'text', text: content }] : [];
  }
  if (!Array.isArray(content)) return [];
  const parts = [];
  for (const block of content) {
    if (!block || typeof block !== 'object') continue;
    if (block.type === 'text' && typeof block.text === 'string' && block.text.trim()) {
      parts.push({ type: 'text', text: block.text });
    } else if (block.type === 'thinking' && typeof block.thinking === 'string' && block.thinking.trim()) {
      parts.push({ type: 'reasoning', text: block.thinking });
    } else if (block.type === 'tool_use') {
      parts.push({
        type: 'tool-call',
        id: String(block.id || `claude-tool-${parts.length}`),
        name: String(block.name || 'tool'),
        arguments: JSON.stringify(block.input ?? {}),
      });
    }
  }
  return parts;
}

/**
 * 扫描 `~/.claude/projects/<project>/<session>.jsonl` 获取 Claude Code 会话列表。
 *
 * @param {{ rootDir?: string, limit?: number }} [options]
 * @returns {Array<object>}
 */
export function scanClaudeSessions(options = {}) {
  const rootDir = options.rootDir || path.join(os.homedir(), '.claude');
  const limit = options.limit ?? 80;
  const projectsDir = path.join(rootDir, 'projects');
  const files = walkFiles(
    projectsDir,
    (_full, name) => name.endsWith('.jsonl') && !name.startsWith('agent-'),
    3,
  );

  const items = [];
  for (const filePath of files) {
    const rawId = path.basename(filePath, '.jsonl');
    if (!isSafeSessionId(rawId)) continue;
    let stat;
    try {
      stat = fs.statSync(filePath);
    } catch {
      continue;
    }
    if (stat.size === 0) continue;

    const rows = readJsonlSafe(filePath);
    if (rows.length === 0) continue;

    let title = '';
    let cwd = null;
    let model = null;
    let updatedAt = 0;

    for (const row of rows) {
      if (!cwd && typeof row.cwd === 'string') cwd = row.cwd;
      if (row.timestamp) {
        const ts = toEpochMs(row.timestamp);
        if (ts > updatedAt) updatedAt = ts;
      }
      if (!title && row.type === 'user' && row.message) {
        const parts = extractClaudeParts(row.message.content);
        const firstText = parts.find((p) => p.type === 'text')?.text || '';
        title = firstText.trim().split(/\r?\n/)[0].slice(0, 80);
      }
      if (row.type === 'assistant' && typeof row.message?.model === 'string') {
        model = row.message.model;
      }
    }

    items.push({
      engine: 'claude',
      rawId,
      sessionId: `cli:claude:${rawId}`,
      title: title || rawId,
      cwd,
      updatedAt: updatedAt > 0 ? updatedAt : Math.trunc(stat.mtimeMs),
      running: false,
      blank: false,
      model,
    });
  }

  items.sort((a, b) => b.updatedAt - a.updatedAt);
  return items.slice(0, limit);
}

/**
 * 读取指定 Claude Code 会话的标准化消息列表。
 *
 * @param {string} rawId
 * @param {{ rootDir?: string }} [options]
 * @returns {{ messages: Array<object>, model: string | null, cwd: string | null }}
 */
export function readClaudeMessages(rawId, options = {}) {
  if (!isSafeSessionId(rawId)) return { messages: [], model: null, cwd: null };
  const rootDir = options.rootDir || path.join(os.homedir(), '.claude');
  const projectsDir = path.join(rootDir, 'projects');
  const match = walkFiles(projectsDir, (_full, name) => name === `${rawId}.jsonl`, 3)[0];
  if (!match) return { messages: [], model: null, cwd: null };

  const rows = readJsonlSafe(match);
  const messages = [];
  let model = null;
  let cwd = null;

  for (const row of rows) {
    if (!cwd && typeof row.cwd === 'string') cwd = row.cwd;
    if (row.type !== 'user' && row.type !== 'assistant') continue;
    const msg = row.message;
    if (!msg || typeof msg !== 'object') continue;
    if (row.type === 'assistant' && typeof msg.model === 'string') model = msg.model;
    const parts = extractClaudeParts(msg.content);
    if (parts.length === 0) continue;
    messages.push({
      messageId: String(row.uuid || `claude-${messages.length}`),
      role: row.type,
      createdAt: toEpochMs(row.timestamp),
      model: row.type === 'assistant' && typeof msg.model === 'string' ? msg.model : null,
      parts,
    });
  }

  return { messages, model, cwd };
}
