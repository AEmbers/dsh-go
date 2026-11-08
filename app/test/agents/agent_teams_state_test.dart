// `@nanmicoder/dsh-agent-teams` on the app side: the conditional poll that
// reads `/plugins/dsh-agent-teams/state`, the ETag it carries back, and the
// halt/plan actions that re-read the snapshot instead of merging a partial
// reply. The Host here is a real loopback `HttpServer`, because the read goes
// through an `HttpClient` of its own (the ETag has to survive, which
// `DshHttpResponse` cannot do) — a stubbed carrier never reaches it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/agent_teams_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Host that answers the three plugin routes.
class _TeamsHost {
  _TeamsHost(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  /// Paths the app asked for, newest last, each with its query and validators.
  final requests = <({String path, Map<String, String> query, String? ifNoneMatch})>[];

  /// What `/state` answers; changed between reads by a test.
  int stateStatus = 200;
  Map<String, Object?> stateBody = _stateJson();
  String? etag = '"state-1"';

  /// While set, `/state` is held at the Host: the app has a read in flight that
  /// only answers when the test says so. This is how a switch of host is made
  /// to race a reply of the host it is leaving.
  Completer<void>? holdState;

  /// What `/halt` and `/plan` answer.
  int actionStatus = 200;
  Map<String, Object?> actionBody = const {'ok': true};

  /// While set, `/halt` and `/plan` are held at the Host, the way [holdState]
  /// holds a read: this is how a write of the host being left is made to come
  /// back after the switch instead of beside it.
  Completer<void>? holdAction;

  /// The bodies the app posted to `/halt` and `/plan`, newest last.
  final posted = <({String path, Map<String, Object?> body})>[];

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  int get stateHits => requests.where((r) => r.path == agentTeamsStatePath).length;

  static Future<_TeamsHost> start() async => _TeamsHost(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final body = await utf8.decoder.bind(request).join();
    if (path == agentTeamsStatePath) {
      requests.add((
        path: path,
        query: request.uri.queryParameters,
        ifNoneMatch: request.headers.value(HttpHeaders.ifNoneMatchHeader),
      ));
      // A held read stays unanswered at the Host, so a test can bring up the
      // next Host and only then let the old reply land.
      if (holdState != null) await holdState!.future;
      final matches = etag != null && request.headers.value(HttpHeaders.ifNoneMatchHeader) == etag;
      if (matches && stateStatus == 200) {
        _write(request.response, 304, null);
        return;
      }
      _write(request.response, stateStatus, stateBody, etag: etag);
      return;
    }
    if (path == agentTeamsHaltPath || path == agentTeamsPlanPath) {
      posted.add((path: path, body: (jsonDecode(body) as Map).cast<String, Object?>()));
      if (holdAction != null) await holdAction!.future;
      _write(request.response, actionStatus, actionBody);
      return;
    }
    _write(request.response, 404, const {'error': 'no such route'});
  }

  void _write(HttpResponse response, int status, Map<String, Object?>? body, {String? etag}) {
    response.statusCode = status;
    response.headers.set('content-type', 'application/json; charset=utf-8');
    if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag);
    if (body != null) response.add(utf8.encode(jsonEncode(body)));
    unawaited(response.close());
  }
}

