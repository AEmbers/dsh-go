import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

import { attachRemoteRpcBridge, createNodePrefixHandler, createWorkbenchRoutes } from '../lib/index.js';
import { parseAntigravityModelsOutput, resolveAntigravityWireModel } from '../lib/models.js';
import { CliRunManager, buildCliCommand, parseCliStreamLine } from '../lib/runner.js';
import { readAntigravityMessages, scanAntigravitySessions } from '../lib/scanners/antigravity.js';
import { unwrapUserRequest } from '../lib/scanners/common.js';
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
    '--output-format',
    'stream-json',
    '--conversation',
    'abc',
    '--print=hi',
  ]);
  assert.deepEqual(
    buildCliCommand('antigravity', {
      rawSessionId: 'abc',
      prompt: 'hi',
      model: 'gemini-4-neon',
      reasoningEffort: 'high',
      addDirs: ['C:\\tmp\\up1'],
    }).args,
    [
      '--output-format',
      'stream-json',
      '--conversation',
      'abc',
      '--model',
      'gemini-4-neon-high',
      '--add-dir',
      'C:\\tmp\\up1',
      '--print=hi',
    ],
  );
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
    async handle(message) {
      if (message?.payload?.method === 'unknown.method') {
        return { id: message.id, type: 'rpc.error', payload: { code: 'METHOD_NOT_FOUND' } };
      }
      const result = await this.invoke(message.payload.method, message.payload.params);
      return { id: message.id, type: 'rpc.response', payload: { result } };
    }
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

  const handled = await router.handle({
    id: 'req-1',
    type: 'rpc.request',
    payload: { method: 'workbench.bridge.health', params: {} },
  });
  assert.equal(handled.v, 1);
  assert.equal(handled.type, 'rpc.response');
  assert.equal(handled.payload.requestId, 'req-1');
  assert.equal(handled.payload.result.plugin, 'dsh-workbench-bridge');

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

