// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
//
// Top-level workbench agent switcher and chat / terminal surface on a wide window.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';
import 'models_state.dart';
import 'sessions_state.dart';
import 'workbench_bridge_state.dart';
import 'workspaces_state.dart';

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

/// 顶层工作台标签栏展示的可用智能体列表（始终包含 DSH，并按安装状态/现有会话追加外部 CLI 智能体）。
final workbenchAvailableEnginesProvider = Provider<List<CliEngine>>((ref) {
  final health = ref.watch(workbenchBridgeHealthProvider).value;
  final bridgeSessions = ref.watch(workbenchBridgeSessionsProvider);
  final active = ref.watch(activeWorkbenchEngineProvider);
  final sessionEngines = <CliEngine>{for (final s in bridgeSessions) s.cliEngine};

  final result = <CliEngine>[CliEngine.dsh];
  for (final engine in [CliEngine.antigravity, CliEngine.codex, CliEngine.claude]) {
    final installed = health?.engines[engine]?.installed ?? false;
    if (installed || sessionEngines.contains(engine) || active == engine) {
      result.add(engine);
    }
  }
  return List.unmodifiable(result);
});

/// 当前在宽屏顶层标签栏激活的智能体（DSH / Antigravity / Codex / Claude）。
class ActiveWorkbenchEngineController extends Notifier<CliEngine> {
  final Map<CliEngine, String?> _lastSessionByEngine = {};

  @override
  CliEngine build() {
    ref.watch(activeHostProvider);
    _lastSessionByEngine.clear();
    ref.listen(currentSessionProvider, (previous, next) {
      if (next != null) {
        final engine = CliSessionRef.parse(next)?.engine ?? CliEngine.dsh;
        _lastSessionByEngine[engine] = next;
        if (state != engine) state = engine;
      }
    });
    final current = ref.read(currentSessionProvider);
    if (current != null) {
      final engine = CliSessionRef.parse(current)?.engine ?? CliEngine.dsh;
      _lastSessionByEngine[engine] = current;
      return engine;
    }
    return CliEngine.dsh;
  }

  /// 切换顶层激活的智能体标签，并恢复该智能体上次打开的会话（或进入该智能体的新对话页）。
  void selectEngine(CliEngine target) {
    final currentId = ref.read(currentSessionProvider);
    if (currentId != null) {
      final currentEngine = CliSessionRef.parse(currentId)?.engine ?? CliEngine.dsh;
      _lastSessionByEngine[currentEngine] = currentId;
    }
    if (state == target) return;
    state = target;
    ref.read(pendingModelProvider.notifier).select(null);
    ref.read(workbenchSurfaceProvider.notifier).show(WorkbenchSurface.chat);

    final currentMatches =
        currentId != null && (CliSessionRef.parse(currentId)?.engine ?? CliEngine.dsh) == target;
    if (currentMatches) return;

    final ws = ref.read(selectedWorkspaceProvider);
    final allRows = ref.read(mergedSessionsProvider).asData?.value ?? const <SessionSummary>[];
    final rows = ws == null
        ? allRows
        : [
            for (final s in allRows)
              if (s.cliEngine == CliEngine.dsh
                  ? ws.sessionIds.contains(s.sessionId)
                  : (ws.sessionIds.contains(s.sessionId) || sessionMatchesWorkspacePath(s.cwd, ws.path)))
                s,
          ];
    final byId = {for (final row in rows) row.sessionId: row};
    final remembered = _lastSessionByEngine[target];
    if (remembered != null && byId.containsKey(remembered)) {
      ref.read(currentSessionProvider.notifier).select(remembered);
      return;
    }
    final latest = rows.where((s) => s.cliEngine == target).firstOrNull;
    if (latest != null) {
      _lastSessionByEngine[target] = latest.sessionId;
      ref.read(currentSessionProvider.notifier).select(latest.sessionId);
      return;
    }
    ref.read(currentSessionProvider.notifier).select(null);
  }

  /// 在指定（或当前激活）智能体下新开空白对话。
  void newChat([CliEngine? engine]) {
    final target = engine ?? state;
    state = target;
    _lastSessionByEngine[target] = null;
    ref.read(pendingModelProvider.notifier).select(null);
    ref.read(workbenchSurfaceProvider.notifier).show(WorkbenchSurface.chat);
    ref.read(currentSessionProvider.notifier).select(null);
  }
}

final activeWorkbenchEngineProvider = NotifierProvider<ActiveWorkbenchEngineController, CliEngine>(
  ActiveWorkbenchEngineController.new,
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
    ref.listen(mergedSessionsProvider, (previous, next) {
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
    ref.read(activeWorkbenchEngineProvider.notifier).newChat();
  }
}

final openSessionTabsProvider = NotifierProvider<OpenSessionTabsController, List<String>>(
  OpenSessionTabsController.new,
);
