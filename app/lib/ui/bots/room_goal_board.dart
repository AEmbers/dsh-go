// A group's goal (`group_goal` of ds-bot): what the group is working toward,
// how the admin judges it done, and the stages with each member's share.
//
// Two forms of the same data: [RoomGoalCard] is the one-line summary the group
// chat keeps above its composer, [RoomGoalBoard] is the whole ledger, shown on
// the group's details page and in the sheet the summary opens.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../chat/widgets/chat_card.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bots_page.dart' show BotTag;

/// The ledger of a goal: stages in order, each with its acceptance and tasks.
///
/// Drawn only for a host that answered `goal` at all; see
/// [RoomChatState.goalsKnown].
class RoomGoalBoard extends StatelessWidget {
  const RoomGoalBoard({super.key, required this.goal, this.compact = false});

  final DsBotRoomGoal goal;

  /// Inside a sheet: no card of its own, tighter spacing.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // In a sheet there is no card to carry the status, so the headline does.
        _Headline(goal: goal, inset: compact ? SheetTitleBar.inset : ChatCard.inset, showStatus: compact),
        if (goal.hasStages)
          _Progress(goal: goal, inset: compact ? SheetTitleBar.inset : ChatCard.inset),
        for (final stage in goal.stages)
          _StageRow(
            stage: stage,
            current: stage.index == goal.current && goal.live,
            inset: compact ? SheetTitleBar.inset : ChatCard.inset,
          ),
        if (goal.objective.isNotEmpty || goal.acceptance.isNotEmpty || goal.constraints.isNotEmpty)
          _Facts(goal: goal, inset: compact ? SheetTitleBar.inset : ChatCard.inset),
        if (goal.finished) _Outcome(goal: goal, inset: compact ? SheetTitleBar.inset : ChatCard.inset),
        SizedBox(height: compact ? 8 : ChatCard.inset),
      ],
    );
    if (compact) return body;
    return ChatCard(
      key: const ValueKey('room-goal'),
      icon: AppIcons.goal,
      title: goalTitle(context, goal),
      tone: _tone(goal),
      trailing: BotTag(goalStatusText(context, goal.status)),
      children: [body],
    );
  }
}

/// The group chat's one-line summary of its goal; tapping opens the ledger.
class RoomGoalCard extends StatelessWidget {
  const RoomGoalCard({super.key, required this.goal});

  final DsBotRoomGoal goal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final l10n = context.l10n;
    final current = goal.currentStage;
    final stage = goal.hasStages
        ? l10n.botsGoalStageOf(goal.current.clamp(0, goal.stages.length - 1) + 1, goal.stages.length)
        : null;
    return ChatCard(
      key: const ValueKey('room-goal-summary'),
      icon: AppIcons.goal,
      title: goalTitle(context, goal),
      tone: _tone(goal),
      trailing: BotTag(goalStatusText(context, goal.status)),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                current != null ? current.title : (goal.objective.isNotEmpty ? goal.objective : l10n.botsGoalBoard),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
              ),
              if (stage != null) ...[
                const SizedBox(height: 6),
                _Bar(passed: goal.passedStages, count: goal.stages.length),
                const SizedBox(height: 4),
                Text(
                  l10n.botsGoalPassedCount(goal.passedStages),
                  style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
                ),
              ],
            ],
          ),
        ),
        ChatCardFooter(
          key: const ValueKey('room-goal-open'),
          label: l10n.botsGoalBoard,
          meta: stage,
          onTap: () => showRoomGoalSheet(context, goal),
        ),
      ],
    );
  }
}

