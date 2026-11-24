import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
    addTearDown(client.close);
    return client;
  }

  void route(String path, Future<void> Function(_MockRequest request, _ResponseWriter response) body) {
    host.rawRoutes[path] = (request, response) async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        builder.add(chunk);
      }
      final raw = utf8.decode(builder.takeBytes(), allowMalformed: true);
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name] = values.join(','));
      await body(
        _MockRequest(
          method: request.method,
          headers: headers,
          body: raw.isEmpty ? null : _tryDecode(raw),
        ),
        _ResponseWriter(response),
      );
    };
  }

  test('CliSessionRef parses and formats prefixed session ids', () {
    expect(CliSessionRef.parse('s1'), isNull);
    expect(CliSessionRef.parse('cli:dsh:s1'), isNull);
    final ref = CliSessionRef.parse('cli:antigravity:abc-123');
    expect(ref, isNotNull);
    expect(ref!.engine, CliEngine.antigravity);
    expect(ref.rawId, 'abc-123');
    expect(ref.sessionId, 'cli:antigravity:abc-123');
  });

  test('reads health, sessions with ETag/304, messages, prompt, and abort', () async {
    route(workbenchBridgeHealthPath, (req, res) async {
      res.sendJson({
        'ok': true,
        'engines': {
          'antigravity': {'installed': true, 'executable': '/usr/bin/agy'},
          'claude': {'installed': false, 'executable': null},
          'codex': {'installed': true, 'executable': '/usr/bin/codex'},
        },
      });
    });

    route(workbenchBridgeSessionsPath, (req, res) async {
      if (req.headers['if-none-match'] == '"v1"') {
        res.status = 304;
        await res.finish();
        return;
      }
      res.sendJson({
        'ok': true,
        'sessions': [
          {
            'engine': 'antigravity',
            'rawId': 'agy-1',
            'sessionId': 'cli:antigravity:agy-1',
            'title': 'Larch-4N',
            'cwd': 'D:/dev/workspace',
            'updatedAt': 1795424852000,
            'running': true,
          },
        ],
      }, etag: '"v1"');
    });

    route('/plugins/dsh-workbench-bridge/sessions/antigravity/agy-1/messages', (req, res) async {
      res.sendJson({
        'ok': true,
        'engine': 'antigravity',
        'rawId': 'agy-1',
        'sessionId': 'cli:antigravity:agy-1',
        'model': 'gemini-4-hydrogen-high',
        'cwd': 'D:/dev/workspace',
        'running': true,
        'messages': [
          {
            'messageId': 'm1',
            'role': 'user',
            'createdAt': 1795424850000,
            'parts': [
              {'type': 'text', 'text': 'Remember Larch-4N'},
            ],
          },
          {
            'messageId': 'm2',
            'role': 'assistant',
            'createdAt': 1795424851000,
            'model': 'gemini-4-hydrogen-high',
            'parts': [
              {'type': 'reasoning', 'text': 'Ack'},
              {'type': 'text', 'text': 'Larch-4N'},
            ],
          },
        ],
      });
    });

    route(workbenchBridgePromptPath, (req, res) async {
      final map = req.body as Map<String, Object?>;
      expect(map['engine'], 'antigravity');
      expect(map['rawSessionId'], 'agy-1');
      expect(map['prompt'], 'Next step');
      res.sendJson({'ok': true, 'sessionId': 'cli:antigravity:agy-1', 'rawId': 'agy-1', 'runId': 'r1', 'running': true});
    });

    route(workbenchBridgeAbortPath, (req, res) async {
      res.sendJson({'ok': true, 'aborted': true});
    });

    final client = await connect();

    final health = await client.readWorkbenchBridgeHealth();
    expect(health.engines[CliEngine.antigravity]?.installed, isTrue);
    expect(health.engines[CliEngine.claude]?.installed, isFalse);

    final first = await client.readWorkbenchBridgeSessions();
    expect(first, isNotNull);
    expect(first!.etag, '"v1"');
    expect(first.sessions.single.engine, CliEngine.antigravity);
    final summary = first.sessions.single.toSessionSummary();
    expect(summary.cliEngine, CliEngine.antigravity);
    expect(summary.isExternalCli, isTrue);

    final unchanged = await client.readWorkbenchBridgeSessions(ifNoneMatch: '"v1"');
    expect(unchanged, isNull);

    final snap = await client.readWorkbenchBridgeMessages(CliEngine.antigravity, 'agy-1');
    expect(snap.running, isTrue);
    expect(snap.messages.length, 2);
    expect(snap.messages[1].toWireMessage().text, 'Larch-4N');

    final promptRes = await client.sendWorkbenchBridgePrompt(
      engine: CliEngine.antigravity,
      rawSessionId: 'agy-1',
      prompt: 'Next step',
    );
    expect(promptRes.running, isTrue);

    expect(await client.abortWorkbenchBridgeRun(CliEngine.antigravity, 'agy-1'), isTrue);
  });

  test('throws WorkbenchBridgeUnavailableException when route returns 404', () async {
    final client = await connect();
    await expectLater(client.readWorkbenchBridgeSessions(), throwsA(isA<WorkbenchBridgeUnavailableException>()));
  });

  test('supports non-HTTP RPC bridge carrier and maps METHOD_NOT_FOUND cleanly', () async {
    final carrier = _FakeRpcCarrier((method, params) async {
      return switch (method) {
        'workbench.bridge.health' => {
          'ok': true,
          'engines': {
            'codex': {'installed': true, 'executable': 'codex'},
          },
        },
        'workbench.bridge.sessions' when params['ifNoneMatch'] == '"e1"' => {'ok': true, 'notModified': true, 'etag': '"e1"'},
        'workbench.bridge.sessions' => {
          'ok': true,
          'etag': '"e1"',
          'sessions': [
            {
              'engine': 'codex',
              'rawId': 'cx-1',
              'sessionId': 'cli:codex:cx-1',
              'title': 'Codex Remote Task',
              'updatedAt': 1795424852000,
              'running': true,
            },
          ],
        },
        'workbench.bridge.messages' => {
          'ok': true,
          'engine': 'codex',
          'rawId': 'cx-1',
          'sessionId': 'cli:codex:cx-1',
          'running': false,
          'messages': const <Object?>[],
        },
        'workbench.bridge.prompt' => {
          'ok': true,
          'sessionId': 'cli:codex:cx-1',
          'rawId': 'cx-1',
          'runId': 'run-1',
          'running': true,
        },
        'workbench.bridge.models' => {
          'ok': true,
          'engine': params['engine'],
          'default': {'provider': 'gemini', 'model': 'gemini-4-neon', 'reasoningEffort': 'high'},
          'routableProviders': ['gemini'],
          'groups': [
            {
              'id': 'gemini',
              'name': 'Gemini',
              'models': [
                {
                  'id': 'gemini-4-neon',
                  'name': 'Gemini 4 Neon',
                  'reasoning': {
                    'efforts': [
                      {'id': 'medium', 'name': 'Medium'},
                      {'id': 'high', 'name': 'High'},
                    ],
                    'defaultEffort': 'high',
                  },
                },
              ],
            },
          ],
          'failures': const <Object?>[],
        },
        'workbench.bridge.upload' => {
          'ok': true,
          'uploadId': params['uploadId'] ?? 'up-rpc-1',
          'name': params['name'] ?? 'pic.png',
          'mediaType': params['mediaType'] ?? 'image/png',
          'bytes': (params['offset'] as int? ?? 0) + (base64Decode(params['chunkBase64'] as String).length),
          'done': params['done'] == true,
        },
        'workbench.bridge.abort' => {'ok': true, 'aborted': true},
        _ => throw const DshRemoteException('METHOD_NOT_FOUND', 'missing'),
      };
    });
    final client = await DshClient.connectCarrier(carrier, startMux: false);
    addTearDown(client.close);

    final health = await client.readWorkbenchBridgeHealth();
    expect(health.engines[CliEngine.codex]?.installed, isTrue);

    final res = await client.readWorkbenchBridgeSessions();
    expect(res?.etag, '"e1"');
    expect(res?.sessions.single.cliEngineOrDefault, CliEngine.codex);

    expect(await client.readWorkbenchBridgeSessions(ifNoneMatch: '"e1"'), isNull);
    expect((await client.readWorkbenchBridgeMessages(CliEngine.codex, 'cx-1')).engine, CliEngine.codex);
    expect((await client.sendWorkbenchBridgePrompt(engine: CliEngine.codex, rawSessionId: 'cx-1', prompt: 'hi')).running, isTrue);
    expect(await client.abortWorkbenchBridgeRun(CliEngine.codex, 'cx-1'), isTrue);

    final models = await client.readWorkbenchBridgeModels(CliEngine.antigravity);
    expect(models.groups.single.id, 'gemini');
    expect(models.groups.single.models.single.id, 'gemini-4-neon');
    expect(models.groups.single.models.single.efforts.map((e) => e.id), ['medium', 'high']);
    expect(models.defaultSelection?.reasoningEffort, 'high');

    final bigBytes = Uint8List.fromList(List<int>.filled(250 * 1024, 7));
    final uploaded = await client.uploadWorkbenchBridgeAttachment(
      name: 'big.png',
      mediaType: 'image/png',
      bytes: bigBytes,
    );
    expect(uploaded.uploadId, 'up-rpc-1');
    expect(uploaded.bytes, bigBytes.length);

    final withAttachment = await client.sendWorkbenchBridgePrompt(
      engine: CliEngine.antigravity,
      rawSessionId: 'agy-1',
      prompt: '',
      model: 'gemini-4-neon',
      reasoningEffort: 'high',
      attachmentIds: [uploaded.uploadId],
    );
    expect(withAttachment.running, isTrue);

    final unavailableClient = await DshClient.connectCarrier(
      _FakeRpcCarrier((method, params) async => throw const DshRemoteException('METHOD_NOT_FOUND', 'missing')),
      startMux: false,
    );
    addTearDown(unavailableClient.close);
    await expectLater(unavailableClient.readWorkbenchBridgeSessions(), throwsA(isA<WorkbenchBridgeUnavailableException>()));
  });
}

extension _SessionEngineX on WorkbenchCliSession {
  CliEngine get cliEngineOrDefault => engine;
}

class _FakeRpcCarrier extends DshCarrier {
  _FakeRpcCarrier(this._onBridgeRpc);

  final Future<Map<String, Object?>?> Function(String method, Map<String, Object?> params) _onBridgeRpc;

  @override
  String get kind => 'fake-remote-rpc';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw UnimplementedError();

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();

  @override
  Future<Map<String, Object?>?> invokeWorkbenchBridgeRpc(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) => _onBridgeRpc(method, params);

  @override
  Future<void> close() async {}
}

class _MockRequest {
  const _MockRequest({required this.method, required this.headers, required this.body});
  final String method;
  final Map<String, String> headers;
  final Object? body;
}

class _ResponseWriter {
  _ResponseWriter(this._response);
  final dynamic _response;

  set status(int value) => _response.statusCode = value;

  void sendJson(Object? value, {String? etag}) {
    _response.headers.set('content-type', 'application/json; charset=utf-8');
    if (etag != null) _response.headers.set('etag', etag);
    _response.add(utf8.encode(jsonEncode(value)));
    _response.close();
  }

  Future<void> finish() async => _response.close();
}

Object? _tryDecode(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}
