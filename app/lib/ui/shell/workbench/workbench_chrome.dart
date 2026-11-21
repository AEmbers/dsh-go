// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
//
// The wide window's conversation column: open tabs, the live connection and
// workspace, then 对话 / 命令行. Phone layout does not build this.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/connection_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workbench_state.dart';
import '../../../state/workspace_state.dart';
import '../../../state/workspaces_state.dart';
import '../../chat/model_sheet.dart';
import '../../common/empty_view.dart';
import '../../common/segmented_pill.dart';
import '../../theme/app_icons.dart';
import '../sessions_drawer.dart' show sessionTitle;

/// Fixed height of [WorkbenchChrome], not counting the status bar above it.
/// The chat list's top inset adds this to the header so messages start
/// under the bar.
class WorkbenchChrome extends ConsumerWidget {
  const WorkbenchChrome({super.key, required this.modelSelection, required this.onModelSelected});

  static const tabRow = 44.0;
  static const metaRow = 44.0;
  static const modeRow = 40.0;
  static const gap = 6.0;
  static const extent = tabRow + gap + metaRow + gap + modeRow + gap;

  final ModelSelection? modelSelection;
  final ValueChanged<ModelSelection> onModelSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final tabs = ref.watch(openSessionTabsProvider);
    final current = ref.watch(currentSessionProvider);
    final sessions = ref.watch(sessionsProvider).asData?.value ?? const <SessionSummary>[];
    final titles = {for (final session in sessions) session.sessionId: sessionTitle(session)};
    final surface = ref.watch(workbenchSurfaceProvider);
    final connection = ref.watch(activeConnectionProvider).asData?.value;
    final workspace = _workspace(ref, current);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('workbench-tabs'),
            height: tabRow,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      if (current == null)
                        _TabChip(
                          key: const ValueKey('workbench-tab-new'),
                          label: l10n.commonNewChat,
                          selected: true,
                          onTap: () {},
                        ),
                      for (final id in tabs)
                        _TabChip(
                          key: ValueKey('workbench-tab-$id'),
                          closeKey: ValueKey('workbench-tab-close-$id'),
                          label: titles[id] ?? l10n.commonUntitledChat,
                          selected: id == current,
                          onTap: () => ref.read(openSessionTabsProvider.notifier).show(id),
                          onClose: () => ref.read(openSessionTabsProvider.notifier).close(id),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                _IconKey(
                  key: const ValueKey('workbench-new-chat'),
                  icon: AppIcons.add,
                  tooltip: l10n.commonNewChat,
                  onPressed: () => ref.read(openSessionTabsProvider.notifier).newChat(),
                ),
              ],
            ),
          ),
          const SizedBox(height: gap),
          SizedBox(
            key: const ValueKey('workbench-meta'),
            height: metaRow,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    [connection?.label ?? l10n.commonNotConnected, ?workspace].join(l10n.viewListSeparator),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 8),
                ModelChip(selection: modelSelection, onSelected: onModelSelected, grouped: true),
                _IconKey(
                  key: const ValueKey('workbench-refresh'),
                  icon: AppIcons.refresh,
                  tooltip: l10n.shellWorkbenchRefresh,
                  onPressed: () => _refresh(ref),
                ),
              ],
            ),
          ),
          const SizedBox(height: gap),
          SizedBox(
            height: modeRow,
            child: SegmentedPill<WorkbenchSurface>(
              key: const ValueKey('workbench-mode'),
              height: 36,
              segments: [
                PillSegment(WorkbenchSurface.chat, l10n.shellWorkbenchChat),
                PillSegment(WorkbenchSurface.cli, l10n.shellWorkbenchCli),
              ],
              selected: surface,
              onChanged: (next) => ref.read(workbenchSurfaceProvider.notifier).show(next),
            ),
          ),
          const SizedBox(height: gap),
        ],
      ),
    );
  }

  String? _workspace(WidgetRef ref, String? sessionId) {
    if (sessionId != null) {
      final cwd = ref.watch(workspaceRootProvider(sessionId));
      if (cwd != null && cwd.isNotEmpty) return cwd;
    }
    final selected = ref.watch(selectedWorkspaceProvider);
    if (selected == null) return null;
    final title = workspaceTitle(selected);
    return title.isEmpty ? null : title;
  }

  Future<void> _refresh(WidgetRef ref) async {
    await ref.read(sessionsProvider.notifier).refresh();
    final id = ref.read(currentSessionProvider);
    if (id == null) return;
    await ref.read(chatProvider(id).notifier).resync();
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onClose,
    this.closeKey,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClose;
  final Key? closeKey;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final background = selected ? scheme.primaryContainer : scheme.surface.withValues(alpha: 0.72);
    final foreground = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
      child: Material(
        color: background,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Padding(
              padding: EdgeInsets.only(left: 12, right: onClose == null ? 12 : 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: foreground, fontSize: 13),
                    ),
                  ),
                  if (onClose != null)
                    IconButton(
                      key: closeKey,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                      tooltip: l10n.shellWorkbenchCloseTab,
                      onPressed: onClose,
                      icon: Icon(AppIcons.close, size: 14, color: foreground),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconKey extends StatelessWidget {
  const _IconKey({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
    );
  }
}

/// Shown instead of a terminal when no conversation is open.
class WorkbenchCliGate extends StatelessWidget {
  const WorkbenchCliGate({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      key: const ValueKey('workbench-cli-gate'),
      child: EmptyView(
        icon: AppIcons.terminal,
        title: l10n.shellWorkbenchCli,
        message: l10n.shellWorkbenchCliNeedsSession,
      ),
    );
  }
}
