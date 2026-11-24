import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

import { attachRemoteRpcBridge, createNodePrefixHandler, createWorkbenchRoutes } from '../lib/index.js';
import { CliRunManager, buildCliCommand, parseCliStreamLine } from '../lib/runner.js';
import { readCliSessionMessages, scanAllCliSessions } from '../lib/scanners/index.js';

function makeTempFixtures() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-wb-bridge-'));

  // 1. Antigravity fixture
  const agyRoot = path.join(root, 'antigravity');
  const agyId = '11111111-1111-1111-1111-111111111111';
  const agyLogDir = path.join(agyRoot, 'brain', agyId, '.system_generated', 'logs');
  fs.mkdirSync(agyLogDir, { recursive: true });
  const db = new DatabaseSync(path.join(agyRoot, 'conversation_summaries.db'));
  db.exec(`
    CREATE TABLE conversation_summaries (
      conversation_id TEXT PRIMARY KEY,
      title TEXT NOT NULL DEFAULT '',
      preview TEXT NOT NULL DEFAULT '',
      step_count INTEGER NOT NULL DEFAULT 0,
      last_modified_time DATETIME NOT NULL,
      workspace_uris TEXT NOT NULL DEFAULT '[]',
      not_fully_idle NUMERIC NOT NULL DEFAULT 0,
      killed NUMERIC NOT NULL DEFAULT 0
    );
  `);
  db.prepare(
    `INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, not_fully_idle, killed)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(agyId, 'Larch-4N', 'preview', 2, '2026-11-23T09:00:00Z', '["file:///d%3A/dev/workspace"]', 1, 0);
  db.close();

  fs.writeFileSync(
    path.join(agyLogDir, 'transcript.jsonl'),
    [
      JSON.stringify({
        step_index: 0,
        source: 'USER_EXPLICIT',
        type: 'USER_INPUT',
        created_at: '2026-11-23T09:00:00Z',
        content: '<USER_REQUEST>\nRemember the code Larch-4N\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nignored\n</ADDITIONAL_METADATA>',
      }),
      JSON.stringify({
        step_index: 1,
        source: 'MODEL',
        type: 'PLANNER_RESPONSE',
        created_at: '2026-11-23T09:00:05Z',
        model: 'gemini-4-hydrogen-high',
        thinking: 'Checking user request',
        tool_calls: [{ id: 'tc1', name: 'read_file', arguments: '{"path":"a.txt"}' }],
        content: 'Larch-4N',
      }),
    ].join('\n'),
    'utf8',
  );

  // 2. Codex fixture
  const codexRoot = path.join(root, 'codex');
  const codexId = '22222222-2222-2222-2222-222222222222';
  const codexDayDir = path.join(codexRoot, 'sessions', '2026', '11', '23');
  fs.mkdirSync(codexDayDir, { recursive: true });
  fs.writeFileSync(
    path.join(codexRoot, 'session_index.jsonl'),
    `${JSON.stringify({ id: codexId, thread_name: 'Remember the code Pebble-3K', updated_at: '2026-11-23T08:00:00Z' })}\n`,
    'utf8',
  );
  fs.writeFileSync(
    path.join(codexDayDir, `rollout-2026-11-23T08-00-00-${codexId}.jsonl`),
    [
      JSON.stringify({
        timestamp: '2026-11-23T08:00:00Z',
        type: 'session_meta',
        payload: { id: codexId, cwd: 'D:\\dev\\codex-proj', model_provider: 'openai' },
      }),
      JSON.stringify({
        timestamp: '2026-11-23T08:00:01Z',
        type: 'response_item',
        payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Hi Codex' }] },
      }),
      JSON.stringify({
        timestamp: '2026-11-23T08:00:02Z',
        type: 'response_item',
        payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Pebble-3K' }] },
      }),
    ].join('\n'),
    'utf8',
  );

  // 3. Claude Code fixture
  const claudeRoot = path.join(root, 'claude');
  const claudeId = 'claude-session-01';
  const claudeProj = path.join(claudeRoot, 'projects', 'D--dev-app');
  fs.mkdirSync(claudeProj, { recursive: true });
  fs.writeFileSync(
    path.join(claudeProj, `${claudeId}.jsonl`),
    [
      JSON.stringify({
        uuid: 'u1',
        type: 'user',
        cwd: 'D:\\dev\\app',
        timestamp: '2026-11-23T07:00:00Z',
        message: { role: 'user', content: 'Paper kites. Reply only with Blue' },
      }),
      JSON.stringify({
        uuid: 'a1',
        type: 'assistant',
        cwd: 'D:\\dev\\app',
        timestamp: '2026-11-23T07:00:05Z',
        message: {
          model: 'claude-sonnet-4-5',
          content: [
            { type: 'thinking', thinking: 'Simple echo' },
            { type: 'text', text: 'Blue' },
          ],
        },
      }),
    ].join('\n'),
    'utf8',
  );

  return {
    root,
    roots: { antigravity: agyRoot, codex: codexRoot, claude: claudeRoot },
    ids: { agyId, codexId, claudeId },
  };
}

test('scanners aggregate Antigravity, Codex, and Claude sessions & messages', (t) => {
  const fx = makeTempFixtures();
  t.after(() => fs.rmSync(fx.root, { recursive: true, force: true }));

  const sessions = scanAllCliSessions({ roots: fx.roots });
  assert.equal(sessions.length, 3);
  assert.equal(sessions[0].engine, 'antigravity');
  assert.equal(sessions[0].title, 'Larch-4N');
  assert.equal(sessions[0].cwd, 'd:/dev/workspace');
  assert.equal(sessions[0].running, true);
  assert.equal(sessions[1].engine, 'codex');
  assert.equal(sessions[2].engine, 'claude');

  const agyMsgs = readCliSessionMessages('antigravity', fx.ids.agyId, { roots: fx.roots });
  assert.equal(agyMsgs.model, 'gemini-4-hydrogen-high');
  assert.equal(agyMsgs.messages.length, 2);
  assert.equal(agyMsgs.messages[0].parts[0].text, 'Remember the code Larch-4N');
  assert.equal(agyMsgs.messages[1].parts[0].type, 'reasoning');
  assert.equal(agyMsgs.messages[1].parts[1].type, 'tool-call');
  assert.equal(agyMsgs.messages[1].parts[2].text, 'Larch-4N');

  const codexMsgs = readCliSessionMessages('codex', fx.ids.codexId, { roots: fx.roots });
  assert.equal(codexMsgs.cwd, 'D:\\dev\\codex-proj');
  assert.equal(codexMsgs.messages.length, 2);

  const claudeMsgs = readCliSessionMessages('claude', fx.ids.claudeId, { roots: fx.roots });
  assert.equal(claudeMsgs.model, 'claude-sonnet-4-5');
  assert.equal(claudeMsgs.messages[1].parts[0].type, 'reasoning');
  assert.equal(claudeMsgs.messages[1].parts[1].text, 'Blue');
});

test('routes enforce fail-closed guard, support ETag 304, and block traversal', async (t) => {
  const fx = makeTempFixtures();
  t.after(() => fs.rmSync(fx.root, { recursive: true, force: true }));

  // Missing connection service -> 503
  const closedRoutes = createWorkbenchRoutes({ get: () => undefined }, { roots: fx.roots });
  const closedRes = await closedRoutes.handleSessions(new Request('http://localhost/plugins/dsh-workbench-bridge/sessions'));
  assert.equal(closedRes.status, 503);

  // Rejected by connection guard -> 403
  const rejectedRoutes = createWorkbenchRoutes(
    { get: () => ({ requestRejection: () => ({ status: 403, code: 'denied', message: 'no' }) }) },
    { roots: fx.roots },
  );
  const rejRes = await rejectedRoutes.handleSessions(new Request('http://localhost/plugins/dsh-workbench-bridge/sessions'));
  assert.equal(rejRes.status, 403);

  // Authorized -> 200 + ETag -> 304
  const okRoutes = createWorkbenchRoutes({ get: () => ({ requestRejection: () => null }) }, { roots: fx.roots });
  const res1 = await okRoutes.handleSessions(new Request('http://localhost/plugins/dsh-workbench-bridge/sessions'));
  assert.equal(res1.status, 200);
  const etag = res1.headers.get('etag');
  assert.ok(etag);
  const body1 = await res1.json();
  assert.equal(body1.sessions.length, 3);

  const res304 = await okRoutes.handleSessions(
    new Request('http://localhost/plugins/dsh-workbench-bridge/sessions', {
      headers: { 'if-none-match': etag },
    }),
  );
  assert.equal(res304.status, 304);

  // Directory traversal blocked
  const badMsg = await okRoutes.handleMessages(
    new Request('http://localhost/plugins/dsh-workbench-bridge/sessions/claude/..%2Fetc/messages'),
    'claude',
    '../etc',
  );
  assert.equal(badMsg.status, 400);
});

test('CliRunManager builds commands, streams output overlay, and supports abort', async (t) => {
  const fx = makeTempFixtures();
  t.after(() => fs.rmSync(fx.root, { recursive: true, force: true }));

  assert.deepEqual(buildCliCommand('antigravity', { rawSessionId: 'abc', prompt: 'hi' }).args, [
    '--print',
    '--output-format',
    'stream-json',
    '--conversation',
    'abc',
    'hi',
  ]);
  assert.deepEqual(buildCliCommand('codex', { rawSessionId: 'abc', prompt: 'hi' }).args, [
    'exec',
    '--json',
    'resume',
    'abc',
    'hi',
  ]);
  assert.deepEqual(buildCliCommand('claude', { rawSessionId: 'abc', prompt: 'hi' }).args, [
    '-p',
    '--output-format',
    'stream-json',
    '--verbose',
    '--resume',
    'abc',
    'hi',
  ]);

  const parsed = parseCliStreamLine('{"session_id":"s1","type":"item.completed","item":{"type":"agent_message","text":"ok"}}');
  assert.equal(parsed.sessionId, 's1');
  assert.equal(parsed.text, 'ok');

  let fakeChild;
  const manager = new CliRunManager({
    resolveBinFn: () => 'fake-agy',
    spawnFn: () => {
      fakeChild = new EventEmitter();
      fakeChild.stdout = new EventEmitter();
      fakeChild.stderr = new EventEmitter();
      fakeChild.kill = () => {
        fakeChild.emit('close', 143);
      };
      return fakeChild;
    },
  });

  const routes = createWorkbenchRoutes(
    { get: () => ({ requestRejection: () => null }) },
    { roots: fx.roots, runner: manager },
  );

  const promptRes = await routes.handlePrompt(
    new Request('http://localhost/plugins/dsh-workbench-bridge/sessions/prompt', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawSessionId: fx.ids.agyId, prompt: 'Ping?' }),
    }),
  );
  assert.equal(promptRes.status, 200);
  const promptBody = await promptRes.json();
  assert.equal(promptBody.running, true);

  fakeChild.stdout.emit('data', Buffer.from('{"text":"Pong!"}\n'));

  const msgRes = await routes.handleMessages(
    new Request(`http://localhost/plugins/dsh-workbench-bridge/sessions/antigravity/${fx.ids.agyId}/messages`),
    'antigravity',
    fx.ids.agyId,
  );
  const msgBody = await msgRes.json();
  assert.equal(msgBody.running, true);
  assert.equal(msgBody.messages.at(-2).parts[0].text, 'Ping?');
  assert.equal(msgBody.messages.at(-1).parts[0].text, 'Pong!');

  const abortRes = await routes.handleAbort(
    new Request('http://localhost/plugins/dsh-workbench-bridge/sessions/abort', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawSessionId: fx.ids.agyId }),
    }),
  );
  assert.equal((await abortRes.json()).aborted, true);
});