/// One running team: a captain, a reviewer and a member the profile removed,
/// over four tasks that cover every visual state and two DAG lanes.
Map<String, Object?> _stateJson({bool archived = false, String teamId = 'team-1', String name = '登录修复'}) => {
  'teams': [
    {
      'teamId': teamId,
      'name': name,
      'workspace': 'dsh-go',
      'workspacePath': '/w/dsh-go',
      'description': '修掉连点重复提交',
      'captainSessionId': 'session-captain',
      'phase': archived ? 'archived' : 'running',
      'archived': archived,
      'planReviewState': 'awaiting_review',
      'halted': false,
      'loopState': 'running',
      'deliverable': false,
      'delivery': {
        'ok': false,
        'blockers': ['task-3 未完成'],
        'warnings': ['task-2 改了两处'],
      },
      'messageCount': 4,
      'captainInbox': [
        {'from': 'reviewer', 'content': '复现了。'},
      ],
      'members': [
        {
          'id': 'session-captain',
          'name': 'captain',
          'role': 'captain',
          'provider': 'deepseek-official',
          'model': 'deepseek-v4-pro',
          'reasoningEffort': 'high',
          'status': 'running',
          'activity': 'working',
          'progress': 40,
          'done': 1,
          'total': 3,
          'currentTask': 'task-2',
          'unread': 1,
        },
        {
          'id': 'session-review',
          'name': 'reviewer',
          'role': 'reviewer',
          'provider': 'deepseek-official',
          'model': 'deepseek-v4-pro',
          'reasoningEffort': 'medium',
          'status': 'running',
          'activity': 'idle',
          'progress': 0,
          'done': 0,
          'total': 0,
          'currentTask': '',
          'unread': 0,
        },
        {
          'id': '',
          'name': 'tester',
          'role': 'tester',
          'status': 'removed',
          'activity': 'idle',
        },
      ],
      'tasks': [
        {
          'id': 'task-1',
          'subject': '复现连点',
          'description': '连点两次提交',
          'status': 'completed',
          'state': 'completed',
          'assignee': 'reviewer',
          'model': 'deepseek-v4-pro',
          'dependencies': [],
          'depth': 0,
          'updatedAt': 1761300000000,
        },
        {
          'id': 'task-2',
          'subject': '加防抖',
          'status': 'in_progress',
          'state': 'running',
          'assignee': 'captain',
          'dependencies': ['task-1'],
          'depth': 0,
          'kind': 'implementation',
        },
        {
          'id': 'task-3',
          'subject': '补组件测试',
          'status': 'pending',
          'state': 'blocked',
          'assignee': 'tester',
          'dependencies': ['task-2'],
          'depth': 1,
        },
        {
          'id': 'task-4',
          'subject': '更新说明',
          'status': 'pending',
          'state': 'open',
          'assignee': 'captain',
          'dependencies': [],
          'depth': 2,
          'kind': 'review',
          'round': 2,
          'verdict': 'pass',
          'verdictStale': 'task-2 改了两处',
        },
      ],
    },
  ],
};

/// The bundles the profile offers, without asking the Host.
class _Bundles extends InstalledPluginsController {
  _Bundles(this.bundles);

  final List<PluginBundle> bundles;

  @override
  Future<List<PluginBundle>?> build() async => bundles;

  @override
  Future<void> refresh() async {}
}

/// A real `HttpClient`: the flutter test binding replaces the default one with
/// a stub that answers 400 to everything, which would hide the route.
class _RealHttp extends HttpOverrides {}

/// Runs [body] with real sockets and a Host on loopback.
Future<void> _onHost(Future<void> Function(_TeamsHost host) body) =>
    HttpOverrides.runWithHttpOverrides(() async {
      final host = await _TeamsHost.start();
      try {
        await body(host);
      } finally {
        await host.close();
      }
    }, _RealHttp());

/// The host the app believes in, mutable so a test can do what the host
/// switcher does: point the connection at another `HttpServer` and let every
/// controller that watches it rebuild. A fixed `overrideWithValue` cannot show
/// this, and the whole point of the generation guard is what happens next.
class _ActiveHost extends Notifier<AsyncValue<HostConnection?>> {
  _ActiveHost(this._initial);

  final _TeamsHost? _initial;

  @override
  AsyncValue<HostConnection?> build() => _connection(_initial);

  void use(_TeamsHost? host) => state = _connection(host);

}

AsyncValue<HostConnection?> _connection(_TeamsHost? host) => AsyncData<HostConnection?>(
  host == null ? null : HostConnection(client: DshClient(DshConnection(host.baseUri)), isLocal: true),
);

final _activeHostProvider = NotifierProvider<_ActiveHost, AsyncValue<HostConnection?>>(() => _ActiveHost(null));

