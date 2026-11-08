/// `@nanmicoder/dsh-agent-teams` — the team activity channel of a dsh-go Host.
///
/// The plugin owns its own state files and serves them through three Fetch
/// routes registered by `dsh-agent-teams/lib/index.js`:
///
/// * `GET  /plugins/dsh-agent-teams/state`   (`:185`) — every live team under
///   the workspace state roots, or one captain's teams with `?session=`, or
///   the archived ones with `?archived=1`, without editor-only text with
///   `?summary=1`. Answered with a strong `ETag`; a second read with
///   `if-none-match` answers `304`.
/// * `POST /plugins/dsh-agent-teams/halt`    (`:205`) — `{sessionId, teamId}`.
/// * `POST /plugins/dsh-agent-teams/plan`    (`:261`) — `{sessionId, teamId,
///   action, …}` for the seven staged-plan actions.
///
/// This is **not** the official experimental Agent Teams bundle
/// (`@deepseek-ai/dsh-experimental-agent-team-profile`), whose roster arrives
/// as an `agentTeam` projection with `phase` / `ownerName` / `blockedBy`.
/// The nanmicoder snapshot carries `activity` / `assignee` / `dependencies` /
/// `depth` / `progress` / `unread` / `delivery` / `loopState` / `captainInbox`
/// instead, so the two models stay separate: [TeamSnapshot] in agents_api.dart
/// keeps serving the projection, this file serves the route.
///
/// Refusals are an HTTP status and a `{error}` string (the routes answer
/// `text`-only errors, not codes): `400` a malformed body, `404` a team that
/// does not belong to that captain, `405` a non-POST, `409` a captain session
/// that is not attached (halt/plan) or a rejected plan mutation, `429` too many
/// event streams. A `404` on the state route itself means the plugin is not
/// installed or not enabled, which is not the same as an empty team list.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

const agentTeamsStatePath = '/plugins/dsh-agent-teams/state';
const agentTeamsHaltPath = '/plugins/dsh-agent-teams/halt';
const agentTeamsPlanPath = '/plugins/dsh-agent-teams/plan';

const _maxReplyBytes = 256 * 1024;

// -----------------------------------------------------------------------------
// Vocabulary
// -----------------------------------------------------------------------------

/// `phase` of a durable team record.
enum TeamPhase {
  staged('staged'),
  running('running'),

  /// Not sent by `/state` (the route only lists live teams and, with
  /// `archived=1`, archived ones) but returned by the `discard` plan action.
  archived('archived'),
  unknown('');

  const TeamPhase(this.wire);
  final String wire;

  static TeamPhase parse(Object? value) =>
      values.firstWhere((p) => p.wire == value, orElse: () => TeamPhase.unknown);

  /// A staged team waits for `approve` / `continue` / `discard`.
  bool get isStaged => this == TeamPhase.staged;
}

/// Where a staged plan stands.
enum PlanReviewState {
  awaitingReview('awaiting_review'),
  awaitingFeedback('awaiting_feedback'),
  none('');

  const PlanReviewState(this.wire);
  final String wire;

  static PlanReviewState parse(Object? value) =>
      values.firstWhere((p) => p.wire == value, orElse: () => PlanReviewState.none);
}

/// A member's live activity (`activity`), as the plugin reads it from the
/// subagent surface.
enum TeamActivity {
  working('working'),
  idle('idle'),

  /// The member has no subagent session the host can see (removed, archived,
  /// or never provisioned).
  unknown('unknown');

  const TeamActivity(this.wire);
  final String wire;

  static TeamActivity parse(Object? value) =>
      values.firstWhere((a) => a.wire == value, orElse: () => TeamActivity.unknown);
}

/// `state` of a task row — the *visual* state the plugin computed with
/// `taskVisualState(status, dependencies, tasks)`, not the raw `status`.
enum TeamTaskState {
  completed('completed'),
  failed('failed'),
  cancelled('cancelled'),
  running('running'),
  claimed('claimed'),

  /// Pending with at least one dependency not completed.
  blocked('blocked'),

  /// Pending and every dependency completed: claimable now.
  open('open'),
  unknown('');

  const TeamTaskState(this.wire);
  final String wire;

  static TeamTaskState parse(Object? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => TeamTaskState.unknown);

  bool get isTerminal => this == completed || this == failed || this == cancelled;
}

/// `loopState.state` from `describeQualityLoop`.
enum TeamLoopState {
  halted('halted'),
  deliverable('deliverable'),
  escalated('escalated'),
  running('running'),
  blocked('blocked'),
  unknown('');

