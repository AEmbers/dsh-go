// `dsh-voice-mode` on the app side: the live channel (`GET /voice-mode/stream`),
// the one-shot reads behind the settings page, and the three things the app
// decides itself (focus, the microphone, the switches).
//
// The Host here is a real loopback `HttpServer`, because the stream is an SSE
// response read through an `HttpClient` of the plugin's own — a stubbed carrier
// never reaches `/voice-mode/*` at all.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/voice_mode_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Host that answers the plugin's routes.
class _VoiceHost {
  _VoiceHost(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  /// Every request, newest last.
  final requests = <({String method, String path, Map<String, String> query, Map<String, Object?>? body})>[];

  /// What `/settings` answers, and the body it answers with.
  int settingsStatus = 200;
  Map<String, Object?> settingsBody = _settingsView();

  /// What `/models/status` answers.
  Map<String, Object?> modelsBody = const {
    'ready': true,
    'tts': {'ready': true, 'engine': 'edge'},
  };

  /// The switches `/config` reports, for the fallback beat.
  Map<String, Object?> configBody = const {
    'active': null,
    'readAloud': 'voice',
    'showCaptions': true,
    'showStatusBar': true,
  };

  /// What the action routes answer.
  int actionStatus = 200;
  Map<String, Object?> actionBody = const {'ok': true};

  /// What `/toggle` says the microphone belongs to after the call.
  String? toggleActive;

  /// Set to a status to refuse the stream instead of opening it.
  int streamStatus = 200;

  /// How many streams were opened, and the sink that pushes frames into the
  /// one that is open.
  int streamOpens = 0;
  void Function(String event, Map<String, Object?> data)? _push;
  bool _streamClosed = true;
  Completer<void>? _streamDone;

  /// While set, `GET /settings` is held at the Host: the app has a read in
  /// flight that only answers when the test says so. This is how a switch of
  /// host is made to race a reply of the host it is leaving.
  Completer<void>? holdSettings;

  /// While set, `GET /models/status` is held at the Host. `_reloadModels` reads
  /// this route off an `asr-ready` frame and is keyed by neither ticket nor
  /// request id, so it is the one path where only the owning host can tell the
  /// app whether the reply is still wanted.
  Completer<void>? holdModels;

  /// The `/settings` reads that reached the Host, whether or not they answered.
  int get settingsHits => hitsOn(voiceModeSettingsPath).length;

  /// The `/models/status` reads that reached the Host, answered or not.
  int get modelsHits => hitsOn(voiceModeModelsStatusPath).length;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  /// The tab id the stream asked for, so a test can compare what was posted.
  String? get streamTabId {
    for (final request in requests.reversed) {
      if (request.path == voiceModeStreamPath) return request.query['tabId'];
    }
    return null;
  }

  /// Every tab id a `/stream` open asked for, oldest first: a reconnect that
  /// mints a new id is a new client as far as the Host is concerned.
  List<String> get streamTabIds => [
    for (final request in requests)
      if (request.path == voiceModeStreamPath) request.query['tabId'] ?? '',
  ];

  List<({String method, String path, Map<String, String> query, Map<String, Object?>? body})> hitsOn(String path) =>
      requests.where((r) => r.path == path).toList();

  /// Drops the stream that is open, the way a Host restart does: the client
  /// sees a closed body and comes back after its backoff.
  void dropStream() {
    if (_streamDone case final open? when !open.isCompleted) open.complete();
    _streamDone = null;
  }

  static Future<_VoiceHost> start() async => _VoiceHost(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() async {
    _streamClosed = true;
    _push = null;
    if (_streamDone case final done? when !done.isCompleted) done.complete();
    await _server.close(force: true);
  }

  /// Pushes one frame into the open stream.
  void push(String event, Map<String, Object?> data) {
    final push = _push;
    if (push == null) fail('no stream is open to push $event');
    push(event, data);
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final raw = await utf8.decoder.bind(request).join();
    final body = raw.isEmpty ? null : _decode(raw);
    requests.add((method: request.method, path: path, query: request.uri.queryParameters, body: body));

    if (path == voiceModeStreamPath) {
      await _serveStream(request);
      return;
    }
    // A held read stays unanswered at the Host, so a test can bring up the next
    // Host and only then let the old reply land.
    if (path == voiceModeSettingsPath && holdSettings != null) await holdSettings!.future;
    if (path == voiceModeModelsStatusPath && holdModels != null) await holdModels!.future;
    final response = request.response;
    switch (path) {
      case voiceModeSettingsPath when request.method == 'GET':
        _sendJson(response, settingsBody, status: settingsStatus);
      case voiceModeSettingsPath:
        _sendJson(response, settingsStatus == 200 ? settingsBody : {'code': 'settings_managed'}, status: settingsStatus);
      case voiceModeModelsStatusPath:
        _sendJson(response, modelsBody);
      case voiceModeConfigPath:
        _sendJson(response, configBody);
      case voiceModeTogglePath:
        _sendJson(response, actionStatus == 200 ? {'active': toggleActive} : {'code': 'voice_disabled'}, status: actionStatus);
      default:
        _sendJson(response, actionStatus == 200 ? actionBody : {'code': 'internal'}, status: actionStatus);
    }
  }

  Future<void> _serveStream(HttpRequest request) async {
    streamOpens++;
    final response = request.response;
    if (streamStatus != 200) {
      _sendJson(response, {'code': 'too_many_streams'}, status: streamStatus);
      return;
    }
    response.statusCode = 200;
    response.headers.set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    // Without this the whole body is buffered until the response closes, and a
    // live stream never closes: the client would wait for a first frame that
    // never leaves the Host.
    response.bufferOutput = false;
    final open = Completer<void>();
    _streamDone = open;
    _streamClosed = false;
    _push = (event, data) {
      if (_streamClosed) return;
      response.add(utf8.encode('event: $event\ndata: ${jsonEncode(data)}\n\n'));
    };
    // The stream stays open until the test tears the Host down: a live channel
    // has no natural end, and closing it here would strand every later frame.
    await open.future;
    _streamClosed = true;
    _push = null;
    await response.close();
  }

  void _sendJson(HttpResponse response, Object? value, {int status = 200}) {
    response.statusCode = status;
    response.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    response.add(utf8.encode(jsonEncode(value)));
    unawaited(response.close());
  }
}

/// `{managedBy, value}` as `GET /voice-mode/settings` shapes it.
Map<String, Object?> _settingsView({
  String managedBy = 'plugin',
  double rate = 1.1,
  String mode = 'toggle',
  String readAloud = 'voice',
  bool showCaptions = true,
  bool showStatusBar = true,
}) => {
  'managedBy': managedBy,
  'value': {
    'ttsEngine': 'edge',
    'voice': 'zh-CN-XiaoxiaoNeural',
    'rate': rate,
    'silenceMs': 1500,
    'idleTimeoutMinutes': 5,
    'mode': mode,
    'readAloud': readAloud,
    'showCaptions': showCaptions,
    'showStatusBar': showStatusBar,
    'bargeInMode': 'detect',
    'shortcut': 'Ctrl+Shift+V',
  },
};

/// The bundles the profile offers, without asking the Host.
class _Bundles extends InstalledPluginsController {
  _Bundles(this.bundles);

  final List<PluginBundle> bundles;

  @override
  Future<List<PluginBundle>?> build() async => bundles;

  @override
  Future<void> refresh() async {}
}

/// A real `HttpClient`: the flutter test binding replaces the default one with
/// a stub that answers 400 to everything, which would hide every route.
class _RealHttp extends HttpOverrides {}

/// Runs [body] with real sockets and a Host on loopback.
Future<void> _onHost(Future<void> Function(_VoiceHost host) body) => HttpOverrides.runWithHttpOverrides(() async {
  final host = await _VoiceHost.start();
  try {
    await body(host);
  } finally {
    await host.close();
  }
}, _RealHttp());

/// The host the app believes in, mutable so a test can do what the host
/// switcher does: point the connection at another `HttpServer` and let every
/// controller that watches it rebuild. A fixed `overrideWithValue` cannot show
/// this, and the whole point of the generation guard is what happens next.
class _ActiveHost extends Notifier<AsyncValue<HostConnection?>> {
  _ActiveHost(this._initial);

  final _VoiceHost? _initial;

  @override
  AsyncValue<HostConnection?> build() => _connection(_initial);

  void use(_VoiceHost? host) => state = _connection(host);
}

AsyncValue<HostConnection?> _connection(_VoiceHost? host) => AsyncData<HostConnection?>(
  host == null ? null : HostConnection(client: DshClient(DshConnection(host.baseUri)), isLocal: true),
);

final _activeHostProvider = NotifierProvider<_ActiveHost, AsyncValue<HostConnection?>>(() => _ActiveHost(null));

ProviderContainer _container({_VoiceHost? host, List<PluginBundle> bundles = const []}) {
  final container = ProviderContainer(
    overrides: [
      // Counted twice on purpose: the switch case re-points this provider, and
      // the controller has to follow it without keeping the old host's numbers.
      activeConnectionProvider.overrideWith((ref) => ref.watch(_activeHostProvider)),
      _activeHostProvider.overrideWith(() => _ActiveHost(host)),
      installedPluginsProvider.overrideWith(() => _Bundles(bundles)),
    ],
  );
  // The controller is auto-dispose: the page watches it for as long as it is
  // open, so the test holds the same subscription.
  container.listen(voiceModeProvider, (_, _) {});
  addTearDown(container.dispose);
  return container;
}

/// Waits for [done], which a socket round trip settles off the test's clock.
Future<void> pumpUntil(
  bool Function() done, {
  String what = 'condition',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('load', () {
    test('reads the settings, the models and the switches at once', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => container.read(voiceModeProvider).settings != null, what: 'the settings');

      final state = container.read(voiceModeProvider);
      expect(state.serving, isTrue);
      expect(state.degraded, isFalse);
      expect(state.owner, VoiceSettingsOwner.plugin);
      expect(state.canEditSettings, isTrue);
      expect(state.settings!.voice, 'zh-CN-XiaoxiaoNeural');
      expect(state.settings!.rate, 1.1);
      // A field the model does not name is still reachable through `raw`.
      expect(state.settings!.raw['shortcut'], 'Ctrl+Shift+V');
      expect(state.models!.ready, isTrue);
      expect(state.models!.engine, 'edge');
      // The switches come from `/config` on the first read, before any frame.
      expect(state.display.readAloud, VoiceReadAloud.voice);
      expect(state.display.showCaptions, isTrue);
      expect(host.hitsOn(voiceModeSettingsPath).single.method, 'GET');
    }));

    test('a host without the plugin is not serving', () => _onHost((host) async {
      host.settingsStatus = 404;
      final container = _container(host: host);
      await pumpUntil(() => !container.read(voiceModeProvider).serving, what: 'the 404');
      expect(container.read(voiceModeProvider).settings, isNull);
    }));

    test('no connection serves nothing', () async {
      final container = _container();
      await pumpUntil(() => !container.read(voiceModeProvider).serving, what: 'the empty state');
      expect(container.read(voiceModeProvider).listening, isFalse);
    });
  });

