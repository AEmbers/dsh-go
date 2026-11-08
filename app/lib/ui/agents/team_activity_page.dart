// The `@nanmicoder/dsh-agent-teams` team panel as a dsh-go page.
//
// `team_page.dart` next door shows the *official experimental* team projection
// off the Lead session. This plugin is a different animal: it keeps its own
// snapshot behind one conditional GET (`/plugins/dsh-agent-teams/state`), so
// what this page adds is the part that only the plugin knows — the review gate
// on a staged plan (approve / continue / discard), the halt switch, the quality
// loop and its delivery verdict, the DAG lanes by depth, and the captain inbox.
//
// Everything here is a mirror plus two writes: `POST /plan` and `POST /halt`.
// The plugin owns the team; the page never guesses a member's or a task's state
// forward from a reply, it re-reads the snapshot.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_teams_state.dart';
import '../../state/agents_state.dart' show selectConversation;
import '../../state/connection_state.dart';
import '../../state/plugins_state.dart' show localSafeModeProvider;
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_title_bar.dart';
import '../common/status_chip.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../features/feature_widgets.dart' show FeatureOffline;
import '../plugins/plugin_actions.dart' show togglePluginBundle;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'agent_widgets.dart';

enum _Pane { overview, members, tasks, inbox }

/// The team that rules this chat, or every team on the host when the chat is
/// not a captain's.
class TeamActivityPage extends ConsumerStatefulWidget {
  const TeamActivityPage({super.key, this.sessionId});

  /// The chat the user came from; null reads the chat on screen.
  final String? sessionId;

  static Route<void> route({String? sessionId}) =>
      MaterialPageRoute<void>(builder: (_) => TeamActivityPage(sessionId: sessionId));

  @override
  ConsumerState<TeamActivityPage> createState() => _TeamActivityPageState();
}

class _TeamActivityPageState extends ConsumerState<TeamActivityPage> {
  _Pane _pane = _Pane.overview;
  bool _enabling = false;