  const TeamLoopState(this.wire);
  final String wire;

  static TeamLoopState parse(Object? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => TeamLoopState.unknown);
}

// -----------------------------------------------------------------------------
// Models
// -----------------------------------------------------------------------------

/// `delivery: {ok, blockers, warnings}` — the same conclusion the
/// `agent_teams_status` tool reaches, audited against the current workspace
/// bytes rather than the task records alone.
class TeamDelivery {
  const TeamDelivery({required this.ok, this.blockers = const [], this.warnings = const []});

  static TeamDelivery? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return TeamDelivery(
      ok: map['ok'] == true,
      blockers: asStringList(map['blockers']),
      warnings: asStringList(map['warnings']),
    );
  }

  final bool ok;
  final List<String> blockers;
  final List<String> warnings;
}

/// One `captainInbox` row: mail the captain has not read yet (the last five).
class TeamInboxMessage {
  const TeamInboxMessage({required this.from, required this.content});

  static TeamInboxMessage? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final from = asString(map['from']);
    final content = asString(map['content']);
    if (from == null && content == null) return null;
    return TeamInboxMessage(from: from ?? '', content: content ?? '');
  }

  final String from;
  final String content;
}

/// One roster row of a `/state` snapshot.
class TeamActivityMember {
  const TeamActivityMember({
    required this.id,
    required this.name,
    this.role = '',
    this.provider = '',
    this.model = '',
    this.reasoningEffort = '',
    this.executionPrompt,
    this.status = '',
    this.activity = TeamActivity.unknown,
    this.progress = 0,
    this.done = 0,
    this.total = 0,
    this.currentTask = '',
    this.unread = 0,
  });

  static TeamActivityMember? fromJson(Object? json) {
    final map = asMap(json);
    final name = asString(map?['name']);
    if (map == null || name == null || name.isEmpty) return null;
    return TeamActivityMember(
      id: asString(map['id']) ?? '',
      name: name,
      role: asString(map['role']) ?? '',
      provider: asString(map['provider']) ?? '',
      model: asString(map['model']) ?? '',
      reasoningEffort: asString(map['reasoningEffort']) ?? '',
      executionPrompt: asString(map['executionPrompt']),
      status: asString(map['status']) ?? '',
      activity: TeamActivity.parse(map['activity']),
      progress: asInt(map['progress']) ?? 0,
      done: asInt(map['done']) ?? 0,
      total: asInt(map['total']) ?? 0,
      currentTask: asString(map['currentTask']) ?? '',
      unread: asInt(map['unread']) ?? 0,
    );
  }

  /// The member's Session id; empty for a row that never got one.
  final String id;

  /// The permanent lower-case name (`researcher`); the captain's is `captain`.
  final String name;
  final String role;

  /// `provider` and `model` as configured; [modelRoute] joins them.
  final String provider;
  final String model;
  final String reasoningEffort;

  /// Null only under `summary=1` for a running team (editor-only text).
  final String? executionPrompt;

  /// `active`, `removed`, `provisioning`, `failed`, …
  final String status;
  final TeamActivity activity;

  /// 0–100 over the tasks assigned to this member.
  final int progress;
  final int done;
  final int total;

  /// The member's first in-progress owned task id, else empty.
  final String currentTask;
  final int unread;

  /// `provider/model`, or just the model when no provider is set.
  String get modelRoute => provider.isNotEmpty && model.isNotEmpty ? '$provider/$model' : model;

  bool get working => activity == TeamActivity.working;
  bool get removed => status == 'removed';

  /// A member can be opened only when it has a session to open.
  bool get openable => id.isNotEmpty && !removed;
}

/// One task row. `state` is the visual state; `status` the durable one.
class TeamActivityTask {
  const TeamActivityTask({
    required this.id,
    required this.subject,
    this.description,
    this.status = '',
    this.state = TeamTaskState.unknown,
    this.assignee = '',
    this.model = '',
    this.dependencies = const [],
    this.depth = 0,
    this.kind,
    this.round,
    this.verdict,
    this.verdictStale,
    this.updatedAt,
  });

