import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

import {
  AntigravityAcpClient,
  AntigravityDesktopCdpClient,
  attachRemoteRpcBridge,
  createNodePrefixHandler,
  createWorkbenchRoutes,
} from '../lib/index.js';
import {
  isLoopbackCdpUrl,
  matchDesktopModelOption,
  matchesCurrentModelLabel,
} from '../lib/desktop_cdp.js';
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

test('bridge strips injected attachment blocks, deduplicates overlay user bubbles, normalizes tool names & supports incremental long-poll', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-wb-sync-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const agyRoot = path.join(root, 'antigravity');
  const uploadRoot = path.join(root, 'uploads');
  const sid = '33333333-3333-3333-3333-333333333333';
  const logDir = path.join(agyRoot, 'brain', sid, '.system_generated', 'logs');
  fs.mkdirSync(logDir, { recursive: true });
  fs.mkdirSync(path.join(agyRoot, 'conversations'), { recursive: true });
  fs.writeFileSync(path.join(agyRoot, 'conversations', `${sid}.db`), '');

  const picPath = path.join(root, 'shot.jpg');
  fs.writeFileSync(picPath, Buffer.from([0xff, 0xd8, 0xff, 0xd9]));

  let activeChild = null;
  const runner = new CliRunManager({
    uploadRoot,
    antigravityIdeRoot: path.join(root, 'ide-empty'),
    antigravityCliRoot: agyRoot,
    resolveBinFn: () => 'fake-agy',
    spawnFn: () => {
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      activeChild = child;
      return child;
    },
  });
  t.after(() => runner.dispose());

  const uploaded = runner.saveUploadChunk({
    name: 'shot.jpg',
    mediaType: 'image/jpeg',
    offset: 0,
    chunkBase64: Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64'),
    done: true,
  });

  const routes = createWorkbenchRoutes({}, { roots: { antigravity: agyRoot }, runner, requireConnection: false });

  // 启动带图对话
  runner.startRun({
    engine: 'antigravity',
    rawSessionId: sid,
    prompt: '宿舍家具全部显示已占用',
    attachmentIds: [uploaded.uploadId],
  });

  // 模拟 Antigravity 将带桥接注入附件块的 USER_INPUT 和含 default_api: 前缀工具调用的 PLANNER_RESPONSE 落盘
  const transcriptPath = path.join(logDir, 'transcript.jsonl');
  const nowIso = new Date().toISOString();
  fs.writeFileSync(
    transcriptPath,
    `${JSON.stringify({
      type: 'USER_INPUT',
      source: 'USER_EXPLICIT',
      step_index: 0,
      created_at: nowIso,
      content: `<USER_REQUEST>\n宿舍家具全部显示已占用\n\n[用户附带的本地文件，请直接读取分析]\n- shot.jpg (image/jpeg): ${picPath}\n</USER_REQUEST>`,
    })}\n${JSON.stringify({
      type: 'PLANNER_RESPONSE',
      step_index: 1,
      created_at: nowIso,
      model: 'gemini-pro-orchestrator-neon',
      thinking: 'Inspecting state',
      tool_calls: [{ id: 'tc1', name: 'default_api:read_file', arguments: '{"Path":"a.dart"}' }],
    })}\n`,
    'utf8',
  );

  // 1) 验证附件块已被剥离并还原为图片 part、工具名已去前缀、且不会在尾部重复追加 run-user-*
  const snap1 = await routes.buildMessagesPayloadAsync('antigravity', sid, { waitMs: 0 });
  const userMsgs = snap1.messages.filter((m) => m.role === 'user');
  assert.equal(userMsgs.length, 1);
  assert.equal(userMsgs[0].parts[0].text, '宿舍家具全部显示已占用');
  assert.equal(userMsgs[0].parts[1].type, 'image');
  assert.equal(userMsgs[0].parts[1].attachment.name, 'shot.jpg');
  assert.equal(snap1.messages[1].parts[1].name, 'read_file');
  assert.ok(snap1.etag);
  assert.equal(snap1.stableCount, 1);

  // 2) 验证 ETag 命中时立即返回 notModified
  const notMod = await routes.buildMessagesPayloadAsync('antigravity', sid, {
    ifNoneMatch: snap1.etag,
    waitMs: 0,
  });
  assert.equal(notMod.notModified, true);
  assert.deepEqual(notMod.messages, []);

  // 3) 验证长轮询在流式 delta 到达时 <500ms 即时唤醒并只返回增量 delta 包
  const t0 = Date.now();
  const waitPromise = routes.buildMessagesPayloadAsync('antigravity', sid, {
    ifNoneMatch: snap1.etag,
    afterCount: snap1.stableCount,
    baseHash: snap1.prefixHash,
    waitMs: 5000,
  });
  setTimeout(() => {
    activeChild.stdout.emit(
      'data',
      Buffer.from(`${JSON.stringify({ event: 'step_update', step_update: { conversation_id: sid, step_index: 2, state: 'ACTIVE', step_type: 'agent_response', text_delta: '已定位问题' } })}\n`),
    );
  }, 40);
  const deltaSnap = await waitPromise;
  assert.ok(Date.now() - t0 < 1500, 'long-poll should wake quickly on stream delta');
  assert.equal(deltaSnap.notModified, undefined);
  assert.equal(deltaSnap.delta, true);
  assert.equal(deltaSnap.replaceFrom, snap1.stableCount);
  assert.ok(deltaSnap.messages.some((m) => m.parts?.some((p) => p.type === 'text' && p.text.includes('已定位问题'))));

  // 4) 验证向 transcript.jsonl 追加新行能通过增量文件缓存立即可见
  fs.appendFileSync(
    transcriptPath,
    `${JSON.stringify({
      type: 'PLANNER_RESPONSE',
      step_index: 2,
      created_at: new Date().toISOString(),
      model: 'gemini-pro-orchestrator-neon',
      content: '已定位问题并修复完成',
    })}\n`,
    'utf8',
  );
  activeChild.emit('close', 0);
  const afterAppend = await routes.buildMessagesPayloadAsync('antigravity', sid, { waitMs: 0 });
  assert.ok(afterAppend.messages.some((m) => m.parts?.some((p) => p.type === 'text' && p.text === '已定位问题并修复完成')));
});

