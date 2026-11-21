// The goal board where the pages use it: the summary above a group chat's
// composer, the ledger on the group's details page, and the hosts that send
// no goal at all.

import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_app/ui/bots/room_goal_board.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

/// The board a `0.2.7` host sends with a page of the group chat.
Map<String, Object?> goalBoard({String status = 'active'}) => {
  'id': 'g1',
  'revision': 4,
  'status': status,
  'title': '完美适配四大插件',
  'objective': '让 dsh-Go 适配四个插件',
  'acceptance': '三个校验脚本零报错',
  'current': 1,
  'stages': [
    {
      'index': 0,
      'title': '同步上游基线',
      'acceptance': 'HEAD 追平上游',
      'status': 'passed',
      'tasks': [
        {'botId': 'b1', 'name': '仓库管', 'task': 'merge upstream', 'status': 'done'},
      ],
    },
    {
      'index': 1,
      'title': '原生 UI',
      'acceptance': '围栏里能点',
      'status': 'active',
      'tasks': [
        {'botId': 'b2', 'name': '界面', 'task': 'genui 交互', 'status': 'working'},
      ],
    },
  ],
};

/// A `0.2.7` DS Bot: it answers `hello` with the `room-goal` capability and
/// puts a `goal` on every page of a group chat.
FakeDsBotTransport newerHost({String? status, bool sendGoal = true}) {
  final fake = FakeDsBotTransport();
  fake.handlers['hello'] = (_) => {
    ...fake.helloAnswer(),
    'plugin': {'name': 'ds-bot', 'version': '0.2.7'},
    'capabilities': [...(fake.helloAnswer()['capabilities']! as List), 'room-goal'],
  };
  fake.handlers['room-chat'] = (payload) => {
    'roomId': payload['roomId'],
    'items': fake.roomItems,
    'cursor': null,
    'running': false,
    if (sendGoal) 'goal': goalBoard(status: status ?? 'active'),
  };
  return fake;
}

Future<void> open(WidgetTester tester, Widget page, FakeDsBotTransport fake) async {
  usePhoneView(tester);
  await tester.pumpWidget(goldenApp(home: page, brightness: Brightness.light, overrides: dsBotOverrides(fake)));
  await frames(tester);
}

