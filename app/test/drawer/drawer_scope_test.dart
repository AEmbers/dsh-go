// The wide sidebar's 进行中 / 历史 pile, and how the status capsules
// apply inside it.
//
//   flutter test test/drawer/drawer_scope_test.dart

import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 24, 15);

SessionSummary _s(String id, {bool running = false}) => SessionSummary(
  sessionId: id,
  updatedAt: _now,
  running: running,
  blank: false,
  agentAvailable: running,
  projections: SessionProjections(1, {'title': id}),
);

List<String> _ids(List<DrawerBlock> blocks) => [
  for (final block in blocks)
    for (final item in block.items) item.sessionId,
];

List<DrawerBlock> _blocks({
  DrawerListScope? listScope,
  DrawerFilter filter = DrawerFilter.all,
  Map<String, PendingKind> pending = const {},
  Set<String> unread = const {},
}) => drawerBlocks(
  sessions: [_s('run', running: true), _s('old'), _s('also', running: true)],
  pinnedIds: const [],
  view: const DrawerView(loaded: true),
  filter: filter,
  pending: pending,
  unread: unread,
  createdAt: const {},
  now: _now,
  listScope: listScope,
);

void main() {
  test('running keeps host-running conversations and history keeps the rest', () {
    expect(_ids(_blocks(listScope: DrawerListScope.running)), ['also', 'run']);
    expect(_ids(_blocks(listScope: DrawerListScope.history)), ['old']);
    expect(sessionsInListScope([_s('run', running: true), _s('old')], null).map((s) => s.sessionId), ['run', 'old']);
  });

  test('status capsules apply inside the selected pile', () {
    expect(_ids(_blocks(listScope: DrawerListScope.running, filter: DrawerFilter.unread, unread: {'run', 'old'})), [
      'run',
    ]);
    expect(
      _ids(
        _blocks(
          listScope: DrawerListScope.history,
          filter: DrawerFilter.pending,
          pending: {'old': PendingKind.approval, 'run': PendingKind.question},
        ),
      ),
      ['old'],
    );
    expect(_ids(_blocks(listScope: DrawerListScope.history, filter: DrawerFilter.running)), isEmpty);
  });
}