test('createNodePrefixHandler serves real Node HTTP requests with JSON body parsing and 304 ETag', async (t) => {
  const fx = makeTempFixtures();
  t.after(() => fs.rmSync(fx.root, { recursive: true, force: true }));

  const routes = createWorkbenchRoutes(
    { get: () => ({ requestRejection: () => null }) },
    { roots: fx.roots },
  );
  const server = http.createServer(createNodePrefixHandler(routes));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    routes.runner.dispose();
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
  });

  const port = server.address().port;
  const res1 = await fetch(`http://127.0.0.1:${port}/plugins/dsh-workbench-bridge/sessions`, {
    headers: { connection: 'close' },
  });
  assert.equal(res1.status, 200);
  const etag = res1.headers.get('etag');
  assert.ok(etag);
  const data1 = await res1.json();
  assert.equal(data1.sessions.length, 3);

  const res304 = await fetch(`http://127.0.0.1:${port}/plugins/dsh-workbench-bridge/sessions`, {
    headers: { 'if-none-match': etag, connection: 'close' },
  });
  assert.equal(res304.status, 304);

  const msgRes = await fetch(
    `http://127.0.0.1:${port}/plugins/dsh-workbench-bridge/sessions/claude/${fx.ids.claudeId}/messages`,
    { headers: { connection: 'close' } },
  );
  assert.equal(msgRes.status, 200);
  const msgData = await msgRes.json();
  assert.equal(msgData.engine, 'claude');

  const badMethod = await fetch(`http://127.0.0.1:${port}/plugins/dsh-workbench-bridge/sessions`, {
    method: 'POST',
    headers: { connection: 'close' },
  });
  assert.equal(badMethod.status, 405);
});