test('Antigravity model catalog parser, stream-json parser, and chunked upload work end-to-end', async (t) => {
  const uploadRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-wb-up-'));
  t.after(() => fs.rmSync(uploadRoot, { recursive: true, force: true }));

  const catalog = parseAntigravityModelsOutput([
    'Fetching available models...',
    'gemini-4-neon-high\tGemini 4 Neon (High)',
    'gemini-4-neon-medium\tGemini 4 Neon (Medium)',
    'gemini-pro-orchestrator-neon\tOrchestrator (Neon)',
    'claude-opus-5-5-low\tClaude Opus 5.5 (Low)',
  ].join('\n'));
  assert.equal(catalog.groups.length, 3);
  assert.equal(catalog.groups[0].id, 'gemini');
  assert.equal(catalog.groups[0].models[0].id, 'gemini-4-neon');
  assert.equal(catalog.default.model, 'gemini-4-neon');
  assert.deepEqual(
    catalog.groups[0].models[0].reasoning.efforts.map((e) => e.id),
    ['medium', 'high'],
  );

  assert.deepEqual(resolveAntigravityWireModel('gemini-pro-orchestrator-neon', 'high'), {
    model: 'gemini-pro-orchestrator-neon',
    effort: null,
  });
  const orchCmd = buildCliCommand('antigravity', {
    prompt: 'hi',
    model: 'gemini-pro-orchestrator-neon',
    reasoningEffort: 'high',
  });
  assert.ok(orchCmd.args.includes('--model'));
  assert.ok(orchCmd.args.includes('gemini-pro-orchestrator-neon'));
  assert.equal(orchCmd.args.includes('--effort'), false);

  const step = parseCliStreamLine(JSON.stringify({
    event: 'step_update',
    step_update: { conversation_id: 'c1', text_delta: 'OK' },
  }));
  assert.equal(step.sessionId, 'c1');
  assert.equal(step.textDelta, 'OK');

  const resLine = parseCliStreamLine(JSON.stringify({
    event: 'result',
    result: { conversation_id: 'c1', response: 'OK\n' },
  }));
  assert.equal(resLine.finalText, 'OK\n');

  let capturedArgs = [];
  const manager = new CliRunManager({
    uploadRoot,
    resolveBinFn: () => 'fake-agy',
    spawnFn: (_exe, args) => {
      capturedArgs = args;
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      setTimeout(() => {
        child.stdout.emit('data', Buffer.from('{"event":"step_update","step_update":{"conversation_id":"c1","text_delta":"Seen"}}\n'));
        child.stdout.emit('data', Buffer.from('{"event":"result","result":{"conversation_id":"c1","response":"Seen"}}\n'));
        child.emit('close', 0);
      }, 5);
      return child;
    },
  });

  const c1 = manager.saveUploadChunk({
    name: '../pic.png',
    mediaType: 'image/png',
    offset: 0,
    chunkBase64: Buffer.from('hello ').toString('base64'),
    done: false,
  });
  const c2 = manager.saveUploadChunk({
    uploadId: c1.uploadId,
    offset: c1.bytes,
    chunkBase64: Buffer.from('world').toString('base64'),
    done: true,
  });
  assert.equal(c2.done, true);
  assert.equal(c2.bytes, 11);
  assert.equal(c2.name, 'pic.png');

  const run = manager.startRun({
    engine: 'antigravity',
    rawSessionId: 'c1',
    prompt: '',
    model: 'gemini-4-neon',
    reasoningEffort: 'high',
    attachmentIds: [c1.uploadId],
  });
  assert.equal(run.running, true);
  assert.ok(capturedArgs.includes('--add-dir'));
  assert.ok(capturedArgs.includes('gemini-4-neon-high'));
  assert.ok(capturedArgs.at(-1).startsWith('--print='));
  assert.ok(capturedArgs.at(-1).includes('pic.png'));

  await new Promise((r) => setTimeout(r, 40));
  const overlay = manager.getOverlay('antigravity', 'c1');
  assert.equal(overlay.assistantText, 'Seen');
  assert.equal(overlay.prompt, '[附件: pic.png]');

  // 新建会话（无 rawSessionId）返回 pending-*，并自动映射 resolvedRawId
  const fresh = manager.startRun({
    engine: 'antigravity',
    prompt: 'Hello new',
  });
  assert.ok(fresh.rawId.startsWith('pending-'));
  await new Promise((r) => setTimeout(r, 40));
  const freshOverlay = manager.getOverlay('antigravity', fresh.rawId);
  assert.equal(freshOverlay.resolvedRawId, 'c1');
  manager.startRun({
    engine: 'antigravity',
    rawSessionId: fresh.rawId,
    prompt: 'Follow up',
  });
  assert.ok(capturedArgs.includes('--conversation'));
  assert.ok(capturedArgs.includes('c1'));
});

