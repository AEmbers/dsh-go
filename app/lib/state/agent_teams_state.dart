// `@nanmicoder/dsh-agent-teams` — the team the plugin actually runs, read from
// `/plugins/dsh-agent-teams/state`. See
// packages/dsh_client/lib/src/agent_teams_api.dart for the wire side.
//
// This is a different team from the one in `agents_state.dart`: that one reads
// the official experimental `agentTeam` projection off the Lead session and
// rides a live `session/control` feed, while this plugin has no push channel at
// all and serves one conditional GET. So the shape here is a poll that carries
// its ETag — a read that comes back 304 changes nothing and costs one small
// request — and the beat speeds up while a plan waits for review or a team
// runs. A host without the plugin answers 404, which is "absent", not an error.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'plugins_state.dart';

/// The bundle that serves the team endpoints.
const agentTeamsBundleName = '@nanmicoder/dsh-agent-teams';

/// Beat while a team is staged for review or running.
const agentTeamsPollLive = Duration(seconds: 2);

/// Beat when every team on the host is parked (archived), so an idle app is quiet.
const agentTeamsPollIdle = Duration(seconds: 10);

/// Budget of one `/state` read.
const agentTeamsReadTimeout = Duration(seconds: 15);

/// The plugin as the host installed it; null while unknown or not offered.
final agentTeamsPluginProvider = Provider<AsyncValue<PluginBundle?>>((ref) {
  return ref
      .watch(installedPluginsProvider)
      .whenData((bundles) => bundles?.where((b) => b.name == agentTeamsBundleName).firstOrNull);
});

/// Every team the plugin keeps for the active host.
///
/// `AsyncData(null)` means the host does not serve the plugin at all (404).
class AgentTeamsController extends Notifier<AsyncValue<AgentTeamsState?>> {
  Timer? _poll;

  /// The ETag belongs to [ _owner ]'s `/state`; a new host starts without one.
  String? _etag;

  /// Read freshness within the current host: only the latest `_read` writes.
  int _ticket = 0;

  /// The host these callbacks belong to; a rebuilt controller reads another.
  DshClient? _owner;

  /// Bumped by every [build] and never reset, so a value is never reused: an
  /// old reply carrying `generation == _generation` cannot be a stale one.
  int _generation = 0;
  bool _disposed = false;

  /// Whether [client] may still write: the same host [build] wired, and the
  /// generation [build] handed out is still the current one.
  bool _live(DshClient client, int generation) =>
      !_disposed && generation == _generation && identical(client, _owner);

  @override
  AsyncValue<AgentTeamsState?> build() {
    _poll?.cancel();
    _poll = null;
    _etag = null;
    // Never reset `_ticket`: a fresh host must not make an old ticket current
    // again. The generation, bumped here and monotonic for the controller's
    // life, is what retires every callback of the host [build] is leaving.
    final generation = ++_generation;
    _disposed = false;
    final conn = ref.watch(activeConnectionProvider).value;
    _owner = conn?.client;
    ref.onDispose(() {
      _disposed = true;
      _poll?.cancel();
      _poll = null;
    });
    if (conn == null) return const AsyncData(null);
    unawaited(_read(conn.client, generation));
    return const AsyncLoading();
  }

  /// Re-reads now: pull to refresh, after a mutation, when the page reopens.
  Future<void> refresh() async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    await _read(client, _generation);
  }

  Future<void> _read(DshClient client, int generation) async {
    // A later read or mutation makes this reply worthless; the ticket says so,
    // and the generation says the host itself was not replaced.
    final ticket = ++_ticket;
    bool stale() => !_live(client, generation) || ticket != _ticket;
    try {
      final next = await client.readAgentTeams(ifNoneMatch: _etag, timeout: agentTeamsReadTimeout);
      if (stale()) return;
      if (next != null) {
        _etag = next.etag;
        state = AsyncData(next);
      } else if (!state.hasValue) {
        // 304 with nothing cached cannot happen, but stay defined anyway.
        state = const AsyncData(AgentTeamsState.empty);
      }
      _schedule(client, generation);
    } on AgentTeamsUnavailableException {
      if (stale()) return;
      _etag = null;
      _poll?.cancel();
      state = const AsyncData(null);
    } catch (error, stack) {
      if (stale()) return;
      if (!state.hasValue) state = AsyncError(error, stack);
      _schedule(client, generation);
    }
  }

  void _schedule(DshClient client, int generation) {
    _poll?.cancel();
    if (!_live(client, generation)) return;
    final teams = state.value?.teams ?? const <AgentTeamSnapshot>[];
    final live = teams.any((t) => t.phase != TeamPhase.archived);
    _poll = Timer(live ? agentTeamsPollLive : agentTeamsPollIdle, () {
      if (!_live(client, generation)) return;
      unawaited(_read(client, generation));
    });
  }
}

final agentTeamsProvider =
    NotifierProvider.autoDispose<AgentTeamsController, AsyncValue<AgentTeamsState?>>(AgentTeamsController.new);

/// One team of the active host by id; null while unknown.
final agentTeamProvider = Provider.autoDispose.family<AgentTeamSnapshot?, String>(
  (ref, teamId) => ref.watch(agentTeamsProvider).value?.byId(teamId),
);

