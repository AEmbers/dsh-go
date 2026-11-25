// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 规范化外部 CLI 模型选择。
///
/// Antigravity CLI 的 Orchestrator 模型使用固定思考预算，传入 `--effort` 会直接报错，
/// 因此这里强制剥离其 `reasoningEffort`。
ModelSelection normalizeCliModelSelection(CliEngine engine, ModelSelection selection) {
  if (engine == CliEngine.antigravity &&
      (selection.provider == 'orchestrator' || selection.model.toLowerCase().contains('orchestrator'))) {
    if (selection.reasoningEffort == null) return selection;
    return ModelSelection(provider: selection.provider, model: selection.model);
  }
  return selection;
}

/// 外部 CLI（Antigravity / Codex / Claude）的本地持久化模型偏好。
class CliModelPrefsState {
  const CliModelPrefsState({
    this.byEngine = const {},
    this.bySession = const {},
    this.loaded = false,
  });

  final Map<CliEngine, ModelSelection> byEngine;
  final Map<String, ModelSelection> bySession;
  final bool loaded;

  ModelSelection? forEngine(CliEngine engine) => byEngine[engine];

  ModelSelection? forSession(String sessionId) => bySession[sessionId];

  CliModelPrefsState copyWith({
    Map<CliEngine, ModelSelection>? byEngine,
    Map<String, ModelSelection>? bySession,
    bool? loaded,
  }) => CliModelPrefsState(
    byEngine: byEngine ?? this.byEngine,
    bySession: bySession ?? this.bySession,
    loaded: loaded ?? this.loaded,
  );
}

/// 通过 `SharedPreferences` 持久化保存外部智能体的默认模型与单会话置顶模型。
class CliModelPrefsController extends Notifier<CliModelPrefsState> {
  static const _enginePrefsKey = 'workbench_cli_model_by_engine_v1';
  static const _sessionPrefsKey = 'workbench_cli_model_by_session_v1';
  static const _maxSessionEntries = 120;

  late Future<void> _loadedFuture;

  @override
  CliModelPrefsState build() {
    _loadedFuture = _load();
    return const CliModelPrefsState();
  }

