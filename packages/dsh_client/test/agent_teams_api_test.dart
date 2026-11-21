import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

/// The `/plugins/dsh-agent-teams/*` routes as `@nanmicoder/dsh-agent-teams`
/// serves them: plain Fetch handlers on the Host, not RPC envelopes, so these
/// tests go through [FakeDsh.rawRoutes] rather than [FakeDsh.handlers].
void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
    addTearDown(client.close);
    return client;
  }

  /// Registers one route; [body] may be either a JSON-encodable value or a
  /// callback that writes to the response itself.
  void route(String path, Future<void> Function(MockRequest request, HttpResponseWriter response) body) {
    host.rawRoutes[path] = (request, response) async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        builder.add(chunk);
      }
      final raw = utf8.decode(builder.takeBytes(), allowMalformed: true);
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name] = values.join(','));
      await body(
        MockRequest(
          method: request.method,
          query: request.uri.queryParameters,
          headers: headers,
          body: raw.isEmpty ? null : tryDecode(raw),
          rawBody: raw,
        ),
        HttpResponseWriter(response),
      );
    };
  }

  /// A two-member, four-task team as the route assembles it.
  Map<String, Object?> teamJson({
    String teamId = 'team-1',
    String phase = 'running',
    bool archived = false,
  }) => {
    'teamId': teamId,
    'name': '登录修复',
    'workspace': 'dsh-go',
    'workspacePath': r'D:\dsh\forks\dsh-go',
    'captainSessionId': 'session-captain',
    'phase': phase,
    if (phase == 'staged') 'planReviewState': 'awaiting_review',
    if (archived) 'halted': true,
    'loopState': 'running',
    'deliverable': false,
    'delivery': {
      'ok': false,
      'blockers': ['task-3 未完成'],
      'warnings': ['write scope 重叠：lib/auth/'],
    },
    'messageCount': 3,
    'captainInbox': [
      {'from': 'reviewer', 'content': '复现了，连点两次会发两个请求。'},
    ],
    'members': [
      {
        'id': 'session-captain',
        'name': 'captain',
        'role': 'captain',
        'provider': 'deepseek-official',
        'model': 'deepseek-pro',
        'reasoningEffort': 'high',
        'status': 'active',
        'activity': 'working',
        'progress': 40,
        'done': 1,
        'total': 3,
        'currentTask': 'task-2',
        'unread': 1,
      },
      {
        'id': 'session-reviewer',
        'name': 'reviewer',
        'role': 'teammate',
        'provider': 'deepseek-official',
        'model': 'deepseek-flash',
        'reasoningEffort': 'medium',
        'executionPrompt': '只看 lib/auth 的改动',
        'status': 'active',
        'activity': 'idle',
        'progress': 100,
        'done': 1,
        'total': 1,
        'currentTask': '',
        'unread': 0,
      },
      {
        'id': '',
        'name': 'tester',
        'role': 'teammate',
        'status': 'removed',
        'activity': 'unknown',
      },
    ],
    'tasks': [
      {
        'id': 'task-1',
        'subject': '复现连点重复提交',
        'description': '在登录页连点两次。',
        'status': 'completed',
        'state': 'completed',
        'assignee': 'reviewer',
        'model': 'deepseek-flash',
        'dependencies': [],
        'depth': 0,
        'updatedAt': 1792822153432,
      },
      {
        'id': 'task-2',
        'subject': '给提交按钮加防抖',
        'status': 'in_progress',
        'state': 'running',
        'assignee': 'captain',
        'dependencies': ['task-1'],
        'depth': 1,
        'kind': 'implementation',
        'round': 1,
      },
      {
        'id': 'task-3',
        'subject': '审查防抖实现',
        'status': 'pending',
        'state': 'blocked',
        'assignee': 'reviewer',
        'dependencies': ['task-2'],
        'depth': 2,
        'kind': 'review',
        'verdict': 'pass',
        'verdictStale': 'workspace 已变',
      },
      {
        'id': 'task-4',
        'subject': '更新变更说明',
        'status': 'pending',
        'state': 'open',
        'dependencies': [],
        'depth': 0,
      },
    ],
  };

  Map<String, Object?> stateJson({String phase = 'running', bool archived = false}) => {
    'teams': [teamJson(phase: phase, archived: archived)],
  };

  group('state', () {
    test('parses teams, roster, tasks, delivery and the inbox', () async {
      route(agentTeamsStatePath, (request, response) async {
        expect(request.method, 'GET');
        response.sendJson(stateJson(), etag: 'W/"t1"');
      });
      final state = await (await connect()).readAgentTeams();
      expect(state, isNotNull);
      expect(state!.etag, 'W/"t1"');
      final team = state.teams.single;
      expect(team.teamId, 'team-1');
      expect(team.name, '登录修复');
      expect(team.workspacePath, r'D:\dsh\forks\dsh-go');
      expect(team.phase, TeamPhase.running);
      expect(team.halted, isFalse);
      expect(team.loopState, TeamLoopState.running);
      expect(team.deliverable, isFalse);
      expect(team.messageCount, 3);
      expect(team.captainInbox.single.from, 'reviewer');
      expect(team.captainInbox.single.content, '复现了，连点两次会发两个请求。');

      // The captain is one member of the roster, named `captain`.
      expect(team.members, hasLength(3));
      expect(team.teammates.map((m) => m.name), ['reviewer', 'tester']);
      expect(team.captain!.name, 'captain');
      expect(team.captain!.modelRoute, 'deepseek-official/deepseek-pro');
      expect(team.captain!.working, isTrue);
      expect(team.workingCount, 1);

      // A member without a session cannot be opened, and `removed` says why.
      final removed = team.teammates.last;
      expect(removed.removed, isTrue);
      expect(removed.openable, isFalse);
      expect(removed.activity, TeamActivity.unknown);
      expect(team.teammates.first.openable, isTrue);

      // Tasks carry the *visual* state as well as the durable status.
      expect(team.tasks.map((t) => t.id), ['task-1', 'task-2', 'task-3', 'task-4']);
      final running = team.tasks[1];
      expect(running.state, TeamTaskState.running);
      expect(running.status, 'in_progress');
      expect(running.isQualityKind, isTrue);
      expect(running.round, 1);
      expect(team.tasks[0].isQualityKind, isFalse);
      final review = team.tasks[2];
      expect(review.state, TeamTaskState.blocked);
      expect(review.verdict, 'pass');
      expect(review.stale, isTrue);
      expect(team.tasks[0].updatedAt, DateTime.fromMillisecondsSinceEpoch(1792822153432));

      // Delivery is the auditor's conclusion, not merely "all tasks done".
      expect(team.delivery!.ok, isFalse);
      expect(team.delivery!.blockers, ['task-3 未完成']);
      expect(team.canDeclareDelivery, isFalse);
      expect(team.openTasks, 3);

      // Four tasks spread over depth 0, 1 and 2.
      expect(team.lanes, 3);
      expect(team.lane(0).map((t) => t.id), ['task-1', 'task-4']);
      expect(team.lane(1).map((t) => t.id), ['task-2']);
      expect(team.lane(9), isEmpty);
    });

    test('sends the query the route expects', () async {
      Map<String, String>? query;
      route(agentTeamsStatePath, (request, response) async {
        query = request.query;
        response.sendJson({'teams': []});
      });
      final client = await connect();
      await client.readAgentTeams(captainSessionId: 'session-captain', summary: true, archived: true);
      expect(query, {'session': 'session-captain', 'summary': '1', 'archived': '1'});
    });

    test('a matching ETag turns the read into null without a payload', () async {
      String? seenIfNoneMatch;
      route(agentTeamsStatePath, (request, response) async {
        seenIfNoneMatch = request.headers['if-none-match'];
        if (seenIfNoneMatch == 'W/"t1"') {
          response.status = 304;
          await response.finish();
          return;
        }
        response.sendJson(stateJson(), etag: 'W/"t1"');
      });
      final client = await connect();
      final first = await client.readAgentTeams();
      expect(first!.etag, 'W/"t1"');
      final second = await client.readAgentTeams(ifNoneMatch: first.etag);
      expect(seenIfNoneMatch, 'W/"t1"');
      expect(second, isNull);
    });

    test('an archived read marks the teams archived', () async {
      route(agentTeamsStatePath, (request, response) async {
        response.sendJson({'teams': [teamJson(archived: true)]});
      });
      final state = await (await connect()).readAgentTeams(archived: true);
      final team = state!.teams.single;
      expect(team.archived, isTrue);
      expect(team.halted, isTrue);
    });

    test('a missing route is unavailable, not an empty list', () async {
      // No route registered: FakeDsh answers 404.
      final client = await connect();
      await expectLater(client.readAgentTeams(), throwsA(isA<AgentTeamsUnavailableException>()));
    });

    test('an unknown phase or activity degrades instead of throwing', () async {
      route(agentTeamsStatePath, (request, response) async {
        response.sendJson({
          'teams': [
            {
              'teamId': 'team-2',
              'name': 'x',
              'captainSessionId': 's',
              'phase': 'something-new',
              'members': [
                {'id': 's', 'name': 'a', 'activity': 'sleeping'},
              ],
              'tasks': [
                {'id': 't', 'subject': 't', 'state': 'queued'},
              ],
            },
          ],
        });
      });
      final team = (await (await connect()).readAgentTeams())!.teams.single;
      expect(team.phase, TeamPhase.unknown);
      expect(team.members.single.activity, TeamActivity.unknown);
      expect(team.tasks.single.state, TeamTaskState.unknown);
      expect(team.delivery, isNull);
      expect(team.canDeclareDelivery, isFalse);
    });

    test('a row without its id is dropped, not guessed', () async {
      route(agentTeamsStatePath, (request, response) async {
        response.sendJson({
          'teams': [
            {'name': 'no id'},
            {
              'teamId': 'team-1',
              'name': 'ok',
              'captainSessionId': 's',
              'members': [
                {'id': 's'},
                {'name': 'nameless-id'},
              ],
              'tasks': [
                {'subject': 'no id'},
              ],
            },
          ],
        });
      });
      final state = await (await connect()).readAgentTeams();
      expect(state!.teams, hasLength(1));
      final team = state.teams.single;
      expect(team.members.map((m) => m.name), ['nameless-id']);
      expect(team.tasks, isEmpty);
    });
  });

  group('lookup', () {
    test('byId and forCaptain pick the right team', () {
      final state = AgentTeamsState(
        teams: [
          const AgentTeamSnapshot(teamId: 'a', name: 'A', captainSessionId: 'cap-a'),
          const AgentTeamSnapshot(teamId: 'b', name: 'B', captainSessionId: 'cap-b'),
        ],
      );
      expect(state.byId('b')!.name, 'B');
      expect(state.byId('c'), isNull);
      expect(state.forCaptain('cap-a')!.teamId, 'a');
      // A member session is not a captain: with only one team the panel still
      // has something to show.
      expect(state.forCaptain('member-session'), isNull);
      expect(AgentTeamsState(teams: const [
        AgentTeamSnapshot(teamId: 'a', name: 'A', captainSessionId: 'cap-a'),
      ]).forCaptain('member-session')!.teamId, 'a');
      expect(AgentTeamsState.empty.isEmpty, isTrue);
    });
  });

  group('halt', () {
    test('posts the captain and the team, and reports the stop', () async {
      Map<String, Object?>? body;
      route(agentTeamsHaltPath, (request, response) async {
        expect(request.method, 'POST');
        body = request.body as Map<String, Object?>?;
        response.sendJson({'ok': true});
      });
      final client = await connect();
      final result = await client.haltAgentTeam(sessionId: 'session-captain', teamId: 'team-1');
      expect(result.ok, isTrue);
      expect(body, {'sessionId': 'session-captain', 'teamId': 'team-1'});
    });

    test('409 is a detached captain, 404 a foreign team, 400 a bad request', () async {
      var status = 409;
      Object? payload = {'error': 'captain session is not attached'};
      route(agentTeamsHaltPath, (request, response) async {
        response.status = status;
        response.sendJson(payload);
      });
      final client = await connect();
      await expectLater(
        client.haltAgentTeam(sessionId: 's', teamId: 't'),
        throwsA(isA<AgentTeamsCaptainDetachedException>()),
      );

      status = 404;
      payload = {'error': 'team not found'};
      await expectLater(
        client.haltAgentTeam(sessionId: 's', teamId: 't'),
        throwsA(isA<AgentTeamsTeamNotFoundException>()),
      );

      status = 400;
      payload = {'error': 'sessionId and teamId are required'};
      await expectLater(
        client.haltAgentTeam(sessionId: 's', teamId: 't'),
        throwsA(
          isA<AgentTeamsPlanRejectedException>().having(
            (e) => e.message,
            'message',
            'sessionId and teamId are required',
          ),
        ),
      );
    });

    test('an empty id never reaches the wire', () async {
      final client = await connect();
      await expectLater(client.haltAgentTeam(sessionId: '', teamId: 't'), throwsA(isA<ArgumentError>()));
      await expectLater(client.haltAgentTeam(sessionId: 's', teamId: ''), throwsA(isA<ArgumentError>()));
      await expectLater(
        client.haltAgentTeam(sessionId: 's', teamId: 'a\nb'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('plan', () {
    test('approve sends only the action and reads the new phase', () async {
      Map<String, Object?>? body;
      route(agentTeamsPlanPath, (request, response) async {
        body = request.body as Map<String, Object?>?;
        response.sendJson({'ok': true, 'phase': 'running', 'members': 3, 'tasks': 4});
      });
      final client = await connect();
      final result = await client.planAgentTeam(
        sessionId: 'session-captain',
        teamId: 'team-1',
        action: AgentTeamPlanAction.approve,
      );
      expect(body, {'sessionId': 'session-captain', 'teamId': 'team-1', 'action': 'approve'});
      expect(result.ok, isTrue);
      expect(result.phase, TeamPhase.running);
      expect(result.members, 3);
      expect(result.tasks, 4);
    });

    test('continue keeps the team staged and asks for feedback', () async {
      route(agentTeamsPlanPath, (request, response) async {
        response.sendJson({'ok': true, 'phase': 'staged', 'review': 'awaiting_feedback'});
      });
      final result = await (await connect()).planAgentTeam(
        sessionId: 's',
        teamId: 't',
        action: AgentTeamPlanAction.continuePlanning,
        fields: {'feedback': '把 task-3 挪到 review 之后'},
      );
      expect(result.phase, TeamPhase.staged);
      expect(result.raw['review'], 'awaiting_feedback');
    });

    test('discard reports the archived phase', () async {
      route(agentTeamsPlanPath, (request, response) async {
        response.sendJson({'ok': true, 'phase': 'archived'});
      });
      final result = await (await connect()).planAgentTeam(
        sessionId: 's',
        teamId: 't',
        action: AgentTeamPlanAction.discard,
      );
      expect(result.phase, TeamPhase.archived);
    });

    test('a rejected mutation carries the route message', () async {
      route(agentTeamsPlanPath, (request, response) async {
        response.status = 409;
        response.sendJson({'error': 'taskId does not exist: task-9'});
      });
      await expectLater(
        (await connect()).planAgentTeam(
          sessionId: 's',
          teamId: 't',
          action: AgentTeamPlanAction.removeTask,
          fields: {'taskId': 'task-9'},
        ),
        throwsA(
          isA<AgentTeamsPlanRejectedException>().having(
            (e) => e.message,
            'message',
            'taskId does not exist: task-9',
          ),
        ),
      );
    });

    test('null fields are dropped from the body', () async {
      Map<String, Object?>? body;
      route(agentTeamsPlanPath, (request, response) async {
        body = request.body as Map<String, Object?>?;
        response.sendJson({'ok': true});
      });
      await (await connect()).planAgentTeam(
        sessionId: 's',
        teamId: 't',
        action: AgentTeamPlanAction.updateTask,
        fields: {'taskId': 'task-1', 'subject': 'x', 'description': null},
      );
      expect(body, {'sessionId': 's', 'teamId': 't', 'action': 'update_task', 'taskId': 'task-1', 'subject': 'x'});
    });

    test('only the three staged actions require a staged team', () {
      expect(AgentTeamPlanAction.approve.requiresStaged, isTrue);
      expect(AgentTeamPlanAction.continuePlanning.requiresStaged, isTrue);
      expect(AgentTeamPlanAction.discard.requiresStaged, isTrue);
      expect(AgentTeamPlanAction.updateMember.requiresStaged, isFalse);
      expect(AgentTeamPlanAction.updateTask.requiresStaged, isFalse);
      expect(AgentTeamPlanAction.addTask.requiresStaged, isFalse);
      expect(AgentTeamPlanAction.removeTask.requiresStaged, isFalse);
      expect(AgentTeamPlanAction.continuePlanning.wire, 'continue');
      expect(AgentTeamPlanAction.updateMember.wire, 'update_member');
    });
  });
}

// -----------------------------------------------------------------------------
// Small helpers: the raw routes speak HTTP, the tests want a request/response
// -----------------------------------------------------------------------------

/// The request as a route saw it: method, query, headers, decoded JSON body.
class MockRequest {
  const MockRequest({
    required this.method,
    required this.query,
    required this.headers,
    required this.body,
    required this.rawBody,
  });

  final String method;
  final Map<String, String> query;
  final Map<String, String> headers;

  /// The decoded JSON body, or null when the route got no body.
  final Object? body;
  final String rawBody;
}

/// What a route answers with: a JSON body, a status, an `ETag`.
class HttpResponseWriter {
  HttpResponseWriter(this._response);

  final dynamic _response;

  set status(int value) => _response.statusCode = value;

  void sendJson(Object? value, {String? etag, String contentType = 'application/json'}) {
    _response.headers.set('content-type', '$contentType; charset=utf-8');
    if (etag != null) _response.headers.set('etag', etag);
    // Written as bytes: HttpResponse.write would encode with the headers'
    // charset, and a bare `application/json` means latin-1.
    _response.add(utf8.encode(jsonEncode(value)));
    _response.close();
  }

  Future<void> finish() async => _response.close();
}

Object? tryDecode(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}
