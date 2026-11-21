// Wide windows get conversation tabs, the running/history pile and the
// chat/CLI switch. A phone does not. Closing a tab does not delete the chat.
//
//   flutter test test/shell/workbench_chrome_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/state/workbench_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../terminal/support.dart';
import 'adaptive/support.dart';

const _wide = Size(1280, 800);
const _phone = Size(390, 844);

Future<void> _pump(WidgetTester tester, Size size, {String? session = 's1', bool panelOpen = false}) async {
  useWindow(tester, size);
  mockClipboard(tester);
  await tester.pumpWidget(
    testApp(
      HomeShell(chatBuilder: (openDrawer) => ChatScreen(onOpenDrawer: openDrawer, backdrop: false)),
      overrides: [
        ...homeOverrides(
          session: session,
          prefs: LayoutPrefs(loaded: true, panelOpen: panelOpen),
        ),
        terminalBackendProvider.overrideWith((ref, id) => FakeTerminalBackend(supported: false)),
      ],
    ),
  );
  await pumpFrames(tester, 2);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  testWidgets('a wide window shows tabs, scope and connection, and closing a tab keeps the chat', (tester) async {
    await _pump(tester, _wide);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('workbench-tabs')), findsOneWidget);
    expect(find.byKey(const ValueKey('workbench-meta')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-list-scope')), findsOneWidget);
    expect(find.text('本机'), findsWidgets);

    final drawer = find.byKey(const ValueKey('persistent-sidebar'));
    expect(find.descendant(of: drawer, matching: find.text('给设置页加深色模式')), findsOneWidget);
    // The open conversation stays listed while 历史 hides other running rows.
    expect(find.descendant(of: drawer, matching: find.text('修复登录重复提交')), findsOneWidget);
    final mode = tester.getRect(find.byKey(const ValueKey('workbench-mode')));
    expect(mode.top, greaterThan(tester.getRect(find.byKey(const ValueKey('chat-title-pill'))).bottom - 1));

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('drawer-list-scope')), matching: find.text('运行中')));
    await tester.pump();
    expect(find.descendant(of: drawer, matching: find.text('修复登录重复提交')), findsOneWidget);
    expect(find.descendant(of: drawer, matching: find.text('给设置页加深色模式')), findsNothing);

    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), contains('s1'));
    await tester.tap(find.byKey(const ValueKey('workbench-tab-close-s1')));
    await tester.pump();
    expect(container.read(currentSessionProvider), isNull);
    expect(container.read(openSessionTabsProvider), isEmpty);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), contains('s1'));
    expect(find.byKey(const ValueKey('workbench-tab-new')), findsOneWidget);

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('workbench-mode')), matching: find.text('命令行')));
    await tester.pump();
    expect(find.byKey(const ValueKey('workbench-cli-gate')), findsOneWidget);
    expect(find.byType(TerminalPage), findsNothing);
  });

  testWidgets('CLI uses the session terminal and does not offer a back route', (tester) async {
    await _pump(tester, _wide);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('workbench-mode')), matching: find.text('命令行')));
    await tester.pump();
    expect(find.byType(TerminalPage), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-back')), findsNothing);
    expect(find.text('这个连接用不了终端'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide and phone light renders', (tester) async {
    await _pump(tester, _wide);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/workbench_wide_light.png'));
    await _pump(tester, _phone);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/workbench_phone_light.png'));
  });

  testWidgets('a phone keeps the single column and hides the workbench bar', (tester) async {
    await _pump(tester, _phone);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('workbench-tabs')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-list-scope')), findsNothing);
    expect(find.byKey(const ValueKey('chat-menu')), findsOneWidget);
    expect(find.byType(Composer), findsOneWidget);
  });
}
