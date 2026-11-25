// Multi-CLI workbench integration tests: Agent chats group, engine icons,
// header metadata, and per-engine terminal input placeholder.
//
//   flutter test test/shell/workbench_multi_cli_test.dart

import 'package:dsh_app/state/adaptive_layout_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/cli_model_prefs_state.dart';
import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/state/workbench_bridge_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:dsh_app/ui/common/tool_glyph.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/workbench/workbench_chrome.dart';
import 'package:dsh_app/ui/theme/glass.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    expect(find.byKey(const ValueKey('cli-icon-claude')), findsWidgets);
    expect(find.byKey(const ValueKey('cli-icon-codex')), findsWidgets);
    expect(find.text('向 Antigravity 终端发送输入...'), findsOneWidget);
  });

  test('resolveCliModelSelection normalizes display names and effort suffixes', () {
    const catalog = ModelCatalog(
      defaultSelection: ModelSelection(provider: 'gemini', model: 'gemini-4-neon', reasoningEffort: 'high'),
      routableProviders: ['gemini'],
      groups: [
        ProviderGroup('gemini', 'Gemini', [
          ModelInfo(
            provider: 'gemini',
            id: 'gemini-4-neon',
            name: 'Gemini 4 Neon',
            efforts: [ReasoningEffort('medium', 'Medium', null), ReasoningEffort('high', 'High', null)],
            defaultEffort: 'high',
          ),
        ]),
      ],
      failures: [],
    );

    final byLabel = resolveCliModelSelection(catalog, 'Gemini 4 Neon Medium', CliEngine.antigravity);
    expect(byLabel?.provider, 'gemini');
    expect(byLabel?.model, 'gemini-4-neon');
    expect(byLabel?.reasoningEffort, 'medium');

    final byWire = resolveCliModelSelection(catalog, 'gemini-4-neon-high', CliEngine.antigravity);
    expect(byWire?.provider, 'gemini');
    expect(byWire?.model, 'gemini-4-neon');
    expect(byWire?.reasoningEffort, 'high');
  });

  testWidgets('Antigravity model sheet shows only Antigravity models and hides DSH manage link', (tester) async {
    useWindow(tester, const Size(1280, 800));
    mockClipboard(tester);
    final extSessions = [
      _cliSession(engine: CliEngine.antigravity, rawId: 'agy-1', title: 'Larch-4N', running: false),
    ];
    const agyCatalog = ModelCatalog(
      defaultSelection: ModelSelection(provider: 'gemini', model: 'gemini-4-neon', reasoningEffort: 'high'),
      routableProviders: ['gemini'],
      groups: [
        ProviderGroup('gemini', 'Gemini', [
          ModelInfo(
            provider: 'gemini',
            id: 'gemini-4-neon',
            name: 'Gemini 4 Neon',
            efforts: [ReasoningEffort('low', 'Low', null), ReasoningEffort('high', 'High', null)],
            defaultEffort: 'high',
          ),
        ]),
      ],
      failures: [],
    );

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
          workbenchBridgeModelsProvider(CliEngine.antigravity).overrideWith((ref) async => agyCatalog),
          terminalBackendProvider.overrideWith((ref, id) => FakeTerminalBackend(supported: false)),
        ],
      ),
    );
    await pumpFrames(tester, 4);

    // 顶栏模型胶囊显示 ModelChip，点击弹出 Antigravity 专属模型面板
    final chip = find.byType(ModelChip);
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await pumpFrames(tester, 4);

    expect(find.text('Antigravity 模型'), findsOneWidget);
    expect(find.text('Gemini 4 Neon'), findsOneWidget);
    expect(find.text('管理模型'), findsNothing);
    expect(find.text('V4.1 Flash'), findsNothing);
  });

  testWidgets('top agent tabs switch engines and + opens per-agent new chat', (tester) async {
    useWindow(tester, const Size(1280, 800));
    mockClipboard(tester);
    final extSessions = [
      _cliSession(engine: CliEngine.antigravity, rawId: 'agy-1', title: 'Larch-4N', running: false),
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

    expect(find.byKey(const ValueKey('workbench-engine-tab-dsh')), findsOneWidget);
    expect(find.byKey(const ValueKey('workbench-engine-tab-antigravity')), findsOneWidget);
    expect(find.byKey(const ValueKey('workbench-engine-tab-codex')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('workbench-engine-tab-codex')));
    await pumpFrames(tester, 4);
    await tester.tap(find.byKey(const ValueKey('workbench-new-chat')));
    await pumpFrames(tester, 4);

    expect(find.text('Codex 新对话'), findsOneWidget);
    expect(find.text('向 Codex 终端发送输入...'), findsOneWidget);
  });

  test('sessionMatchesWorkspacePath matches Windows/POSIX paths, subdirectories, and ignores unrelated paths', () {
    expect(sessionMatchesWorkspacePath(r'D:\dev\workspace', 'd:/dev/workspace/'), isTrue);
    expect(sessionMatchesWorkspacePath('D:/dev/workspace/sub/pkg', r'd:\dev\workspace'), isTrue);
    expect(sessionMatchesWorkspacePath('D:/dev/workspace2', 'D:/dev/workspace'), isFalse);
    expect(sessionMatchesWorkspacePath('/home/user/repo', '/home/user/repo'), isTrue);
    expect(sessionMatchesWorkspacePath(null, 'D:/dev/workspace'), isFalse);
  });

  test('CliModelPrefsController persists engine defaults and session pins and strips orchestrator effort', () async {
    final c1 = ProviderContainer();
    addTearDown(c1.dispose);
    final n1 = c1.read(cliModelPrefsProvider.notifier);
    await n1.ensureLoaded();

    await n1.saveEngineDefault(
      CliEngine.antigravity,
      const ModelSelection(provider: 'orchestrator', model: 'gemini-pro-orchestrator-neon', reasoningEffort: 'high'),
    );
    await n1.saveSessionModel(
      'cli:codex:cx-1',
      CliEngine.codex,
      const ModelSelection(provider: 'codex', model: 'gpt-6.2-sol', reasoningEffort: 'xhigh'),
    );

    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    final n2 = c2.read(cliModelPrefsProvider.notifier);
    await n2.ensureLoaded();
    final restored = c2.read(cliModelPrefsProvider);

    expect(restored.loaded, isTrue);
    expect(restored.forEngine(CliEngine.antigravity)?.model, 'gemini-pro-orchestrator-neon');
    expect(restored.forEngine(CliEngine.antigravity)?.reasoningEffort, isNull);
    expect(restored.forSession('cli:codex:cx-1')?.model, 'gpt-6.2-sol');
    expect(restored.forSession('cli:codex:cx-1')?.reasoningEffort, 'xhigh');
    expect(restored.forEngine(CliEngine.codex)?.model, 'gpt-6.2-sol');
  });

  testWidgets('Antigravity Orchestrator shows fixed effort note in model sheet', (tester) async {
    useWindow(tester, const Size(1280, 800));
    mockClipboard(tester);
    final extSessions = [
      _cliSession(engine: CliEngine.antigravity, rawId: 'agy-1', title: 'Larch-4N', running: false),
    ];
    const agyCatalog = ModelCatalog(
      defaultSelection: ModelSelection(provider: 'gemini', model: 'gemini-4-neon', reasoningEffort: 'high'),
      routableProviders: ['gemini', 'orchestrator'],
      groups: [
        ProviderGroup('gemini', 'Gemini', [
          ModelInfo(
            provider: 'gemini',
            id: 'gemini-4-neon',
            name: 'Gemini 4 Neon',
            efforts: [ReasoningEffort('low', 'Low', null), ReasoningEffort('high', 'High', null)],
            defaultEffort: 'high',
          ),
        ]),
        ProviderGroup('orchestrator', 'Orchestrator', [
          ModelInfo(
            provider: 'orchestrator',
            id: 'gemini-pro-orchestrator-neon',
            name: 'Orchestrator (Neon)',
            efforts: [],
          ),
        ]),
      ],
      failures: [],
    );

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
          workbenchBridgeModelsProvider(CliEngine.antigravity).overrideWith((ref) async => agyCatalog),
          terminalBackendProvider.overrideWith((ref, id) => FakeTerminalBackend(supported: false)),
        ],
      ),
    );
    await pumpFrames(tester, 4);

    await tester.tap(find.byType(ModelChip));
    await pumpFrames(tester, 4);

    await tester.tap(find.text('Orchestrator'));
    await pumpFrames(tester, 4);
    await tester.tap(find.text('Orchestrator (Neon)'));
    await pumpFrames(tester, 4);

    expect(find.byKey(const ValueKey('orchestrator-effort-note')), findsOneWidget);
  });

  testWidgets('workbench header fuses with theme glass without hardcoded blue-grey slab', (tester) async {
    useWindow(tester, const Size(1280, 800));
    mockClipboard(tester);
    final extSessions = [
      _cliSession(engine: CliEngine.antigravity, rawId: 'agy-1', title: 'Larch-4N', running: false),
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

    final tabBar = find.byType(WorkbenchTabBar);
    expect(tabBar, findsOneWidget);
    // 左圆标、DSH 与 Antigravity 两个智能体胶囊、右 + 按钮，共 4 个 GlassSurface。
    expect(find.descendant(of: tabBar, matching: find.byType(GlassSurface)), findsNWidgets(4));

    final hardcodedBoxes = tester.widgetList<ColoredBox>(find.byType(ColoredBox)).where(
      (b) => b.color == const Color(0xFFE7EEF5),
    );
    expect(hardcodedBoxes, isEmpty);
  });

  test('external CLI tool names map cleanly in TurnSummary, ToolGlyphs, and ToolView without falling into Other', () {
    final tools = [
      const ToolChatItem(
        callId: 'c1',
        name: 'read_file',
        arguments: '{"Path":"D:/dev/app/lib/main.dart"}',
        status: ToolStatus.succeeded,
        seq: 1,
      ),
      const ToolChatItem(
        callId: 'c2',
        name: 'edit_file',
        arguments: '{"Path":"D:/dev/app/lib/state.dart"}',
        status: ToolStatus.succeeded,
        seq: 2,
      ),
      const ToolChatItem(
        callId: 'c3',
        name: 'run_command',
        arguments: '{"CommandLine":"flutter test"}',
        status: ToolStatus.succeeded,
        seq: 3,
      ),
      const ToolChatItem(
        callId: 'c4',
        name: 'grep_search',
        arguments: '{"Query":"WorkbenchTabBar"}',
        status: ToolStatus.succeeded,
        seq: 4,
      ),
      const ToolChatItem(
        callId: 'c5',
        name: 'update_steps',
        arguments: '{"steps":[{"title":"step1","status":"done"}]}',
        status: ToolStatus.succeeded,
        seq: 5,
      ),
    ];

    final summary = summarizeTools(tools);
    expect(summary.other, 0);
    expect(summary.readFiles, 1);
    expect(summary.editedFiles, 1);
    expect(summary.commands, 1);
    expect(summary.searches, 1);
    expect(summary.todos, 1);

    expect(ToolView.of(tools[0]).path, 'D:/dev/app/lib/main.dart');
    expect(ToolView.of(tools[2]).command, 'flutter test');
    expect(ToolView.of(tools[3]).summary, 'WorkbenchTabBar');
    expect(ToolGlyphs.toneFor('read_file'), ToolGlyphs.toneFor('read'));
    expect(ToolGlyphs.toneFor('run_command'), ToolGlyphs.toneFor('bash'));
  });
}