  Future<void> _enable(PluginBundle bundle) async {
    setState(() => _enabling = true);
    await togglePluginBundle(context, bundle, true);
    if (!mounted) return;
    setState(() => _enabling = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sessionId = widget.sessionId ?? ref.watch(currentSessionProvider);
    if (ref.watch(activeConnectionProvider).value == null) {
      return AppPage.list(title: l10n.ateamTitle, children: const [FeatureOffline()]);
    }

    final plugin = ref.watch(agentTeamsPluginProvider).value;
    if (plugin == null) {
      return AppPage.list(
        title: l10n.ateamTitle,
        children: [
          EmptyView(
            icon: AppIcons.team,
            title: l10n.ateamNotServed,
            message: l10n.ateamNoTeamsMessage,
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
          ),
        ],
      );
    }
    if (!plugin.enabled) {
      final safe = ref.watch(localSafeModeProvider);
      return AppPage.list(
        title: l10n.ateamTitle,
        children: [
          EmptyView(
            icon: AppIcons.team,
            title: l10n.ateamNotEnabled,
            message: plugin.description,
            actionLabel: _enabling ? l10n.ateamEnabling : l10n.ateamEnable,
            onAction: safe || _enabling ? null : () => _enable(plugin),
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
          ),
        ],
      );
    }

    final read = ref.watch(agentTeamsProvider);
    if (read.hasError && read.value == null) {
      return AppPage.list(
        title: l10n.ateamTitle,
        children: [
          EmptyView(
            icon: AppIcons.error,
            title: l10n.ateamReadFailed,
            message: '$read.error',
            actionLabel: l10n.commonRetry,
            onAction: () => ref.read(agentTeamsProvider.notifier).refresh(),
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
          ),
        ],
      );
    }
    if (read.value == null) {
      return AppPage(
        title: l10n.ateamTitle,
        slivers: const [
          SliverFillRemaining(hasScrollBody: false, child: Center(child: QuietSpinner())),
        ],
      );
    }

    // A captain's chat sees its own team; any other chat falls back to the only
    // team on the host, which is what the plugin's own panel does.
    final teams = read.value!.teams;
    final team = sessionId == null ? null : read.value!.forCaptain(sessionId);
    if (team == null && teams.isEmpty) {
      return AppPage.list(
        title: l10n.ateamTitle,
        children: [
          EmptyView(
            icon: AppIcons.team,
            title: l10n.ateamNoTeams,
            message: l10n.ateamNoTeamsMessage,
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
          ),
        ],
      );
    }
    if (team == null) {
      return _TeamPicker(teams: teams, onOpen: (id) => _openTeam(id));
    }
    return _TeamView(
      team: team,
      pane: _pane,
      onPane: (pane) => setState(() => _pane = pane),
      onOpenChat: _openChat,
    );
  }

  void _openTeam(String teamId) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _SingleTeamPage(teamId: teamId),
    ),
  );

  void _openChat(String sessionId) {
    selectConversation(ref, sessionId);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

/// Every team on the host, when the chat on screen is not a captain's.
class _TeamPicker extends ConsumerWidget {
  const _TeamPicker({required this.teams, required this.onOpen});

  final List<AgentTeamSnapshot> teams;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return AppPage.list(
      title: l10n.ateamTitle,
      children: [
        ListPageCard(
          children: [
            for (final (i, team) in teams.indexed)
              FadeSlideIn(
                index: i,
                child: ListPageRow(
                  leading: const Icon(AppIcons.team),
                  title: team.name,
                  subtitle: ateamPhaseLabel(l10n, team.phase, halted: team.halted),
                  meta: l10n.ateamMembersWorking(team.workingCount),
                  onTap: () => onOpen(team.teamId),
                ),
              ),
          ],
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
      ],
    );
  }
}

/// One team opened by id from the picker.
class _SingleTeamPage extends ConsumerStatefulWidget {
  const _SingleTeamPage({required this.teamId});

  final String teamId;

  @override
  ConsumerState<_SingleTeamPage> createState() => _SingleTeamPageState();
}

class _SingleTeamPageState extends ConsumerState<_SingleTeamPage> {
  _Pane _pane = _Pane.overview;

  @override
  Widget build(BuildContext context) {
    final team = ref.watch(agentTeamProvider(widget.teamId));
    if (team == null) {
      return AppPage.list(
        title: context.l10n.ateamTitle,
        children: [
          EmptyView(icon: AppIcons.team, title: context.l10n.ateamNoTeams, padding: const EdgeInsets.all(32)),
        ],
      );
    }
    return _TeamView(
      team: team,
      pane: _pane,
      onPane: (pane) => setState(() => _pane = pane),
      onOpenChat: (sessionId) {
        selectConversation(ref, sessionId);
        Navigator.of(context).popUntil((route) => route.isFirst);
      },
    );
  }
}

// -----------------------------------------------------------------------------
// The team

class _TeamView extends ConsumerWidget {
  const _TeamView({required this.team, required this.pane, required this.onPane, required this.onOpenChat});

  final AgentTeamSnapshot team;
  final _Pane pane;
  final ValueChanged<_Pane> onPane;
  final ValueChanged<String> onOpenChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final action = ref.watch(agentTeamsActionProvider);
    final failure = action.failedOn(team.teamId) ? _errorText(l10n, action) : null;
    final content = switch (pane) {
      _Pane.overview => _OverviewPane(team: team, onOpenChat: onOpenChat),
      _Pane.members => _MembersPane(team: team, onOpenChat: onOpenChat),
      _Pane.tasks => _TasksPane(team: team),
      _Pane.inbox => _InboxPane(team: team),
    };
    return AppPage(
      title: l10n.ateamTitle,
      hero: PageHero(
        leading: _AvatarRow(names: [for (final m in team.members) m.name]),
        title: team.name,
        subtitle: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(tone: ateamPhaseTone(team.phase, halted: team.halted), size: 6),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                ateamPhaseLabel(l10n, team.phase, halted: team.halted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: DshColors.of(context).textTertiary,
                ),
              ),
            ),
          ],
        ),
        stats: [
          ('${team.members.length}', l10n.ateamMembers),
          ('${team.openTasks}', l10n.ateamTasks),
          ('${team.messageCount}', l10n.botsMessages),
        ],
      ),
      actions: [
        if (action.isBusyOn(team.teamId))
          const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: QuietSpinner())
        else ...[
          if (team.phase == TeamPhase.running && !team.halted)
            GlassIconButton(
              icon: AppIcons.pause,
              tooltip: l10n.ateamHalt,
              onPressed: () => _halt(context, ref, l10n),
            ),
          GlassIconButton(
            icon: AppIcons.refresh,
            tooltip: l10n.commonRetry,
            onPressed: () => ref.read(agentTeamsProvider.notifier).refresh(),
          ),
        ],
      ],
      slivers: [
        SliverList.list(
          children: [
            if (team.staged) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _ReviewGate(team: team),
              ),
            ],
            if ((team.delivery?.blockers.isNotEmpty ?? false) || (team.delivery?.warnings.isNotEmpty ?? false))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _DeliveryCard(team: team),
              ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _Note(
                  text: failure,
                  tone: DshColors.of(context).danger,
                  onDismiss: () => ref.read(agentTeamsActionProvider.notifier).dismiss(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SegmentedPill<_Pane>(
                segments: [
                  PillSegment(_Pane.overview, l10n.ateamOverview),
                  PillSegment(_Pane.members, l10n.ateamMembers),
                  PillSegment(_Pane.tasks, l10n.ateamTasks),
                  PillSegment(_Pane.inbox, l10n.ateamCaptainInbox),
                ],
                selected: pane,
                onChanged: onPane,
              ),
            ),
            AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.quick),
              switchInCurve: AppMotion.enter,
              switchOutCurve: AppMotion.exit,
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
              child: KeyedSubtree(key: ValueKey(pane), child: content),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _halt(BuildContext context, WidgetRef ref, L10n l10n) async {
    final ok = await _confirm(context, title: l10n.ateamHaltConfirmTitle, body: l10n.ateamHaltConfirmBody);
    if (!ok) return;
    await ref
        .read(agentTeamsActionProvider.notifier)
        .halt(sessionId: team.captainSessionId, teamId: team.teamId);
  }
}