test('persistent Antigravity ACP client reuses daemon, sends native image blocks, streams tool_call updates & cancels cleanly', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-wb-acp-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  let spawnCount = 0;
  const receivedRequests = [];
  let holdNextPrompt = false;
  let heldPromptId = null;
  let activeChild = null;

  const acpClient = new AntigravityAcpClient({
    resolveBinFn: () => 'fake-agy',
    spawnFn: () => {
      spawnCount += 1;
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.stderr = new EventEmitter();
      child.killed = false;
      child.exitCode = null;
      child.kill = () => {
        child.killed = true;
        child.exitCode = 0;
        child.emit('close', 0);
      };
      const send = (obj) => child.stdout.emit('data', Buffer.from(`${JSON.stringify(obj)}\n`));
      child.stdin = {
        destroyed: false,
        write: (raw) => {
          for (const line of String(raw).split(/\r?\n/)) {
            if (!line.trim()) continue;
            const msg = JSON.parse(line);
            receivedRequests.push(msg);
            if (msg.method === 'initialize') {
              send({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: 1, agentCapabilities: { loadSession: true } } });
            } else if (msg.method === 'session/new') {
              send({ jsonrpc: '2.0', id: msg.id, result: { sessionId: 'acp-sess-1', models: { currentModelId: 'gemini-4-neon-high' } } });
            } else if (msg.method === 'session/set_model') {
              send({ jsonrpc: '2.0', id: msg.id, result: {} });
            } else if (msg.method === 'session/prompt') {
              const sid = msg.params.sessionId;
              send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: sid, update: { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'Analyzing image' } } } });
              send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: sid, update: { sessionUpdate: 'tool_call', toolCallId: 'tc-acp-1', name: 'default_api:read_file', args: { Path: 'a.dart' }, status: 'in_progress' } } });
              send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: sid, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Done via ACP' } } } });
              if (holdNextPrompt) {
                heldPromptId = msg.id;
              } else {
                setTimeout(() => send({ jsonrpc: '2.0', id: msg.id, result: { stopReason: 'end_turn' } }), 15);
              }
            } else if (msg.method === 'session/cancel' && heldPromptId !== null) {
              const idToFinish = heldPromptId;
              heldPromptId = null;
              send({ jsonrpc: '2.0', id: idToFinish, result: { stopReason: 'cancelled' } });
            }
          }
        },
      };
      activeChild = child;
      return child;
    },
  });

  const runner = new CliRunManager({
    uploadRoot: path.join(root, 'uploads'),
    antigravityIdeRoot: path.join(root, 'ide'),
    antigravityCliRoot: path.join(root, 'cli'),
    acpClient,
  });
  t.after(() => runner.dispose());

  const uploaded = runner.saveUploadChunk({
    name: 'pic.jpg',
    mediaType: 'image/jpeg',
    offset: 0,
    chunkBase64: Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64'),
    done: true,
  });

  const routes = createWorkbenchRoutes({}, { roots: { antigravity: path.join(root, 'cli') }, runner, requireConnection: false });

  // 第一轮：新建会话 + 传原生图片块 + 切模型 + 接收 thought / tool_call / message 流
  const run1 = runner.startRun({
    engine: 'antigravity',
    prompt: '看看这张图',
    model: 'gemini-4-hydrogen',
    reasoningEffort: 'medium',
    attachmentIds: [uploaded.uploadId],
  });
  assert.equal(run1.running, true);

  await new Promise((r) => setTimeout(r, 90));
  const snap1 = await routes.buildMessagesPayloadAsync('antigravity', run1.rawId, { waitMs: 0 });
  assert.equal(snap1.resolvedSessionId, 'cli:antigravity:acp-sess-1');
  const assistant = snap1.messages.find((m) => m.role === 'assistant');
  assert.ok(assistant);
  assert.ok(assistant.parts.some((p) => p.type === 'reasoning' && p.text.includes('Analyzing image')));
  assert.ok(assistant.parts.some((p) => p.type === 'tool-call' && p.name === 'read_file' && p.id === 'tc-acp-1'));
  assert.ok(assistant.parts.some((p) => p.type === 'text' && p.text.includes('Done via ACP')));

  const promptReq = receivedRequests.find((r) => r.method === 'session/prompt');
  assert.ok(promptReq.params.prompt.some((b) => b.type === 'image' && b.mimeType === 'image/jpeg'));
  assert.ok(receivedRequests.some((r) => r.method === 'session/set_model' && r.params.modelId === 'gemini-4-hydrogen-medium'));
  assert.equal(spawnCount, 1);

  // 第二轮：同一会话续聊零冷启动复用常驻进程，并测试优雅取消 session/cancel
  holdNextPrompt = true;
  runner.startRun({
    engine: 'antigravity',
    rawSessionId: run1.rawId,
    prompt: '第二轮长任务',
  });
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(spawnCount, 1, 'should reuse persistent agy acp process without respawning');
  assert.equal(runner.abortRun('antigravity', 'acp-sess-1'), true);
  assert.ok(receivedRequests.some((r) => r.method === 'session/cancel' && r.params.sessionId === 'acp-sess-1'));
  assert.equal(acpClient.isAlive, true, 'cancel should keep persistent ACP process alive');
  assert.ok(activeChild);
});