  group('live', () {
    test('applies the opening frames and the turn state', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');

      host.push('mode', {'active': 'session-a', 'ownerTabId': 'tab-1'});
      host.push('focus', {'sessionId': 'session-a', 'tabId': 'tab-1'});
      host.push('display', {'readAloud': 'always', 'showCaptions': false, 'showStatusBar': true});
      host.push('turn', {'sessionId': 'session-a', 'state': 'speaking', 'turn': 3});
      await pumpUntil(() => container.read(voiceModeProvider).turnOf('session-a') == VoiceTurnState.speaking, what: 'the turn');

      final state = container.read(voiceModeProvider);
      expect(state.mode.active, 'session-a');
      expect(state.listening, isTrue);
      expect(state.focus.sessionId, 'session-a');
      expect(state.display.readAloud, VoiceReadAloud.always);
      expect(state.display.showCaptions, isFalse);

      // The turn going idle drops it instead of leaving a stale "speaking".
      host.push('turn', {'sessionId': 'session-a', 'state': 'idle'});
      await pumpUntil(() => container.read(voiceModeProvider).turnOf('session-a') == VoiceTurnState.idle, what: 'the idle');
    }));

    test('a growing skip streak means the engine is struggling', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');

      host.push('tts-skip', {'sessionId': 'session-a', 'text': '第一句', 'streak': 1});
      await pumpUntil(() => container.read(voiceModeProvider).tts != null, what: 'the skip');
      expect(container.read(voiceModeProvider).engineStruggling, isFalse);

      host.push('tts-skip', {'sessionId': 'session-a', 'text': '第二句', 'streak': 3});
      await pumpUntil(() => container.read(voiceModeProvider).engineStruggling, what: 'the streak');
      expect(container.read(voiceModeProvider).tts!.text, '第二句');
    }));

    test('replaced closes the microphone for this tab', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');

      host.push('mode', {'active': 'session-a', 'ownerTabId': 'tab-1'});
      await pumpUntil(() => container.read(voiceModeProvider).listening, what: 'the microphone');

      host.push('replaced', {});
      await pumpUntil(() => !container.read(voiceModeProvider).listening, what: 'the replacement');
    }));

    test('a stream that cannot open degrades and falls back', () => _onHost((host) async {
      host.streamStatus = 429;
      final container = _container(host: host);
      // The degrade and the one-shot load are two independent paths: waiting on
      // the degrade alone leaves the load unsettled under CPU contention, so
      // wait for both rather than asserting on a race.
      await pumpUntil(() {
        final s = container.read(voiceModeProvider);
        return s.degraded && s.settings != null && s.serving;
      }, what: 'the degrade and the settings');

      // The settings still loaded: only the live channel is missing.
      expect(container.read(voiceModeProvider).settings, isNotNull);
      expect(container.read(voiceModeProvider).serving, isTrue);
    }));
  });

  group('microphone', () {
    test('toggle posts the tab and adopts the answer', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');
      host.toggleActive = 'session-a';

      final ok = await container.read(voiceModeProvider.notifier).setListening('session-a', true);

      expect(ok, isTrue);
      final posted = host.hitsOn(voiceModeTogglePath).single;
      expect(posted.body, {'sessionId': 'session-a', 'on': true, 'tabId': host.streamTabId});
      expect(container.read(voiceModeProvider).mode.active, 'session-a');
      expect(container.read(voiceModeProvider).ownedByThisSession, isFalse);
    }));

    test('toggle reports when the host kept another session', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');
      host.toggleActive = 'session-b';

      final ok = await container.read(voiceModeProvider.notifier).setListening('session-a', true);

      expect(ok, isFalse);
      expect(container.read(voiceModeProvider).mode.active, 'session-b');
      expect(container.read(voiceModeProvider).mode.heldByOther('session-a'), isTrue);
    }));

    test('cancel interrupts only when asked', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');

      await container.read(voiceModeProvider.notifier).stop('session-a');
      expect(host.hitsOn(voiceModeCancelPath).single.body, {'sessionId': 'session-a', 'reason': 'interrupt'});

      await container.read(voiceModeProvider.notifier).stop('session-a', interrupt: false);
      expect(host.hitsOn(voiceModeCancelPath).last.body, {'sessionId': 'session-a'});
    }));
  });

  group('focus', () {
    test('syncFocus posts the session and remembers it', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');

      await container.read(voiceModeProvider.notifier).syncFocus('session-a');

      final posted = host.hitsOn(voiceModeFocusPath).single;
      expect(posted.body, {'sessionId': 'session-a', 'tabId': host.streamTabId});
      expect(container.read(voiceModeProvider).focus.sessionId, 'session-a');

      // The same focus again is not a second round trip.
      await container.read(voiceModeProvider.notifier).syncFocus('session-a');
      expect(host.hitsOn(voiceModeFocusPath), hasLength(1));
    }));
  });

  group('display', () {
    test('a switch is mirrored before the write lands', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => container.read(voiceModeProvider).settings != null, what: 'the settings');
      host.settingsBody = _settingsView(showCaptions: false);

      await container.read(voiceModeProvider.notifier).setDisplay(showCaptions: false);

      final posted = host.hitsOn(voiceModeSettingsPath).where((r) => r.method == 'POST').single;
      expect(posted.body, {'showCaptions': false});
      expect(container.read(voiceModeProvider).display.showCaptions, isFalse);
      // Only the flipped switch travels; the other two stay as they were.
      expect(posted.body!.containsKey('showStatusBar'), isFalse);
    }));
  });

  group('settings', () {
    test('a write adopts the host copy', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => container.read(voiceModeProvider).settings != null, what: 'the settings');
      host.settingsBody = _settingsView(rate: 1.4);

      final result = await container.read(voiceModeProvider.notifier).updateSettings({'rate': 1.4});

      expect(result, VoiceSettingsWrite.saved);
      expect(host.hitsOn(voiceModeSettingsPath).last.body, {'rate': 1.4});
      expect(container.read(voiceModeProvider).settings!.rate, 1.4);
    }));

    test('a host that keeps its own settings refuses the write', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => container.read(voiceModeProvider).settings != null, what: 'the settings');
      host.settingsStatus = 409;

      final result = await container.read(voiceModeProvider.notifier).updateSettings({'rate': 1.4});

      expect(result, VoiceSettingsWrite.managedByDsh);
      expect(container.read(voiceModeProvider).owner, VoiceSettingsOwner.dsh);
      expect(container.read(voiceModeProvider).canEditSettings, isFalse);
    }));

    test('a rejected value records what the host said', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => container.read(voiceModeProvider).settings != null, what: 'the settings');
      host.settingsStatus = 400;

      final result = await container.read(voiceModeProvider.notifier).updateSettings({'rate': 9});

      expect(result, VoiceSettingsWrite.rejected);
      expect(container.read(voiceModeProvider).error, isA<VoiceSettingsRejectedException>());
    }));

    test('no host writes nothing', () async {
      final container = _container();
      await pumpUntil(() => !container.read(voiceModeProvider).serving, what: 'the empty state');
      expect(await container.read(voiceModeProvider.notifier).updateSettings({'rate': 1.4}), VoiceSettingsWrite.failed);
    });

    test('setTrigger writes the mode', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => container.read(voiceModeProvider).settings != null, what: 'the settings');

      await container.read(voiceModeProvider.notifier).setTrigger(VoiceModeTrigger.hold);

      expect(host.hitsOn(voiceModeSettingsPath).last.body, {'mode': 'hold'});
    }));

    test('retryModels asks for the model and re-reads the status', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => container.read(voiceModeProvider).models?.ready ?? false, what: 'the models');

      host.modelsBody = const {
        'ready': false,
        'tts': {'ready': true, 'engine': 'edge'},
      };
      await container.read(voiceModeProvider.notifier).retryModels();

      expect(host.hitsOn('$voiceModeBasePath/models/retry').single.body, {'kind': 'asr'});
      expect(host.hitsOn(voiceModeModelsStatusPath), hasLength(2));
      expect(container.read(voiceModeProvider).models!.asrReady, isFalse);
    }));
  });

  group('host switch', () {
    test('a reply of the host being left cannot land on the new one', () async {
      // Two real Hosts: each can hold its own `/settings` read, so the old
      // reply is made to arrive after the switch instead of beside it.
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _VoiceHost.start();
        final hostB = await _VoiceHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });
        hostA.settingsBody = _settingsView(rate: 0.5);
        hostB.settingsBody = _settingsView(rate: 2.0);
        // A answers only when the test lets it, and B answers at once.
        hostA.holdSettings = Completer<void>();

        final container = _container(host: hostA);
        await pumpUntil(() => hostA.settingsHits == 1, what: 'the first read');

        // The host switcher does this: one provider value changes, and the
        // controller rebuilds around the other Host.
        container.read(_activeHostProvider.notifier).use(hostB);
        // The switch is real on the provider the app reads, not just on the
        // test's own notch: this is what a host switcher changes.
        expect(
          container.read(activeConnectionProvider).value!.client.connection.baseUri,
          hostB.baseUri,
        );
        await pumpUntil(() => container.read(voiceModeProvider).settings?.rate == 2.0, what: 'the new host');

        // Now the Host being left answers, late. Its generation is gone, so its
        // numbers must not come back.
        hostA.holdSettings!.complete();
        await pumpUntil(() => hostA.settingsHits == 1, what: 'the held reply');
        // One beat with the socket, so a leaked write would have landed by now.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final state = container.read(voiceModeProvider);
        expect(state.settings?.rate, 2.0);
        expect(state.settings?.rate, isNot(0.5));
      }, _RealHttp());
    });

    test('a model re-read of the host being left cannot overwrite the new one', () async {
      // `_reloadModels` is started by a frame of the host it belongs to and is
      // answered later, so it carries no request ticket of its own. Only the
      // owner check can tell it that the app has moved on.
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _VoiceHost.start();
        final hostB = await _VoiceHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });
        hostA.modelsBody = const {
          'ready': true,
          'tts': {'ready': true, 'engine': 'edge-a'},
        };
        hostB.modelsBody = const {
          'ready': false,
          'tts': {'ready': true, 'engine': 'edge-b'},
        };

        final container = _container(host: hostA);
        await pumpUntil(() => container.read(voiceModeProvider).models?.engine == 'edge-a', what: 'the first read');
        await pumpUntil(() => hostA.streamOpens == 1, what: 'the stream');

        // The frame asks for a fresh model status; the Host sits on it.
        hostA.holdModels = Completer<void>();
        hostA.push('asr-ready', const {'ready': true});
        await pumpUntil(() => hostA.modelsHits == 2, what: 'the re-read');

        container.read(_activeHostProvider.notifier).use(hostB);
        await pumpUntil(() => container.read(voiceModeProvider).models?.engine == 'edge-b', what: 'the new host');

        // The abandoned re-read answers last, with numbers from the old host.
        hostA.holdModels!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(container.read(voiceModeProvider).models!.engine, 'edge-b');
        expect(container.read(voiceModeProvider).models!.asrReady, isFalse);
      }, _RealHttp());
    });

    test('the old host keeps its own stream and the new one gets its own', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _VoiceHost.start();
        final hostB = await _VoiceHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });

        final container = _container(host: hostA);
        await pumpUntil(() => hostA.streamOpens == 1, what: 'the first stream');

        container.read(_activeHostProvider.notifier).use(hostB);
        await pumpUntil(() => hostB.streamOpens == 1, what: 'the second stream');

        // A frame on the abandoned stream is not this app's business any more.
        hostA.push('mode', {'active': 'session-old', 'ownerTabId': 'tab-old'});
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(container.read(voiceModeProvider).mode.active, isNull);

        // The live one still is.
        hostB.push('mode', {'active': 'session-new', 'ownerTabId': 'tab-new'});
        await pumpUntil(() => container.read(voiceModeProvider).mode.active == 'session-new', what: 'the new frame');
      }, _RealHttp());
    });
  });

  group('reconnect', () {
    test('a reconnect arrives under the tab id the host already knows', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the first stream');
      final first = host.streamTabId;

      // The Host drops the connection; the app comes back on its backoff.
      host.dropStream();
      await pumpUntil(() => host.streamOpens == 2, what: 'the second stream');

      expect(host.streamTabIds, hasLength(2));
      expect(
        host.streamTabIds[1],
        first,
        reason: 'a new tab id on reconnect is a new client to the Host, which refuses more than eight tabs',
      );
      // The focus and the microphone name the same tab as the stream.
      container.read(voiceModeProvider.notifier).syncFocus('session-a');
      await pumpUntil(() => host.hitsOn(voiceModeFocusPath).isNotEmpty, what: 'the focus');
      expect(host.hitsOn(voiceModeFocusPath).single.body, {'sessionId': 'session-a', 'tabId': first});
    }));

    test('a host switch introduces itself under a tab id of its own', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _VoiceHost.start();
        final hostB = await _VoiceHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });

        final container = _container(host: hostA);
        await pumpUntil(() => hostA.streamOpens == 1, what: 'the first stream');
        final onA = hostA.streamTabId;

        container.read(_activeHostProvider.notifier).use(hostB);
        await pumpUntil(() => hostB.streamOpens == 1, what: 'the stream on B');

        // Not the id A was told: the new host must not take this app for a
        // reconnect of a tab it never had.
        expect(hostB.streamTabId, isNotNull);
        expect(hostB.streamTabId, isNot(onA));
      }, _RealHttp());
    });
  });

  // A dropped connection takes the Host's focus with it: `dsh-voice-mode`
  // clears `focusedSessionId` and broadcasts `focus{null,null}`, and a page
  // that never says what it is looking at again loses 「每条回复」, turn/step
  // and `/cancel` for that session — silently, with nothing wrong on screen.
  group('focus after a drop', () {
    test('a cleared focus is claimed back on the reconnect', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');

      await container.read(voiceModeProvider.notifier).syncFocus('session-a');
      await pumpUntil(() => host.hitsOn(voiceModeFocusPath).isNotEmpty, what: 'the opening focus');
      final tab = host.streamTabId;
      expect(host.hitsOn(voiceModeFocusPath).single.body, {'sessionId': 'session-a', 'tabId': tab});

      // The socket dies (a network change, a locked screen); the Host drops the
      // focus it held for the tab that is gone.
      host.dropStream();
      await pumpUntil(() => host.streamOpens == 2, what: 'the reconnect');
      host.push('focus', {'sessionId': null, 'tabId': null});

      await pumpUntil(
        () => host.hitsOn(voiceModeFocusPath).length == 2,
        what: 'the focus to be claimed back without the page being touched',
      );
      expect(host.hitsOn(voiceModeFocusPath).last.body, {'sessionId': 'session-a', 'tabId': tab});
      // The write-back of that re-report is a second round trip; wait for it
      // rather than reading the state the frame left behind.
      await pumpUntil(
        () => container.read(voiceModeProvider).focus.sessionId == 'session-a',
        what: 'the reclaimed focus in the state',
      );
      expect(container.read(voiceModeProvider).focus.tabId, tab);
    }));

    test('a page that was left does not come back to life', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');

      await container.read(voiceModeProvider.notifier).syncFocus('session-a');
      // The user leaves: the app says so, and that is now the intent.
      await container.read(voiceModeProvider.notifier).syncFocus(null);
      await pumpUntil(() => host.hitsOn(voiceModeFocusPath).length == 2, what: 'the cleared focus');
      expect(host.hitsOn(voiceModeFocusPath).last.body?['sessionId'], isNull);

      host.dropStream();
      await pumpUntil(() => host.streamOpens == 2, what: 'the reconnect');
      host.push('focus', {'sessionId': null, 'tabId': null});

      // Give a wrong re-report the same time a right one needs.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        host.hitsOn(voiceModeFocusPath),
        hasLength(2),
        reason: 'the intent is null: re-posting session-a would read for a conversation nobody is looking at',
      );
      expect(container.read(voiceModeProvider).focus.sessionId, isNull);
    }));

    test('another page takes the focus on purpose and keeps it', () => _onHost((host) async {
      final container = _container(host: host);
      await pumpUntil(() => host.streamOpens == 1, what: 'the stream');

      await container.read(voiceModeProvider.notifier).syncFocus('session-a');
      await pumpUntil(() => host.hitsOn(voiceModeFocusPath).isNotEmpty, what: 'the opening focus');

      // A second tab opened on another conversation: last writer wins, and
      // claiming it back would leave the two pages taking turns.
      host.push('focus', {'sessionId': 'session-b', 'tabId': 'other-tab'});
      await pumpUntil(
        () => container.read(voiceModeProvider).focus.sessionId == 'session-b',
        what: 'the frame of the other tab',
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(host.hitsOn(voiceModeFocusPath), hasLength(1));
      expect(container.read(voiceModeProvider).focus.sessionId, 'session-b');
    }));

    test('the intent does not follow the app to its new host', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _VoiceHost.start();
        final hostB = await _VoiceHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });

        final container = _container(host: hostA);
        await pumpUntil(() => hostA.streamOpens == 1, what: 'the stream on A');
        await container.read(voiceModeProvider.notifier).syncFocus('session-a');
        await pumpUntil(() => hostA.hitsOn(voiceModeFocusPath).isNotEmpty, what: 'the focus on A');

        container.read(_activeHostProvider.notifier).use(hostB);
        await pumpUntil(() => hostB.streamOpens == 1, what: 'the stream on B');
        // A cleared focus is what a fresh connection sees before the page has
        // said anything. The id it would answer with belongs to the host being
        // left: posting it here names a conversation B need not have, and the
        // Host would then read, record turns for and cancel a session that does
        // not exist. The page re-states its own focus through `syncFocus`.
        hostB.push('focus', {'sessionId': null, 'tabId': null});

        // Give a wrong re-report the same time a right one needs.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(
          hostB.hitsOn(voiceModeFocusPath),
          isEmpty,
          reason: 'a session id of the host being left must not be posted to the new one',
        );
        expect(container.read(voiceModeProvider).focus.sessionId, isNull);
      }, _RealHttp());
    });
  });
}

/// The posted body, when there is one.
Map<String, Object?>? _decode(String raw) {
  final value = jsonDecode(raw);
  return value is Map<String, Object?> ? value : null;
}