  static TeamActivityTask? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    if (map == null || id == null || id.isEmpty) return null;
    return TeamActivityTask(
      id: id,
      subject: asString(map['subject']) ?? id,
      description: asString(map['description']),
      status: asString(map['status']) ?? '',
      state: TeamTaskState.parse(map['state']),
      assignee: asString(map['assignee']) ?? '',
      model: asString(map['model']) ?? '',
      dependencies: asStringList(map['dependencies']),
      depth: asInt(map['depth']) ?? 0,
      kind: asString(map['kind']),
      round: asInt(map['round']),
      verdict: asString(map['verdict']),
      verdictStale: asString(map['verdictStale']),
      updatedAt: asEpochMs(map['updatedAt']),
    );
  }

  final String id;
  final String subject;

  /// Null only under `summary=1` for a running team.
  final String? description;

  /// `pending` / `in_progress` / `completed` / `failed` / `cancelled` / `claimed`.
  final String status;
  final TeamTaskState state;
  final String assignee;

  /// The assignee's model route when the roster names it.
  final String model;
  final List<String> dependencies;

  /// Longest dependency path length: one lane column per depth.
  final int depth;

  /// Quality kinds: `requirements` / `implementation` / `verification` /
  /// `review` / `repair` / `integration`.
  final String? kind;

  /// 1-based review / requirements / repair round.
  final int? round;

  /// `pass` / `needs_revision` / `reject` on a judging task.
  final String? verdict;

  /// Set when the gate passed but the workspace changed afterwards, so the
  /// verdict no longer describes the current bytes.
  final String? verdictStale;

  final DateTime? updatedAt;

  bool get isQualityKind => kind != null && kind!.isNotEmpty;
  bool get stale => verdictStale != null && verdictStale!.isNotEmpty;
}

/// One team of `GET /plugins/dsh-agent-teams/state`.
class AgentTeamSnapshot {
  const AgentTeamSnapshot({
    required this.teamId,
    required this.name,
    required this.captainSessionId,
    this.workspace = '',
    this.workspacePath,
    this.description,
    this.phase = TeamPhase.unknown,
    this.planReviewState = PlanReviewState.none,
    this.halted = false,
    this.loopState,
    this.deliverable,
    this.delivery,
    this.members = const [],
    this.tasks = const [],
    this.messageCount = 0,
    this.captainInbox = const [],
    this.archived = false,
  });

  static AgentTeamSnapshot? fromJson(Object? json, {bool archived = false}) {
    final map = asMap(json);
    final teamId = asString(map?['teamId']);
    if (map == null || teamId == null || teamId.isEmpty) return null;
    return AgentTeamSnapshot(
      teamId: teamId,
      name: asString(map['name']) ?? teamId,
      captainSessionId: asString(map['captainSessionId']) ?? '',
      workspace: asString(map['workspace']) ?? '',
      workspacePath: asString(map['workspacePath']),
      description: asString(map['description']),
      phase: TeamPhase.parse(map['phase']),
      planReviewState: PlanReviewState.parse(map['planReviewState']),
      halted: map['halted'] == true,
      loopState: map['loopState'] == null ? null : TeamLoopState.parse(map['loopState']),
      deliverable: map['deliverable'] == null ? null : map['deliverable'] == true,
      delivery: TeamDelivery.fromJson(map['delivery']),
      members: [for (final m in asListOrEmpty(map['members'])) ?TeamActivityMember.fromJson(m)],
      tasks: [for (final t in asListOrEmpty(map['tasks'])) ?TeamActivityTask.fromJson(t)],
      messageCount: asInt(map['messageCount']) ?? 0,
      captainInbox: [for (final m in asListOrEmpty(map['captainInbox'])) ?TeamInboxMessage.fromJson(m)],
      archived: archived,
    );
  }

  final String teamId;
  final String name;
  final String captainSessionId;

  /// The owning workspace's display title, and its absolute path (the route
  /// sends both; the path is what the auditor read).
  final String workspace;
  final String? workspacePath;

  /// Present unless `summary=1` dropped it for a running team.
  final String? description;

  final TeamPhase phase;
  final PlanReviewState planReviewState;

  /// The human stopped the team: further work needs `agent_teams_resume`.
  final bool halted;

  /// Only sent when the route could audit the workspace.
  final TeamLoopState? loopState;
  final bool? deliverable;
  final TeamDelivery? delivery;

  final List<TeamActivityMember> members;
  final List<TeamActivityTask> tasks;

  /// Unread mail across the captain and every member.
  final int messageCount;
  final List<TeamInboxMessage> captainInbox;

  /// Read through `?archived=1`: a team moved to `archive/`, activity forced
  /// to `idle`.
  final bool archived;

  /// A staged team can be approved, continued or discarded.
  bool get staged => phase.isStaged;

  /// Members other than the captain.
  List<TeamActivityMember> get teammates => [
    for (final m in members)
      if (m.name != 'captain') m,
  ];

