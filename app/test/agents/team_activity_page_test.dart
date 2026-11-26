import 'package:dsh_app/state/agent_teams_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/agents/team_activity_page.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart' show FixedSession;
import '../providers/support.dart' show settle;
import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

class _FakeTunnelCarrier extends DshCarrier {
  _FakeTunnelCarrier(this._onBridgeRpc);

  final Future<Map<String, Object?>?> Function(String method, Map<String, Object?> params) _onBridgeRpc;

  @override
  String get kind => 'fake-remote-rpc';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) => throw UnimplementedError();

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();

  @override
  Future<Map<String, Object?>?> invokeWorkbenchBridgeRpc(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) => _onBridgeRpc(method, params);

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('TeamActivityPage shows friendly hint without stack trace and stops 10s polling on unsupported tunnel', (
    tester,
  ) async {
    await tester.runAsync(loadGoldenFonts);
    var hits = 0;
    final client = await tester.runAsync(() async {
      final carrier = _FakeTunnelCarrier((method, _) async {
        if (method == 'workbench.bridge.agentTeams.state') {
          hits++;
          throw const DshRemoteException('METHOD_NOT_FOUND', 'unknown');
        }
        return null;
      });
      return DshClient.connectCarrier(carrier, startMux: false);
    });
    addTearDown(() async => tester.runAsync(() async => client!.close()));

    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(780, 1688);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      goldenApp(
        home: const TeamActivityPage(),
        brightness: Brightness.light,
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData<HostConnection?>(HostConnection(client: client!, isLocal: false)),
          ),
          currentSessionProvider.overrideWith(() => FixedSession('session-cap')),
          localSafeModeProvider.overrideWithValue(false),
          installedPluginsProvider.overrideWith(
            () => FakeInstalled([const PluginBundle(name: agentTeamsBundleName, enabled: true, installed: true)]),
          ),
        ],
      ),
    );
    await settle(tester);

    expect(hits, 1);
    expect(find.text('读取团队状态失败'), findsOneWidget);
    expect(
      find.text('当前远程连接暂不支持团队面板接口，请更新并重启宿主机 dsh-workbench-bridge，或改用局域网直连。'),
      findsOneWidget,
    );
    expect(find.textContaining('AsyncError'), findsNothing);
    expect(find.textContaining('stackTrace'), findsNothing);
    expect(find.textContaining('#0'), findsNothing);

    // 推进 25 秒（超过原 10 秒轮询间隔），确认不再重复触发请求
    await tester.pump(const Duration(seconds: 25));
    expect(hits, 1);
  });

  testWidgets('TeamActivityPage renders team snapshot received over remote bridge RPC', (tester) async {
    await tester.runAsync(loadGoldenFonts);
    final client = await tester.runAsync(() async {
      final carrier = _FakeTunnelCarrier((method, _) async {
        if (method == 'workbench.bridge.agentTeams.state') {
          return {
            'status': 200,
            'etag': '"rpc-ui-1"',
            'body': {
              'teams': [
                {
                  'teamId': 'team-remote-1',
                  'name': '远程协作团队',
                  'workspace': 'dsh-go',
                  'captainSessionId': 'session-cap',
                  'phase': 'running',
                  'members': [
                    {
                      'id': 'session-cap',
                      'name': 'captain',
                      'role': 'captain',
                      'status': 'active',
                      'activity': 'working',
                      'progress': 50,
                      'done': 1,
                      'total': 2,
                    },
                  ],
                  'tasks': [
                    {
                      'id': 't1',
                      'subject': '打通隧道转发',
                      'status': 'in_progress',
                      'state': 'running',
                      'assignee': 'captain',
                      'dependencies': [],
                      'depth': 0,
                    },
                  ],
                },
              ],
            },
          };
        }
        return null;
      });
      return DshClient.connectCarrier(carrier, startMux: false);
    });
    addTearDown(() async => tester.runAsync(() async => client!.close()));

    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(780, 1688);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      goldenApp(
        home: const TeamActivityPage(),
        brightness: Brightness.light,
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData<HostConnection?>(HostConnection(client: client!, isLocal: false)),
          ),
          currentSessionProvider.overrideWith(() => FixedSession('session-cap')),
          localSafeModeProvider.overrideWithValue(false),
          installedPluginsProvider.overrideWith(
            () => FakeInstalled([const PluginBundle(name: agentTeamsBundleName, enabled: true, installed: true)]),
          ),
        ],
      ),
    );
    await settle(tester);

    expect(find.text('远程协作团队'), findsOneWidget);
    expect(find.text('captain'), findsAtLeastNWidgets(1));
    expect(find.text('读取团队状态失败'), findsNothing);

    await tester.tap(
      find.descendant(of: find.byWidgetPredicate((w) => w is SegmentedPill), matching: find.text('任务')),
    );
    await settle(tester);
    expect(find.text('打通隧道转发'), findsOneWidget);
  });
}
