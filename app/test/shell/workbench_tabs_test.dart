// Closing a wide-window tab forgets the tab only. The conversation stays
// on the host list.
//
//   flutter test test/shell/workbench_tabs_test.dart

import 'package:dsh_app/state/sessions_state.dart';
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
}