/// The gate a staged plan waits behind: approve, keep talking, or throw it away.
class _ReviewGate extends ConsumerWidget {
  const _ReviewGate({required this.team});

  final AgentTeamSnapshot team;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    final action = ref.watch(agentTeamsActionProvider);
    final busy = action.isBusyOn(team.teamId);
    final review = switch (team.planReviewState) {
      PlanReviewState.awaitingFeedback => l10n.ateamPlanAwaitingFeedback,
      _ => l10n.ateamPlanAwaitingReview,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: colors.warningContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.info, size: 18, color: colors.onWarningContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  review,
                  style: theme.textTheme.bodyMedium?.copyWith(color: colors.onWarningContainer),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: busy ? null : () => _plan(ref, AgentTeamPlanAction.approve),
                child: Text(l10n.ateamApprove),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: busy ? null : () => _plan(ref, AgentTeamPlanAction.continuePlanning),
                child: Text(l10n.ateamContinue),
              ),
              const Spacer(),
              TextButton(
                onPressed: busy ? null : () => _discard(context, ref),
                child: Text(l10n.ateamDiscard),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _plan(WidgetRef ref, AgentTeamPlanAction plan) => ref
      .read(agentTeamsActionProvider.notifier)
      .plan(sessionId: team.captainSessionId, teamId: team.teamId, action: plan);

  Future<void> _discard(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final ok = await _confirm(context, title: l10n.ateamDiscardConfirmTitle, body: l10n.ateamDiscardConfirmBody);
    if (!ok) return;
    await _plan(ref, AgentTeamPlanAction.discard);
  }
}

/// The quality loop's verdict, with the reasons a delivery is still refused.
class _DeliveryCard extends StatelessWidget {
  const _DeliveryCard({required this.team});

