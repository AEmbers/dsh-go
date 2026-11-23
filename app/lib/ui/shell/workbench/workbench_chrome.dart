// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
//
// The wide window's conversation chrome:
// 1) WorkbenchTabBar sits at the top (count badge, open tabs, new-chat +);
// 2) ChatHeader sits underneath it (menu, title pill with icon, model, refresh);
// 3) WorkbenchModeBar sits below the header (对话 / CLI).
// Phone layout does not build these.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workbench_state.dart';
import '../../common/empty_view.dart';
import '../../common/segmented_pill.dart';
import '../../common/status_dot.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../sessions_drawer.dart' show sessionTitle;

/// Refreshes the host conversation list and resyncs the active chat.
Future<void> refreshWorkbench(WidgetRef ref) async {
  await ref.read(sessionsProvider.notifier).refresh();
  final id = ref.read(currentSessionProvider);
  if (id == null) return;
  await ref.read(chatProvider(id).notifier).resync();
}

/// Top strip of the wide workbench: open-tab counter, scrollable session tabs,
/// and the `+` button to start a new chat. Owns the top status-bar inset.
class WorkbenchTabBar extends ConsumerWidget {
  const WorkbenchTabBar({super.key});

  static const topGap = 4.0;
  static const tabRow = 40.0;
  static const bottomGap = 2.0;

  static double heightOf(BuildContext context) => MediaQuery.paddingOf(context).top + topGap + tabRow + bottomGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final topInset = MediaQuery.paddingOf(context).top;
    final tabs = ref.watch(openSessionTabsProvider);
    final current = ref.watch(currentSessionProvider);
    final sessions = ref.watch(sessionsProvider).asData?.value ?? const <SessionSummary>[];
    final byId = {for (final session in sessions) session.sessionId: session};
    final tabCount = tabs.isEmpty && current == null ? 1 : tabs.length + (current == null ? 1 : 0);

    return Padding(
      padding: EdgeInsets.fromLTRB(12, topInset + topGap, 12, bottomGap),
      child: SizedBox(
        key: const ValueKey('workbench-tabs'),
        height: tabRow,
        child: Row(
          children: [
            _TabCountBadge(
              key: const ValueKey('workbench-tab-count'),
              count: tabCount,
              tooltip: l10n.shellChatList,
              tabs: tabs,
              current: current,
              byId: byId,
              untitledLabel: l10n.commonUntitledChat,
              onSelect: (id) => ref.read(openSessionTabsProvider.notifier).show(id),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  if (current == null)
                    _TabChip(
                      key: const ValueKey('workbench-tab-new'),
                      label: l10n.commonNewChat,
                      selected: true,
                      running: false,
                      onTap: () {},
                    ),
                  for (final id in tabs)
                    _TabChip(
                      key: ValueKey('workbench-tab-$id'),
                      closeKey: ValueKey('workbench-tab-close-$id'),
                      runningKey: ValueKey('workbench-tab-running-$id'),
                      label: byId[id] == null ? l10n.commonUntitledChat : sessionTitle(byId[id]!),
                      selected: id == current,
                      running: byId[id]?.running ?? false,
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
    );
  }
}

/// Bottom strip of the wide workbench header: switches between 对话 and CLI.
class WorkbenchModeBar extends ConsumerWidget {
  const WorkbenchModeBar({super.key});

  static const topGap = 4.0;
  static const modeRow = 36.0;
  static const bottomGap = 8.0;
  static const extent = topGap + modeRow + bottomGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final surface = ref.watch(workbenchSurfaceProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, topGap, 12, bottomGap),
      child: SizedBox(
        height: modeRow,
        child: SegmentedPill<WorkbenchSurface>(
          key: const ValueKey('workbench-mode'),
          height: modeRow,
          segments: [
            PillSegment(WorkbenchSurface.chat, l10n.shellWorkbenchChat, icon: AppIcons.chat),
            PillSegment(WorkbenchSurface.cli, l10n.shellWorkbenchModeCli, icon: AppIcons.terminal),
          ],
          selected: surface,
          onChanged: (next) => ref.read(workbenchSurfaceProvider.notifier).show(next),
        ),
      ),
    );
  }
}

/// Static extent helpers kept for callers computing wide workbench header height.
abstract final class WorkbenchChrome {
  static double extentOf(BuildContext context) => WorkbenchTabBar.heightOf(context) + WorkbenchModeBar.extent;
}

class _TabCountBadge extends StatelessWidget {
  const _TabCountBadge({
    super.key,
    required this.count,
    required this.tooltip,
    required this.tabs,
    required this.current,
    required this.byId,
    required this.untitledLabel,
    required this.onSelect,
  });

  final int count;
  final String tooltip;
  final List<String> tabs;
  final String? current;
  final Map<String, SessionSummary> byId;
  final String untitledLabel;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final badge = Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surface.withValues(alpha: 0.7),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Text(
        '$count',
        style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
      ),
    );
    if (tabs.isEmpty) {
      return Tooltip(message: tooltip, child: badge);
    }
    return PopupMenuButton<String>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (final id in tabs)
          PopupMenuItem<String>(
            key: ValueKey('workbench-tab-menu-$id'),
            value: id,
            child: Row(
              children: [
                Icon(AppIcons.chat, size: 15, color: id == current ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    byId[id] == null ? untitledLabel : sessionTitle(byId[id]!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: id == current ? FontWeight.w600 : FontWeight.w400),
                  ),
                ),
                if (byId[id]?.running ?? false) ...[
                  const SizedBox(width: 8),
                  const StatusDot(tone: StatusTone.busy, size: 6),
                ],
              ],
            ),
          ),
      ],
      child: badge,
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    super.key,
    required this.label,
    required this.selected,
    required this.running,
    required this.onTap,
    this.onClose,
    this.closeKey,
    this.runningKey,
  });

  final String label;
  final bool selected;
  final bool running;
  final VoidCallback onTap;
  final VoidCallback? onClose;
  final Key? closeKey;
  final Key? runningKey;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final dsh = DshColors.of(context);
    final background = selected ? scheme.surface : scheme.surface.withValues(alpha: 0.55);
    final foreground = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    final showClose = onClose != null && (selected || !running);
    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 2, bottom: 2),
      child: Material(
        color: background,
        elevation: selected ? 0.8 : 0,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Padding(
              padding: EdgeInsets.only(left: 10, right: showClose ? 2 : 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.chat, size: 14, color: selected ? scheme.primary : dsh.textTertiary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: foreground, fontSize: 13),
                    ),
                  ),
                  if (running) ...[
                    const SizedBox(width: 6),
                    StatusDot(key: runningKey, tone: StatusTone.busy, size: 6),
                  ],
                  if (showClose)
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
