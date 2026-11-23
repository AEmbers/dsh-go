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
