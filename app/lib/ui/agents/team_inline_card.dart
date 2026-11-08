// The team card that sits in the conversation, for `@nanmicoder/dsh-agent-teams`.
//
// The plugin publishes no `dsh-go/view` on its tool results (`lib/tools.js:841`
// sends `presentationMeta` and nothing else), so the generic plugin-card path
// never fires for it: a card here has to be recognised by the tool's name and
// its published identity. That identity is deliberately the canonical one —
// `team_id` / `captain_session_id` — because a client cannot reproduce the
// host's key cleaning for arbitrary (CJK) team names (upstream issue #203).
//
// Two widgets live here:
//
//  * [AgentTeamsInlineCard] — one team: the head (captain avatar, team name,
//    phase, member count, the panel key) and the member row. Members open
//    their own conversation; the panel key opens [TeamActivityPage].
//  * [AgentTeamsTurnCards] — every team created in one turn, stacked. A turn
//    that created three teams shows three cards, not one merged card.
//
// The card is a mirror: it reads the plugin's snapshot through
// `agentTeamProvider` and falls back to what the tool result itself carried
// while that read is still on its way.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/agent_teams_state.dart';
import '../../state/agents_state.dart' show selectConversation;
import '../common/status_chip.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'agent_widgets.dart';
import 'team_activity_page.dart' show TeamActivityPage, agentTeamsCreateToolName, ateamPhaseLabel, ateamPhaseTone;

/// One member as the tool result published it: `{id, name, role, status}`.
class AgentTeamsMetaMember {
  const AgentTeamsMetaMember({required this.id, required this.name, this.role = '', this.status = ''});

  static AgentTeamsMetaMember? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    final id = json['id'];
    final role = json['role'];
    final status = json['status'];
    return AgentTeamsMetaMember(
      id: id is String ? id : '',
      name: name,
      role: role is String ? role : '',
      status: status is String ? status : '',
    );
  }

  /// The member's session id; empty for a row that never got one.
  final String id;
  final String name;
  final String role;

  /// `active`, `removed`, … as the team was created.
  final String status;

  bool get removed => status == 'removed';
  bool get openable => id.isNotEmpty && !removed;
}

/// The identity a folded `agent_teams_create` result carries.
class AgentTeamsCreateMeta {
  const AgentTeamsCreateMeta({
    required this.teamId,
    required this.teamName,
    required this.captainSessionId,
    this.phase = TeamPhase.unknown,
    this.members = const [],
  });

  /// Null when the result is not this tool's, or carries no `team_id`: the
  /// anchor is required, a name alone is not an identity.
  static AgentTeamsCreateMeta? fromJson(Object? json) {
    if (json is! Map) return null;
    final teamId = json['team_id'];
    if (teamId is! String || teamId.isEmpty) return null;
    final name = json['team_name'];
    final captain = json['captain_session_id'];
    final phase = json['phase'];
    final members = json['members'];
    return AgentTeamsCreateMeta(
      teamId: teamId,
      teamName: name is String && name.isNotEmpty ? name : teamId,
      captainSessionId: captain is String ? captain : '',
      phase: TeamPhase.parse(phase),
      members: [
        if (members is List)
          for (final m in members) ?AgentTeamsMetaMember.fromJson(m),
      ],
    );
  }

  /// The durable team id: the fold anchor.
  final String teamId;
  final String teamName;

  /// The session that owns the team; empty when the host did not send it.
  final String captainSessionId;

  /// `staged` for a team created with a plan to review, else `running`.
  final TeamPhase phase;

  final List<AgentTeamsMetaMember> members;

  /// Stable across a reload: the id, never the name.
  String get key => 'ateam-$teamId';
}

/// The team identity of a succeeded `agent_teams_create` call, or null.
///
/// The plugin never writes `dsh-go/view`, so [ToolChatItem.meta] is the only
/// place this can come from.
AgentTeamsCreateMeta? agentTeamsCreateMetaOf(ToolChatItem item) {
  if (item.name != agentTeamsCreateToolName) return null;
  if (item.status != ToolStatus.succeeded) return null;
  return AgentTeamsCreateMeta.fromJson(item.meta);
}

/// Every team one turn created, in the order the calls happened, one entry per
/// team id. A turn that created three teams yields three entries.
List<AgentTeamsCreateMeta> agentTeamsMetasOf(Iterable<ToolChatItem> items) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (agentTeamsCreateMetaOf(item) case final meta?) if (seen.add(meta.teamId)) meta,
  ];
}

/// Every team of one turn, stacked (T-D).
///
/// The caller decides whether to show it at all: once the turn is closed and
/// the official team tail already names the team, this must stay out of the
/// way so nothing is drawn twice (T-C).
class AgentTeamsTurnCards extends StatelessWidget {
  const AgentTeamsTurnCards({super.key, required this.metas, this.padding = const EdgeInsets.only(bottom: 6)});

  final List<AgentTeamsCreateMeta> metas;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (metas.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final meta in metas)
          Padding(
            key: ValueKey(meta.key),
            padding: padding,
            child: AgentTeamsInlineCard(
              teamId: meta.teamId,
              captainSessionId: meta.captainSessionId,
              teamName: meta.teamName,
              members: meta.members,
              phase: meta.phase,
            ),
          ),
      ],
    );
  }
}

