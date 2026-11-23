// Multi-CLI workbench integration tests: Agent chats group, engine icons,
// header metadata, and per-engine terminal input placeholder.
//
//   flutter test test/shell/workbench_multi_cli_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/state/workbench_bridge_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../terminal/support.dart';
import 'adaptive/support.dart';

class _FakeBridgeSessions extends WorkbenchBridgeSessionsController {
  _FakeBridgeSessions(this.rows);

  final List<SessionSummary> rows;

  @override
  List<SessionSummary> build() => rows;

  @override
  Future<void> refresh() async {}
}

SessionSummary _cliSession({
  required CliEngine engine,
  required String rawId,
  required String title,
  bool running = false,
}) => WorkbenchCliSession(
  engine: engine,
  rawId: rawId,
  sessionId: 'cli:${engine.wire}:$rawId',
  title: title,
  cwd: 'D:/dev/workspace',
  updatedAt: DateTime(2026, 11, 23, 10, 0),
  running: running,
).toSessionSummary();

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    freezeClocks();
  });
  tearDown(thawClocks);

  test('cliSnapshotToChatItems maps user, reasoning, tool-call, and assistant parts', () {
    final snap = WorkbenchCliChatSnapshot(
      engine: CliEngine.antigravity,
      rawId: 'agy-1',
      sessionId: 'cli:antigravity:agy-1',
      running: true,
      model: 'gemini-4-hydrogen-high',
      cwd: 'D:/dev/workspace',
      messages: [
        WorkbenchCliMessage(
          messageId: 'm1',
          role: MessageRole.user,
          createdAt: DateTime(2026, 11, 23, 10, 0),
          parts: const [TextPart('Remember Larch-4N')],
        ),
        WorkbenchCliMessage(
          messageId: 'm2',
          role: MessageRole.assistant,
          createdAt: DateTime(2026, 11, 23, 10, 1),
          parts: const [
            ReasoningPart('Thinking'),
            ToolCallPart(id: 'tc1', name: 'read_file', arguments: '{"path":"a"}'),
            TextPart('Larch-4N'),
          ],
        ),
      ],
    );

    final items = cliSnapshotToChatItems(snap);
    expect(items.length, 3);
    expect(items[0], isA<UserChatItem>());
    expect((items[0] as UserChatItem).text, 'Remember Larch-4N');
    expect(items[1], isA<AssistantChatItem>());
    expect((items[1] as AssistantChatItem).reasoning, 'Thinking');
    expect((items[1] as AssistantChatItem).text, 'Larch-4N');
    expect((items[1] as AssistantChatItem).streaming, isTrue);
    expect(items[2], isA<ToolChatItem>());
    expect((items[2] as ToolChatItem).status, ToolStatus.running);
  });

  testWidgets('wide workbench renders Agent chats group, multi-CLI icons, and engine composer hint', (tester) async {
    useWindow(tester, const Size(1280, 800));
    mockClipboard(tester);
    final extSessions = [
      _cliSession(engine: CliEngine.antigravity, rawId: 'agy-1', title: 'Larch-4N', running: false),
      _cliSession(engine: CliEngine.claude, rawId: 'cl-1', title: 'Paper kites', running: false),
      _cliSession(engine: CliEngine.codex, rawId: 'cx-1', title: 'Pebble-3K', running: false),
    ];

    await tester.pumpWidget(
      testApp(
        HomeShell(chatBuilder: (openDrawer) => ChatScreen(onOpenDrawer: openDrawer, backdrop: false)),
        overrides: [
          ...homeOverrides(
            session: 'cli:antigravity:agy-1',
            prefs: const LayoutPrefs(loaded: true, panelOpen: false),
            chat: (id) => const ChatState(loading: false, items: []),
          ),
          workbenchBridgeSessionsProvider.overrideWith(() => _FakeBridgeSessions(extSessions)),
          terminalBackendProvider.overrideWith((ref, id) => FakeTerminalBackend(supported: false)),
        ],
      ),
    );
    await pumpFrames(tester, 4);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('agent-chats-label')), findsOneWidget);
    expect(find.text('智能体对话'), findsOneWidget);
    expect(find.byKey(const ValueKey('cli-icon-antigravity')), findsWidgets);
    expect(find.byKey(const ValueKey('cli-icon-claude')), findsOneWidget);
    expect(find.byKey(const ValueKey('cli-icon-codex')), findsOneWidget);
    expect(find.text('向 Antigravity 终端发送输入...'), findsOneWidget);
  });
}