test('desktop_cdp validates loopback URLs and matches Antigravity desktop model & effort options', () => {
  assert.equal(isLoopbackCdpUrl('http://127.0.0.1:19222'), true);
  assert.equal(isLoopbackCdpUrl('http://localhost:9222/'), true);
  assert.equal(isLoopbackCdpUrl('http://[::1]:19222'), true);
  assert.equal(isLoopbackCdpUrl('http://192.168.1.50:19222'), false);
  assert.equal(isLoopbackCdpUrl('https://127.0.0.1:19222'), false);
  assert.equal(isLoopbackCdpUrl('ws://127.0.0.1:19222'), false);

  const nonLoopback = new AntigravityDesktopCdpClient({ cdpUrl: 'http://10.0.0.2:19222' });
  assert.equal(nonLoopback.enabled, false);
  assert.equal(nonLoopback.isAvailableSync(), false);

  assert.equal(matchesCurrentModelLabel('Orchestrator Gemini 4 Neon High', 'gemini-pro-orchestrator-neon', null), true);
  assert.equal(matchesCurrentModelLabel('Gemini 4 Neon High', 'gemini-4-neon', 'high'), true);
  assert.equal(matchesCurrentModelLabel('Gemini 4 Neon High', 'gemini-4-neon', 'xhigh'), false);
  assert.equal(matchesCurrentModelLabel('Gemini 4 Neon Medium', 'gemini-pro-orchestrator-neon', null), false);

  const menuItems = [
    { index: 0, text: 'Gemini 4 Neon Medium New', testid: '', modelLabel: '', cx: 100, cy: 100 },
    { index: 1, text: 'Gemini 4 Hydrogen Medium New', testid: '', modelLabel: '', cx: 100, cy: 140 },
    {
      index: 2,
      text: 'Orchestrator Gemini 4 Neon High New',
      testid: 'model-selector-orchestrator',
      modelLabel: 'Orchestrator',
      cx: 100,
      cy: 180,
    },
    { index: 3, text: 'Claude Opus 5.5 Medium New', testid: '', modelLabel: '', cx: 100, cy: 220 },
  ];

  const m1 = matchDesktopModelOption('gemini-4-neon', 'xhigh', menuItems);
  assert.equal(m1?.item.index, 0);
  assert.equal(m1?.desiredEffortLabel, 'Extra High');

  const m2 = matchDesktopModelOption('gemini-pro-orchestrator-neon', 'high', menuItems);
  assert.equal(m2?.item.index, 2);
  assert.equal(m2?.desiredEffortLabel, null);

  const m3 = matchDesktopModelOption('claude-opus-5-5', 'medium', menuItems);
  assert.equal(m3?.item.index, 3);
  assert.equal(m3?.desiredEffortLabel, 'Medium');
});

