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
      final files = [
        for (final p in msg.parts.whereType<FilePart>()) p.attachment,
        for (final p in msg.parts.whereType<ImagePart>())
          FileAttachment(attachmentId: p.attachment.attachmentId, name: p.attachment.name ?? 'image', bytes: p.attachment.bytes),
      ];
      if (text.trim().isEmpty && files.isEmpty) continue;
      items.add(
        UserChatItem(
          seq: seq,
          time: msg.createdAt,
          text: text,
          images: const [],
          files: files,
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
  Completer<void>? _cancelCompleter;

  void _cancelPending() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final completer = _cancelCompleter;
    _cancelCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  @override
  List<SessionSummary> build() {
    final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
    if (!identical(client, _owner)) {
      _owner = client;
      _etag = null;
      _generation += 1;
    }
    _cancelPending();

    ref.onDispose(() {
      _generation += 1;
      _cancelPending();
    });

    if (client == null) {
      return const [];
    }

    final gen = _generation;
    unawaited(_fetch(client, gen));
    return const [];
  }

  Future<void> refresh() async {
    final client = _owner;
    if (client == null) return;
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
    final prev = _cancelCompleter;
    if (prev != null && !prev.isCompleted) prev.complete();
    final cancel = Completer<void>.sync();
    _cancelCompleter = cancel;
    try {
      final result = await client.readWorkbenchBridgeSessions(
        ifNoneMatch: _etag,
        cancelSignal: cancel.future,
      );
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
    } finally {
      if (identical(_cancelCompleter, cancel)) _cancelCompleter = null;
    }
  }
}

final workbenchBridgeSessionsProvider =
    NotifierProvider<WorkbenchBridgeSessionsController, List<SessionSummary>>(
      WorkbenchBridgeSessionsController.new,
    );

/// 探测宿主机上已安装的外部 CLI 智能体健康状态。
final workbenchBridgeHealthProvider = FutureProvider<WorkbenchBridgeHealth?>((ref) async {
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null) return null;
  try {
    return await client.readWorkbenchBridgeHealth();
  } on WorkbenchBridgeUnavailableException {
    return null;
  } on DshRemoteException {
    return null;
  } catch (_) {
    return null;
  }
});

/// 拉取指定外部 CLI 智能体自身支持的模型目录（与 DSH 原生模型目录彻底隔离）。
final workbenchBridgeModelsProvider = FutureProvider.family<ModelCatalog?, CliEngine>((ref, engine) async {
  if (engine == CliEngine.dsh) return null;
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null) return null;
  try {
    return await client.readWorkbenchBridgeModels(engine);
  } on WorkbenchBridgeUnavailableException {
    return null;
  }
});

/// 将外部快照中记录的模型名称（如 `Gemini 4 Neon Medium` 或 `gemini-4-neon-medium`）
/// 规范化匹配到外部智能体目录中对应的 `ModelSelection`。
ModelSelection? resolveCliModelSelection(ModelCatalog? catalog, String? rawModel, CliEngine engine) {
  final raw = rawModel?.trim();
  if (raw == null || raw.isEmpty) return null;
  if (catalog == null || catalog.models.isEmpty) {
    return ModelSelection(provider: engine.wire, model: raw);
  }
  final normalized = raw.toLowerCase().replaceAll(RegExp(r'[\s_()]+'), '-').replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-|-$'), '');
  for (final model in catalog.models) {
    final modelNorm = model.id.toLowerCase();
    final nameNorm = model.name.toLowerCase().replaceAll(RegExp(r'[\s_()]+'), '-').replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-|-$'), '');
    if (normalized == modelNorm || normalized == nameNorm || raw.toLowerCase() == modelNorm) {
      return ModelSelection(
        provider: model.provider,
        model: model.id,
        reasoningEffort: model.defaultEffort ?? (model.efforts.isEmpty ? null : model.efforts.first.id),
      );
    }
    for (final effort in model.efforts) {
      final suffix = '-${effort.id.toLowerCase()}';
      if (normalized == '$modelNorm$suffix' || normalized == '$nameNorm$suffix') {
        return ModelSelection(provider: model.provider, model: model.id, reasoningEffort: effort.id);
      }
    }
  }
  return ModelSelection(provider: engine.wire, model: raw);
}

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
