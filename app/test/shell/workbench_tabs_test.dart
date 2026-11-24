// Closing a wide-window tab forgets the tab only. The conversation stays
// on the host list.
//
//   flutter test test/shell/workbench_tabs_test.dart

import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workbench_bridge_state.dart';
import 'package:dsh_app/state/workbench_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

SessionSummary _s(String id) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime(2026, 10, 24),
  running: false,
  blank: false,
  agentAvailable: false,
  projections: SessionProjections(1, {'title': id}),
);

class _Sessions extends SessionsController {
  _Sessions(this.rows);

  List<SessionSummary> rows;

  @override
  Future<List<SessionSummary>> build() async => rows;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('close drops the tab and leaves the conversation', () async {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(() => _Sessions([_s('a'), _s('b')])),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionsProvider.future);

    expect(container.read(openSessionTabsProvider), isEmpty);
    container.read(currentSessionProvider.notifier).select('a');
    expect(container.read(openSessionTabsProvider), ['a']);

    container.read(openSessionTabsProvider.notifier).show('b');
    expect(container.read(openSessionTabsProvider), ['a', 'b']);
    expect(container.read(currentSessionProvider), 'b');

    container.read(openSessionTabsProvider.notifier).close('a');
    expect(container.read(openSessionTabsProvider), ['b']);
    expect(container.read(currentSessionProvider), 'b');

    container.read(openSessionTabsProvider.notifier).close('b');
    expect(container.read(openSessionTabsProvider), isEmpty);
    expect(container.read(currentSessionProvider), isNull);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['a', 'b']);
  });

  test('a conversation the host drops leaves the tab strip', () async {
    final sessions = _Sessions([_s('a'), _s('b')]);
    final container = ProviderContainer(overrides: [sessionsProvider.overrideWith(() => sessions)]);
    addTearDown(container.dispose);
    await container.read(sessionsProvider.future);
    container.read(openSessionTabsProvider.notifier).show('a');
    container.read(openSessionTabsProvider.notifier).show('b');
    sessions.rows = [_s('b')];
    sessions.state = AsyncData(sessions.rows);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(openSessionTabsProvider), ['b']);
  });

  test('activeWorkbenchEngineProvider switches agents, recalls last session, and opens per-agent new chat', () async {
    final sessions = _Sessions([_s('dsh-1')]);
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(() => sessions),
        workbenchBridgeHealthProvider.overrideWith(
          (ref) async => const WorkbenchBridgeHealth(
            ok: true,
            engines: {
              CliEngine.antigravity: CliEngineAvailability(engine: CliEngine.antigravity, installed: true),
              CliEngine.codex: CliEngineAvailability(engine: CliEngine.codex, installed: true),
              CliEngine.claude: CliEngineAvailability(engine: CliEngine.claude, installed: false),
            },
          ),
        ),
        workbenchBridgeSessionsProvider.overrideWith(() => _FakeBridge([
          WorkbenchCliSession(
            engine: CliEngine.antigravity,
            rawId: 'agy-1',
            sessionId: 'cli:antigravity:agy-1',
            title: 'Agy Task',
            updatedAt: DateTime(2026, 11, 24),
            running: false,
          ).toSessionSummary(),
        ])),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sessionsProvider.future);
    await container.read(workbenchBridgeHealthProvider.future);

    expect(container.read(workbenchAvailableEnginesProvider), [
      CliEngine.dsh,
      CliEngine.antigravity,
      CliEngine.codex,
    ]);

    container.read(activeWorkbenchEngineProvider.notifier).selectEngine(CliEngine.antigravity);
    expect(container.read(activeWorkbenchEngineProvider), CliEngine.antigravity);
    expect(container.read(currentSessionProvider), 'cli:antigravity:agy-1');

    // 在 Antigravity 标签下点击新建，保持 Antigravity 激活且清空当前会话
    container.read(activeWorkbenchEngineProvider.notifier).newChat();
    expect(container.read(activeWorkbenchEngineProvider), CliEngine.antigravity);
    expect(container.read(currentSessionProvider), isNull);

    // 切回 DSH，恢复 DSH 会话
    container.read(activeWorkbenchEngineProvider.notifier).selectEngine(CliEngine.dsh);
    expect(container.read(activeWorkbenchEngineProvider), CliEngine.dsh);
    expect(container.read(currentSessionProvider), 'dsh-1');
  });
}

class _FakeBridge extends WorkbenchBridgeSessionsController {
  _FakeBridge(this.rows);
  final List<SessionSummary> rows;
  @override
  List<SessionSummary> build() => rows;
  @override
  Future<void> refresh() async {}
}
