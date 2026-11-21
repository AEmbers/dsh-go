import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// A `room-chat` page as `ds-bot` sends it, goal and all.
Map<String, Object?> page(List<Object?> items, {Object? goal}) => {
  'roomId': 'r1',
  'items': items,
  'cursor': null,
  'running': false,
  if (goal != null) 'goal': goal,
};

Map<String, Object?> board({Map<String, Object?> overrides = const {}}) => {
  'id': 'g1',
  'revision': 12,
  'status': 'active',
  'title': '完美适配四大插件',
  'objective': '让 dsh-Go 适配 ds-bot / genui / voice / agent-teams',
  'acceptance': '三个校验脚本零报错',
  'constraints': ['不手改生成物', '只推 AEmbers/dsh-go'],
  'current': 1,
  'stages': [
    {
      'index': 0,
      'title': '同步上游基线',
      'acceptance': 'HEAD 追平上游',
      'status': 'passed',
      'reworks': 2,
      'feedback': '漏了生成脚本',
      'tasks': [
        {'botId': 'b1', 'name': '仓库管', 'task': 'merge upstream', 'status': 'done', 'note': '已合'},
        {'botId': 'b2', 'name': '基准', 'task': '跑基准', 'status': 'reported', 'note': '7 项里 5 项过'},
      ],
    },
    {
      'index': 1,
      'title': '原生 UI',
      'acceptance': '围栏里能点',
      'status': 'active',
      'tasks': [
        {'botId': 'b3', 'name': '界面', 'task': 'genui 交互', 'status': 'working'},
      ],
    },
    {'index': 2, 'title': '双语同步', 'acceptance': 'guide 校验通过', 'status': 'pending'},
  ],
  'updatedAt': 1762000000000,
  'startedAt': 1761900000000,
  ...overrides,
};