  TeamActivityMember? get captain =>
      members.where((m) => m.name == 'captain').firstOrNull;

  int get workingCount => members.where((m) => m.working).length;

  int get openTasks => tasks.where((t) => !t.state.isTerminal).length;

  /// Highest `depth` present, i.e. the number of DAG lanes.
  int get lanes => tasks.fold<int>(0, (max, t) => t.depth + 1 > max ? t.depth + 1 : max);

  /// Tasks of one lane, in the order the plugin sent them.
  List<TeamActivityTask> lane(int depth) => [
    for (final t in tasks)
      if (t.depth == depth) t,
  ];

  /// Whether [ok] may be reported as delivered, as the panel concludes it.
  bool get canDeclareDelivery => delivery?.ok ?? false;
}

/// The whole answer of the state route.
class AgentTeamsState {
  const AgentTeamsState({this.teams = const [], this.etag});

  static const empty = AgentTeamsState();

  static AgentTeamsState? fromJson(Object? json, {String? etag, bool archived = false}) {
    final map = asMap(json);
    if (map == null) return null;
    return AgentTeamsState(
      teams: [for (final t in asListOrEmpty(map['teams'])) ?AgentTeamSnapshot.fromJson(t, archived: archived)],
      etag: etag,
    );
  }

  final List<AgentTeamSnapshot> teams;

  /// The strong validator the next read may send as `if-none-match`.
  final String? etag;

  bool get isEmpty => teams.isEmpty;

  AgentTeamSnapshot? byId(String teamId) => teams.where((t) => t.teamId == teamId).firstOrNull;

  /// The team whose captain is [sessionId]; falls back to the only team when a
  /// member session asks (members are not captains).
  AgentTeamSnapshot? forCaptain(String sessionId) =>
      teams.where((t) => t.captainSessionId == sessionId).firstOrNull ??
      (teams.length == 1 ? teams.first : null);
}

/// Result of `POST /halt`.
class AgentTeamHaltResult {
  const AgentTeamHaltResult({this.ok = true, this.raw = const {}});

  final bool ok;
  final JsonMap raw;
}

/// Result of `POST /plan`.
class AgentTeamPlanResult {
  const AgentTeamPlanResult({this.ok = true, this.phase, this.members, this.tasks, this.raw = const {}});

  final bool ok;

  /// The phase the route reported: `running` after `approve`, `staged` after
  /// `continue`, `archived` after `discard`, else unchanged.
  final TeamPhase? phase;

  /// Roster and task counts (`update_member` / `update_task` / `add_task` /
  /// `remove_task` answer with counts, not with the plan).
  final int? members;
  final int? tasks;

  final JsonMap raw;
}

// -----------------------------------------------------------------------------
// The seven staged-plan actions
// -----------------------------------------------------------------------------

/// One `POST /plan` action. [body] adds the action-specific fields the route
/// validates: `update_member` needs `memberName` + `provider` + `model`,
/// `update_task` needs `taskId` + `subject`, `add_task` needs `subject`,
/// `remove_task` needs `taskId`.
enum AgentTeamPlanAction {
  /// Commit the staged plan and start work. The route also steers the captain
  /// so the model learns about the approval; a failed steer never fails the
  /// approval.
  approve('approve'),
  continuePlanning('continue'),

  /// Move the staged team to `archive/`.
  discard('discard'),
  updateMember('update_member'),
  updateTask('update_task'),
  addTask('add_task'),
  removeTask('remove_task');

  const AgentTeamPlanAction(this.wire);
  final String wire;

  /// The actions only a staged team accepts.
  bool get requiresStaged =>
      this == approve || this == continuePlanning || this == discard;
}

// -----------------------------------------------------------------------------
// The client
// -----------------------------------------------------------------------------

