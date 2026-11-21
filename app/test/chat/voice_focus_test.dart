import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/voice_mode_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// The chat page has to tell the Host which conversation it is showing:
/// `dsh-voice-mode` reads 「每条回复」 for the session it calls focused, records
/// turn/step only for it, and honours `/cancel` only for it.
///
/// What is checked here is the wiring — that opening, switching, leaving and
/// coming back each hand the right session (or none) to the controller. The
/// controller's own behaviour against a live Host is in
/// `test/voice/voice_mode_state_test.dart`; this file overrides the controller
/// so the call is recorded instead of dialled.
void main() {
  group('voice focus', () {
    testWidgets('opening a conversation introduces it to the Host', (tester) async {
      final recorder = _FocusRecorder();
      await _pump(tester, session: 's1', recorder: recorder);

      await _frames(tester);
      expect(recorder.calls, isNotEmpty);
      expect(recorder.calls.last, 's1');
    });

    testWidgets('switching conversation moves the focus with it', (tester) async {
      final recorder = _FocusRecorder();
      await _pump(tester, session: 's1', recorder: recorder);
      await _frames(tester);
      expect(recorder.calls.last, 's1');

      containerOf(tester).read(currentSessionProvider.notifier).select('s2');
      await _frames(tester);
      expect(recorder.calls.last, 's2');
    });

    testWidgets('leaving the app clears the focus and coming back restores it', (tester) async {
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      final recorder = _FocusRecorder();
      await _pump(tester, session: 's1', recorder: recorder);
      await _frames(tester);
      expect(recorder.calls.last, 's1');

      // The app goes to the background: the conversation is no longer on
      // screen, so 「每条回复」 must stop reading for it.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _frames(tester);
      expect(recorder.calls.last, isNull);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _frames(tester);
      expect(recorder.calls.last, 's1');
    });

    testWidgets('a new Host is introduced to again under its own connection', (tester) async {
      final recorder = _FocusRecorder();
      final active = _ActiveHost(1);
      await _pump(
        tester,
        session: 's1',
        recorder: recorder,
        extra: [_activeHostProvider.overrideWith(() => active)],
        host: activeConnectionProvider.overrideWith((ref) => ref.watch(_activeHostProvider)),
      );
      await _frames(tester);
      expect(recorder.calls.last, 's1');
      final before = recorder.calls.length;

      // Another machine: every controller that watches the connection rebuilds,
      // and the page has to state its conversation all over again — the new
      // Host has never been told which one is on screen.
      active.use(2);
      await _frames(tester);
      expect(recorder.calls.length, greaterThan(before));
      expect(recorder.calls.last, 's1');
    });
  });
}

/// Stands in for the controller so the page's call is what is asserted, and no
/// socket is opened: what the controller does with the call is another file's
/// subject.
class _FocusRecorder extends VoiceModeController {
  final calls = <String?>[];

  @override
  VoiceModeSnapshot build() => const VoiceModeSnapshot(serving: false);

  @override
  Future<void> syncFocus(String? sessionId) async {
    calls.add(sessionId);
  }
}

/// The host the app believes in, mutable so a test can do what the host
/// switcher does: point the connection somewhere else and let every controller
/// that watches it rebuild. The number stands in for a machine; nothing here
/// is dialled, so it only has to be distinct.
class _ActiveHost extends Notifier<AsyncValue<HostConnection?>> {
  _ActiveHost(this._initial);

  final int _initial;

  @override
  AsyncValue<HostConnection?> build() => _connection(_initial);

  void use(int host) => state = _connection(host);
}

final _activeHostProvider = NotifierProvider<_ActiveHost, AsyncValue<HostConnection?>>(() => throw UnimplementedError());

AsyncValue<HostConnection?> _connection(int host) => AsyncData<HostConnection?>(
  HostConnection(client: DshClient(DshConnection(Uri.parse('http://127.0.0.1:$host'))), isLocal: true),
);

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));

Future<void> _pump(
  WidgetTester tester, {
  required String session,
  required _FocusRecorder recorder,
  Override? host,
  List<Override> extra = const [],
}) async {
  final harness = ChatHarness(
    session: session,
    host: host,
    extra: [voiceModeProvider.overrideWith(() => recorder), ...extra],
  );
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, 6);
}

/// A few frames of the test's own clock, so the post-frame call and any
/// listener the last action fired both reach the recorder.
Future<void> _frames(WidgetTester tester) => pumpFrames(tester, 3);
