import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/voice_model_state.dart';
import 'package:dsh_app/voice/voice_model_assets.dart';
import 'package:dsh_app/voice/voice_model_download.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_model_assets_test.dart' show rc2Lock;

/// Waits for [done], which the controller settles off the test's clock.
Future<void> _until(bool Function() done, {String what = 'condition', Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// The default carrier still uses Dart's real sockets under Flutter's binding.
class _RealHttp extends HttpOverrides {}

class _Local extends LocalConnectionController {
  _Local(this.client);
  final DshClient client;
  @override
  Future<HostConnection?> build() async => HostConnection(client: client, isLocal: true);
}

class _Files implements VoiceModelPlatform {
  _Files(this.root);
  final Directory root;
  final notices = <(String?, int?)>[];
  @override
  Future<VoiceModelFiles?> files() async => VoiceModelFiles(root);
  @override
  Future<int?> freeBytes() async => 1 << 40;
  @override
  Future<bool> metered() async => false;
  @override
  Future<VoiceDownloadRun> download(List<VoiceDownloadJob> jobs) =>
      throw StateError('all model files are already present in this preparation fixture');
  @override
  Future<void> notice(String? text, {int? progress}) async => notices.add((text, progress));
}

// Models the pinned Host contract at the RPC boundary, not a live recognizer:
// cancel joins the old preparation first. Only its already-settled HTTP reply
// is held, while other requests use the carrier's normal concurrent sockets.
class _Host {
  _Host(this.server, this.phase) {
    server.listen((request) {
      final pending = _handle(request);
      requests.add(pending);
      unawaited(
        pending.then<void>(
          (_) {
            requests.remove(pending);
          },
          onError: (Object error) {
            errors.add(error);
            requests.remove(pending);
          },
        ),
      );
    });
  }
  final HttpServer server;
  String phase;
  final cancelSeen = Completer<void>();
  final preparationExit = Completer<void>();
  final preparationSettled = Completer<void>();
  final cancelAck = Completer<void>();
  final requests = <Future<void>>{};
  final errors = <Object>[];
  int prepares = 0;

  static Future<_Host> start({String phase = 'loading'}) async =>
      _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), phase);

  Future<void> _handle(HttpRequest request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
    Object? value;
    switch (request.uri.path) {
      case '/api/pluginManager/listBundles':
        value = [
          {'name': voiceInputBundle, 'official': true, 'optional': true, 'enabled': true},
        ];
      case '/api/speech/catalog':
        value = {
          'providers': [
            {
              'id': voiceModelProviderId,
              'name': 'SenseVoiceSmall (INT8)',
              'location': 'host-local',
              'preparation': {'phase': phase},
            },
          ],
          'selection': {'providerId': voiceModelProviderId, 'language': 'auto'},
          'maxAudioBytes': 4194304,
          'maxDurationSeconds': 120,
        };
      case '/api/speech/cancelPreparation':
        if (!cancelSeen.isCompleted) cancelSeen.complete();
        if (phase != 'ready' && phase != 'standby') {
          phase = 'cancelling';
          await preparationExit.future;
          phase = 'cancelled';
        }
        if (!preparationSettled.isCompleted) preparationSettled.complete();
        await cancelAck.future;
      case '/api/speech/prepare':
        if (!preparationSettled.isCompleted) throw StateError('new preparation before old resources settled');
        prepares++;
        phase = 'loading';
      default:
        throw StateError('unexpected RPC ${request.uri.path}');
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'type': 'server-response',
        'rpcId': body['rpcId'],
        'result': {'ok': true, 'value': ?value},
      }),
    );
    await request.response.close();
  }

  Future<void> close() async {
    if (!preparationExit.isCompleted) preparationExit.complete();
    if (!cancelAck.isCompleted) cancelAck.complete();
    await Future.wait(requests.toList());
    await server.close(force: true);
  }
}