ProviderContainer _container({_TeamsHost? host, List<PluginBundle> bundles = const []}) {
  final container = ProviderContainer(
    overrides: [
      // Counted twice on purpose: the switch case re-points this provider, and
      // the controller has to follow it without keeping the old host's ETag.
      activeConnectionProvider.overrideWith((ref) => ref.watch(_activeHostProvider)),
      _activeHostProvider.overrideWith(() => _ActiveHost(host)),
      installedPluginsProvider.overrideWith(() => _Bundles(bundles)),
    ],
  );
  // The action provider is autoDispose: a page watches it while its request is
  // in flight, so the test holds the same subscription the page would.
  container.listen(agentTeamsActionProvider, (_, _) {});
  addTearDown(container.dispose);
  return container;
}

/// Keeps an auto-dispose provider alive and waits for [done].
Future<void> pumpUntil(bool Function() done, {String what = 'condition', Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('read', () {
    test('parses the whole snapshot and remembers the ETag', () => _onHost((host) async {
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).value?.teams.isNotEmpty ?? false, what: 'the team');

      final state = container.read(agentTeamsProvider).value!;
      expect(state.etag, '"state-1"');
      final team = state.teams.single;
      expect(team.teamId, 'team-1');
      expect(team.name, '登录修复');
      expect(team.captainSessionId, 'session-captain');
      expect(team.phase, TeamPhase.running);
      expect(team.planReviewState, PlanReviewState.awaitingReview);
      expect(team.halted, isFalse);
      expect(team.loopState, TeamLoopState.running);
      expect(team.deliverable, isFalse);
      expect(team.delivery!.ok, isFalse);
      expect(team.delivery!.blockers, ['task-3 未完成']);
      expect(team.messageCount, 4);
      expect(team.captainInbox.single.from, 'reviewer');
      expect(host.requests.single.query, isEmpty);
      expect(host.requests.single.ifNoneMatch, isNull);

      // The captain is one of the members, and the removed one is still listed
      // but cannot be opened.
      expect(team.captain?.name, 'captain');
      expect(team.teammates.map((m) => m.name), ['reviewer', 'tester']);
      expect(team.teammates.last.removed, isTrue);
      expect(team.teammates.last.openable, isFalse);
      expect(team.workingCount, 1);
      expect(team.openTasks, 3);
      expect(team.lanes, 3);
      expect(team.lane(0).map((t) => t.id), ['task-1', 'task-2']);
      expect(team.canDeclareDelivery, isFalse);
      expect(team.staged, isFalse);

      final reviewed = team.tasks.last;
      expect(reviewed.isQualityKind, isTrue);
      expect(reviewed.stale, isTrue);
      expect(reviewed.round, 2);
      expect(reviewed.verdict, 'pass');
      expect(reviewed.stale, isTrue);
      // Only the rows the plugin stamped carry a time; the rest stay null.
      expect(team.tasks.first.updatedAt, isNotNull);
      expect(reviewed.updatedAt, isNull);
    }));

    test('sends the ETag back and a 304 changes nothing', () => _onHost((host) async {
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).value != null, what: 'the first read');
      final before = container.read(agentTeamsProvider).value;

      await container.read(agentTeamsProvider.notifier).refresh();
      await pumpUntil(() => host.requests.length >= 2, what: 'the second read');

      expect(host.requests.last.ifNoneMatch, '"state-1"');
      expect(identical(container.read(agentTeamsProvider).value, before), isTrue);
    }));

    test('an archived phase reads as archived; the flag only tracks the query', () => _onHost((host) async {
      host.stateBody = _stateJson(archived: true);
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).value?.teams.isNotEmpty ?? false, what: 'the team');

      final team = container.read(agentTeamsProvider).value!.teams.single;
      expect(team.phase, TeamPhase.archived);
      // `archived` is the editor-only `?archived=1` read, not a payload field,
      // and the live list never asks for those.
      expect(team.archived, isFalse);
      expect(host.requests.single.query, isEmpty);
    }));

    test('a host without the plugin is absent, not broken', () => _onHost((host) async {
      host.stateStatus = 404;
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).hasValue, what: 'the absent answer');

      expect(container.read(agentTeamsProvider).value, isNull);
      expect(container.read(agentTeamsProvider).hasError, isFalse);
    }));

    test('a failing route keeps the last good snapshot and says so', () => _onHost((host) async {
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).value != null, what: 'the first read');

      host.stateStatus = 500;
      host.etag = null;
      await container.read(agentTeamsProvider.notifier).refresh();
      await pumpUntil(() => host.requests.length >= 2, what: 'the failing read');
      await pumpUntil(() => !container.read(agentTeamsProvider).isLoading, what: 'settling');

      final value = container.read(agentTeamsProvider);
      expect(value.hasError, isFalse, reason: 'a snapshot worth showing outlives one bad read');
      expect(value.value!.teams.single.teamId, 'team-1');
    }));

    test('a first read that fails is an error', () => _onHost((host) async {
      host.stateStatus = 500;
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).hasError, what: 'the failure');
    }));

    test('no connection is no team', () {
      final container = _container();
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      expect(container.read(agentTeamsProvider).value, isNull);
      expect(container.read(agentTeamsProvider).isLoading, isFalse);
    });
  });

  group('lookup', () {
    test('by id, and by captain with the only-team fallback', () => _onHost((host) async {
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).value != null, what: 'the read');

      expect(container.read(agentTeamProvider('team-1'))!.name, '登录修复');
      expect(container.read(agentTeamProvider('team-2')), isNull);
      expect(container.read(sessionAgentTeamProvider('session-captain'))!.teamId, 'team-1');
      // A member session is not a captain, so it gets the only team there is.
      expect(container.read(sessionAgentTeamProvider('session-review'))!.teamId, 'team-1');
    }));
  });

  group('plugin', () {
    test('is found by bundle name, and null when not installed', () async {
      final withBundle = ProviderContainer(
        overrides: [
          installedPluginsProvider.overrideWith(
            () => _Bundles(const [PluginBundle(name: agentTeamsBundleName, enabled: true)]),
          ),
        ],
      );
      addTearDown(withBundle.dispose);
      final sub = withBundle.listen(agentTeamsPluginProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => withBundle.read(agentTeamsPluginProvider).value != null, what: 'the bundle');
      expect(withBundle.read(agentTeamsPluginProvider).value!.enabled, isTrue);

      final without = ProviderContainer(
        overrides: [
          installedPluginsProvider.overrideWith(() => _Bundles(const [PluginBundle(name: 'dsh-voice-mode')])),
        ],
      );
      addTearDown(without.dispose);
      final other = without.listen(agentTeamsPluginProvider, (_, _) {});
      addTearDown(other.close);
      await pumpUntil(() => without.read(agentTeamsPluginProvider).hasValue, what: 'the empty profile');
      expect(without.read(agentTeamsPluginProvider).value, isNull);
    });
  });

  group('halt', () {
    test('posts the pair, clears the spinner and re-reads the snapshot', () => _onHost((host) async {
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).value != null, what: 'the read');
      final reads = host.stateHits;

      final ok = await container.read(agentTeamsActionProvider.notifier).halt(
        sessionId: 'session-captain',
        teamId: 'team-1',
      );

      expect(ok, isTrue);
      expect(host.posted.single.path, agentTeamsHaltPath);
      expect(host.posted.single.body, {'sessionId': 'session-captain', 'teamId': 'team-1'});
      final action = container.read(agentTeamsActionProvider);
      expect(action.busy, isFalse);
      expect(action.error, isNull);
      await pumpUntil(() => host.stateHits > reads, what: 'the re-read');
    }));

    test('a detached captain is its own branch, with no detail', () => _onHost((host) async {
      host.actionStatus = 409;
      final container = _container(host: host);
      final ok = await container.read(agentTeamsActionProvider.notifier).halt(
        sessionId: 'session-captain',
        teamId: 'team-1',
      );

      expect(ok, isFalse);
      final action = container.read(agentTeamsActionProvider);
      expect(action.error, AgentTeamsActionError.captainDetached);
      expect(action.failedOn('team-1'), isTrue);
      expect(action.isBusyOn('team-1'), isFalse);
      expect(action.detail, isNull);

      container.read(agentTeamsActionProvider.notifier).dismiss();
      expect(container.read(agentTeamsActionProvider).error, isNull);
      expect(container.read(agentTeamsActionProvider).failedOn('team-1'), isFalse);
    }));

    test('a mismatch team is missing, not detached', () => _onHost((host) async {
      host.actionStatus = 404;
      final container = _container(host: host);
      final ok = await container.read(agentTeamsActionProvider.notifier).halt(
        sessionId: 'session-captain',
        teamId: 'team-1',
      );
      expect(ok, isFalse);
      expect(container.read(agentTeamsActionProvider).error, AgentTeamsActionError.teamMissing);
    }));
  });

  group('plan', () {
    test('approve starts the team and refreshes', () => _onHost((host) async {
      host.actionBody = const {'ok': true, 'phase': 'running'};
      final container = _container(host: host);
      final sub = container.listen(agentTeamsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpUntil(() => container.read(agentTeamsProvider).value != null, what: 'the read');
      final reads = host.stateHits;

      final ok = await container.read(agentTeamsActionProvider.notifier).plan(
        sessionId: 'session-captain',
        teamId: 'team-1',
        action: AgentTeamPlanAction.approve,
      );

      expect(ok, isTrue);
      expect(host.posted.single.path, agentTeamsPlanPath);
      expect(host.posted.single.body, {
        'sessionId': 'session-captain',
        'teamId': 'team-1',
        'action': 'approve',
      });
      await pumpUntil(() => host.stateHits > reads, what: 'the re-read');
    }));

    test('a rejected edit keeps the route words', () => _onHost((host) async {
      host.actionStatus = 409;
      host.actionBody = const {'error': 'task-9 is not in the plan'};
      final container = _container(host: host);
      final ok = await container.read(agentTeamsActionProvider.notifier).plan(
        sessionId: 'session-captain',
        teamId: 'team-1',
        action: AgentTeamPlanAction.removeTask,
        fields: const {'taskId': 'task-9'},
      );

      expect(ok, isFalse);
      final action = container.read(agentTeamsActionProvider);
      expect(action.error, AgentTeamsActionError.rejected);
      expect(action.detail, 'task-9 is not in the plan');
      expect(action.action, AgentTeamPlanAction.removeTask);
      // The fields ride along, and a null one is dropped rather than sent.
      expect(host.posted.single.body['taskId'], 'task-9');
    }));

    test('a 500 is a plain failure, not a refusal', () => _onHost((host) async {
      host.actionStatus = 500;
      final container = _container(host: host);
      final ok = await container.read(agentTeamsActionProvider.notifier).plan(
        sessionId: 'session-captain',
        teamId: 'team-1',
        action: AgentTeamPlanAction.discard,
      );
      expect(ok, isFalse);
      expect(container.read(agentTeamsActionProvider).error, AgentTeamsActionError.failed);
    }));

    test('with no host nothing is sent', () async {
      final container = _container();
      expect(
        await container.read(agentTeamsActionProvider.notifier).halt(sessionId: 's', teamId: 't'),
        isFalse,
      );
      expect(container.read(agentTeamsActionProvider).busy, isFalse);
    });
  });

  group('host switch', () {
    test('a reply of the host being left cannot land on the new one', () async {
      // Two real Hosts: each can hold its own `/state` read, so the old reply is
      // made to arrive after the switch instead of beside it.
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _TeamsHost.start();
        final hostB = await _TeamsHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });
        hostA.stateBody = _stateJson(teamId: 'team-a', name: 'A 上的队');
        hostB.stateBody = _stateJson(teamId: 'team-b', name: 'B 上的队');
        // A answers only when the test lets it, and B answers at once.
        hostA.holdState = Completer<void>();

        final container = _container(host: hostA);
        final sub = container.listen(agentTeamsProvider, (_, _) {});
        addTearDown(sub.close);
        await pumpUntil(() => hostA.stateHits == 1, what: 'the first read');

        // The host switcher does this: one provider value changes, and the
        // controller rebuilds around the other Host.
        container.read(_activeHostProvider.notifier).use(hostB);
        // The switch is real on the provider the app actually reads, not just
        // on the test's own notch: this is what a host switcher changes.
        expect(
          container.read(activeConnectionProvider).value!.client.connection.baseUri,
          hostB.baseUri,
        );
        await pumpUntil(
          () => container.read(agentTeamsProvider).value?.teams.single.teamId == 'team-b',
          what: 'the new host',
        );
        // The ETag belongs to A's `/state`; B starts without one, so its first
        // read cannot be answered 304 off the other host's validator.
        expect(hostB.requests.single.ifNoneMatch, isNull);

        // Now the Host being left answers, late. Its generation is gone, so its
        // team must not come back.
        hostA.holdState!.complete();
        await pumpUntil(() => hostA.stateHits == 1, what: 'the held reply');
        // One beat with the socket, so a leaked write would have landed by now,
        // and one poll beat, so a beat armed off the abandoned reply would have
        // fired. The host being left is not read again.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(hostA.stateHits, 1, reason: 'the abandoned host is not polled again');

        final state = container.read(agentTeamsProvider).value!;
        expect(state.teams.single.teamId, 'team-b');
        expect(state.etag, '"state-1"');
      }, _RealHttp());
    });

    test('a reply of the host being left cannot revive a host-less controller', () async {
      // Switching to "no connection" is the one switch the ticket cannot cover:
      // `build` returns before it starts a read, so `_ticket` does not move and
      // the abandoned reply still holds the current ticket. Only the owner check
      // knows the app has no host at all.
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _TeamsHost.start();
        addTearDown(hostA.close);
        hostA.stateBody = _stateJson(teamId: 'team-a', name: 'A 上的队');
        hostA.holdState = Completer<void>();

        final container = _container(host: hostA);
        final sub = container.listen(agentTeamsProvider, (_, _) {});
        addTearDown(sub.close);
        await pumpUntil(() => hostA.stateHits == 1, what: 'the first read');

        container.read(_activeHostProvider.notifier).use(null);
        await pumpUntil(
          () => container.read(agentTeamsProvider).value == null,
          what: 'the empty controller',
        );

        hostA.holdState!.complete();
        await pumpUntil(() => hostA.stateHits == 1, what: 'the held reply');
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final state = container.read(agentTeamsProvider);
        expect(state.value, isNull, reason: 'no host is no team, whatever A says');
        expect(state.error, isNull);
      }, _RealHttp());
    });

    test('a 404 of the host being left cannot blank the new one', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _TeamsHost.start();
        final hostB = await _TeamsHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });
        hostB.stateBody = _stateJson(teamId: 'team-b', name: 'B 上的队');
        hostA.holdState = Completer<void>();

        final container = _container(host: hostA);
        final sub = container.listen(agentTeamsProvider, (_, _) {});
        addTearDown(sub.close);
        await pumpUntil(() => hostA.stateHits == 1, what: 'the first read');

        container.read(_activeHostProvider.notifier).use(hostB);
        await pumpUntil(
          () => container.read(agentTeamsProvider).value?.teams.single.teamId == 'team-b',
          what: 'the new host',
        );

        // The abandoned read comes back as "no plugin here". That is A's answer
        // about A, and B serves the team just fine.
        hostA.stateStatus = 404;
        hostA.holdState!.complete();
        await pumpUntil(() => hostA.stateHits == 1, what: 'the held reply');
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final state = container.read(agentTeamsProvider);
        expect(state.value, isNotNull, reason: 'B still serves the plugin');
        expect(state.value!.teams.single.teamId, 'team-b');
      }, _RealHttp());
    });

    test('a halt failure of the host being left does not show on the new one', () async {
      // The spinner and the failure of a halt name a team that one Host serves.
      // Leaving that Host mid-request is the case the read-side ticket cannot
      // cover: the action does not poll, it waits on its own write.
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _TeamsHost.start();
        final hostB = await _TeamsHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });
        hostA.stateBody = _stateJson(teamId: 'team-a', name: 'A 上的队');
        hostB.stateBody = _stateJson(teamId: 'team-b', name: 'B 上的队');
        // A holds the halt; its answer arrives only after the switch.
        hostA.holdAction = Completer<void>();
        hostA.actionStatus = 409;
        hostA.actionBody = const {'error': 'captain detached'};

        final container = _container(host: hostA);
        final snapshot = container.listen(agentTeamsProvider, (_, _) {});
        addTearDown(snapshot.close);
        await pumpUntil(() => hostA.stateHits == 1, what: 'the first read');

        final halted = container
            .read(agentTeamsActionProvider.notifier)
            .halt(sessionId: 's', teamId: 'team-a');
        await pumpUntil(() => hostA.posted.isNotEmpty, what: 'the halt');
        expect(container.read(agentTeamsActionProvider).isBusyOn('team-a'), isTrue);

        container.read(_activeHostProvider.notifier).use(hostB);
        await pumpUntil(
          () => container.read(agentTeamsProvider).value?.teams.single.teamId == 'team-b',
          what: 'the new host',
        );

        // B is serving its own team; A now answers "captain detached". That is
        // A's answer about a team B has never heard of.
        hostA.holdAction!.complete();
        expect(await halted, isFalse, reason: 'the halt of the host being left did not happen');
        // One beat with the socket, so a leaked write would have landed by now.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final state = container.read(agentTeamsActionProvider);
        expect(state.busy, isFalse, reason: 'no spinner belongs to the host being left');
        expect(state.isBusyOn('team-a'), isFalse);
        expect(state.failedTeamId, isNull, reason: 'the failure is A talking about A');
        expect(state.error, isNull);
        expect(state.detail, isNull);
      }, _RealHttp());
    });

    test('a plan failure of the host being left does not show on the new one', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _TeamsHost.start();
        final hostB = await _TeamsHost.start();
        addTearDown(() async {
          await hostA.close();
          await hostB.close();
        });
        hostA.stateBody = _stateJson(teamId: 'team-a', name: 'A 上的队');
        hostB.stateBody = _stateJson(teamId: 'team-b', name: 'B 上的队');
        hostA.holdAction = Completer<void>();
        hostA.actionStatus = 422;
        hostA.actionBody = const {'error': 'unknown option'};

        final container = _container(host: hostA);
        final snapshot = container.listen(agentTeamsProvider, (_, _) {});
        addTearDown(snapshot.close);
        await pumpUntil(() => hostA.stateHits == 1, what: 'the first read');

        final planned = container
            .read(agentTeamsActionProvider.notifier)
            .plan(sessionId: 's', teamId: 'team-a', action: AgentTeamPlanAction.approve);
        await pumpUntil(() => hostA.posted.isNotEmpty, what: 'the plan edit');
        expect(container.read(agentTeamsActionProvider).action, AgentTeamPlanAction.approve);

        container.read(_activeHostProvider.notifier).use(hostB);
        await pumpUntil(
          () => container.read(agentTeamsProvider).value?.teams.single.teamId == 'team-b',
          what: 'the new host',
        );

        hostA.holdAction!.complete();
        expect(await planned, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final state = container.read(agentTeamsActionProvider);
        expect(state.busy, isFalse);
        expect(state.action, isNull);
        expect(state.failedTeamId, isNull);
        expect(state.error, isNull);
      }, _RealHttp());
    });

    test('an action that answers before the switch still reports', () async {
      // The guard must not throw away an answer that lands while its own Host
      // is still the one on screen: a halt that fails there has to say so.
      await HttpOverrides.runWithHttpOverrides(() async {
        final hostA = await _TeamsHost.start();
        addTearDown(hostA.close);
        hostA.actionStatus = 409;
        hostA.actionBody = const {'error': 'captain detached'};

        final container = _container(host: hostA);
        final snapshot = container.listen(agentTeamsProvider, (_, _) {});
        addTearDown(snapshot.close);
        await pumpUntil(() => hostA.stateHits == 1, what: 'the first read');

        expect(
          await container.read(agentTeamsActionProvider.notifier).halt(sessionId: 's', teamId: 'team-1'),
          isFalse,
        );
        final state = container.read(agentTeamsActionProvider);
        expect(state.failedTeamId, 'team-1');
        expect(state.error, AgentTeamsActionError.captainDetached);
      }, _RealHttp());
    });

  });

  group('captain session', () {
    test('an empty captain id is no chat to open', () {
      const team = AgentTeamSnapshot(teamId: 't', name: 't', captainSessionId: '');
      expect(agentTeamCaptainSession(team), isNull);
      const named = AgentTeamSnapshot(teamId: 't', name: 't', captainSessionId: 'session-x');
      expect(agentTeamCaptainSession(named), 'session-x');
    });
  });
}