/// The whole ledger in a sheet, where the rows have room to breathe.
Future<void> showRoomGoalSheet(BuildContext context, DsBotRoomGoal goal) {
  final l10n = context.l10n;
  return showAppSheet<void>(
    context,
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetTitleBar(goalTitle(context, goal)),
            if (!goal.hasStages && goal.objective.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
                child: Text(goal.objective, style: Theme.of(context).textTheme.bodyMedium),
              )
            else
              RoomGoalBoard(goal: goal, compact: true),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SheetTitleBar.inset),
              child: Text(
                l10n.botsGoalBoard,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The goal's own title, else the board's name.
String goalTitle(BuildContext context, DsBotRoomGoal goal) {
  final title = goal.title.trim();
  return title.isEmpty ? context.l10n.botsGoalBoard : title;
}

/// The stage/task status words the host uses, in the interface's language.
String goalStatusText(BuildContext context, DsBotGoalStatus status) {
  final l10n = context.l10n;
  return switch (status) {
    DsBotGoalStatus.drafting => l10n.botsGoalStatusDrafting,
    DsBotGoalStatus.active => l10n.botsGoalStatusActive,
    DsBotGoalStatus.paused => l10n.botsGoalStatusPaused,
    DsBotGoalStatus.complete => l10n.botsGoalStatusComplete,
    DsBotGoalStatus.stopped => l10n.botsGoalStatusStopped,
    DsBotGoalStatus.unknown => l10n.botsGoalStatusUnknown,
  };
}

String stageStatusText(BuildContext context, DsBotStageStatus status) {
  final l10n = context.l10n;
  return switch (status) {
    DsBotStageStatus.pending => l10n.botsGoalStagePending,
    DsBotStageStatus.active => l10n.botsGoalStageActive,
    DsBotStageStatus.passed => l10n.botsGoalStagePassed,
    DsBotStageStatus.unknown => l10n.botsGoalStageUnknown,
  };
}

String taskStatusText(BuildContext context, DsBotTaskStatus status) {
  final l10n = context.l10n;
  return switch (status) {
    DsBotTaskStatus.pending => l10n.botsGoalTaskPending,
    DsBotTaskStatus.working => l10n.botsGoalTaskWorking,
    DsBotTaskStatus.reported => l10n.botsGoalTaskReported,
    DsBotTaskStatus.done => l10n.botsGoalTaskDone,
    DsBotTaskStatus.unknown => l10n.botsGoalTaskUnknown,
  };
}

ChatCardTone _tone(DsBotRoomGoal goal) => switch (goal.status) {
  DsBotGoalStatus.active => ChatCardTone.ask,
  DsBotGoalStatus.paused || DsBotGoalStatus.stopped => ChatCardTone.attention,
  _ => ChatCardTone.neutral,
};

IconData _stageIcon(DsBotStageStatus status) => switch (status) {
  DsBotStageStatus.passed => AppIcons.completed,
  DsBotStageStatus.active => AppIcons.working,
  _ => AppIcons.pending,
};

IconData _taskIcon(DsBotTaskStatus status) => switch (status) {
  DsBotTaskStatus.done => AppIcons.completed,
  DsBotTaskStatus.working => AppIcons.working,
  DsBotTaskStatus.reported => AppIcons.toConfirm,
  _ => AppIcons.pending,
};

class _Headline extends StatelessWidget {
  const _Headline({required this.goal, required this.inset, required this.showStatus});

  final DsBotRoomGoal goal;
  final double inset;

  /// Whether the goal's status rides here; on a card its trailing tag says it.
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final current = goal.currentStage;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
      child: Row(
        children: [
          Icon(_stageIcon(current?.status ?? DsBotStageStatus.pending), size: 18, color: dsh.textTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              current?.title ?? context.l10n.botsGoalCurrent,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (showStatus) ...[
            const SizedBox(width: 6),
            BotTag(goalStatusText(context, goal.status)),
          ],
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.goal, required this.inset});

  final DsBotRoomGoal goal;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Bar(passed: goal.passedStages, count: goal.stages.length),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.botsGoalStageOf(
                    goal.current.clamp(0, goal.stages.length - 1) + 1,
                    goal.stages.length,
                  ),
                  style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
                ),
              ),
              Text(
                context.l10n.botsGoalPassedCount(goal.passedStages),
                style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.passed, required this.count});

  final int passed;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: AppShape.radiusXs,
      child: LinearProgressIndicator(
        value: count == 0 ? 0 : (passed / count).clamp(0.0, 1.0),
        minHeight: 4,
        backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
      ),
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.current, required this.inset});

  final DsBotGoalStage stage;
  final bool current;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final l10n = context.l10n;
    final open = stage.open;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, current ? 6 : 4, inset, current ? 10 : 4),
      child: Container(
        decoration: current
            ? ShapeDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
                shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusSm),
              )
            : null,
        padding: current ? const EdgeInsets.fromLTRB(8, 8, 8, 8) : EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(_stageIcon(stage.status), size: 18, color: StatusDotColor.of(context, stage.status)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stage.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: stage.active ? FontWeight.w600 : null,
                    ),
                  ),
                ),
                if (stage.reworks > 0) ...[
                  const SizedBox(width: 6),
                  BotTag('×${stage.reworks}'),
                ],
                if (open > 0) ...[
                  const SizedBox(width: 6),
                  BotTag(taskStatusText(context, DsBotTaskStatus.working)),
                ],
              ],
            ),
            if (stage.acceptance.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: Text(
                  stage.acceptance,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                ),
              ),
            if (stage.reworks > 0)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: Text(
                  l10n.botsGoalReworks(stage.reworks),
                  style: theme.textTheme.labelSmall?.copyWith(color: dsh.warning),
                ),
              ),
            if (stage.feedback case final feedback? when feedback.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: Text(
                  l10n.botsGoalFeedback(feedback),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: dsh.warning),
                ),
              ),
            for (final task in stage.tasks)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_taskIcon(task.status), size: 14, color: StatusDotColor.of(context, task.status)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            task.name.isEmpty ? task.task : '${task.name} · ${task.task}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                          if (task.note case final note? when note.trim().isNotEmpty)
                            Text(
                              note,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    BotTag(taskStatusText(context, task.status)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.goal, required this.inset});

  final DsBotRoomGoal goal;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (goal.objective.trim().isNotEmpty) _Fact(l10n.botsGoalObjective, goal.objective),
          if (goal.acceptance.trim().isNotEmpty) _Fact(l10n.botsGoalAcceptance, goal.acceptance),
          if (goal.constraints.isNotEmpty)
            _Fact(l10n.botsGoalConstraints, [for (final rule in goal.constraints) '· $rule'].join('\n')),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.text);

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary)),
          const SizedBox(height: 2),
          Text(text, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.goal, required this.inset});

  final DsBotRoomGoal goal;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final reason = goal.reason?.trim() ?? '';
    final summary = goal.summary?.trim() ?? '';
    final evidence = goal.evidence?.trim() ?? '';
    if (reason.isEmpty && summary.isEmpty && evidence.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reason.isNotEmpty) _Fact(l10n.botsGoalReason, reason),
          if (summary.isNotEmpty) _Fact(l10n.botsGoalSummary, summary),
          if (evidence.isNotEmpty) _Fact(l10n.botsGoalEvidence, evidence),
        ],
      ),
    );
  }
}

/// The status colour of a stage or task, from its own enum.
abstract final class StatusDotColor {
  static Color of(BuildContext context, Object status) {
    final dsh = DshColors.of(context);
    return switch (status) {
      DsBotStageStatus.passed || DsBotTaskStatus.done => dsh.success,
      DsBotStageStatus.active || DsBotTaskStatus.working || DsBotTaskStatus.reported =>
        Theme.of(context).colorScheme.primary,
      _ => Theme.of(context).colorScheme.outline,
    };
  }
}
