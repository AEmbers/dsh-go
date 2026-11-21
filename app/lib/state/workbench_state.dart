// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
//
// Open conversation tabs and the chat / terminal surface on a wide window.
// Closing a tab only forgets it here. The conversation stays on the host.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';
import 'sessions_state.dart';

/// What the wide conversation column is showing.
enum WorkbenchSurface { chat, cli }

class WorkbenchSurfaceController extends Notifier<WorkbenchSurface> {
  @override
  WorkbenchSurface build() {
    ref.watch(activeHostProvider);
    return WorkbenchSurface.chat;
  }

  void show(WorkbenchSurface surface) => state = surface;
}

final workbenchSurfaceProvider = NotifierProvider<WorkbenchSurfaceController, WorkbenchSurface>(
  WorkbenchSurfaceController.new,
);

/// Conversation ids open as tabs, oldest first. Not a copy of the host list:
/// a tab appears when the conversation is shown, and leaves when its tab is
/// closed or the host no longer has it.
class OpenSessionTabsController extends Notifier<List<String>> {
  @override
  List<String> build() {
    ref.watch(activeHostProvider);
    ref.listen(currentSessionProvider, (previous, next) {
      if (next != null) remember(next);
    });
    ref.listen(sessionsProvider, (previous, next) {
      final rows = next.asData?.value;
      if (rows == null) return;
      final known = {for (final row in rows) row.sessionId};
      final kept = [
        for (final id in state)
          if (known.contains(id)) id,
      ];
      if (kept.length != state.length) state = kept;
    });
    final current = ref.read(currentSessionProvider);
    return current == null ? const [] : [current];
  }

  void remember(String id) {
    if (id.isEmpty || state.contains(id)) return;
    state = [...state, id];
  }

  void show(String id) {
    remember(id);
    ref.read(currentSessionProvider.notifier).select(id);
  }

  /// Drops the tab. Does not archive or delete the conversation.
  void close(String id) {
    final kept = [
      for (final existing in state)
        if (existing != id) existing,
    ];
    if (kept.length == state.length) return;
    state = kept;
    if (ref.read(currentSessionProvider) != id) return;
    ref.read(currentSessionProvider.notifier).select(kept.isEmpty ? null : kept.last);
  }

  void newChat() {
    ref.read(currentSessionProvider.notifier).select(null);
  }
}

final openSessionTabsProvider = NotifierProvider<OpenSessionTabsController, List<String>>(
  OpenSessionTabsController.new,
);
