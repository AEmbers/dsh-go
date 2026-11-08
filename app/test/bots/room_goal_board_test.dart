// The group goal board draws what `room-chat` sent: the stage ledger, each
// stage's tasks, and how a finished goal ended.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/bots/bots_page.dart' show BotTag;
import 'package:dsh_app/ui/bots/room_goal_board.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;

Map<String, Object?> stage({
  int index = 0,
  String title = '同步上游基线',
  String acceptance = 'HEAD 追平上游',
  String status = 'passed',
  int reworks = 0,
  String? feedback,
  List<Object?> tasks = const [],
}) => {
  'index': index,
  'title': title,
  'acceptance': acceptance,
  'status': status,
  'reworks': reworks,
  'feedback': ?feedback,
  'tasks': tasks,
};

Map<String, Object?> task(String name, String what, String status, {String? note}) => {
  'botId': name,
  'name': name,
  'task': what,
  'status': status,
  'note': ?note,
};

DsBotRoomGoal goalOf(Map<String, Object?> json) => DsBotRoomGoal.fromJson(json);

DsBotRoomGoal activeGoal() => goalOf({
  'id': 'g1',
  'revision': 3,
  'status': 'active',
  'title': '完美适配四大插件',
  'objective': '让 dsh-Go 适配四个插件',
  'acceptance': '三个校验脚本零报错',
  'constraints': ['不手改生成物'],
  'current': 1,
  'stages': [
    stage(
      reworks: 2,
      feedback: '漏了生成脚本',
      tasks: [task('仓库管', 'merge upstream', 'done', note: '已合')],
    ),
    stage(
      index: 1,
      title: '原生 UI',
      acceptance: '围栏里能点',
      status: 'active',
      tasks: [task('界面', 'genui 交互', 'working')],
    ),
    stage(index: 2, title: '双语同步', acceptance: 'guide 校验通过', status: 'pending'),
  ],
});