test('files/stat, read-bytes, read-text, list, wb-upload, and Antigravity USER_INPUT media parts work', async (t) => {
  const fx = makeTempFixtures();
  t.after(() => fs.rmSync(fx.root, { recursive: true, force: true }));

  const workspaceDir = path.join(fx.root, 'ws');
  fs.mkdirSync(workspaceDir, { recursive: true });
  const textFile = path.join(workspaceDir, 'hello.txt');
  fs.writeFileSync(textFile, 'line1\nline2\nline3\n', 'utf8');
  const binFile = path.join(workspaceDir, 'sample.png');
  const pngBytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01, 0x02]);
  fs.writeFileSync(binFile, pngBytes);

  // 追加一条带 media 图片（无正文）的 Antigravity USER_INPUT 记录
  const transcriptPath = path.join(fx.roots.antigravity, 'brain', fx.ids.agyId, '.system_generated', 'logs', 'transcript.jsonl');
  fs.appendFileSync(
    transcriptPath,
    `\n${JSON.stringify({
      type: 'USER_INPUT',
      source: 'USER_EXPLICIT',
      step_index: 99,
      created_at: '2026-11-25T05:00:00Z',
      content: '<USER_REQUEST>\n</USER_REQUEST>',
      media: [{ mime_type: 'image/png', uri: `file:///${binFile.replace(/\\/g, '/')}` }],
    })}\n`,
  );

  const uploadRoot = path.join(fx.root, 'uploads-files');
  const manager = new CliRunManager({
    uploadRoot,
    resolveBinFn: () => 'fake-agy',
    spawnFn: () => {
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      return child;
    },
  });
  const uploaded = manager.saveUploadChunk({
    name: 'snap.png',
    mediaType: 'image/png',
    offset: 0,
    chunkBase64: pngBytes.toString('base64'),
    done: true,
  });

  const routes = createWorkbenchRoutes(
    { get: () => ({ requestRejection: () => null }) },
    { roots: fx.roots, runner: manager },
  );

  // 验证 Antigravity media 图片解析
  const agyMsgs = routes.buildMessagesPayload('antigravity', fx.ids.agyId);
  const mediaMsg = agyMsgs.messages.at(-1);
  assert.equal(mediaMsg.role, 'user');
  assert.equal(mediaMsg.parts[0].type, 'image');
  assert.equal(mediaMsg.parts[0].attachment.name, 'sample.png');
  assert.ok(mediaMsg.parts[0].attachment.attachmentId.startsWith('wb-file:'));

  // 验证 file:// 与 /C:/... 规范化及 stat/read-bytes/read-text/list
  const normalizedUri = binFile.replace(/\\/g, '/');
  const fileUri = /^[A-Za-z]:\//.test(normalizedUri) ? `file:///${normalizedUri}` : `file://${normalizedUri}`;
  const statRes = await routes.handleFileStat(
    new Request('http://localhost/plugins/dsh-workbench-bridge/files/stat', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawId: fx.ids.agyId, path: fileUri }),
    }),
  );
  assert.equal(statRes.status, 200);
  const statBody = await statRes.json();
  assert.equal(statBody.bytes, pngBytes.length);
  assert.match(statBody.version, /^\d+:\d+:\d+:\d+:\d+$/);

  const bytesRes = await routes.handleFileReadBytes(
    new Request('http://localhost/plugins/dsh-workbench-bridge/files/read-bytes', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawId: fx.ids.agyId, path: fileUri, offset: 0, length: 6 }),
    }),
  );
  assert.equal(bytesRes.status, 200);
  const bytesBody = await bytesRes.json();
  assert.equal(bytesBody.eof, false);
  assert.deepEqual(Buffer.from(bytesBody.data, 'base64'), pngBytes.subarray(0, 6));

  // wb-upload:<id> 读取
  const upBytes = routes.buildFileReadBytesPayload({
    engine: 'antigravity',
    rawId: fx.ids.agyId,
    path: `wb-upload:${uploaded.uploadId}`,
    offset: 0,
    length: 1024,
  });
  assert.equal(upBytes.eof, true);
  assert.deepEqual(Buffer.from(upBytes.data, 'base64'), pngBytes);

  // read-text 正常分页与二进制文件拒绝
  const textRes = await routes.handleFileReadText(
    new Request('http://localhost/plugins/dsh-workbench-bridge/files/read-text', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawId: fx.ids.agyId, path: textFile, offset: 2, limit: 2 }),
    }),
  );
  assert.equal(textRes.status, 200);
  const textBody = await textRes.json();
  assert.equal(textBody.text, 'line2\nline3');
  assert.equal(textBody.lines, 2);
  assert.equal(textBody.eof, true);

  const binTextRes = await routes.handleFileReadText(
    new Request('http://localhost/plugins/dsh-workbench-bridge/files/read-text', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawId: fx.ids.agyId, path: binFile }),
    }),
  );
  assert.equal(binTextRes.status, 400);
  assert.equal((await binTextRes.json()).code, 'workspace-file/not-text');

  // list 目录枚举
  const listRes = await routes.handleFileList(
    new Request('http://localhost/plugins/dsh-workbench-bridge/files/list', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawId: fx.ids.agyId, path: workspaceDir }),
    }),
  );
  assert.equal(listRes.status, 200);
  const listBody = await listRes.json();
  assert.ok(listBody.entries.some((e) => e.name === 'hello.txt' && e.type === 'file'));

  // 缺失文件 & 目录当作普通文件读取的错误码
  const missingRes = await routes.handleFileStat(
    new Request('http://localhost/plugins/dsh-workbench-bridge/files/stat', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawId: fx.ids.agyId, path: path.join(workspaceDir, 'nope.png') }),
    }),
  );
  assert.equal(missingRes.status, 404);
  assert.equal((await missingRes.json()).code, 'workspace-file/not-found');

  const dirStatRes = await routes.handleFileStat(
    new Request('http://localhost/plugins/dsh-workbench-bridge/files/stat', {
      method: 'POST',
      body: JSON.stringify({ engine: 'antigravity', rawId: fx.ids.agyId, path: workspaceDir }),
    }),
  );
  assert.equal(dirStatRes.status, 400);
  assert.equal((await dirStatRes.json()).code, 'workspace-file/not-regular-file');
});

