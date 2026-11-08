import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

/// The `/voice-mode/*` routes as `dsh-voice-mode` serves them: Fetch handlers on
/// the Host behind `denyNonLoopback`, so these go through [FakeDsh.rawRoutes].
void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
    addTearDown(client.close);
    return client;
  }

  void route(String path, Future<void> Function(MockRequest request, HttpResponseWriter response) body) {
    host.rawRoutes[path] = (request, response) async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        builder.add(chunk);
      }
      final raw = utf8.decode(builder.takeBytes(), allowMalformed: true);
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name] = values.join(','));
      await body(
        MockRequest(
          method: request.method,
          query: request.uri.queryParameters,
          headers: headers,
          body: raw.isEmpty ? null : tryDecode(raw),
          rawBody: raw,
        ),
        HttpResponseWriter(response),
      );
    };
  }

  /// A full settings payload: every key the route sends, with non-default
  /// values where the test asserts on them.
  Map<String, Object?> settingsJson({
    String managedBy = 'plugin',
    String mode = 'hold',
    double rate = 0.85,
    String readAloud = 'always',
    String ttsEngine = 'kokoro',
  }) => {
    'managedBy': managedBy,
    'value': {
      'ttsEngine': ttsEngine,
      'kokoroModel': 'fp32',
      'voice': 'zh-CN-YunxiNeural',
      'rate': rate,
      'interruptLevel': 2,
      'silenceMs': 2000,
      'idleTimeoutMinutes': 30,
      'modelHost': 'http://127.0.0.1:9999',
      'autoSend': false,
      'autoResume': true,
      'mode': mode,
      'readAloud': readAloud,
      'showCaptions': false,
      'showStatusBar': false,
      'bargeInMode': 'manual',
      'echoGateDb': 9,
      'shortcut': 'Ctrl+Shift+V',
      'composerShortcut': 'Alt+Enter',
      'spokenFormat': false,
      'senseVoice': false,
      'wakeWord': '小d',
      'toolBeep': true,
      'senseITN': false,
      'captionFontSize': 3,
      'captionMaxWidth': 2,
      'backchannelYield': false,
      'bargeInSalvage': false,
      'llmCorrect': true,
      'yieldMs': 2500,
    },
  };

  group('settings', () {
    test('GET parses every modelled field and keeps the rest in raw', () async {
      route(voiceModeSettingsPath, (request, response) async {
        expect(request.method, 'GET');
        response.sendJson(settingsJson());
      });
      final view = await (await connect()).readVoiceModeSettings();
      expect(view.managedBy, VoiceSettingsOwner.plugin);
      expect(view.managedBy.writable, isTrue);
      final value = view.value;
      expect(value.ttsEngine, VoiceTtsEngine.kokoro);
      expect(value.kokoroModel, 'fp32');
      expect(value.voice, 'zh-CN-YunxiNeural');
      expect(value.rate, 0.85);
      expect(value.interruptLevel, 2);
      expect(value.silenceMs, 2000);
      expect(value.idleTimeoutMinutes, 30);
      expect(value.modelHost, 'http://127.0.0.1:9999');
      expect(value.autoSend, isFalse);
      expect(value.autoResume, isTrue);
      expect(value.mode, VoiceModeTrigger.hold);
      expect(value.readAloud, VoiceReadAloud.always);
      expect(value.showCaptions, isFalse);
      expect(value.showStatusBar, isFalse);
      expect(value.bargeInMode, VoiceBargeIn.manual);
      expect(value.echoGateDb, 9);
      expect(value.wakeWord, '小d');
      expect(value.toolBeep, isTrue);
      expect(value.llmCorrect, isTrue);
      expect(value.yieldMs, 2500);
      // `shortcut` is not modelled, but survives in raw for a caller that
      // needs it; it must never be dropped by a write.
      expect(value.raw['shortcut'], 'Ctrl+Shift+V');
    });

    test('a missing payload falls back to the documented defaults', () async {
      route(voiceModeSettingsPath, (request, response) async {
        response.sendJson({'value': <String, Object?>{}});
      });
      final view = await (await connect()).readVoiceModeSettings();
      expect(view.managedBy, VoiceSettingsOwner.plugin);
      expect(view.value.ttsEngine, VoiceTtsEngine.edge);
      expect(view.value.voice, 'zh-CN-XiaoxiaoNeural');
      expect(view.value.rate, 1.1);
      expect(view.value.mode, VoiceModeTrigger.toggle);
      expect(view.value.readAloud, VoiceReadAloud.voice);
      expect(view.value.bargeInMode, VoiceBargeIn.detect);
      expect(view.value.silenceMs, 1500);
    });

    test('POST sends only the patch and reads the answer back', () async {
      Map<String, Object?>? body;
      route(voiceModeSettingsPath, (request, response) async {
        expect(request.method, 'POST');
        body = request.body as Map<String, Object?>?;
        response.sendJson(settingsJson(rate: 1.3));
      });
      final view = await (await connect()).writeVoiceModeSettings({'rate': 1.3});
      expect(body, {'rate': 1.3});
      expect(view.value.rate, 1.3);
    });

    test('an empty patch never reaches the wire', () async {
      await expectLater(
        (await connect()).writeVoiceModeSettings(const {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('409 means the Host owns the settings', () async {
      route(voiceModeSettingsPath, (request, response) async {
        response.status = 409;
        response.sendJson({'code': 'settings_managed'});
      });
      await expectLater(
        (await connect()).writeVoiceModeSettings({'rate': 1}),
        throwsA(isA<VoiceSettingsManagedException>()),
      );
    });

    test('400 names the offending key', () async {
      route(voiceModeSettingsPath, (request, response) async {
        response.status = 400;
        response.sendJson({'code': 'bad_request', 'error': 'invalid value: rate'});
      });
      await expectLater(
        (await connect()).writeVoiceModeSettings({'rate': 99}),
        throwsA(
          isA<VoiceSettingsRejectedException>().having((e) => e.message, 'message', 'invalid value: rate'),
        ),
      );
    });

    test('diffFrom sends only what changed, by wire value', () {
      const before = VoiceModeSettings();
      final after = before.copyWith(
        rate: 1.4,
        mode: VoiceModeTrigger.once,
        readAloud: VoiceReadAloud.off,
        ttsEngine: VoiceTtsEngine.vits,
        showCaptions: false,
      );
      expect(after.diffFrom(before), {
        'ttsEngine': 'vits',
        'rate': 1.4,
        'mode': 'once',
        'readAloud': 'off',
        'showCaptions': false,
      });
      expect(after.diffFrom(after), isEmpty);
    });
  });

  group('microphone', () {
    test('toggle posts the session and reports who holds it now', () async {
      Map<String, Object?>? body;
      route(voiceModeTogglePath, (request, response) async {
        expect(request.method, 'POST');
        body = request.body as Map<String, Object?>?;
        // Another session took the microphone in between.
        response.sendJson({'active': 'session-other'});
      });
      final active = await (await connect()).toggleVoiceMode(
        sessionId: 'session-1',
        on: true,
        tabId: 'tab-1',
        lang: 'zh',
      );
      expect(body, {'sessionId': 'session-1', 'on': true, 'tabId': 'tab-1', 'lang': 'zh'});
      expect(active, 'session-other');
    });

    test('toggle closing sends on:false and no empty tab', () async {
      Map<String, Object?>? body;
      route(voiceModeTogglePath, (request, response) async {
        body = request.body as Map<String, Object?>?;
        response.sendJson({'active': null});
      });
      final active = await (await connect()).toggleVoiceMode(sessionId: 's', on: false, tabId: '');
      expect(body, {'sessionId': 's', 'on': false});
      expect(active, isNull);
    });

    test('a disabled plugin and an unknown session are distinct failures', () async {
      var code = 'voice_disabled';
      route(voiceModeTogglePath, (request, response) async {
        response.status = 403;
        response.sendJson({'code': code});
      });
      final client = await connect();
      await expectLater(
        client.toggleVoiceMode(sessionId: 's', on: true),
        throwsA(isA<VoiceDisabledException>()),
      );
      code = 'unknown_session';
      await expectLater(
        client.toggleVoiceMode(sessionId: 's', on: true),
        throwsA(isA<VoiceUnknownSessionException>()),
      );
    });

    test('rate limiting is its own failure', () async {
      route(voiceModeTogglePath, (request, response) async {
        response.status = 429;
        response.sendJson({'code': 'rate_limited'});
      });
      await expectLater(
        (await connect()).toggleVoiceMode(sessionId: 's', on: true),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'voice-mode/rate-limited')),
      );
    });

    test('cancel sends keepAsr and the reason only when asked', () async {
      Map<String, Object?>? body;
      route(voiceModeCancelPath, (request, response) async {
        body = request.body as Map<String, Object?>?;
        response.sendJson({'ok': true});
      });
      final client = await connect();
      await client.cancelVoiceMode(sessionId: 's');
      expect(body, {'sessionId': 's'});
      await client.cancelVoiceMode(sessionId: 's', keepAsr: true, reason: 'interrupt');
      expect(body, {'sessionId': 's', 'keepAsr': true, 'reason': 'interrupt'});
    });

    test('focus needs a tab id the Host will not drop', () async {
      Map<String, Object?>? body;
      route(voiceModeFocusPath, (request, response) async {
        body = request.body as Map<String, Object?>?;
        response.sendJson({'ok': true});
      });
      final client = await connect();
      await client.focusVoiceMode(sessionId: 'session-1', tabId: 'tab-1');
      expect(body, {'sessionId': 'session-1', 'tabId': 'tab-1'});
      await client.focusVoiceMode(sessionId: null, tabId: 'tab-1');
      expect(body, {'sessionId': null, 'tabId': 'tab-1'});
      await expectLater(client.focusVoiceMode(sessionId: 's', tabId: ''), throwsA(isA<ArgumentError>()));
      await expectLater(
        client.focusVoiceMode(sessionId: 's', tabId: 'x' * 65),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('mode posts its wire value', () async {
      Map<String, Object?>? body;
      route(voiceModeModePath, (request, response) async {
        body = request.body as Map<String, Object?>?;
        response.sendJson({'ok': true});
      });
      await (await connect()).setVoiceModeTrigger(VoiceModeTrigger.hold);
      expect(body, {'mode': 'hold'});
    });
  });

  group('engine', () {
    test('voices parse both the Edge spelling and the short one', () async {
      route(voiceModeVoicesPath, (request, response) async {
        response.sendJson({
          'voices': [
            {
              'Name': 'Microsoft Xiaoxiao Online (Natural)',
              'ShortName': 'zh-CN-XiaoxiaoNeural',
              'FriendlyName': 'Microsoft Xiaoxiao Online (Natural) - Chinese (Mainland)',
              'Locale': 'zh-CN',
              'Gender': 'Female',
            },
            {'id': 'kokoro-1', 'label': 'Kokoro 1', 'locale': 'zh', 'gender': 'Male'},
            {'label': 'no id'},
            'not an object',
          ],
        });
      });
      final voices = await (await connect()).listVoiceModeVoices();
      expect(voices, hasLength(2));
      expect(voices.first.id, 'zh-CN-XiaoxiaoNeural');
      expect(voices.first.label, 'Microsoft Xiaoxiao Online (Natural) - Chinese (Mainland)');
      expect(voices.first.locale, 'zh-CN');
      expect(voices.first.gender, 'Female');
      expect(voices.last.id, 'kokoro-1');
      expect(voices.last.locale, 'zh');
    });

    test('a 502 on the voice list is a remote failure, not an empty list', () async {
      route(voiceModeVoicesPath, (request, response) async {
        response.status = 502;
        response.sendJson({'code': 'internal'});
      });
      await expectLater(
        (await connect()).listVoiceModeVoices(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'voice-mode/voice-list-unavailable')),
      );
    });

    test('models/status readies only when both halves are ready', () async {
      var ttsReady = false;
      route(voiceModeModelsStatusPath, (request, response) async {
        response.sendJson({
          'ready': true,
          'tts': {'ready': ttsReady, 'engine': 'kokoro'},
        });
      });
      final client = await connect();
      final status = await client.readVoiceModelsStatus();
      expect(status.asrReady, isTrue);
      expect(status.ttsReady, isFalse);
      expect(status.ready, isFalse);
      expect(status.engine, 'kokoro');
      ttsReady = true;
      expect((await client.readVoiceModelsStatus()).ready, isTrue);
    });

    test('models/retry defaults to asr', () async {
      final seen = <Object?>[];
      route('$voiceModeBasePath/models/retry', (request, response) async {
        expect(request.method, 'POST');
        seen.add((request.body as Map<String, Object?>?)?['kind']);
        response.sendJson({'ok': true});
      });
      final client = await connect();
      await client.retryVoiceModels();
      await client.retryVoiceModels(kind: VoiceModelKind.sense);
      expect(seen, ['asr', 'sense']);
    });

    test('correct answers the original text whenever the route does not', () async {
      var status = 200;
      Object? payload = {'text': '把按钮改成防抖。'};
      route(voiceModeCorrectPath, (request, response) async {
        expect(request.body, {'text': '把按钮改成防抖', 'lang': 'zh'});
        response.status = status;
        response.sendJson(payload);
      });
      final client = await connect();
      expect(await client.correctVoiceText('把按钮改成防抖'), '把按钮改成防抖。');
      // Any failure is answered with the text as it came in.
      status = 500;
      payload = {'code': 'internal'};
      expect(await client.correctVoiceText('把按钮改成防抖'), '把按钮改成防抖');
    });

    test('preview returns the bytes and clamps the rate', () async {
      Map<String, Object?>? body;
      route(voiceModePreviewPath, (request, response) async {
        body = request.body as Map<String, Object?>?;
        response.sendBytes(Uint8List.fromList([1, 2, 3, 4]), contentType: 'audio/mpeg');
      });
      final preview = await (await connect()).previewVoice(voice: 'zh-CN-XiaoxiaoNeural', rate: 9);
      expect(body, {'voice': 'zh-CN-XiaoxiaoNeural', 'rate': 2.0});
      expect(preview.bytes, [1, 2, 3, 4]);
      expect(preview.contentType, startsWith('audio/mpeg'));
    });

    test('preview keeps the failure category, not the message', () async {
      route(voiceModePreviewPath, (request, response) async {
        response.status = 502;
        response.sendJson({'code': 'preview_engine'});
      });
      await expectLater(
        (await connect()).previewVoice(voice: 'v'),
        throwsA(isA<VoicePreviewFailedException>().having((e) => e.reason, 'reason', VoicePreviewError.engine)),
      );
      expect(VoicePreviewError.engine.retryable, isTrue);
      expect(VoicePreviewError.text.retryable, isFalse);
      await expectLater(
        (await connect()).previewVoice(voice: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('config is passed through unmodelled', () async {
      route(voiceModeConfigPath, (request, response) async {
        response.sendJson({'basePath': '/voice-mode', 'rate': 1.1, 'voice': 'zh-CN-XiaoxiaoNeural'});
      });
      final config = await (await connect()).readVoiceModeConfig();
      expect(config['basePath'], '/voice-mode');
      expect(config['voice'], 'zh-CN-XiaoxiaoNeural');
    });
  });

  group('stream', () {
    /// Registers the live route: [frames] are written at once and the
    /// connection then stays open (as the real route keeps it) until [closed].
    void sseRoute(String path, List<String> frames, Completer<void> closed) {
      host.rawRoutes[path] = (request, response) async {
        response.headers.set('content-type', 'text/event-stream; charset=utf-8');
        // Without this the whole body is buffered until the response closes,
        // which never happens on a live stream.
        response.bufferOutput = false;
        response.add(utf8.encode(frames.join()));
        await response.flush();
        await closed.future;
        await response.close();
      };
    }

    /// Writes the three opening frames the route sends on connect.
    List<String> opening() => [
          'retry: 3000\n\n',
          'event: mode\ndata: {"active":"session-1","ownerTabId":"tab-1"}\n\n',
          'event: focus\ndata: {"sessionId":"session-1","tabId":"tab-1"}\n\n',
          'event: display\ndata: {"readAloud":"voice","showCaptions":true,"showStatusBar":true}\n\n',
        ];

    test('decodes the opening frames and the turn/audio pair', () async {
      final closed = Completer<void>();
      var sawTabId = '';
      var sawAccept = '';
      host.rawRoutes[voiceModeStreamPath] = (request, response) async {
        sawTabId = request.uri.queryParameters['tabId'] ?? '';
        sawAccept = request.headers.value('accept') ?? '';
        response.headers.set('content-type', 'text/event-stream; charset=utf-8');
        response.bufferOutput = false;
        response.add(utf8.encode([
          ...opening(),
          'event: turn\ndata: {"sessionId":"session-1","state":"speaking","turn":2}\n\n',
          'event: audio\ndata: {"sessionId":"session-1","sentenceId":7,"chunkId":0,"final":false,'
              '"audio":"AAEC","mime":"audio/mpeg"}\n\n',
          'event: audio\ndata: {"sessionId":"session-1","sentenceId":7,"chunkId":1,"final":true,'
              '"text":"好了。","audio":"","mime":"audio/mpeg"}\n\n',
        ].join()));
        await response.flush();
        await closed.future;
        await response.close();
      };

      final stream = VoiceModeStream(await connect(), tabId: 'tab-fixed');
      final events = <VoiceModeEvent>[];
      final done = Completer<void>();
      final sub = stream.events.listen((event) {
        events.add(event);
        if (events.length == 6 && !done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 10));
      await sub.cancel();
      await stream.close();
      closed.complete();

      expect(sawTabId, 'tab-fixed');
      expect(sawAccept, 'text/event-stream');
      expect(events.map((e) => e.event), ['mode', 'focus', 'display', 'turn', 'audio', 'audio']);
      expect(events[0].mode!.active, 'session-1');
      expect(events[0].mode!.listening, isTrue);
      expect(events[0].mode!.ownedBy('session-1'), isTrue);
      expect(events[0].mode!.heldByOther('session-2'), isTrue);
      expect(events[1].focus!.focused, isTrue);
      expect(events[2].display!.showCaptions, isTrue);
      expect(events[2].display!.readAloud, VoiceReadAloud.voice);
      expect(events[3].turn!.state, VoiceTurnState.speaking);
      expect(events[3].turn!.state.busy, isTrue);
      expect(events[3].turn!.turn, 2);
      final chunk = events[4].audio!;
      expect(chunk.decode(), [0, 1, 2]);
      expect(chunk.isFinal, isFalse);
      final closing = events[5].audio!;
      expect(closing.decode(), isNull);
      expect(closing.text, '好了。');
      expect(closing.isFinal, isTrue);
    });

    test('a replaced frame tells this client to stop retrying', () async {
      final closed = Completer<void>();
      sseRoute(voiceModeStreamPath, ['event: replaced\ndata: {}\n\n'], closed);
      final stream = VoiceModeStream(await connect(), tabId: 'tab-replaced');
      final event = await stream.events.first.timeout(const Duration(seconds: 10));
      expect(event.isReplaced, isTrue);
      await stream.close();
      closed.complete();
    });

    test('too many streams is its own failure', () async {
      route(voiceModeStreamPath, (request, response) async {
        response.status = 429;
        response.sendJson({'code': 'too_many_streams'});
      });
      final stream = VoiceModeStream(await connect(), tabId: 'tab-9');
      await expectLater(
        stream.events.first,
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'voice-mode/too-many-streams')),
      );
      await stream.close();
    });

    test('a generated tab id fits the Host limit', () {
      final id = VoiceModeStream.newTabId();
      expect(id, isNotEmpty);
      expect(id.length, lessThanOrEqualTo(64));
      expect(VoiceModeStream.newTabId('x'), startsWith('x'));
    });
  });

  group('events', () {
    test('a frame without a named event is dropped, not guessed', () {
      expect(VoiceModeEvent.fromSse(const DsBotSseEvent('', {})), isNull);
      expect(VoiceModeEvent.fromSse(const DsBotSseEvent('message', {})), isNull);
      final event = VoiceModeEvent.fromSse(
        const DsBotSseEvent('tts-skip', {'sessionId': 's', 'text': '嗯', 'streak': 4}),
      );
      expect(event!.tts!.streak, 4);
      expect(event.tts!.text, '嗯');
      expect(event.model, isNull);
    });

    test('a turn frame without a session is not a turn', () {
      expect(VoiceTurn.fromJson({'state': 'speaking'}), isNull);
      expect(VoiceTurn.fromJson({'sessionId': '', 'state': 'speaking'}), isNull);
      expect(VoiceTurn.fromJson({'sessionId': 's'})!.state, VoiceTurnState.unknown);
      expect(VoiceTurnState.parse('idle'), VoiceTurnState.idle);
      expect(VoiceTurnState.parse('idle').busy, isFalse);
      expect(VoiceTurnState.parse('nonsense'), VoiceTurnState.unknown);
    });
  });
}

class MockRequest {
  const MockRequest({
    required this.method,
    required this.query,
    required this.headers,
    required this.body,
    required this.rawBody,
  });

  final String method;
  final Map<String, String> query;
  final Map<String, String> headers;
  final Object? body;
  final String rawBody;
}

class HttpResponseWriter {
  HttpResponseWriter(this._response);

  final dynamic _response;

  set status(int value) => _response.statusCode = value;

  void sendJson(Object? value, {String? etag, String contentType = 'application/json'}) {
    _response.headers.set('content-type', '$contentType; charset=utf-8');
    if (etag != null) _response.headers.set('etag', etag);
    _response.add(utf8.encode(jsonEncode(value)));
    _response.close();
  }

  void sendBytes(Uint8List bytes, {required String contentType}) {
    _response.headers.set('content-type', contentType);
    _response.add(bytes);
    _response.close();
  }
}

Object? tryDecode(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}
