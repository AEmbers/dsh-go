import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'sessions_state.dart';

/// 将桥接返回的多 CLI 消息快照折叠为通用 [ChatItem] 列表，直接复用现有聊天渲染层。
List<ChatItem> cliSnapshotToChatItems(WorkbenchCliChatSnapshot snapshot) {
  final items = <ChatItem>[];
  var seq = 0;
  for (final msg in snapshot.messages) {
    seq += 1;
    if (msg.role == MessageRole.user) {
      final text = msg.parts.whereType<TextPart>().map((p) => p.text).join('\n');
      if (text.trim().isEmpty) continue;
      items.add(
        UserChatItem(
          seq: seq,
          time: msg.createdAt,
          text: text,
          images: const [],
          files: const [],
        ),
      );
      continue;
    }

    final text = msg.parts.whereType<TextPart>().map((p) => p.text).join('\n');
    final reasoning = msg.parts.whereType<ReasoningPart>().map((p) => p.text).join('\n');
    final tools = msg.parts.whereType<ToolCallPart>().toList(growable: false);

    if (text.trim().isNotEmpty || reasoning.trim().isNotEmpty) {
      items.add(
        AssistantChatItem(
          id: msg.messageId.isNotEmpty ? msg.messageId : 'cli-a-$seq',
          seq: seq,
          time: msg.createdAt,
          text: text,
          reasoning: reasoning,
          streaming: snapshot.running && identical(msg, snapshot.messages.last),
          model: msg.model ?? snapshot.model,
        ),
      );
    }

    for (final call in tools) {
      items.add(
        ToolChatItem(
          callId: call.id,
          name: call.name,
          arguments: call.arguments,
          status: snapshot.running && identical(msg, snapshot.messages.last)
              ? ToolStatus.running
              : ToolStatus.succeeded,
          seq: seq,
        ),
      );
    }
  }
  return List.unmodifiable(items);
}

/// 聚合宿主机上 `dsh-workbench-bridge` 插件暴露的外部 CLI 会话（Antigravity / Claude / Codex）。
///
/// 当宿主未安装桥接插件（404/503）或连接不是 HTTP 载具时，静默返回空列表，不影响纯 DSH 使用。
class WorkbenchBridgeSessionsController extends Notifier<List<SessionSummary>> {
  String? _etag;
  DshClient? _owner;
  var _generation = 0;
  Timer? _pollTimer;

  @override
  List<SessionSummary> build() {
    final conn = ref.watch(activeConnectionProvider).value;
    final client = conn?.state == DshConnectionState.connected ? conn?.client : null;
    if (!identical(client, _owner)) {
      _owner = client;
      _etag = null;
      _generation += 1;
    }
    _pollTimer?.cancel();
    _pollTimer = null;

    ref.onDispose(() {
      _pollTimer?.cancel();
      _pollTimer = null;
      _generation += 1;
    });

    if (client == null || client.carrier is! DshHttpCarrier) {
      return const [];
    }

    final gen = _generation;
    unawaited(_fetch(client, gen));
    return const [];
  }

  Future<void> refresh() async {
    final client = _owner;
    if (client == null || client.carrier is! DshHttpCarrier) return;
    _etag = null;
    await _fetch(client, _generation);
  }

  void _schedulePoll(DshClient client, int gen) {
    _pollTimer?.cancel();
    _pollTimer = Timer(const Duration(seconds: 6), () {
      if (ref.mounted && identical(client, _owner) && gen == _generation) {
        unawaited(_fetch(client, gen));
      }
    });
  }

  Future<void> _fetch(DshClient client, int gen) async {
    try {
      final result = await client.readWorkbenchBridgeSessions(ifNoneMatch: _etag);
      if (!ref.mounted || !identical(client, _owner) || gen != _generation) return;
      if (result != null) {
        _etag = result.etag;
        state = [for (final s in result.sessions) s.toSessionSummary()];
      }
      if (state.any((s) => s.running)) _schedulePoll(client, gen);
    } on WorkbenchBridgeUnavailableException {
      if (!ref.mounted || !identical(client, _owner) || gen != _generation) return;
      state = const [];
    } on DshRemoteException {
      if (!ref.mounted || !identical(client, _owner) || gen != _generation) return;
      state = const [];
    } catch (_) {
      // 网络瞬断时保留已有投影并在下一周期重试
      if (ref.mounted && identical(client, _owner) && gen == _generation) {
        _schedulePoll(client, gen);
      }
    }
  }
}

final workbenchBridgeSessionsProvider =
    NotifierProvider<WorkbenchBridgeSessionsController, List<SessionSummary>>(
      WorkbenchBridgeSessionsController.new,
    );

/// 合并原生 DSH 会话与外部多 CLI 桥接会话；去重并按最近更新排序。
final mergedSessionsProvider = Provider<AsyncValue<List<SessionSummary>>>((ref) {
  final native = ref.watch(sessionsProvider);
  final bridge = ref.watch(workbenchBridgeSessionsProvider);
  return native.whenData((rows) {
    if (bridge.isEmpty) return rows;
    final seen = <String>{for (final row in rows) row.sessionId};
    final combined = <SessionSummary>[
      ...rows,
      for (final ext in bridge)
        if (seen.add(ext.sessionId)) ext,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return combined;
  });
});