class _Rig {
  _Rig(this.root, this.host) {
    final files = VoiceModelFiles(root);
    files.host(VoiceModelPaths.lock)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        rc2Lock
            .replaceFirst('"bytes": 239233841', '"bytes": 1000')
            .replaceFirst('"bytes": 315894', '"bytes": 40')
            .replaceFirst('"bytes": 1807522', '"bytes": 60'),
      );
    for (final asset in files.assets()!) {
      files.host(asset.guestPath)
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(asset.bytes, 7));
    }
    platform = _Files(root);
    http = _RealHttp().createHttpClient(null);
    client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${host.server.port}'), httpClient: http));
    container = ProviderContainer(
      overrides: [
        localConnectionProvider.overrideWith(() => _Local(client)),
        voiceModelPlatformProvider.overrideWithValue(platform),
      ],
    );
    container.listen(voiceModelProvider, (_, _) {});
    controller = container.read(voiceModelProvider.notifier);
    controller.noticeText = VoiceModelNoticeText(
      downloading: (percent) => 'download $percent',
      preparing: 'preparing',
      ready: 'ready',
      failed: 'failed',
    );
  }
  final Directory root;
  final _Host host;
  late final _Files platform;
  late final HttpClient http;
  late final DshClient client;
  late final ProviderContainer container;
  late final VoiceModelController controller;
  VoiceModelState get state => container.read(voiceModelProvider);

  static Future<_Rig> open({String phase = 'loading'}) async {
    final rig = _Rig(await Directory.systemTemp.createTemp('voice-cancel-owner-'), await _Host.start(phase: phase));
    addTearDown(rig.close);
    await rig.container.read(localConnectionProvider.future);
    await rig.controller.refresh();
    return rig;
  }

  Future<void> foregroundRefreshToAbsent() async {
    final absent = Completer<void>();
    // `fireImmediately` closes the window where a refresh lands before the
    // listener is wired: the observer would otherwise wait for a transition
    // that has already happened.
    final sub = container.listen(voiceModelProvider, (_, next) {
      if (next.status == VoiceModelStatus.absent && !absent.isCompleted) absent.complete();
    }, fireImmediately: true);
    try {
      // The actual VoiceModelHost.onShow entry. Coming back on screen is an
      // event that fires every time, so knock once and then let the owner of
      // the state drive it: while a preparation poll is armed, `refresh()`
      // returns early (`voice_model_state.dart:390`) and awaits nothing, so
      // looping on it here would only spin without ever advancing the state.
      // The caller sets `pollEvery` low enough for that poll to converge.
      controller.setForeground(true);
      await controller.refresh();
      await absent.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'the foreground refresh never published an absent state '
          '(status: ${state.status})',
        ),
      );
    } finally {
      sub.close();
    }
  }

  Future<void> close() async {
    container.dispose();
    await host.close();
    await client.close();
    http.close(force: true);
    await root.delete(recursive: true);
    expect(host.errors, isEmpty);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // These cases explicitly refresh through real HTTP, not a polling clock.
    VoiceModelController.pollEvery = const Duration(hours: 1);
    VoiceModelController.noticeEvery = Duration.zero;
  });
  tearDown(() {
    VoiceModelController.pollEvery = const Duration(milliseconds: 700);
    VoiceModelController.noticeEvery = const Duration(milliseconds: 500);
  });

  test('a settled cancel ACK arriving after foreground refresh and retry cannot clear the new preparation', () async {
    // A preparation poll that is already armed owns the state: `refresh()`
    // returns early while it lives, so the clock has to tick for the poll
    // itself to read the Host's settled phase.
    VoiceModelController.pollEvery = const Duration(milliseconds: 20);
    final rig = await _Rig.open();
    expect(rig.state.status, VoiceModelStatus.preparing);
    rig.controller.setForeground(false);
    var cancelDone = false;
    final cancelling = rig.controller.cancel().then((_) => cancelDone = true);
    await rig.host.cancelSeen.future;
    expect(cancelDone, isFalse);
    expect(rig.host.preparationSettled.isCompleted, isFalse);

    rig.host.preparationExit.complete();
    await rig.host.preparationSettled.future;
    expect(rig.host.phase, 'cancelled');
    expect(cancelDone, isFalse, reason: 'only the ACK, not the old preparation, is still held');
    await rig.foregroundRefreshToAbsent();
    await rig.controller.download();
    expect(rig.host.prepares, 1);
    expect(rig.state.status, VoiceModelStatus.preparing);
    expect(rig.platform.notices.last.$1, 'preparing');

    rig.host.cancelAck.complete();
    await cancelling;
    expect(rig.host.phase, 'loading', reason: 'the Host is now preparing the retry');
    expect(rig.state.status, VoiceModelStatus.preparing, reason: 'the retired cancel cannot own the retry display');
    expect(rig.state.wanted, isTrue);
    expect(rig.platform.notices.last.$1, 'preparing');
  });

  test('a current cancel waits for preparation settlement and keeps normal retry working', () async {
    // A preparation poll that is already armed owns the state: `refresh()`
    // returns early while it lives, so the clock has to tick for the poll
    // itself to read the Host's settled phase.
    VoiceModelController.pollEvery = const Duration(milliseconds: 20);
    final rig = await _Rig.open();
    var cancelDone = false;
    final cancelling = rig.controller.cancel().then((_) => cancelDone = true);
    await rig.host.cancelSeen.future;
    expect(cancelDone, isFalse);
    expect(rig.state.status, VoiceModelStatus.preparing);
    rig.host.cancelAck.complete();
    expect(rig.host.preparationSettled.isCompleted, isFalse);
    rig.host.preparationExit.complete();
    await cancelling;
    expect(rig.host.preparationSettled.isCompleted, isTrue);
    // `cancel()` resolves when the Host answers; the controller publishes the
    // settled snapshot on a later microtask, so read the state after it lands
    // rather than on the instant the future completes. The platform notice is
    // a second, independently paced channel (`cancel()` clears it, then the
    // `unawaited(refresh())` it schedules can republish a line for the phase
    // the Host still reports), so wait for each to settle on its own instead
    // of requiring both to be true at one sampled instant.
    await _until(() => rig.state.status == VoiceModelStatus.absent, what: 'the settled cancel');
    expect(rig.state.status, VoiceModelStatus.absent);
    expect(rig.state.wanted, isFalse);
    await _until(() => rig.platform.notices.last.$1 == null, what: 'the cleared notice (${rig.platform.notices})');
    await rig.controller.download();
    expect(rig.host.prepares, 1);
    expect(rig.state.status, VoiceModelStatus.preparing);
  });

  test('cancel retains a Host preparation that was already ready', () async {
    final rig = await _Rig.open(phase: 'ready');
    expect(rig.state.status, VoiceModelStatus.ready);
    final cancelling = rig.controller.cancel();
    await rig.host.preparationSettled.future;
    expect(rig.host.phase, 'ready');
    rig.host.cancelAck.complete();
    await cancelling;
    await rig.controller.refresh();
    expect(rig.state.status, VoiceModelStatus.ready);
    expect(rig.host.prepares, 0);
  });
}