/// The team whose captain is [sessionId], for the chat that session belongs to.
final sessionAgentTeamProvider = Provider.autoDispose.family<AgentTeamSnapshot?, String>(
  (ref, sessionId) => ref.watch(agentTeamsProvider).value?.forCaptain(sessionId),
);

/// Why a halt or a plan edit did not land, as a branch the page translates.
enum AgentTeamsActionError {
  /// The host stopped serving the plugin.
  unavailable,

  /// The captain session is not attached to that team.
  captainDetached,

  /// The team belongs to another captain.
  teamMissing,

  /// The plugin refused the mutation; its own words are in the detail.
  rejected,

  /// Transport, a 500, an unreadable reply.
  failed,
}

/// One halt or plan edit in flight, plus the last failure, so the page can
/// disable its own controls and keep a message under the right team.
class AgentTeamsActionState {
  const AgentTeamsActionState({this.busyTeamId, this.action, this.failedTeamId, this.error, this.detail});

  /// Team whose control is spinning; null when nothing runs.
  final String? busyTeamId;

  /// The plan action being applied; null for a halt.
  final AgentTeamPlanAction? action;

  /// Team whose last action failed; cleared by [AgentTeamsActionController.dismiss].
  final String? failedTeamId;

  final AgentTeamsActionError? error;

  /// The plugin's own words, when it gave any.
  final String? detail;

  bool get busy => busyTeamId != null;

  bool isBusyOn(String teamId) => busyTeamId == teamId;

  bool failedOn(String teamId) => error != null && failedTeamId == teamId;
}

/// Drives `POST /halt` and `POST /plan` and re-reads the snapshot after each.
class AgentTeamsActionController extends Notifier<AgentTeamsActionState> {
  /// The Host this controller's spinner and failure belong to.
  DshClient? _owner;

  /// Whether [client] may still write. Identity is the whole test: a halt or a
  /// plan is answered by the Host it was sent to, so a reply from any other
  /// client — the Host being left, or a reconnect that replaced it — has
  /// nothing to say about the team on screen.
  bool _live(DshClient client) => ref.mounted && identical(client, _owner);

  @override
  AgentTeamsActionState build() {
    // A halt or a plan belongs to one Host: its spinner names a team that Host
    // serves, and its failure is about that team. Watching the connection is
    // what re-points this controller when the switcher moves, so the spinner of
    // the Host being left cannot spin over the new one.
    _owner = ref.watch(activeConnectionProvider).value?.client;
    return const AgentTeamsActionState();
  }

  /// Stops every member of [teamId]; the team itself stays where it is.
  Future<bool> halt({required String sessionId, required String teamId}) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return false;
    state = AgentTeamsActionState(busyTeamId: teamId);
    try {
      await client.haltAgentTeam(sessionId: sessionId, teamId: teamId, timeout: agentTeamsReadTimeout);
      if (!_live(client)) return false;
      _settle();
      return true;
    } catch (error) {
      // A Host that was left mid-request answers late; its failure is not the
      // new Host's problem, and the page it would draw over is already gone.
      if (_live(client)) _fail(teamId, error);
      return false;
    }
  }

  /// Applies one plan edit: `approve` and `continue` start work, the other four
  /// change the staged graph, `discard` archives the team.
  Future<bool> plan({
    required String sessionId,
    required String teamId,
    required AgentTeamPlanAction action,
    Map<String, Object?> fields = const {},
  }) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return false;
    state = AgentTeamsActionState(busyTeamId: teamId, action: action);
    try {
      await client.planAgentTeam(
        sessionId: sessionId,
        teamId: teamId,
        action: action,
        fields: fields,
        timeout: agentTeamsReadTimeout,
      );
      if (!_live(client)) return false;
      _settle();
      return true;
    } catch (error) {
      if (_live(client)) _fail(teamId, error, action: action);
      return false;
    }
  }

  /// Drops the message of the last failure.
  void dismiss() => state = const AgentTeamsActionState();

  void _settle() {
    if (!ref.mounted) return;
    state = const AgentTeamsActionState();
    // The reply carries the new phase, but members and tasks are only whole in
    // the snapshot, so re-read instead of merging a partial reply.
    unawaited(ref.read(agentTeamsProvider.notifier).refresh());
  }

  void _fail(String teamId, Object error, {AgentTeamPlanAction? action}) {
    // The team page can be gone while its request is still in flight; a reply
    // for a closed panel has nowhere to land.
    if (!ref.mounted) return;
    final (kind, detail) = switch (error) {
      AgentTeamsUnavailableException() => (AgentTeamsActionError.unavailable, null),
      AgentTeamsCaptainDetachedException() => (AgentTeamsActionError.captainDetached, null),
      AgentTeamsTeamNotFoundException() => (AgentTeamsActionError.teamMissing, null),
      AgentTeamsPlanRejectedException(:final message) => (AgentTeamsActionError.rejected, message),
      DshException(:final message) => (AgentTeamsActionError.failed, message),
      _ => (AgentTeamsActionError.failed, null),
    };
    state = AgentTeamsActionState(failedTeamId: teamId, action: action, error: kind, detail: detail);
  }
}

final agentTeamsActionProvider =
    NotifierProvider.autoDispose<AgentTeamsActionController, AgentTeamsActionState>(AgentTeamsActionController.new);

/// The captain's chat id for a team, so its rows open the right conversation.
String? agentTeamCaptainSession(AgentTeamSnapshot team) =>
    team.captainSessionId.isEmpty ? null : team.captainSessionId;