  final AgentTeamSnapshot team;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final delivery = team.delivery;
    final loop = switch (team.loopState) {
      TeamLoopState.halted => l10n.ateamLoopHalted,
      TeamLoopState.deliverable => l10n.ateamLoopDeliverable,
      TeamLoopState.escalated => l10n.ateamLoopEscalated,
      TeamLoopState.running => l10n.ateamLoopRunning,
      TeamLoopState.blocked => l10n.ateamLoopBlocked,
      _ => null,
    };
    final ok = delivery?.ok ?? false;
    return ListPageCard(
      children: [
        ListPageRow(
          leading: Icon(
            ok ? AppIcons.success : AppIcons.warning,
            color: ok ? colors.success : colors.warning,
          ),
          title: l10n.ateamDeliveryReady,
          meta: ok ? l10n.commonDone : l10n.ateamDeliveryBlocked,
          metaColor: ok ? colors.success : colors.warning,
        ),
        if (loop != null) ListPageRow(title: l10n.ateamLoop, meta: loop),
        for (final blocker in delivery?.blockers ?? const <String>[])
          ListPageRow(title: l10n.ateamBlockers, subtitle: blocker, subtitleMaxLines: 3),
        for (final warning in delivery?.warnings ?? const <String>[])
          ListPageRow(
            title: l10n.ateamWarnings,
            subtitle: warning,
            subtitleColor: colors.warning,
            subtitleMaxLines: 3,
          ),
        if (team.halted)
          ListPageRow(
            leading: Icon(AppIcons.pause, color: colors.warning),
            title: l10n.ateamHalted,
            subtitle: l10n.ateamHaltedNote,
          ),
        if (team.workspace.isNotEmpty || (team.description ?? '').isNotEmpty)
          ListPageRow(
            title: l10n.ateamDescription,
            subtitle: team.workspacePath ?? team.workspace,
            subtitleMaxLines: 2,
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Panes

class _OverviewPane extends StatelessWidget {
  const _OverviewPane({required this.team, required this.onOpenChat});

  final AgentTeamSnapshot team;
  final ValueChanged<String> onOpenChat;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final captain = team.captain;
    final working = team.members.where((m) => m.working).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (captain != null)
          ListPageCard(
            children: [
              ListPageRow(
                leading: AgentAvatar(captain.name),
                title: captain.name,
                subtitle: l10n.ateamCaptain,
                badge: _activityChip(context, captain),
                meta: captain.modelRoute.isEmpty ? null : captain.modelRoute,
                metaColor: colors.textTertiary,
                onTap: captain.openable ? () => onOpenChat(captain.id) : null,
                chevron: captain.openable,
              ),
            ],
          ),
        if (working.isNotEmpty)
          ListPageCard(
            title: l10n.ateamMembersWorking(working.length),
            children: [
              for (final m in working)
                ListPageRow(
                  leading: AgentAvatar(m.name),
                  title: m.name,
                  subtitle: m.currentTask.isEmpty ? m.role : m.currentTask,
                  meta: m.total > 0 ? l10n.ateamProgress(m.done, m.total) : null,
                  onTap: m.openable ? () => onOpenChat(m.id) : null,
                  chevron: m.openable,
                ),
            ],
          ),
        if (team.captainInbox.isNotEmpty)
          ListPageCard(
            title: l10n.ateamCaptainInbox,
            children: [
              for (final message in team.captainInbox)
                ListPageRow(
                  leading: const Icon(AppIcons.info),
                  title: message.from,
                  subtitle: message.content,
                  subtitleMaxLines: 3,
                ),
            ],
          ),
        if (captain == null && working.isEmpty && team.captainInbox.isEmpty)
          ListPageCard(
            children: [
              ListPageRow(title: l10n.ateamOverview, subtitle: ateamPhaseLabel(l10n, team.phase, halted: team.halted)),
              ListPageRow(
                title: l10n.ateamMembers,
                value: '${team.members.length}',
                onTap: null,
              ),
              ListPageRow(title: l10n.ateamTasks, value: '${team.tasks.length}'),
            ],
          ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
      ],
    );
  }
}

class _MembersPane extends StatelessWidget {
  const _MembersPane({required this.team, required this.onOpenChat});

  final AgentTeamSnapshot team;
  final ValueChanged<String> onOpenChat;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    if (team.members.isEmpty) {
      return EmptyView(icon: AppIcons.team, title: l10n.ateamNoTeams, padding: const EdgeInsets.all(32));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          children: [
            for (final (i, member) in team.members.indexed)
              FadeSlideIn(
                index: i,
                child: ListPageRow(
                  leading: AgentAvatar(member.name),
                  title: member.name,
                  titleNote: member.removed ? l10n.ateamRemoved : null,
                  subtitle: _memberSubtitle(l10n, member),
                  subtitleColor: member.removed ? colors.textDisabled : null,
                  subtitleMaxLines: 2,
                  badge: _activityChip(context, member),
                  meta: member.modelRoute.isEmpty ? null : member.modelRoute,
                  metaColor: colors.textTertiary,
                  onTap: member.openable ? () => onOpenChat(member.id) : null,
                  chevron: member.openable,
                ),
              ),
          ],
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
      ],
    );
  }
}

class _TasksPane extends StatelessWidget {
  const _TasksPane({required this.team});

