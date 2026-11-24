// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
//
// The wide window's conversation chrome:
// 1) WorkbenchTabBar sits at the top (engine count badge, agent tabs, new-chat + for active agent);
// 2) ChatHeader sits underneath it (menu, title pill with icon, model, refresh);
// 3) WorkbenchModeBar sits below the header (对话 / CLI).
// Phone layout does not build these.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workbench_bridge_state.dart';
import '../../../state/workbench_state.dart';
import '../../common/cli_engine_icon.dart';
import '../../common/empty_view.dart';
import '../../common/segmented_pill.dart';
import '../../common/status_dot.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// Refreshes the host conversation list, multi-CLI bridge, and active chat.
Future<void> refreshWorkbench(WidgetRef ref) async {
  await Future.wait([
    ref.read(sessionsProvider.notifier).refresh(),
    ref.read(workbenchBridgeSessionsProvider.notifier).refresh(),
  ]);
  final id = ref.read(currentSessionProvider);
  if (id == null) return;
  await ref.read(chatProvider(id).notifier).resync();
}

/// Top strip of the wide workbench: available agent counter, agent-switcher tabs,
/// and the `+` button to start a new chat in the active agent.
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
    final engines = ref.watch(workbenchAvailableEnginesProvider);
    final activeEngine = ref.watch(activeWorkbenchEngineProvider);
    final sessions = ref.watch(mergedSessionsProvider).asData?.value ?? const <SessionSummary>[];
    final runningEngines = <CliEngine>{
      for (final s in sessions)
        if (s.running) s.cliEngine,
    };
    final newChatTooltip = activeEngine == CliEngine.dsh
        ? l10n.commonNewChat
        : (AppLocale.isEnglish ? 'New ${activeEngine.label} chat' : '新建 ${activeEngine.label} 对话');

    return Padding(
      padding: EdgeInsets.fromLTRB(12, topInset + topGap, 12, bottomGap),
      child: SizedBox(
        key: const ValueKey('workbench-tabs'),
        height: tabRow,
        child: Row(
          children: [
            _EngineCountBadge(
              key: const ValueKey('workbench-tab-count'),
              engines: engines,
              activeEngine: activeEngine,
              runningEngines: runningEngines,
              tooltip: AppLocale.isEnglish ? 'Switch agent' : '切换智能体',
              onSelect: (engine) => ref.read(activeWorkbenchEngineProvider.notifier).selectEngine(engine),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final engine in engines)
                    _EngineTabChip(
                      key: ValueKey('workbench-engine-tab-${engine.wire}'),
                      runningKey: ValueKey('workbench-engine-running-${engine.wire}'),
                      engine: engine,
                      selected: engine == activeEngine,
                      running: runningEngines.contains(engine),
                      onTap: () => ref.read(activeWorkbenchEngineProvider.notifier).selectEngine(engine),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            _IconKey(
              key: const ValueKey('workbench-new-chat'),
              icon: AppIcons.add,
              tooltip: newChatTooltip,
              onPressed: () => ref.read(activeWorkbenchEngineProvider.notifier).newChat(),
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

class _EngineCountBadge extends StatelessWidget {
  const _EngineCountBadge({
    super.key,
    required this.engines,
    required this.activeEngine,
    required this.runningEngines,
    required this.tooltip,
    required this.onSelect,
  });

  final List<CliEngine> engines;
  final CliEngine activeEngine;
  final Set<CliEngine> runningEngines;
  final String tooltip;
  final ValueChanged<CliEngine> onSelect;

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
        '${engines.length}',
        style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
      ),
    );
    return PopupMenuButton<CliEngine>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (final engine in engines)
          PopupMenuItem<CliEngine>(
            key: ValueKey('workbench-engine-menu-${engine.wire}'),
            value: engine,
            child: Row(
              children: [
                CliEngineIcon(
                  engine: engine,
                  size: 15,
                  dshColor: engine == activeEngine ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    engine.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: engine == activeEngine ? FontWeight.w600 : FontWeight.w400),
                  ),
                ),
                if (runningEngines.contains(engine)) ...[
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

class _EngineTabChip extends StatelessWidget {
  const _EngineTabChip({
    super.key,
    required this.engine,
    required this.selected,
    required this.running,
    required this.onTap,
    this.runningKey,
  });

  final CliEngine engine;
  final bool selected;
  final bool running;
  final VoidCallback onTap;
  final Key? runningKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dsh = DshColors.of(context);
    final background = selected ? scheme.surface : scheme.surface.withValues(alpha: 0.55);
    final foreground = selected ? scheme.onSurface : scheme.onSurfaceVariant;
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
            constraints: const BoxConstraints(maxWidth: 180),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CliEngineIcon(
                    engine: engine,
                    size: 15,
                    dshColor: selected ? scheme.primary : dsh.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      engine.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: foreground, fontSize: 13),
                    ),
                  ),
                  if (running) ...[
                    const SizedBox(width: 6),
                    StatusDot(key: runningKey, tone: StatusTone.busy, size: 6),
                  ],
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