test('Antigravity empty SQLite title falls back to transcript and multi-engine quota preserves Codex', async (t) => {
  const fx = makeTempFixtures();
  t.after(() => fs.rmSync(fx.root, { recursive: true, force: true }));

  const emptyId = '44444444-4444-4444-4444-444444444444';
  const emptyLogDir = path.join(fx.roots.antigravity, 'brain', emptyId, '.system_generated', 'logs');
  fs.mkdirSync(emptyLogDir, { recursive: true });
  fs.writeFileSync(
    path.join(emptyLogDir, 'transcript.jsonl'),
    JSON.stringify({
      step_index: 0,
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      created_at: '2026-11-24T01:00:00Z',
      content: '<USER_REQUEST>\nFallback Title From Transcript\n</USER_REQUEST>',
    }),
    'utf8',
  );
  const db = new DatabaseSync(path.join(fx.roots.antigravity, 'conversation_summaries.db'));
  db.prepare(
    `INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, not_fully_idle, killed)
     VALUES (?, '', '', 1, ?, '[]', 0, 0)`,
  ).run(emptyId, '2026-11-24T01:00:00Z');
  // 再写入两个更新的 Antigravity 记录后按 limit=3 扫描，仍能保留 Codex 与 Claude
  for (const extra of ['55555555-5555-5555-5555-555555555555', '66666666-6666-6666-6666-666666666666']) {
    db.prepare(
      `INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, last_modified_time, workspace_uris, not_fully_idle, killed)
       VALUES (?, ?, '', 1, ?, '[]', 0, 0)`,
    ).run(extra, extra, '2026-11-24T02:00:00Z');
  }
  db.close();

  const limited = scanAllCliSessions({ roots: fx.roots, limit: 3 });
  const engines = new Set(limited.map((item) => item.engine));
  assert.equal(engines.has('antigravity'), true);
  assert.equal(engines.has('claude'), true);
  assert.equal(engines.has('codex'), true);

  const full = scanAllCliSessions({ roots: fx.roots, limit: 20 });
  const fallbackItem = full.find((item) => item.rawId === emptyId);
  assert.equal(fallbackItem?.title, 'Fallback Title From Transcript');
});