test('CliRunManager routes IDE sessions in-place & new chats to desktop CDP, and falls back to ACP when offline', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-wb-cdp-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const ideRoot = path.join(root, 'ide');
  const cliRoot = path.join(root, 'cli');
  const ideId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  const cliId = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

  fs.mkdirSync(path.join(ideRoot, 'conversations'), { recursive: true });
  fs.mkdirSync(path.join(ideRoot, 'brain', ideId, '.system_generated', 'logs'), { recursive: true });
  fs.writeFileSync(path.join(ideRoot, 'conversations', `${ideId}.db`), '');
  fs.writeFileSync(
    path.join(ideRoot, 'brain', ideId, '.system_generated', 'logs', 'transcript.jsonl'),
    `${JSON.stringify({
      step_index: 0,
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      created_at: '2026-11-26T01:00:00Z',
      content: '<USER_REQUEST>\nDesktop original prompt\n</USER_REQUEST>',
    })}\n`,
  );

  fs.mkdirSync(path.join(cliRoot, 'conversations'), { recursive: true });
  fs.writeFileSync(path.join(cliRoot, 'conversations', `${cliId}.db`), '');

  let desktopOnline = true;
  const cdpSent = [];
  const cdpAborted = [];
  let holdCdp = false;
  let releaseHeldCdp = null;

  const mockDesktopCdp = {
    enabled: true,
    cdpUrl: 'http://127.0.0.1:19222',
    isAvailableSync: () => desktopOnline,
    probeAvailability: async () => desktopOnline,
    sendPrompt: async (req) => {
      cdpSent.push(req);
      const targetId = req.rawId || 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
      req.onResolvedId?.(targetId);
      req.onStreamUpdate?.({ text: 'Desktop streaming chunk', domRunning: true });
      if (holdCdp) {
        await new Promise((res) => {
          releaseHeldCdp = res;
        });
      }
      return { resolvedRawId: targetId };
    },
    abort: async (id) => {
      cdpAborted.push(id);
      releaseHeldCdp?.();
      return true;
    },
    dispose: () => {},
  };

  const acpCalls = [];
  const mockAcp = {
    isAlive: true,
    ensureSession: async ({ rawId }) => {
      acpCalls.push({ op: 'ensure', rawId });
      return { sessionId: rawId || 'acp-fallback-1' };
    },
    setModel: async () => {},
    prompt: async ({ sessionId, prompt, onUpdate }) => {
      acpCalls.push({ op: 'prompt', sessionId, prompt });
      onUpdate?.({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'ACP fallback reply' } });
      return { stopReason: 'end_turn' };
    },
    cancel: () => {},
    dispose: () => {},
  };

  const runner = new CliRunManager({
    uploadRoot: path.join(root, 'uploads'),
    antigravityIdeRoot: ideRoot,
    antigravityCliRoot: cliRoot,
    desktopCdpClient: mockDesktopCdp,
    acpClient: mockAcp,
  });
  t.after(() => runner.dispose());

  const routes = createWorkbenchRoutes({}, { roots: { antigravity: cliRoot }, runner, requireConnection: false });
  const health = routes.buildHealthPayload();
  assert.deepEqual(health.antigravityDesktop, {
    available: true,
    cdpUrl: 'http://127.0.0.1:19222',
  });

  const pic = runner.saveUploadChunk({
    name: 'desk.jpg',
    mediaType: 'image/jpeg',
    offset: 0,
    chunkBase64: Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString('base64'),
    done: true,
  });

  // 1) 已有桌面 IDE 会话原位续聊：不走 HANDOFF，保留原始 ideId，透传本地图片路径
  holdCdp = true;
  const ideRun = runner.startRun({
    engine: 'antigravity',
    rawSessionId: ideId,
    prompt: 'Continue on desktop',
    model: 'gemini-4-neon',
    reasoningEffort: 'high',
    attachmentIds: [pic.uploadId],
  });
  assert.equal(ideRun.rawId, ideId);
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(cdpSent.length, 1);
  assert.equal(cdpSent[0].rawId, ideId);
  assert.equal(cdpSent[0].prompt, 'Continue on desktop');
  assert.equal(cdpSent[0].filePaths.length, 1);
  assert.equal(acpCalls.length, 0);

  const ideSnap = await routes.buildMessagesPayloadAsync('antigravity', ideId, { waitMs: 0 });
  assert.ok(ideSnap.messages.some((m) => m.role === 'assistant' && m.parts.some((p) => p.text === 'Desktop streaming chunk')));

  // 中止正在进行的桌面 CDP 运行
  assert.equal(runner.abortRun('antigravity', ideId), true);
  assert.deepEqual(cdpAborted, [ideId]);
  await new Promise((r) => setTimeout(r, 20));
  holdCdp = false;

  // 2) 新建会话直连桌面 CDP 并正确写回 resolvedSessionId
  const newDeskRun = runner.startRun({
    engine: 'antigravity',
    prompt: 'Hello new desktop chat',
  });
  assert.ok(newDeskRun.rawId.startsWith('pending-'));
  await new Promise((r) => setTimeout(r, 30));
  const newSnap = await routes.buildMessagesPayloadAsync('antigravity', newDeskRun.rawId, { waitMs: 0 });
  assert.equal(newSnap.resolvedSessionId, 'cli:antigravity:eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');

  // 3) CLI 会话依然直走常驻 ACP，不碰桌面 CDP
  const cdpBeforeCli = cdpSent.length;
  runner.startRun({
    engine: 'antigravity',
    rawSessionId: cliId,
    prompt: 'Stay in CLI ACP',
  });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(cdpSent.length, cdpBeforeCli);
  assert.ok(acpCalls.some((c) => c.op === 'ensure' && c.rawId === cliId));

  // 4) 桌面端直发任务（不在 _runs 中）也可通过 abortRun 通知桌面 CDP 停止
  assert.equal(runner.abortRun('antigravity', ideId), true);
  assert.equal(cdpAborted.filter((id) => id === ideId).length, 2);

  // 5) 桌面版离线时，新建会话自动无缝降级到常驻 ACP
  desktopOnline = false;
  const fallbackRun = runner.startRun({
    engine: 'antigravity',
    prompt: 'Fallback to ACP when desktop offline',
  });
  await new Promise((r) => setTimeout(r, 30));
  const fbSnap = await routes.buildMessagesPayloadAsync('antigravity', fallbackRun.rawId, { waitMs: 0 });
  assert.equal(fbSnap.resolvedSessionId, 'cli:antigravity:acp-fallback-1');
  assert.ok(fbSnap.messages.some((m) => m.parts.some((p) => p.text === 'ACP fallback reply')));
});