void main() {
  test('a room page carries the whole goal board', () {
    final parsed = DsBotRoomPage.fromJson(page(const [], goal: board()));
    final goal = parsed.goal;
    expect(goal, isNotNull);
    expect(goal!.id, 'g1');
    expect(goal.revision, 12);
    expect(goal.status, DsBotGoalStatus.active);
    expect(goal.title, '完美适配四大插件');
    expect(goal.objective, isNotEmpty);
    expect(goal.acceptance, '三个校验脚本零报错');
    expect(goal.constraints, ['不手改生成物', '只推 AEmbers/dsh-go']);
    expect(goal.current, 1);
    expect(goal.stages, hasLength(3));
    expect(goal.updatedAt, DateTime.fromMillisecondsSinceEpoch(1762000000000));
    expect(goal.startedAt, DateTime.fromMillisecondsSinceEpoch(1761900000000));
    expect(goal.endedAt, isNull);
    expect(goal.summary, isNull);
  });

  test('a stage keeps its reworks, feedback and each member task', () {
    final goal = DsBotRoomPage.fromJson(page(const [], goal: board())).goal!;
    final first = goal.stages[0];
    expect(first.index, 0);
    expect(first.title, '同步上游基线');
    expect(first.acceptance, 'HEAD 追平上游');
    expect(first.status, DsBotStageStatus.passed);
    expect(first.reworks, 2);
    expect(first.feedback, '漏了生成脚本');
    expect(first.passed, isTrue);
    expect(first.active, isFalse);
    expect(first.tasks, hasLength(2));
    final merge = first.tasks[0];
    expect(merge.botId, 'b1');
    expect(merge.name, '仓库管');
    expect(merge.task, 'merge upstream');
    expect(merge.status, DsBotTaskStatus.done);
    expect(merge.note, '已合');
    expect(first.tasks[1].status, DsBotTaskStatus.reported);
    // `working` and `reported` both still need the member.
    expect(first.open, 1);
    expect(goal.stages[1].open, 1);
    expect(goal.stages[2].open, 0);
  });

  test('current stage, progress and the two ways a goal ends', () {
    final goal = DsBotRoomPage.fromJson(page(const [], goal: board())).goal!;
    expect(goal.hasStages, isTrue);
    expect(goal.currentStage?.title, '原生 UI');
    expect(goal.passedStages, 1);
    expect(goal.live, isTrue);
    expect(goal.finished, isFalse);

    // Paused is still under way; stopped and complete are the ends.
    final paused = DsBotRoomPage.fromJson(
      page(const [], goal: board(overrides: {'status': 'paused'})),
    ).goal!;
    expect(paused.live, isTrue);
    expect(paused.finished, isFalse);
    for (final wire in ['complete', 'stopped']) {
      final ended = DsBotRoomPage.fromJson(
        page(const [], goal: board(overrides: {'status': wire, 'reason': '主人叫停', 'summary': '交了四个插件'})),
      ).goal!;
      expect(ended.live, isFalse);
      expect(ended.finished, isTrue);
      expect(ended.reason, '主人叫停');
      expect(ended.summary, '交了四个插件');
    }
  });

  test('a current index outside the ledger has no stage', () {
    final goal = DsBotRoomPage.fromJson(
      page(const [], goal: board(overrides: {'current': 9})),
    ).goal!;
    expect(goal.currentStage, isNull);
    final negative = DsBotRoomPage.fromJson(
      page(const [], goal: board(overrides: {'current': -1})),
    ).goal!;
    expect(negative.currentStage, isNull);
  });

  test('a drafting goal answers no stages and still parses', () {
    final goal = DsBotRoomPage.fromJson(
      page(const [], goal: {
        'id': 'g2',
        'revision': 1,
        'status': 'drafting',
        'title': '',
        'objective': '还没对齐',
      }),
    ).goal!;
    expect(goal.status, DsBotGoalStatus.drafting);
    expect(goal.hasStages, isFalse);
    expect(goal.passedStages, 0);
    expect(goal.title, isEmpty);
    expect(goal.constraints, isEmpty);
    expect(goal.live, isFalse);
  });

  test('a goal of nothing but nulls falls back to empty, not a crash', () {
    final goal = DsBotRoomPage.fromJson(page(const [], goal: <String, Object?>{})).goal!;
    expect(goal.id, isEmpty);
    expect(goal.revision, 0);
    expect(goal.status, DsBotGoalStatus.unknown);
    expect(goal.stages, isEmpty);
    expect(goal.current, 0);
    expect(goal.updatedAt, isNull);
  });

  test('a word this client does not know becomes unknown at every level', () {
    final goal = DsBotRoomPage.fromJson(
      page(
        const [],
        goal: board(
          overrides: {
            'status': 'archived',
            'stages': [
              {
                'index': 0,
                'title': '??',
                'status': 'halted',
                'tasks': [
                  {'botId': 'b', 'name': 'n', 'task': 't', 'status': 'blocked'},
                ],
              },
            ],
          },
        ),
      ),
    ).goal!;
    expect(goal.status, DsBotGoalStatus.unknown);
    expect(goal.stages.single.status, DsBotStageStatus.unknown);
    expect(goal.stages.single.tasks.single.status, DsBotTaskStatus.unknown);
    expect(goal.stages.single.passed, isFalse);
    expect(goal.stages.single.active, isFalse);
    // An unknown status is not done, so the task still counts as open.
    expect(goal.stages.single.open, 1);
  });

  group('the room record in state', () {
    // `state` -> `rooms[]` is where a real host keeps the goal: ds-bot has no
    // `room-chat` endpoint at all, and a room's own record carries the board.
    test('a room carries its goal without any other endpoint', () {
      final room = DsBotRoom.fromJson({
        'id': 'r1',
        'name': '发布会',
        'members': ['m1'],
        'admin': 'm1',
        'mode': 'admin',
        'notice': '',
        'preview': '',
        'parts': ['g1'],
        'createdAt': 0,
        'goal': board(),
      });
      expect(room.goal, isNotNull);
      expect(room.goal!.title, '完美适配四大插件');
      expect(room.goal!.stages, hasLength(3));
    });

    test('a room without a goal leaves it null, exactly as before', () {
      final room = DsBotRoom.fromJson({'id': 'r1', 'name': '发布会'});
      expect(room.goal, isNull);
      expect(DsBotRoom.fromJson({'id': 'r1', 'goal': null}).goal, isNull);
      expect(DsBotRoom.fromJson({'id': 'r1', 'goal': 'nope'}).goal, isNull);
    });

    test('a team reads every room goal, so the list needs no second call', () {
      final team = DsBotTeam.fromJson({
        'revision': 1,
        'bots': const [],
        'rooms': [
          {'id': 'r1', 'name': 'a', 'goal': board()},
          {'id': 'r2', 'name': 'b'},
        ],
        'views': const {},
        'models': const [],
        'defaultModel': 'm',
        'modelsKey': 'k',
      });
      expect(team.rooms[0].goal, isNotNull);
      expect(team.rooms[1].goal, isNull);
    });
  });

  group('a host that does not send goals', () {
    test('room-chat without the key leaves goal null', () {
      expect(DsBotRoomPage.fromJson(page(const [])).goal, isNull);
    });

    test('an explicit null goal is the same as none', () {
      expect(DsBotRoomPage.fromJson(page(const [], goal: null)).goal, isNull);
      expect(DsBotRoomPage.fromJson({...page(const []), 'goal': 'nope'}).goal, isNull);
    });

    test('the capability is what says whether a null means "no goal"', () {
      final hello = DsBotHello.fromJson({
        'api': 1,
        'apiMin': 1,
        'apiMax': 1,
        'plugin': {'name': 'ds-bot', 'version': '0.2.7'},
        'capabilities': ['state', 'room-chat', 'room-goal'],
        'boot': 'boot-1',
        'seq': 0,
        'revision': 1,
      });
      expect(hello.supports('room-goal'), isTrue);
      final older = DsBotHello.fromJson({
        'api': 1,
        'apiMin': 1,
        'apiMax': 1,
        'plugin': {'name': 'ds-bot', 'version': '0.2.0'},
        'capabilities': ['state', 'room-chat'],
        'boot': 'boot-1',
        'seq': 0,
        'revision': 1,
      });
      expect(older.supports('room-goal'), isFalse);
    });
  });
}