Future<void> mount(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    goldenApp(brightness: Brightness.light, home: Scaffold(body: SingleChildScrollView(child: child))),
  );
  await tester.pump();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the board names the goal, its progress and every stage', (tester) async {
    await mount(tester, RoomGoalBoard(goal: activeGoal()));
    expect(find.text('完美适配四大插件'), findsOneWidget);
    expect(find.text(appL10n.botsGoalStatusActive), findsWidgets);
    // The stage under way is the headline; the rest are rows below it.
    expect(find.text('原生 UI'), findsWidgets);
    expect(find.text('同步上游基线'), findsOneWidget);
    expect(find.text('双语同步'), findsOneWidget);
    // 1 passed of 3.
    expect(find.text(appL10n.botsGoalStageOf(2, 3)), findsOneWidget);
    expect(find.text(appL10n.botsGoalPassedCount(1)), findsOneWidget);
    // A stage row says its own state where a task has not: the three stages
    // are done, under way, and not started.
    expect(find.text(appL10n.botsGoalTaskDone), findsOneWidget);
    expect(find.text('双语同步'), findsOneWidget);
  });

  testWidgets('a reworked stage shows its count and the reason it came back', (tester) async {
    await mount(tester, RoomGoalBoard(goal: activeGoal()));
    expect(find.text('×2'), findsOneWidget);
    expect(find.text(appL10n.botsGoalReworks(2)), findsOneWidget);
    expect(find.text(appL10n.botsGoalFeedback('漏了生成脚本')), findsOneWidget);
  });

  testWidgets('each member task carries its name, its work and its own status', (tester) async {
    await mount(tester, RoomGoalBoard(goal: activeGoal()));
    expect(find.text('仓库管 · merge upstream'), findsOneWidget);
    expect(find.text('已合'), findsOneWidget);
    expect(find.text('界面 · genui 交互'), findsOneWidget);
    expect(find.text(appL10n.botsGoalTaskDone), findsOneWidget);
    // Two stages still have a task needing someone, so both say 进行中; the
    // quiet stage says nothing.
    expect(find.text(appL10n.botsGoalTaskWorking), findsWidgets);
    expect(find.text(appL10n.botsGoalTaskPending), findsNothing);
  });

  testWidgets('the goal own words about what it is for are all on the board', (tester) async {
    await mount(tester, RoomGoalBoard(goal: activeGoal()));
    expect(find.text(appL10n.botsGoalObjective), findsOneWidget);
    expect(find.text('让 dsh-Go 适配四个插件'), findsOneWidget);
    expect(find.text(appL10n.botsGoalAcceptance), findsOneWidget);
    expect(find.text('三个校验脚本零报错'), findsOneWidget);
    expect(find.text(appL10n.botsGoalConstraints), findsOneWidget);
    expect(find.text('· 不手改生成物'), findsOneWidget);
    // Nothing has ended, so no outcome section.
    expect(find.text(appL10n.botsGoalSummary), findsNothing);
    expect(find.text(appL10n.botsGoalReason), findsNothing);
  });

  testWidgets('a finished goal says what it delivered and why it stopped', (tester) async {
    final stopped = goalOf({
      'id': 'g2',
      'revision': 9,
      'status': 'stopped',
      'title': '四插件适配',
      'reason': '主人叫停，先修崩溃',
      'summary': '三个插件已上，语音还没接',
      'evidence': 'fl.sh test → +93',
      'stages': [stage()],
    });
    await mount(tester, RoomGoalBoard(goal: stopped));
    expect(find.text(appL10n.botsGoalStatusStopped), findsWidgets);
    expect(find.text(appL10n.botsGoalReason), findsOneWidget);
    expect(find.text('主人叫停，先修崩溃'), findsOneWidget);
    expect(find.text(appL10n.botsGoalSummary), findsOneWidget);
    expect(find.text('三个插件已上，语音还没接'), findsOneWidget);
    expect(find.text(appL10n.botsGoalEvidence), findsOneWidget);
    expect(find.text('fl.sh test → +93'), findsOneWidget);
  });

  testWidgets('a goal still being drafted draws without a ledger and still names itself', (tester) async {
    final drafting = goalOf({
      'id': 'g3',
      'revision': 1,
      'status': 'drafting',
      'title': '还在对齐',
      'objective': '还不知道要做到哪一步',
    });
    await mount(tester, RoomGoalBoard(goal: drafting));
    expect(find.text('还在对齐'), findsOneWidget);
    expect(find.text(appL10n.botsGoalStatusDrafting), findsWidgets);
    expect(find.text(appL10n.botsGoalObjective), findsOneWidget);
    expect(find.text('还不知道要做到哪一步'), findsOneWidget);
    expect(find.text(appL10n.botsGoalPassedCount(0)), findsNothing);
  });

  testWidgets('a goal with no title is named by the board, not left blank', (tester) async {
    await mount(tester, RoomGoalBoard(goal: goalOf({'id': 'g4', 'status': 'active', 'title': '  '})));
    expect(find.text(appL10n.botsGoalBoard), findsWidgets);
  });

  testWidgets('the group chat summary carries the stage and opens the whole ledger', (tester) async {
    await mount(tester, RoomGoalCard(goal: activeGoal()));
    expect(find.byKey(const ValueKey('room-goal-summary')), findsOneWidget);
    expect(find.text('完美适配四大插件'), findsOneWidget);
    expect(find.text(appL10n.botsGoalStatusActive), findsWidgets);
    expect(find.text(appL10n.botsGoalPassedCount(1)), findsOneWidget);
    final open = find.byKey(const ValueKey('room-goal-open'));
    expect(open, findsOneWidget);
    await tester.tap(open);
    await tester.pumpAndSettle();
    // The sheet repeats the ledger with room to read it.
    expect(find.text(appL10n.botsGoalObjective), findsOneWidget);
    expect(find.text('同步上游基线'), findsOneWidget);
    expect(find.text(appL10n.botsGoalFeedback('漏了生成脚本')), findsOneWidget);
  });

  testWidgets('the status words follow the interface language, not the wire', (tester) async {
    await mount(
      tester,
      Builder(
        builder: (context) => Column(
          children: [
            for (final status in DsBotGoalStatus.values) Text(goalStatusText(context, status)),
            for (final status in DsBotStageStatus.values) Text(stageStatusText(context, status)),
            for (final status in DsBotTaskStatus.values) Text(taskStatusText(context, status)),
          ],
        ),
      ),
    );
    // Every wire word has a word here; none of them is the raw token.
    for (final raw in ['drafting', 'active', 'paused', 'complete', 'stopped', 'pending', 'passed', 'working', 'reported', 'done', 'unknown']) {
      expect(find.text(raw), findsNothing, reason: 'raw wire word $raw leaked into the interface');
    }
    // One word per enum value; several enums share the unknown word on purpose.
    expect(find.text(appL10n.botsGoalStatusUnknown), findsWidgets);
    expect(find.text(appL10n.botsGoalTaskReported), findsWidgets);
  });

  testWidgets('a task whose name the host lost still says what the work was', (tester) async {
    final anonymous = goalOf({
      'id': 'g5',
      'status': 'active',
      'title': 'T',
      'current': 0,
      'stages': [
        stage(
          status: 'active',
          tasks: [
            {'botId': 'b9', 'task': '跑基准', 'status': 'working'},
          ],
        ),
      ],
    });
    await mount(tester, RoomGoalBoard(goal: anonymous));
    expect(find.text('跑基准'), findsOneWidget);
  });

  testWidgets('the tags are the shared small label, not a bespoke chip', (tester) async {
    await mount(tester, RoomGoalBoard(goal: activeGoal()));
    expect(find.byType(BotTag), findsWidgets);
  });
}