test('attachRemoteRpcBridge handles workbench.bridge.* calls and restores original invoke on dispose', async (t) => {
  const fx = makeTempFixtures();
  t.after(() => fs.rmSync(fx.root, { recursive: true, force: true }));

  class FakeRpcError extends Error {
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }
  class FakeRpcRouter {
    async invoke(method, params) {
      return { passthrough: method, params };
    }
  }

  const routes = createWorkbenchRoutes(
    { get: () => ({ requestRejection: () => null }) },
    { roots: fx.roots },
  );
  t.after(() => routes.runner.dispose());

  const detach = attachRemoteRpcBridge(FakeRpcRouter, routes, FakeRpcError);
  const router = new FakeRpcRouter();

  const health = await router.invoke('workbench.bridge.health', {});
  assert.equal(health.ok, true);
  assert.equal(health.plugin, 'dsh-workbench-bridge');

  const sess1 = await router.invoke('workbench.bridge.sessions', {});
  assert.equal(sess1.sessions.length, 3);
  assert.ok(sess1.etag);

  const sess304 = await router.invoke('workbench.bridge.sessions', { ifNoneMatch: sess1.etag });
  assert.equal(sess304.notModified, true);

  const msgs = await router.invoke('workbench.bridge.messages', {
    engine: 'codex',
    rawId: fx.ids.codexId,
  });
  assert.equal(msgs.engine, 'codex');
  assert.equal(msgs.messages.length, 2);

  await assert.rejects(
    () => router.invoke('workbench.bridge.messages', { engine: 'bad', rawId: '../evil' }),
    (err) => err instanceof FakeRpcError && err.code === 'INVALID_MESSAGE',
  );

  const other = await router.invoke('session/list', { foo: 1 });
  assert.deepEqual(other, { passthrough: 'session/list', params: { foo: 1 } });

  detach();
  const afterDetach = await router.invoke('workbench.bridge.health', {});
  assert.deepEqual(afterDetach, { passthrough: 'workbench.bridge.health', params: {} });
});