test('proxies workbench.bridge.agentTeams.* RPCs over authenticated loopback HTTP with ETag and 401 cookie refresh', async (t) => {
  const validCookies = new Set(['dsh-auth-test=cookie-v1']);
  let nextCookieSeq = 1;
  let etagVersion = 1;
  let serverAddr = '';
  const requests = [];

  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const rawBody = Buffer.concat(chunks).toString('utf8');
      requests.push({
        method: req.method,
        pathname: url.pathname,
        query: Object.fromEntries(url.searchParams.entries()),
        cookie: req.headers.cookie || null,
        ifNoneMatch: req.headers['if-none-match'] || null,
        body: rawBody ? JSON.parse(rawBody) : null,
      });

      // 模拟桌面端无根目录 fallback、由 /connect 完成 launch token -> HttpOnly Cookie 换票
      if (url.pathname === '/') {
        res.writeHead(404);
        res.end();
        return;
      }
      if (url.pathname === '/connect') {
        if (url.searchParams.get('token') !== 'secret-tok') {
          res.writeHead(401, { 'content-type': 'text/plain' });
          res.end('unauthorized');
          return;
        }
        const cookieVal = `dsh-auth-test=cookie-v${nextCookieSeq++}`;
        validCookies.add(cookieVal);
        res.writeHead(302, {
          location: './api/remote.mux',
          'set-cookie': `${cookieVal}; Path=/; HttpOnly; SameSite=Strict`,
        });
        res.end();
        return;
      }

      if (!req.headers.cookie || !validCookies.has(req.headers.cookie)) {
        res.writeHead(401, { 'content-type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ error: 'unauthorized' }));
        return;
      }

      if (url.pathname === '/plugins/dsh-agent-teams/state' && req.method === 'GET') {
        const currentEtag = `W/"etag-v${etagVersion}"`;
        if (req.headers['if-none-match'] === currentEtag) {
          res.writeHead(304, { etag: currentEtag });
          res.end();
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', etag: currentEtag });
        res.end(
          JSON.stringify({
            teams: [
              {
                teamId: 'team-1',
                name: '远端团队',
                captainSessionId: 'session-cap',
                phase: 'running',
                members: [{ id: 'session-cap', name: 'captain', role: 'captain', status: 'active' }],
                tasks: [],
              },
            ],
          }),
        );
        return;
      }

      if (url.pathname === '/plugins/dsh-agent-teams/halt' && req.method === 'POST') {
        const parsed = rawBody ? JSON.parse(rawBody) : {};
        if (parsed.teamId === 'missing') {
          res.writeHead(409, { 'content-type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ error: 'captain session is not attached' }));
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: true }));
        return;
      }

      if (url.pathname === '/plugins/dsh-agent-teams/plan' && req.method === 'POST') {
        const parsed = rawBody ? JSON.parse(rawBody) : {};
        if (parsed.action === 'discard' && parsed.teamId === 'reject-me') {
          res.writeHead(409, { 'content-type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ error: 'plan already running' }));
          return;
        }
        res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: true, phase: 'running', members: 1, tasks: 0 }));
        return;
      }

      res.writeHead(404);
      res.end();
    });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const addr = server.address();
  serverAddr = `http://127.0.0.1:${addr.port}`;

  const mockCtx = {
    get(key) {
      if (key === 'webServer') return { getOrigin: () => serverAddr };
      if (key === 'connection') {
        return {
          authenticatedUrl(baseUrl) {
            const u = new URL(baseUrl);
            u.searchParams.set('token', 'secret-tok');
            return u.href;
          },
        };
      }
      return undefined;
    },
  };

  class FakeRpcRouter {
    async invoke() {
      throw new Error('should not fall through for workbench.bridge.*');
    }
  }
  const routes = createWorkbenchRoutes(mockCtx, { requireConnection: false });
  t.after(() => routes.runner.dispose());
  const detach = attachRemoteRpcBridge(FakeRpcRouter, routes);
  t.after(detach);

  const router = new FakeRpcRouter();

  // 1) 首次读取：自动走 /connect 换票，携带查询参数与 ETag 返回
  const stateRes1 = await router.invoke('workbench.bridge.agentTeams.state', {
    session: 'session-cap',
    summary: true,
  });
  assert.equal(stateRes1.status, 200);
  assert.equal(stateRes1.etag, 'W/"etag-v1"');
  assert.equal(stateRes1.body.teams[0].teamId, 'team-1');
  const firstStateReq = requests.find((r) => r.pathname === '/plugins/dsh-agent-teams/state');
  assert.equal(firstStateReq.query.session, 'session-cap');
  assert.equal(firstStateReq.query.summary, '1');
  assert.equal(firstStateReq.cookie, 'dsh-auth-test=cookie-v1');

  // 2) 带相同 ETag：返回 304 且未重复换票（命中 Cookie 缓存）
  const connectCountBefore = requests.filter((r) => r.pathname === '/connect').length;
  const stateRes304 = await router.invoke('workbench.bridge.agentTeams.state', {
    ifNoneMatch: 'W/"etag-v1"',
  });
  assert.equal(stateRes304.status, 304);
  assert.equal(requests.filter((r) => r.pathname === '/connect').length, connectCountBefore);

  // 3) 模拟旧 Cookie 被撤销导致 401：自动重新换票（cookie-v2）并重试成功
  validCookies.delete('dsh-auth-test=cookie-v1');
  etagVersion = 2;
  const stateResRefreshed = await router.invoke('workbench.bridge.agentTeams.state', {
    archived: true,
  });
  assert.equal(stateResRefreshed.status, 200);
  assert.equal(stateResRefreshed.etag, 'W/"etag-v2"');
  assert.equal(requests.filter((r) => r.pathname === '/connect').length, connectCountBefore + 1);

  // 4) halt 成功与 409/400 错误透传
  const haltOk = await router.invoke('workbench.bridge.agentTeams.halt', {
    sessionId: 'session-cap',
    teamId: 'team-1',
  });
  assert.equal(haltOk.status, 200);
  assert.equal(haltOk.body.ok, true);

  const haltConflict = await router.invoke('workbench.bridge.agentTeams.halt', {
    sessionId: 'session-cap',
    teamId: 'missing',
  });
  assert.equal(haltConflict.status, 409);
  assert.equal(haltConflict.body.error, 'captain session is not attached');

  const haltBad = await router.invoke('workbench.bridge.agentTeams.halt', {
    sessionId: '',
    teamId: 'team-1',
  });
  assert.equal(haltBad.status, 400);

  // 5) plan 成功与 409 拒绝消息透传
  const planOk = await router.invoke('workbench.bridge.agentTeams.plan', {
    sessionId: 'session-cap',
    teamId: 'team-1',
    action: 'approve',
  });
  assert.equal(planOk.status, 200);
  assert.equal(planOk.body.phase, 'running');

  const planRejected = await router.invoke('workbench.bridge.agentTeams.plan', {
    sessionId: 'session-cap',
    teamId: 'reject-me',
    action: 'discard',
  });
  assert.equal(planRejected.status, 409);
  assert.match(planRejected.rawText, /plan already running/);
});