test('Antigravity scanner merges IDE and CLI roots and auto-hands off IDE-only session prompts', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-agy-dual-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const ideRoot = path.join(root, 'antigravity');
  const cliRoot = path.join(root, 'antigravity-cli');
  const ideId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const cliId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

  fs.mkdirSync(path.join(ideRoot, 'conversations'), { recursive: true });
  fs.mkdirSync(path.join(ideRoot, 'brain', ideId, '.system_generated', 'logs'), { recursive: true });
  fs.writeFileSync(path.join(ideRoot, 'conversations', `${ideId}.db`), '');
  fs.writeFileSync(
    path.join(ideRoot, 'brain', ideId, '.system_generated', 'logs', 'transcript.jsonl'),
    `${JSON.stringify({
      step_index: 0,
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      created_at: '2026-11-25T01:00:00Z',
      content: '<USER_REQUEST>\nIDE only prompt\n</USER_REQUEST>',
    })}\n`,
  );

  fs.mkdirSync(path.join(cliRoot, 'conversations'), { recursive: true });
  fs.mkdirSync(path.join(cliRoot, 'brain', cliId, '.system_generated', 'logs'), { recursive: true });
  fs.writeFileSync(path.join(cliRoot, 'conversations', `${cliId}.db`), '');
  fs.writeFileSync(
    path.join(cliRoot, 'brain', cliId, '.system_generated', 'logs', 'transcript.jsonl'),
    `${JSON.stringify({
      step_index: 0,
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      created_at: '2026-11-25T02:00:00Z',
      content: '<USER_REQUEST>\nCLI prompt\n</USER_REQUEST>',
    })}\n`,
  );

  const merged = scanAntigravitySessions({ rootDir: ideRoot, cliRootDir: cliRoot });
  assert.deepEqual(
    merged.map((s) => s.rawId),
    [cliId, ideId],
  );
  const cliMsgs = readAntigravityMessages(cliId, { rootDir: ideRoot, cliRootDir: cliRoot });
  assert.equal(cliMsgs.messages[0].parts[0].text, 'CLI prompt');

  const calls = [];
  const manager = new CliRunManager({
    antigravityIdeRoot: ideRoot,
    antigravityCliRoot: cliRoot,
    resolveBinFn: () => 'fake-agy',
    spawnFn: (_exe, args) => {
      calls.push(args);
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      return child;
    },
  });

  // IDE 独占会话发送消息：自动开启 pending-* 接续会话并注入历史上下文，不再报错
  const handoffRun = manager.startRun({ engine: 'antigravity', rawSessionId: ideId, prompt: 'continue please' });
  assert.equal(handoffRun.running, true);
  assert.ok(handoffRun.rawId.startsWith('pending-'));
  assert.equal(handoffRun.handedOffFrom, ideId);
  assert.ok(!calls[0].includes('--conversation'));
  const handoffPrintArg = calls[0].at(-1);
  assert.ok(handoffPrintArg.includes('<HANDOFF_CONTEXT>'));
  assert.ok(handoffPrintArg.includes('IDE only prompt'));
  assert.ok(handoffPrintArg.includes('continue please'));

  // transcript 展示清洗：剥离 <HANDOFF_CONTEXT>，仅保留用户原始问题
  assert.equal(
    unwrapUserRequest(`<USER_REQUEST>\n<HANDOFF_CONTEXT>\nhistory\n</HANDOFF_CONTEXT>\n\ncontinue please\n</USER_REQUEST>`),
    'continue please',
  );

  // CLI 会话发送消息：正常带 --conversation 续聊
  const okRun = manager.startRun({ engine: 'antigravity', rawSessionId: cliId, prompt: 'hello' });
  assert.equal(okRun.running, true);
  assert.equal(okRun.rawId, cliId);
  assert.ok(calls[1].includes('--conversation'));
  assert.ok(calls[1].includes(cliId));
  manager.dispose();
});