extension AgentTeamsApi on DshClient {
  /// `GET /plugins/dsh-agent-teams/state`.
  ///
  /// [captainSessionId] narrows to one captain's teams, [archived] reads the
  /// archived ones, [summary] drops editor-only text from running teams.
  ///
  /// The route answers a strong `ETag`; passing it back as [ifNoneMatch] turns
  /// an unchanged list into a `null` result without a payload. The read is not
  /// through [DshConnection.get] because the reply's `ETag` has to survive:
  /// [DshHttpResponse] carries the body and the cookies, not the headers, and
  /// an `ETag` read back through it would be lost.
  ///
  /// Throws [AgentTeamsUnavailableException] when the route is missing.
  Future<AgentTeamsState?> readAgentTeams({
    String? captainSessionId,
    bool archived = false,
    bool summary = false,
    String? ifNoneMatch,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final connection = _agentTeamsConnection(agentTeamsStatePath);
    final query = <String, String>{
      if (captainSessionId != null && captainSessionId.isNotEmpty) 'session': captainSessionId,
      if (archived) 'archived': '1',
      if (summary) 'summary': '1',
    };
    final response = await _conditionalGet(
      connection,
      connection.resolve(agentTeamsStatePath, query.isEmpty ? null : query),
      ifNoneMatch: ifNoneMatch,
      maxBytes: _maxReplyBytes,
      timeout: timeout,
    );
    if (response.statusCode == 304) return null;
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501) {
      throw const AgentTeamsUnavailableException();
    }
    if (response.statusCode != 200) {
      throw _agentTeamsHttpError(agentTeamsStatePath, response.statusCode, response.text);
    }
    final body = asMap(tryDecodeJson(response.text));
    final state = AgentTeamsState.fromJson(body, etag: response.etag, archived: archived);
    if (state == null) throw const DshProtocolException('agent-teams state: not a team list');
    return state;
  }

  /// `POST /plugins/dsh-agent-teams/halt`: stops every running member of one
  /// team. A captain session that is no longer attached is
  /// [AgentTeamsCaptainDetachedException]; a team that is not that captain's is
  /// [AgentTeamsTeamNotFoundException].
  Future<AgentTeamHaltResult> haltAgentTeam({
    required String sessionId,
    required String teamId,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _requireId(sessionId, 'sessionId');
    _requireId(teamId, 'teamId');
    final response = await _agentTeamsConnection(agentTeamsHaltPath).postBytes(
      agentTeamsHaltPath,
      utf8.encode(jsonEncode({'sessionId': sessionId, 'teamId': teamId})),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxReplyBytes,
      timeout: timeout,
    );
    final body = asMap(tryDecodeJson(response.text));
    if (response.statusCode != 200) {
      throw _agentTeamsHttpError(agentTeamsHaltPath, response.statusCode, response.text);
    }
    return AgentTeamHaltResult(ok: body?['ok'] != false, raw: body ?? const {});
  }

  /// `POST /plugins/dsh-agent-teams/plan`: the staged-plan actions.
  ///
  /// [fields] carries the action-specific payload (`memberName`, `provider`,
  /// `model`, `role`, `reasoningEffort`, `executionPrompt`, `tool_policy`,
  /// `taskId`, `subject`, `description`, `assignee`, `dependencies`). A
  /// rejected mutation is [AgentTeamsPlanRejectedException] with the route's
  /// own message.
  Future<AgentTeamPlanResult> planAgentTeam({
    required String sessionId,
    required String teamId,
    required AgentTeamPlanAction action,
    Map<String, Object?> fields = const {},
    Duration timeout = const Duration(seconds: 60),
  }) async {
    _requireId(sessionId, 'sessionId');
    _requireId(teamId, 'teamId');
    final body = <String, Object?>{
      'sessionId': sessionId,
      'teamId': teamId,
      'action': action.wire,
      for (final entry in fields.entries)
        if (entry.value != null) entry.key: entry.value,
    };
    final response = await _agentTeamsConnection(agentTeamsPlanPath).postBytes(
      agentTeamsPlanPath,
      utf8.encode(jsonEncode(body)),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxReplyBytes,
      timeout: timeout,
    );
    final decoded = asMap(tryDecodeJson(response.text));
    if (response.statusCode != 200) {
      throw _agentTeamsHttpError(agentTeamsPlanPath, response.statusCode, response.text, plan: true);
    }
    return AgentTeamPlanResult(
      ok: decoded?['ok'] != false,
      phase: decoded?['phase'] == null ? null : TeamPhase.parse(decoded!['phase']),
      members: asInt(decoded?['members']),
      tasks: asInt(decoded?['tasks']),
      raw: decoded ?? const {},
    );
  }

  DshConnection _agentTeamsConnection(String path) {
    final carrier = this.carrier;
    if (carrier is! DshHttpCarrier) {
      throw DshRemoteException(
        'agent-teams/unsupported',
        'this connection cannot reach the agent-teams route',
        {'path': path},
      );
    }
    return carrier.connection;
  }
}

void _requireId(String value, String name) {
  if (value.isEmpty || value.length > 256 || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw ArgumentError.value(value, name);
  }
}

// -----------------------------------------------------------------------------
// A conditional GET that keeps the validators
// -----------------------------------------------------------------------------

/// One reply with the headers the parsers need and [DshHttpResponse] drops.
class _EtagedResponse {
  const _EtagedResponse(this.statusCode, this.body, {this.etag, this.contentType = ''});