  final AgentTeamSnapshot team;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (team.tasks.isEmpty) {
      return EmptyView(icon: AppIcons.pending, title: l10n.ateamTasks, padding: const EdgeInsets.all(32));
    }
    final lanes = team.lanes;
    var index = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One card per DAG depth: tasks that can run together sit in one lane.
        for (var depth = 0; depth < lanes; depth++)
          if (team.lane(depth).isNotEmpty)
            ListPageCard(
              title: lanes > 1 ? l10n.ateamLane(depth + 1) : l10n.ateamTasks,
              children: [
                for (final task in team.lane(depth))
                  FadeSlideIn(
                    index: index++,
                    child: ListPageRow(
                      leading: _taskGlyph(context, task),
                      title: task.subject,
                      titleMaxLines: 2,
                      badge: task.isQualityKind ? _QualityBadge(label: l10n.ateamQualityKind) : null,
                      subtitle: _taskSubtitle(l10n, task),
                      subtitleMaxLines: 2,
                      onTap: () => _showTask(context, task),
                    ),
                  ),
              ],
            ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
      ],
    );
  }
}

class _InboxPane extends StatelessWidget {
  const _InboxPane({required this.team});

  final AgentTeamSnapshot team;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (team.captainInbox.isEmpty) {
      return EmptyView(
        icon: AppIcons.info,
        title: l10n.ateamCaptainInboxEmpty,
        message: team.messageCount == 0 ? null : l10n.ateamMessagesCount(team.messageCount),
        padding: const EdgeInsets.all(32),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          title: l10n.ateamMessagesCount(team.messageCount),
          children: [
            for (final (i, message) in team.captainInbox.indexed)
              FadeSlideIn(
                index: i,
                child: ListPageRow(
                  leading: AgentAvatar(message.from),
                  title: message.from,
                  subtitle: message.content,
                  subtitleMaxLines: 4,
                ),
              ),
          ],
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// One task

Future<void> _showTask(BuildContext context, TeamActivityTask task) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (context) {
      final l10n = context.l10n;
      final colors = DshColors.of(context);
      final theme = Theme.of(context);
      final (label, tone) = _taskStateLabel(l10n, task.state);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(task.subject),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  kSheetGutter,
                  0,
                  kSheetGutter,
                  MediaQuery.paddingOf(context).bottom + 20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        StatusChip(tone: tone, label: label),
                        if (task.isQualityKind) StatusChip(tone: StatusTone.idle, label: l10n.ateamQualityKind),
                        if (task.stale) StatusChip(tone: StatusTone.warn, label: l10n.ateamVerdictStale),
                      ],
                    ),
                    if ((task.description ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 16),
                      SelectableText(
                        task.description!.trim(),
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SheetGroup(
                      margin: EdgeInsets.zero,
                      children: [
                        ListPageRow(title: l10n.ateamAssignee, value: task.assignee),
                        ListPageRow(title: l10n.botsTaskId, value: task.id),
                        if (task.model.isNotEmpty) ListPageRow(title: l10n.ateamModelRoute, value: task.model),
                        if (task.dependencies.isNotEmpty)
                          ListPageRow(
                            title: l10n.botsDependencies,
                            value: task.dependencies.join(l10n.botsNameSeparator),
                          ),
                        if (task.round != null)
                          ListPageRow(title: l10n.ateamRound(task.round!), value: '${task.round}'),
                        if ((task.verdict ?? '').isNotEmpty)
                          ListPageRow(title: l10n.ateamVerdict(task.verdict!), subtitle: task.verdict),
                      ],
                    ),
                    if (task.assignee.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        l10n.ateamLane(task.depth + 1),
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

// -----------------------------------------------------------------------------
// Vocabulary

Widget _taskGlyph(BuildContext context, TeamActivityTask task) {
  final colors = DshColors.of(context);
  final scheme = Theme.of(context).colorScheme;
  return switch (task.state) {
    TeamTaskState.completed => Icon(AppIcons.success, size: 20, color: colors.success),
    TeamTaskState.failed => Icon(AppIcons.error, size: 20, color: colors.danger),
    TeamTaskState.cancelled => Icon(AppIcons.close, size: 20, color: colors.textTertiary),
    TeamTaskState.running => const StatusDot(tone: StatusTone.busy, size: 10),
    TeamTaskState.claimed => const StatusDot(tone: StatusTone.ok, size: 10),
    TeamTaskState.blocked => Icon(AppIcons.taskBlocked, size: 20, color: colors.warning),
    _ => Icon(AppIcons.pending, size: 20, color: scheme.outline),
  };
}

(String, StatusTone) _taskStateLabel(L10n l10n, TeamTaskState state) => switch (state) {
  TeamTaskState.completed => (l10n.ateamTaskStateCompleted, StatusTone.ok),
  TeamTaskState.failed => (l10n.ateamTaskStateFailed, StatusTone.error),
  TeamTaskState.cancelled => (l10n.ateamTaskStateCancelled, StatusTone.idle),
  TeamTaskState.running => (l10n.ateamTaskStateRunning, StatusTone.busy),
  TeamTaskState.claimed => (l10n.ateamTaskStateClaimed, StatusTone.busy),
  TeamTaskState.blocked => (l10n.ateamTaskStateBlocked, StatusTone.warn),
  TeamTaskState.open => (l10n.ateamTaskStateOpen, StatusTone.idle),
  TeamTaskState.unknown => (l10n.ateamUnknown, StatusTone.idle),
};

String _taskSubtitle(L10n l10n, TeamActivityTask task) {
  final parts = <String>[
    task.assignee.isEmpty ? l10n.botsUnassigned : task.assignee,
    if (task.dependencies.isNotEmpty) l10n.ateamTaskDependencies(task.dependencies.length),
    if (task.round != null) l10n.ateamRound(task.round!),
    if ((task.verdict ?? '').isNotEmpty) l10n.ateamVerdict(task.verdict!),
  ];
  return parts.join(l10n.botsNameSeparator);
}

String _memberSubtitle(L10n l10n, TeamActivityMember member) {
  final parts = <String>[
    if (member.role.isNotEmpty) member.role,
    if (member.currentTask.isNotEmpty) '${l10n.ateamCurrentTask}：${member.currentTask}',
    if (member.total > 0) l10n.ateamProgress(member.done, member.total),
    if (member.unread > 0) l10n.ateamUnread(member.unread),
  ];
  return parts.isEmpty ? l10n.ateamIdle : parts.join(l10n.botsNameSeparator);
}

Widget _activityChip(BuildContext context, TeamActivityMember member) {
  final l10n = context.l10n;
  if (member.removed) return StatusChip(tone: StatusTone.idle, label: l10n.ateamRemoved);
  return switch (member.activity) {
    TeamActivity.working => StatusChip(tone: StatusTone.busy, label: l10n.ateamWorking),
    TeamActivity.idle => StatusChip(tone: StatusTone.idle, label: l10n.ateamIdle),
    TeamActivity.unknown => StatusChip(tone: StatusTone.warn, label: l10n.ateamUnknown),
  };
}

/// How a team's phase reads. Shared with the in-conversation card so the chat
/// and the panel never name the same phase differently.
String ateamPhaseLabel(L10n l10n, TeamPhase phase, {bool halted = false}) => switch (phase) {
  TeamPhase.staged => l10n.ateamPhaseStaged,
  TeamPhase.running => halted ? l10n.ateamHalted : l10n.ateamPhaseRunning,
  TeamPhase.archived => l10n.ateamPhaseArchived,
  TeamPhase.unknown => l10n.ateamUnknown,
};

StatusTone ateamPhaseTone(TeamPhase phase, {bool halted = false}) => switch (phase) {
  TeamPhase.staged => StatusTone.warn,
  TeamPhase.running => halted ? StatusTone.warn : StatusTone.ok,
  TeamPhase.archived => StatusTone.idle,
  TeamPhase.unknown => StatusTone.idle,
};

/// The harness's own name for the tool whose result folds into a team card.
const agentTeamsCreateToolName = 'agent_teams_create';

String _errorText(L10n l10n, AgentTeamsActionState action) {
  final base = switch (action.error) {
    AgentTeamsActionError.unavailable => l10n.ateamErrorUnavailable,
    AgentTeamsActionError.captainDetached => l10n.ateamErrorCaptainDetached,
    AgentTeamsActionError.teamMissing => l10n.ateamErrorTeamMissing,
    AgentTeamsActionError.rejected => l10n.ateamErrorRejected,
    AgentTeamsActionError.failed || null => l10n.ateamErrorFailed,
  };
  final detail = action.detail;
  return detail == null || detail.isEmpty ? base : '$base · $detail';
}

Future<bool> _confirm(BuildContext context, {required String title, required String body}) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: DshColors.of(dialog).danger,
            foregroundColor: DshColors.of(dialog).onDanger,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l10n.commonConfirm),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// One line that can be dismissed (a failed plan edit).
class _Note extends StatelessWidget {
  const _Note({required this.text, required this.tone, this.onDismiss});

  final String text;
  final Color tone;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(AppIcons.warning, size: 18, color: tone),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: tone)),
          ),
          if (onDismiss != null)
            IconButton(
              icon: const Icon(AppIcons.close, size: 18),
              onPressed: onDismiss,
              tooltip: context.l10n.commonClose,
            ),
        ],
      ),
    );
  }
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colors.infoContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.onInfoContainer),
      ),
    );
  }
}

/// Up to four overlapping avatars, the hero's graphic.
class _AvatarRow extends StatelessWidget {
  const _AvatarRow({required this.names});

  final List<String> names;

  static const size = 40.0;
  static const step = 26.0;

  @override
  Widget build(BuildContext context) {
    final shown = names.take(names.length > 4 ? 3 : 4).toList();
    final rest = names.length - shown.length;
    final ring = DshSurfaces.of(context).backdropTop;
    final count = shown.length + (rest > 0 ? 1 : 0);
    if (count == 0) return const SizedBox.square(dimension: size);
    return SizedBox(
      width: size + step * (count - 1),
      height: size,
      child: Stack(
        children: [
          for (final (i, name) in shown.indexed)
            Positioned(left: step * i, child: AgentAvatar(name, size: size, ring: ring)),
          if (rest > 0)
            Positioned(left: step * shown.length, child: AgentAvatar('+$rest', size: size, ring: ring)),
        ],
      ),
    );
  }
}