  /// 等待磁盘中的持久化模型偏好加载完成。
  Future<void> ensureLoaded() => _loadedFuture;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final diskByEngine = _decodeEngineMap(prefs.getString(_enginePrefsKey));
      final diskBySession = _decodeSessionMap(prefs.getString(_sessionPrefsKey));
      // 内存中的最新操作优先于磁盘旧值，避免异步加载覆盖刚选中的模型。
      final mergedEngine = <CliEngine, ModelSelection>{...diskByEngine, ...state.byEngine};
      final mergedSession = _trimSessions(<String, ModelSelection>{...diskBySession, ...state.bySession});
      state = CliModelPrefsState(
        byEngine: Map.unmodifiable(mergedEngine),
        bySession: Map.unmodifiable(mergedSession),
        loaded: true,
      );
    } catch (_) {
      if (ref.mounted) {
        state = state.copyWith(loaded: true);
      }
    }
  }

  /// 保存指定外部 CLI 智能体的默认模型（用于新对话与未单独指定模型的会话回退）。
  Future<void> saveEngineDefault(CliEngine engine, ModelSelection selection) async {
    if (engine == CliEngine.dsh) return;
    final normalized = normalizeCliModelSelection(engine, selection);
    final nextEngine = <CliEngine, ModelSelection>{...state.byEngine, engine: normalized};
    state = state.copyWith(byEngine: Map.unmodifiable(nextEngine));
    await _loadedFuture;
    if (!ref.mounted) return;
    final merged = <CliEngine, ModelSelection>{...state.byEngine, engine: normalized};
    state = state.copyWith(byEngine: Map.unmodifiable(merged));
    await _persist();
  }

  /// 保存单个外部 CLI 会话置顶的模型，并同步更新该引擎的最近默认模型。
  Future<void> saveSessionModel(String sessionId, CliEngine engine, ModelSelection selection) async {
    if (engine == CliEngine.dsh || sessionId.isEmpty) return;
    final normalized = normalizeCliModelSelection(engine, selection);
    final nextEngine = <CliEngine, ModelSelection>{...state.byEngine, engine: normalized};
    final nextSession = <String, ModelSelection>{...state.bySession}
      ..remove(sessionId)
      ..[sessionId] = normalized;
    state = state.copyWith(
      byEngine: Map.unmodifiable(nextEngine),
      bySession: Map.unmodifiable(_trimSessions(nextSession)),
    );
    await _loadedFuture;
    if (!ref.mounted) return;
    final mergedEngine = <CliEngine, ModelSelection>{...state.byEngine, engine: normalized};
    final mergedSession = <String, ModelSelection>{...state.bySession}
      ..remove(sessionId)
      ..[sessionId] = normalized;
    state = state.copyWith(
      byEngine: Map.unmodifiable(mergedEngine),
      bySession: Map.unmodifiable(_trimSessions(mergedSession)),
    );
    await _persist();
  }

  /// 当临时会话（`pending-*`）解析为真实 `sessionId` 时，迁移其持久化置顶模型。
  Future<void> migrateSessionModel(String fromSessionId, String toSessionId, CliEngine engine) async {
    if (engine == CliEngine.dsh || fromSessionId.isEmpty || toSessionId.isEmpty || fromSessionId == toSessionId) {
      return;
    }
    await _loadedFuture;
    if (!ref.mounted) return;
    final saved = state.bySession[fromSessionId];
    if (saved == null) return;
    final normalized = normalizeCliModelSelection(engine, saved);
    final nextSession = <String, ModelSelection>{...state.bySession};
    if (fromSessionId.contains(':pending-')) {
      nextSession.remove(fromSessionId);
    }
    nextSession.remove(toSessionId);
    nextSession[toSessionId] = normalized;
    state = state.copyWith(bySession: Map.unmodifiable(_trimSessions(nextSession)));
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enginePayload = <String, dynamic>{
        for (final entry in state.byEngine.entries) entry.key.wire: _encodeSelection(entry.value),
      };
      final sessionPayload = <String, dynamic>{
        for (final entry in state.bySession.entries) entry.key: _encodeSelection(entry.value),
      };
      await prefs.setString(_enginePrefsKey, jsonEncode(enginePayload));
      await prefs.setString(_sessionPrefsKey, jsonEncode(sessionPayload));
    } catch (_) {
      // 忽略持久化写入失败，不影响当次交互。
    }
  }

  static Map<String, ModelSelection> _trimSessions(Map<String, ModelSelection> map) {
    if (map.length <= _maxSessionEntries) return map;
    final keys = map.keys.skip(map.length - _maxSessionEntries).toList(growable: false);
    return {for (final k in keys) k: map[k]!};
  }

  static Map<CliEngine, ModelSelection> _decodeEngineMap(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final result = <CliEngine, ModelSelection>{};
      for (final entry in decoded.entries) {
        final engine = CliEngine.parse(entry.key.toString());
        if (engine == CliEngine.dsh) continue;
        final sel = _decodeSelection(entry.value);
        if (sel != null) {
          result[engine] = normalizeCliModelSelection(engine, sel);
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  static Map<String, ModelSelection> _decodeSessionMap(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final result = <String, ModelSelection>{};
      for (final entry in decoded.entries) {
        final sessionId = entry.key.toString();
        if (sessionId.isEmpty) continue;
        final sel = _decodeSelection(entry.value);
        if (sel != null) {
          final engine = CliSessionRef.parse(sessionId)?.engine;
          result[sessionId] = engine == null ? sel : normalizeCliModelSelection(engine, sel);
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  static Map<String, dynamic> _encodeSelection(ModelSelection selection) => {
    'provider': selection.provider,
    'model': selection.model,
    if (selection.reasoningEffort != null) 'reasoningEffort': selection.reasoningEffort,
  };

  static ModelSelection? _decodeSelection(Object? value) {
    if (value is! Map) return null;
    final provider = value['provider']?.toString().trim() ?? '';
    final model = value['model']?.toString().trim() ?? '';
    if (provider.isEmpty || model.isEmpty) return null;
    final effortRaw = value['reasoningEffort']?.toString().trim();
    return ModelSelection(
      provider: provider,
      model: model,
      reasoningEffort: (effortRaw == null || effortRaw.isEmpty) ? null : effortRaw,
    );
  }
}

final cliModelPrefsProvider = NotifierProvider<CliModelPrefsController, CliModelPrefsState>(
  CliModelPrefsController.new,
);