  final int statusCode;
  final Uint8List body;

  /// The `ETag` the next conditional read may send back, quotes included.
  final String? etag;
  final String contentType;

  String get text => utf8.decode(body, allowMalformed: true);
}

/// `GET [uri]` on a client of its own, forwarding the Host fence headers and
/// the cookie, and returning the `ETag` along with the body.
///
/// It mirrors [DshConnection.get]'s fence handling (Host override, cookie, no
/// redirects) because that call discards the response headers.
Future<_EtagedResponse> _conditionalGet(
  DshConnection connection,
  Uri uri, {
  String? ifNoneMatch,
  required int maxBytes,
  required Duration timeout,
}) async {
  final http = HttpClient()
    ..connectionTimeout = connection.connectTimeout
    ..autoUncompress = true;
  HttpClientRequest? request;
  try {
    request = await http.openUrl('GET', uri);
    final req = request;
    req.followRedirects = false;
    if (connection.hostHeader case final host?) {
      final parsed = Uri.tryParse('http://$host');
      if (parsed == null || parsed.host.isEmpty) {
        throw ArgumentError.value(host, 'hostHeader', 'expected host or host:port');
      }
      req.headers.host = parsed.host;
      req.headers.port = parsed.hasPort ? parsed.port : 80;
    }
    if (connection.cookie case final cookie?) {
      req.headers.set(HttpHeaders.cookieHeader, cookie.header);
    }
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (ifNoneMatch != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, ifNoneMatch);
    final response = await req.close().timeout(timeout);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      if (builder.length + chunk.length > maxBytes) {
        throw DshProtocolException('GET ${uri.path}: response exceeds $maxBytes bytes');
      }
      builder.add(chunk);
    }
    // A 304 carries no body and no need to spend anything else on it.
    final type = response.headers.contentType;
    return _EtagedResponse(
      response.statusCode,
      builder.takeBytes(),
      etag: response.headers.value(HttpHeaders.etagHeader),
      contentType: type == null ? '' : '${type.primaryType}/${type.subType}'.toLowerCase(),
    );
  } on TimeoutException catch (error) {
    request?.abort(error);
    throw DshTransportException('GET ${uri.path} timed out', error);
  } on SocketException catch (error) {
    throw DshTransportException('GET ${uri.path} failed: ${error.message}', error);
  } on HandshakeException catch (error) {
    throw DshTransportException('TLS handshake failed: ${error.message}', error);
  } finally {
    http.close(force: true);
  }
}

// -----------------------------------------------------------------------------
// Failures
// -----------------------------------------------------------------------------

/// The route is not there: the plugin is not installed, not enabled, or the
/// host predates it. Distinct from an empty team list.
final class AgentTeamsUnavailableException extends DshException {
  const AgentTeamsUnavailableException() : super('agent-teams is not served by this host');
}

/// `409`: the captain session is not attached any more.
final class AgentTeamsCaptainDetachedException extends DshException {
  const AgentTeamsCaptainDetachedException() : super('the captain session is not attached');
}

/// `404`: the team is not that captain's (or is gone).
final class AgentTeamsTeamNotFoundException extends DshException {
  const AgentTeamsTeamNotFoundException() : super('this team does not belong to that captain');
}

/// `409` from `/plan`: the mutation was rejected, with the route's reason.
final class AgentTeamsPlanRejectedException extends DshException {
  const AgentTeamsPlanRejectedException(super.message);
}

DshException _agentTeamsHttpError(String path, int statusCode, String body, {bool plan = false}) {
  final error = asString(asMap(tryDecodeJson(body))?['error']);
  return switch (statusCode) {
    400 => AgentTeamsPlanRejectedException(error ?? 'bad request'),
    404 => const AgentTeamsTeamNotFoundException(),
    405 => DshHttpException(405, '$path: method not allowed', body: body),
    409 => plan
        ? AgentTeamsPlanRejectedException(error ?? 'plan operation rejected')
        : const AgentTeamsCaptainDetachedException(),
    429 => const DshRemoteException('agent-teams/rate-limited', 'too many requests'),
    503 => const AgentTeamsUnavailableException(),
    _ => DshHttpException(statusCode, '$path: HTTP $statusCode', body: body),
  };
}