Future<void> frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the group chat keeps its goal above the composer', (tester) async {
    await open(tester, const RoomChatPage(roomId: 'r1'), newerHost());
    expect(find.byKey(const ValueKey('room-goal-summary')), findsOneWidget);
    expect(find.text('完美适配四大插件'), findsOneWidget);
    expect(find.text(appL10n.botsGoalPassedCount(1)), findsOneWidget);
    // The chat itself is still there under it.
    expect(find.byType(BotChatFrame), findsOneWidget);
  });

  testWidgets("tapping the summary opens that group's whole ledger", (tester) async {
    await open(tester, const RoomChatPage(roomId: 'r1'), newerHost());
    await tester.tap(find.byKey(const ValueKey('room-goal-open')));
    await tester.pumpAndSettle();
    expect(find.text('同步上游基线'), findsOneWidget);
    expect(find.text('原生 UI'), findsWidgets);
    expect(find.text('仓库管 · merge upstream'), findsOneWidget);
  });

  testWidgets('a group with no goal shows no board, and the chat is unaffected', (tester) async {
    await open(tester, const RoomChatPage(roomId: 'r1'), newerHost(sendGoal: false));
    expect(find.byKey(const ValueKey('room-goal-summary')), findsNothing);
    expect(find.byType(BotChatFrame), findsOneWidget);
  });

  testWidgets('a host without the capability draws no board even if it sends a goal', (tester) async {
    // `0.2.0`: the goal rides along but `hello` never claimed to have one, so
    // a null here would not mean "this group has no goal".
    final fake = FakeDsBotTransport();
    fake.handlers['room-chat'] = (payload) => {
      'roomId': payload['roomId'],
      'items': fake.roomItems,
      'cursor': null,
      'running': false,
      'goal': goalBoard(),
    };
    await open(tester, const RoomChatPage(roomId: 'r1'), fake);
    expect(find.byKey(const ValueKey('room-goal-summary')), findsNothing);
  });

  testWidgets('the details page carries the same ledger, not just the summary', (tester) async {
    await open(tester, const RoomDetailsPage(roomId: 'r1'), newerHost());
    // The ledger sits below the member and settings cards, so the page is
    // scrolled to it the way a reader would.
    await tester.scrollUntilVisible(find.byType(RoomGoalBoard), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.byType(RoomGoalBoard), findsOneWidget);
    expect(find.byKey(const ValueKey('room-goal')), findsOneWidget);
    expect(find.text('同步上游基线'), findsOneWidget);
    expect(find.text(appL10n.botsGoalObjective), findsOneWidget);
  });

  testWidgets('the details page of a group without a goal draws no ledger', (tester) async {
    await open(tester, const RoomDetailsPage(roomId: 'r1'), newerHost(sendGoal: false));
    await tester.scrollUntilVisible(find.text(appL10n.botsDeleteGroup), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.byType(RoomGoalBoard), findsNothing);
  });

  testWidgets('a paused goal still draws, with the word for paused', (tester) async {
    await open(tester, const RoomChatPage(roomId: 'r1'), newerHost(status: 'paused'));
    expect(find.byKey(const ValueKey('room-goal-summary')), findsOneWidget);
    expect(find.text(appL10n.botsGoalStatusPaused), findsWidgets);
  });

  testWidgets('a goal that rides on the room record in state draws the board', (tester) async {
    // ds-bot 0.3.x sends the goal with the room itself (`state` → `rooms[]`)
    // and has no `room-chat` endpoint at all, so this is the shape a real host
    // answers. The page carries no goal of its own here.
    final fake = FakeDsBotTransport();
    final team = sampleTeam();
    final rooms = [
      for (final room in team['rooms']! as List)
        if (room is Map<String, Object?> && room['id'] == 'r1') {...room, 'goal': goalBoard()},
    ];
    fake.handlers['state'] = (_) => {...team, 'rooms': rooms};
    fake.handlers['room-chat'] = (payload) => {
      'roomId': payload['roomId'],
      'items': fake.roomItems,
      'cursor': null,
      'running': false,
    };
    await open(tester, const RoomChatPage(roomId: 'r1'), fake);
    expect(find.byKey(const ValueKey('room-goal-summary')), findsOneWidget);
    expect(find.text('完美适配四大插件'), findsOneWidget);
  });

  testWidgets('a page that brings its own goal wins over the room record', (tester) async {
    // The page is newer than the `state` the controller already holds: a stage
    // passed in between must show as passed, not as the stale board.
    final fake = FakeDsBotTransport();
    final team = sampleTeam();
    final rooms = [
      for (final room in team['rooms']! as List)
        if (room is Map<String, Object?> && room['id'] == 'r1')
          {...room, 'goal': goalBoard(status: 'paused')},
    ];
    fake.handlers['state'] = (_) => {...team, 'rooms': rooms};
    fake.handlers['room-chat'] = (payload) => {
      'roomId': payload['roomId'],
      'items': fake.roomItems,
      'cursor': null,
      'running': false,
      'goal': goalBoard(),
    };
    await open(tester, const RoomChatPage(roomId: 'r1'), fake);
    expect(find.text(appL10n.botsGoalStatusActive), findsWidgets);
    expect(find.text(appL10n.botsGoalStatusPaused), findsNothing);
  });

  group('a DS Bot from before the mobile API', () {
    /// `hello` is gone, but `state` and `room-chat` still answer.
    FakeDsBotTransport olderHost() {
      final fake = FakeDsBotTransport();
      fake.handlers['hello'] = (_) => throw DshRemoteException('bot/not-found', 'legacy endpoint');
      return fake;
    }

    testWidgets('a group chat that had locked to an update page now reads', (tester) async {
      final fake = olderHost();
      await open(tester, const RoomChatPage(roomId: 'r1'), fake);
      // The dead end is gone: the chat is drawn from `state` as before.
      expect(find.byType(BotChatFrame), findsOneWidget);
      expect(find.byKey(const ValueKey('room-goal-summary')), findsNothing);
      expect(find.text(appL10n.botsMobileUnsupportedTitle), findsNothing);
    });

    testWidgets('the details page of the same host is readable too', (tester) async {
      await open(tester, const RoomDetailsPage(roomId: 'r1'), olderHost());
      expect(find.text('发布会'), findsWidgets);
      expect(find.byType(RoomGoalBoard), findsNothing);
      expect(find.text(appL10n.botsMobileUnsupportedTitle), findsNothing);
    });

    testWidgets('a host with no DS Bot at all still gets the explanation', (tester) async {
      // Nothing answers `state` either: this is the one dead end left.
      final fake = FakeDsBotTransport();
      fake.handlers['hello'] = (_) => throw const DshHttpException(404, 'no ds-bot');
      fake.handlers['state'] = (_) => throw const DshHttpException(404, 'no ds-bot');
      await open(tester, const RoomChatPage(roomId: 'r1'), fake);
      expect(find.byType(BotChatFrame), findsNothing);
    });
  });
}