/// One team, as the conversation shows it.
class AgentTeamsInlineCard extends ConsumerWidget {
  const AgentTeamsInlineCard({
    super.key,
    required this.teamId,
    required this.captainSessionId,
    this.teamName,
    this.members = const [],
    this.phase = TeamPhase.unknown,
  });

  /// The card for one folded tool result: everything it shows before the
  /// snapshot arrives comes from the call's own identity.
  AgentTeamsInlineCard.fromMeta(AgentTeamsCreateMeta meta, {super.key})
    : teamId = meta.teamId,
      captainSessionId = meta.captainSessionId,
      teamName = meta.teamName,
      members = meta.members,
      phase = meta.phase;

  static const padding = 12.0;
  static const avatarSize = 26.0;
  static const avatarStep = 22.0;
  static const maxAvatars = 4;

  /// The anchor: a reload finds this card again by its id.
  final String teamId;
  final String captainSessionId;

  /// What the tool result said; the snapshot wins when it has arrived.
  final String? teamName;
  final List<AgentTeamsMetaMember> members;
  final TeamPhase phase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final live = ref.watch(agentTeamProvider(teamId));
    final name = live?.name ?? teamName ?? teamId;
    final shownPhase = live?.phase ?? phase;
    final halted = live?.halted ?? false;
    // The snapshot names the captain as a member too; the row is teammates.
    final teammates = live != null
        ? [for (final m in live.teammates) (id: m.id, name: m.name, working: m.working, openable: m.openable)]
        : [
            for (final m in members)
              if (m.name != 'captain')
                (id: m.id, name: m.name, working: false, openable: m.openable),
          ];
    final count = teammates.length;
    final working = teammates.where((m) => m.working).length;
    final ring = DshSurfaces.of(context).backdropTop;
    final tint = StatusDot.colorFor(context, ateamPhaseTone(shownPhase, halted: halted));

    void openPanel() => Navigator.of(context).push(
      TeamActivityPage.route(sessionId: captainSessionId.isEmpty ? null : captainSessionId),
    );

    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      onTap: openPanel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(padding, padding - 2, padding - 4, padding - 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                AgentAvatar(name, size: avatarSize, ring: ring),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        working > 0 ? l10n.ateamMembersWorking(working) : l10n.botsTeamMemberCount(count),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusChip(tone: ateamPhaseTone(shownPhase, halted: halted), label: ateamPhaseLabel(l10n, shownPhase, halted: halted)),
                const SizedBox(width: 4),
                Semantics(
                  button: true,
                  label: l10n.ateamCardOpenPanel,
                  excludeSemantics: true,
                  child: GlassSurface(
                    tier: GlassTier.pill,
                    circle: true,
                    onTap: openPanel,
                    child: SizedBox.square(
                      dimension: 30,
                      child: Center(child: Icon(AppIcons.team, size: 17, color: tint)),
                    ),
                  ),
                ),
              ],
            ),
            if (count > 0) ...[
              const SizedBox(height: 10),
              _MemberRow(teammates: teammates, ring: ring, onOpen: (id) => selectConversation(ref, id)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Up to [AgentTeamsInlineCard.maxAvatars] avatars; the rest collapse into a
/// `+N`. Each one opens its own conversation.
class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.teammates, required this.ring, required this.onOpen});

  final List<({String id, String name, bool working, bool openable})> teammates;
  final Color ring;
  final void Function(String sessionId) onOpen;

  @override
  Widget build(BuildContext context) {
    const size = AgentTeamsInlineCard.avatarSize;
    const step = AgentTeamsInlineCard.avatarStep;
    final shown = teammates.take(teammates.length > AgentTeamsInlineCard.maxAvatars ? 3 : 4).toList();
    final rest = teammates.length - shown.length;
    final slots = shown.length + (rest > 0 ? 1 : 0);
    return SizedBox(
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final (i, m) in shown.indexed)
            Positioned(
              left: step * i,
              child: _MemberAvatar(member: m, ring: ring, onOpen: onOpen),
            ),
          if (rest > 0)
            Positioned(
              left: step * shown.length,
              child: AgentAvatar('+$rest', size: size, ring: ring),
            ),
          // Reserve the row's width so the card does not jump as heads arrive.
          Positioned.fill(
            left: step * slots,
            child: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.member, required this.ring, required this.onOpen});

  final ({String id, String name, bool working, bool openable}) member;
  final Color ring;
  final void Function(String sessionId) onOpen;

  @override
  Widget build(BuildContext context) {
    const size = AgentTeamsInlineCard.avatarSize;
    final avatar = AgentAvatar(member.name, size: size, ring: ring);
    return Semantics(
      button: member.openable,
      label: member.name,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: member.openable ? () => onOpen(member.id) : null,
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              avatar,
              if (member.working)
                const Positioned(
                  right: -1,
                  bottom: -1,
                  child: StatusDot(tone: StatusTone.busy, size: 7),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
