// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
//
// The wide window's conversation column: open tabs, then 对话 / CLI.
// The title pill above this bar carries the connection and workspace.
// Phone layout does not build this.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workbench_state.dart';
import '../../common/empty_view.dart';
import '../../common/segmented_pill.dart';
import '../../theme/app_icons.dart';
import '../sessions_drawer.dart' show sessionTitle;

/// Fixed height of [WorkbenchChrome], not counting the status bar above it.
/// The chat list's top inset adds this to the header so messages start
/// under the bar.
class WorkbenchChrome extends ConsumerWidget {
  const WorkbenchChrome({super.key});

  static const tabRow = 40.0;
  static const modeRow = 40.0;
  static const gap = 8.0;
  static const extent = tabRow + gap + modeRow + gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tabs = ref.watch(openSessionTabsProvider);
    final current = ref.watch(currentSessionProvider);
    final sessions = ref.watch(sessionsProvider).asData?.value ?? const <SessionSummary>[];
    final titles = {for (final session in sessions) session.sessionId: sessionTitle(session)};
    final surface = ref.watch(workbenchSurfaceProvider);

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
                  key: const ValueKey('workbench-refresh'),
                  icon: AppIcons.refresh,
                  tooltip: l10n.shellWorkbenchRefresh,
                  onPressed: () => _refresh(ref),
                ),
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
            height: modeRow,
            child: SegmentedPill<WorkbenchSurface>(
              key: const ValueKey('workbench-mode'),
              height: 36,
              segments: [
                PillSegment(WorkbenchSurface.chat, l10n.shellWorkbenchChat, icon: AppIcons.chat),
                PillSegment(WorkbenchSurface.cli, l10n.shellWorkbenchModeCli, icon: AppIcons.terminal),
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
    final background = selected ? scheme.surface : scheme.surface.withValues(alpha: 0.55);
    final foreground = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 2, bottom: 2),
      child: Material(
        color: background,
        elevation: selected ? 0.5 : 0,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Padding(
              padding: EdgeInsets.only(left: 8, right: onClose == null ? 10 : 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.chat, size: 14, color: foreground),
                  const SizedBox(width: 6),
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
