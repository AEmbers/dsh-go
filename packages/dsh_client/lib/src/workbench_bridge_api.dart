/// Multi-CLI bridge client (`/plugins/dsh-workbench-bridge/*`).
///
/// Connects DSH Go to the `dsh-workbench-bridge` plugin on the Host so that
/// Antigravity, Claude Code, and Codex sessions appear alongside native DSH
/// conversations, with live message sync, prompt execution, and abort control.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'carrier.dart';
import 'connection.dart';
import 'errors.dart';
import 'files_api.dart';
import 'json.dart';
import 'models.dart';
import 'session_api.dart';
import 'workspace_api.dart';

const workbenchBridgeHealthPath = '/plugins/dsh-workbench-bridge/health';
const workbenchBridgeSessionsPath = '/plugins/dsh-workbench-bridge/sessions';
const workbenchBridgeModelsPath = '/plugins/dsh-workbench-bridge/models';
const workbenchBridgeUploadPath = '/plugins/dsh-workbench-bridge/uploads';
const workbenchBridgePromptPath = '/plugins/dsh-workbench-bridge/sessions/prompt';
const workbenchBridgeAbortPath = '/plugins/dsh-workbench-bridge/sessions/abort';
const workbenchBridgeFileStatPath = '/plugins/dsh-workbench-bridge/files/stat';
const workbenchBridgeFileReadBytesPath = '/plugins/dsh-workbench-bridge/files/read-bytes';
const workbenchBridgeFileReadTextPath = '/plugins/dsh-workbench-bridge/files/read-text';
const workbenchBridgeFileListPath = '/plugins/dsh-workbench-bridge/files/list';

const _maxReplyBytes = 4 * 1024 * 1024;
const _uploadChunkBytes = 192 * 1024;
const _bridgeFileWindowBytes = 512 * 1024;

/// Supported CLI engines in the unified multi-CLI workbench.
enum CliEngine {
  dsh('dsh', 'DSH'),
  antigravity('antigravity', 'Antigravity'),
  claude('claude', 'Claude'),
  codex('codex', 'Codex');

  const CliEngine(this.wire, this.label);

  final String wire;
  final String label;

  static CliEngine parse(Object? value) {
    final s = asString(value)?.trim().toLowerCase();
    return switch (s) {
      'antigravity' || 'agy' => CliEngine.antigravity,
      'claude' || 'claude-code' => CliEngine.claude,
      'codex' => CliEngine.codex,
      _ => CliEngine.dsh,
    };
  }
}

/// Parsed external CLI session reference (`cli:<engine>:<rawId>`).
class CliSessionRef {
  const CliSessionRef(this.engine, this.rawId);

  final CliEngine engine;
  final String rawId;

  String get sessionId => 'cli:${engine.wire}:$rawId';

  static CliSessionRef? parse(String? sessionId) {
    if (sessionId == null || !sessionId.startsWith('cli:')) return null;
    final parts = sessionId.split(':');
    if (parts.length < 3) return null;
    final engine = CliEngine.parse(parts[1]);
    if (engine == CliEngine.dsh) return null;
    final rawId = parts.sublist(2).join(':');
    if (rawId.isEmpty) return null;
    return CliSessionRef(engine, rawId);
  }
}

/// Convenience helpers on [SessionSummary] without altering its core constructor.
extension CliSessionSummary on SessionSummary {
  CliEngine get cliEngine {
    final byId = CliSessionRef.parse(sessionId);
    if (byId != null) return byId.engine;
    final byRaw = raw['cliEngine'];
    if (byRaw != null) return CliEngine.parse(byRaw);
    return CliEngine.dsh;
  }

  bool get isExternalCli => cliEngine != CliEngine.dsh;
}

class CliEngineAvailability {
  const CliEngineAvailability({required this.engine, required this.installed, this.executable});

  final CliEngine engine;
  final bool installed;
  final String? executable;
}

class WorkbenchBridgeHealth {
  const WorkbenchBridgeHealth({required this.ok, required this.engines});

  factory WorkbenchBridgeHealth.fromJson(Map<String, Object?> json) {
    final rawEngines = asMapOrEmpty(json['engines']);
    final engines = <CliEngine, CliEngineAvailability>{};
    for (final engine in [CliEngine.antigravity, CliEngine.claude, CliEngine.codex]) {
      final entry = asMapOrEmpty(rawEngines[engine.wire]);
      engines[engine] = CliEngineAvailability(
        engine: engine,
        installed: entry['installed'] == true,
        executable: asString(entry['executable']),
      );
    }
    return WorkbenchBridgeHealth(ok: json['ok'] != false, engines: engines);
  }

  final bool ok;
  final Map<CliEngine, CliEngineAvailability> engines;
}

class WorkbenchCliSession {
  const WorkbenchCliSession({
    required this.engine,
    required this.rawId,
    required this.sessionId,
    required this.title,
    required this.updatedAt,
    required this.running,
    this.blank = false,
    this.cwd,
    this.model,
    this.raw = const {},
  });

  factory WorkbenchCliSession.fromJson(Map<String, Object?> json) {
    final engine = CliEngine.parse(json['engine']);
    final rawId = asString(json['rawId']) ?? '';
    final sessionId = asString(json['sessionId']) ?? 'cli:${engine.wire}:$rawId';
    return WorkbenchCliSession(
      engine: engine,
      rawId: rawId,
      sessionId: sessionId,
      title: (asString(json['title']) ?? '').trim().isNotEmpty ? asString(json['title'])!.trim() : rawId,
      updatedAt: asEpochMs(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      running: json['running'] == true,
      blank: json['blank'] == true,
      cwd: asString(json['cwd']),
      model: asString(json['model']),
      raw: json,
    );
  }

  final CliEngine engine;
  final String rawId;
  final String sessionId;
  final String title;
  final DateTime updatedAt;
  final bool running;
  final bool blank;
  final String? cwd;
  final String? model;
  final Map<String, Object?> raw;

  /// Adapts this external CLI session into a [SessionSummary] compatible with
  /// the app's drawer, tabs, and header chrome.
  SessionSummary toSessionSummary() => SessionSummary(
    sessionId: sessionId,
    updatedAt: updatedAt,
    running: running,
    blank: blank,
    agentAvailable: true,
    cwd: cwd,
    projections: SessionProjections(1, {'title': title, 'blank': blank}),
    projectionsKind: 'cli-bridge',
    raw: {...raw, 'cliEngine': engine.wire, 'rawId': rawId},
  );
}

class WorkbenchBridgeSessions {
  const WorkbenchBridgeSessions({required this.sessions, this.etag});

  final List<WorkbenchCliSession> sessions;
  final String? etag;
}

class WorkbenchCliMessage {
  const WorkbenchCliMessage({
    required this.messageId,
    required this.role,
    required this.createdAt,
    required this.parts,
    this.model,
  });

  factory WorkbenchCliMessage.fromJson(Map<String, Object?> json) {
    final role = MessageRole.parse(json['role']);
    return WorkbenchCliMessage(
      messageId: asString(json['messageId']) ?? '',
      role: role,
      createdAt: asEpochMs(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      parts: Part.listFromJson(json['parts']),
      model: asString(json['model']),
    );
  }

  final String messageId;
  final MessageRole role;
  final DateTime createdAt;
  final List<Part> parts;
  final String? model;

  Message toWireMessage() => Message(
    id: messageId,
    role: role,
    parts: parts,
    source: MessageSource(role == MessageRole.user ? 'user' : 'model', {
      'kind': role == MessageRole.user ? 'user' : 'model',
      'model': ?model,
    }),
  );
}

class WorkbenchCliChatSnapshot {
  const WorkbenchCliChatSnapshot({
    required this.engine,
    required this.rawId,
    required this.sessionId,
    required this.running,
    required this.messages,
    this.resolvedSessionId,
    this.model,
    this.cwd,
  });

  factory WorkbenchCliChatSnapshot.fromJson(Map<String, Object?> json) {
    final engine = CliEngine.parse(json['engine']);
    final rawId = asString(json['rawId']) ?? '';
    final sessionId = asString(json['sessionId']) ?? 'cli:${engine.wire}:$rawId';
    final rawMsgs = asListOrEmpty(json['messages']);
    return WorkbenchCliChatSnapshot(
      engine: engine,
      rawId: rawId,
      sessionId: sessionId,
      running: json['running'] == true,
      resolvedSessionId: asString(json['resolvedSessionId']),
      model: asString(json['model']),
      cwd: asString(json['cwd']),
      messages: [
        for (final entry in rawMsgs)
          if (asMap(entry) case final map?) WorkbenchCliMessage.fromJson(map),
      ],
    );
  }

  final CliEngine engine;
  final String rawId;
  final String sessionId;
  final bool running;
  final String? resolvedSessionId;
  final String? model;
  final String? cwd;
  final List<WorkbenchCliMessage> messages;
}

class WorkbenchCliPromptResult {
  const WorkbenchCliPromptResult({
    required this.ok,
    required this.sessionId,
    required this.rawId,
    required this.runId,
    required this.running,
  });

  factory WorkbenchCliPromptResult.fromJson(Map<String, Object?> json) => WorkbenchCliPromptResult(
    ok: json['ok'] != false,
    sessionId: asString(json['sessionId']) ?? '',
    rawId: asString(json['rawId']) ?? '',
    runId: asString(json['runId']) ?? '',
    running: json['running'] == true,
  );

  final bool ok;
  final String sessionId;
  final String rawId;
  final String runId;
  final bool running;
}

class WorkbenchBridgeUploadedFile {
  const WorkbenchBridgeUploadedFile({
    required this.uploadId,
    required this.name,
    required this.mediaType,
    required this.bytes,
  });

  factory WorkbenchBridgeUploadedFile.fromJson(Map<String, Object?> json) => WorkbenchBridgeUploadedFile(
    uploadId: asString(json['uploadId']) ?? '',
    name: asString(json['name']) ?? 'attachment.bin',
    mediaType: asString(json['mediaType']) ?? 'application/octet-stream',
    bytes: asInt(json['bytes']) ?? 0,
  );

  final String uploadId;
  final String name;
  final String mediaType;
  final int bytes;
}

final class WorkbenchBridgeUnavailableException extends DshException {
  const WorkbenchBridgeUnavailableException() : super('workbench-bridge is not served by this host');
}

extension WorkbenchBridgeApi on DshClient {
  Future<Map<String, Object?>> _callRpcBridge(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    try {
      final result = await carrier.invokeWorkbenchBridgeRpc(method, params, timeout);
      if (result == null) throw const WorkbenchBridgeUnavailableException();
      return result;
    } on DshRemoteException catch (error) {
      if (error.code == 'METHOD_NOT_FOUND' || error.code == 'FEATURE_NOT_SUPPORTED') {
        throw const WorkbenchBridgeUnavailableException();
      }
      rethrow;
    }
  }

  Future<WorkbenchBridgeHealth> readWorkbenchBridgeHealth({Duration timeout = const Duration(seconds: 10)}) async {
    if (carrier is! DshHttpCarrier) {
      final body = await _callRpcBridge('workbench.bridge.health', const {}, timeout);
      return WorkbenchBridgeHealth.fromJson(body);
    }
    final connection = _bridgeConnection(workbenchBridgeHealthPath);
    final response = await _bridgeGet(
      connection,
      connection.resolve(workbenchBridgeHealthPath),
      maxBytes: _maxReplyBytes,
      timeout: timeout,
    );
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501 || response.statusCode == 503) {
      throw const WorkbenchBridgeUnavailableException();
    }
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, '$workbenchBridgeHealthPath: HTTP ${response.statusCode}', body: response.text);
    }
    final body = asMap(tryDecodeJson(response.text));
    if (body == null) throw const DshProtocolException('workbench-bridge health: invalid JSON');
    return WorkbenchBridgeHealth.fromJson(body);
  }

  /// `GET /plugins/dsh-workbench-bridge/sessions` or `workbench.bridge.sessions` RPC.
  /// Returns `null` on `304 Not Modified`.
  Future<WorkbenchBridgeSessions?> readWorkbenchBridgeSessions({
    String? ifNoneMatch,
    Duration timeout = const Duration(seconds: 15),
    Future<void>? cancelSignal,
  }) async {
    if (carrier is! DshHttpCarrier) {
      final body = await _callRpcBridge(
        'workbench.bridge.sessions',
        {'ifNoneMatch': ?ifNoneMatch},
        timeout,
      );
      if (body['notModified'] == true) return null;
      final rawList = asListOrEmpty(body['sessions']);
      return WorkbenchBridgeSessions(
        sessions: [
          for (final entry in rawList)
            if (asMap(entry) case final map?) WorkbenchCliSession.fromJson(map),
        ],
        etag: asString(body['etag']),
      );
    }
    final connection = _bridgeConnection(workbenchBridgeSessionsPath);
    final response = await _bridgeGet(
      connection,
      connection.resolve(workbenchBridgeSessionsPath),
      ifNoneMatch: ifNoneMatch,
      maxBytes: _maxReplyBytes,
      timeout: timeout,
      cancelSignal: cancelSignal,
    );
    if (response.statusCode == 304) return null;
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501 || response.statusCode == 503) {
      throw const WorkbenchBridgeUnavailableException();
    }
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, '$workbenchBridgeSessionsPath: HTTP ${response.statusCode}', body: response.text);
    }
    final body = asMap(tryDecodeJson(response.text));
    if (body == null) throw const DshProtocolException('workbench-bridge sessions: invalid JSON');
    final rawList = asListOrEmpty(body['sessions']);
    return WorkbenchBridgeSessions(
      sessions: [
        for (final entry in rawList)
          if (asMap(entry) case final map?) WorkbenchCliSession.fromJson(map),
      ],
      etag: response.etag,
    );
  }

  /// `GET /plugins/dsh-workbench-bridge/sessions/:engine/:id/messages` or RPC.
  Future<WorkbenchCliChatSnapshot> readWorkbenchBridgeMessages(
    CliEngine engine,
    String rawId, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _requireSafeId(rawId, 'rawId');
    if (carrier is! DshHttpCarrier) {
      final body = await _callRpcBridge(
        'workbench.bridge.messages',
        {'engine': engine.wire, 'rawId': rawId},
        timeout,
      );
      return WorkbenchCliChatSnapshot.fromJson(body);
    }
    final path = '/plugins/dsh-workbench-bridge/sessions/${engine.wire}/${Uri.encodeComponent(rawId)}/messages';
    final connection = _bridgeConnection(path);
    final response = await _bridgeGet(
      connection,
      connection.resolve(path),
      maxBytes: _maxReplyBytes,
      timeout: timeout,
    );
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501 || response.statusCode == 503) {
      throw const WorkbenchBridgeUnavailableException();
    }
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, '$path: HTTP ${response.statusCode}', body: response.text);
    }
    final body = asMap(tryDecodeJson(response.text));
    if (body == null) throw const DshProtocolException('workbench-bridge messages: invalid JSON');
    return WorkbenchCliChatSnapshot.fromJson(body);
  }

  /// `GET /plugins/dsh-workbench-bridge/models/:engine` or `workbench.bridge.models` RPC.
  Future<ModelCatalog> readWorkbenchBridgeModels(
    CliEngine engine, {
    bool refresh = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (engine == CliEngine.dsh) {
      throw ArgumentError.value(engine, 'engine', 'Use listModels for native DSH models');
    }
    if (carrier is! DshHttpCarrier) {
      final body = await _callRpcBridge(
        'workbench.bridge.models',
        {'engine': engine.wire, if (refresh) 'refresh': true},
        timeout,
      );
      return ModelCatalog.fromJson(body);
    }
    final query = refresh ? '?refresh=1' : '';
    final path = '$workbenchBridgeModelsPath/${engine.wire}$query';
    final connection = _bridgeConnection(path);
    final response = await _bridgeGet(
      connection,
      connection.resolve(path),
      maxBytes: _maxReplyBytes,
      timeout: timeout,
    );
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501 || response.statusCode == 503) {
      throw const WorkbenchBridgeUnavailableException();
    }
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, '$path: HTTP ${response.statusCode}', body: response.text);
    }
    final body = asMap(tryDecodeJson(response.text));
    if (body == null) throw const DshProtocolException('workbench-bridge models: invalid JSON');
    return ModelCatalog.fromJson(body);
  }

  /// Uploads an attachment in bounded chunks (`workbench.bridge.upload` RPC or HTTP POST).
  Future<WorkbenchBridgeUploadedFile> uploadWorkbenchBridgeAttachment({
    required String name,
    required String mediaType,
    required Uint8List bytes,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    String? uploadId;
    WorkbenchBridgeUploadedFile? result;
    var offset = 0;
    do {
      final end = offset + _uploadChunkBytes < bytes.length ? offset + _uploadChunkBytes : bytes.length;
      final slice = bytes.sublist(offset, end);
      final done = end >= bytes.length;
      final payload = <String, Object?>{
        'uploadId': ?uploadId,
        if (offset == 0) 'name': name,
        if (offset == 0) 'mediaType': mediaType,
        'offset': offset,
        'chunkBase64': base64Encode(slice),
        'done': done,
      };
      Map<String, Object?> body;
      if (carrier is! DshHttpCarrier) {
        body = await _callRpcBridge('workbench.bridge.upload', payload, timeout);
      } else {
        final response = await _bridgeConnection(workbenchBridgeUploadPath).postBytes(
          workbenchBridgeUploadPath,
          utf8.encode(jsonEncode(payload)),
          contentType: 'application/json',
          followRedirects: false,
          maxResponseBytes: _maxReplyBytes,
          timeout: timeout,
        );
        if (response.statusCode == 404 ||
            response.statusCode == 405 ||
            response.statusCode == 501 ||
            response.statusCode == 503) {
          throw const WorkbenchBridgeUnavailableException();
        }
        if (response.statusCode != 200) {
          throw DshHttpException(
            response.statusCode,
            '$workbenchBridgeUploadPath: HTTP ${response.statusCode}',
            body: response.text,
          );
        }
        final parsed = asMap(tryDecodeJson(response.text));
        if (parsed == null) throw const DshProtocolException('workbench-bridge upload: invalid JSON');
        body = parsed;
      }
      result = WorkbenchBridgeUploadedFile.fromJson(body);
      uploadId ??= result.uploadId;
      offset = end;
    } while (offset < bytes.length);
    return result;
  }

  /// `POST /plugins/dsh-workbench-bridge/sessions/prompt` or RPC.
  Future<WorkbenchCliPromptResult> sendWorkbenchBridgePrompt({
    required CliEngine engine,
    String? rawSessionId,
    String? cwd,
    required String prompt,
    String? model,
    String? reasoningEffort,
    List<String> attachmentIds = const [],
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (engine == CliEngine.dsh) {
      throw ArgumentError.value(engine, 'engine', 'Use sessionPrompt for native DSH sessions');
    }
    if (rawSessionId != null) _requireSafeId(rawSessionId, 'rawSessionId');
    final payload = <String, Object?>{
      'engine': engine.wire,
      'rawSessionId': ?rawSessionId,
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      'prompt': prompt,
      if (model != null && model.isNotEmpty) 'model': model,
      if (reasoningEffort != null && reasoningEffort.isNotEmpty) 'reasoningEffort': reasoningEffort,
      if (attachmentIds.isNotEmpty) 'attachmentIds': attachmentIds,
    };
    if (carrier is! DshHttpCarrier) {
      final body = await _callRpcBridge('workbench.bridge.prompt', payload, timeout);
      return WorkbenchCliPromptResult.fromJson(body);
    }
    final response = await _bridgeConnection(workbenchBridgePromptPath).postBytes(
      workbenchBridgePromptPath,
      utf8.encode(jsonEncode(payload)),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxReplyBytes,
      timeout: timeout,
    );
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501 || response.statusCode == 503) {
      throw const WorkbenchBridgeUnavailableException();
    }
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, '$workbenchBridgePromptPath: HTTP ${response.statusCode}', body: response.text);
    }
    final body = asMap(tryDecodeJson(response.text));
    if (body == null) throw const DshProtocolException('workbench-bridge prompt: invalid JSON');
    return WorkbenchCliPromptResult.fromJson(body);
  }

  /// `POST /plugins/dsh-workbench-bridge/sessions/abort` or RPC.
  Future<bool> abortWorkbenchBridgeRun(
    CliEngine engine,
    String rawId, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _requireSafeId(rawId, 'rawId');
    if (carrier is! DshHttpCarrier) {
      final body = await _callRpcBridge(
        'workbench.bridge.abort',
        {'engine': engine.wire, 'rawId': rawId},
        timeout,
      );
      return body['aborted'] == true;
    }
    final response = await _bridgeConnection(workbenchBridgeAbortPath).postBytes(
      workbenchBridgeAbortPath,
      utf8.encode(jsonEncode({'engine': engine.wire, 'rawId': rawId})),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxReplyBytes,
      timeout: timeout,
    );
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501 || response.statusCode == 503) {
      throw const WorkbenchBridgeUnavailableException();
    }
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, '$workbenchBridgeAbortPath: HTTP ${response.statusCode}', body: response.text);
    }
    final body = asMap(tryDecodeJson(response.text));
    return body?['aborted'] == true;
  }

  Future<Map<String, Object?>> _postBridgeFileJson(
    String httpPath,
    String rpcMethod,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (carrier is! DshHttpCarrier) {
      return _callRpcBridge(rpcMethod, payload, timeout);
    }
    final response = await _bridgeConnection(httpPath).postBytes(
      httpPath,
      utf8.encode(jsonEncode(payload)),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxReplyBytes,
      timeout: timeout,
    );
    final parsed = asMap(tryDecodeJson(response.text));
    if (response.statusCode != 200) {
      final code = asString(parsed?['code']);
      if (code != null && code.startsWith('workspace-file/')) {
        throw DshRemoteException(
          code,
          asString(parsed?['message']) ?? '$httpPath: HTTP ${response.statusCode}',
          {'path': payload['path']},
        );
      }
      if (response.statusCode == 404 ||
          response.statusCode == 405 ||
          response.statusCode == 501 ||
          response.statusCode == 503) {
        throw const WorkbenchBridgeUnavailableException();
      }
      throw DshHttpException(response.statusCode, '$httpPath: HTTP ${response.statusCode}', body: response.text);
    }
    if (parsed == null) throw DshProtocolException('$httpPath: invalid JSON');
    return parsed;
  }

  Future<DshFileStat> workbenchBridgeStatFile(CliSessionRef ref, String path) async {
    final map = await _postBridgeFileJson(
      workbenchBridgeFileStatPath,
      'workbench.bridge.file.stat',
      {'engine': ref.engine.wire, 'rawId': ref.rawId, 'path': path},
    );
    return DshFileStat.fromJson(map);
  }

  Future<DshWorkspaceBytes> workbenchBridgeReadFileBytes(
    CliSessionRef ref,
    String path, {
    int offset = 0,
    int length = _bridgeFileWindowBytes,
  }) async {
    final map = await _postBridgeFileJson(
      workbenchBridgeFileReadBytesPath,
      'workbench.bridge.file.readBytes',
      {'engine': ref.engine.wire, 'rawId': ref.rawId, 'path': path, 'offset': offset, 'length': length},
      timeout: const Duration(seconds: 30),
    );
    final rawData = asString(map['data']) ?? '';
    return DshWorkspaceBytes(
      data: rawData.isEmpty ? Uint8List(0) : base64Decode(rawData),
      eof: map['eof'] == true,
      offset: asInt(map['offset']) ?? offset,
      absolutePath: asString(map['absolutePath']) ?? '',
      version: asString(map['version']) ?? '',
      bytes: asInt(map['bytes']),
    );
  }

  Future<int> workbenchBridgeReadFile(
    CliSessionRef ref,
    String path, {
    required FutureOr<void> Function(Uint8List chunk) onChunk,
    void Function(int received, int? total)? onProgress,
    int? maxBytes,
  }) async {
    final stat = await workbenchBridgeStatFile(ref, path);
    final total = stat.bytes;
    if (maxBytes != null && total != null && total > maxBytes) {
      throw DshRemoteException('workspace-file/too-large', '"$path" is $total bytes (limit $maxBytes)', {
        'path': path,
        'limit': maxBytes,
      });
    }
    onProgress?.call(0, total);
    var offset = 0;
    var expectedVersion = stat.version.isEmpty ? null : stat.version;
    while (true) {
      final page = await workbenchBridgeReadFileBytes(ref, path, offset: offset, length: _bridgeFileWindowBytes);
      if (page.version.isNotEmpty) {
        if (expectedVersion != null && page.version != expectedVersion) {
          throw DshRemoteException('workspace-file/changed', '"$path" changed while reading', {'path': path});
        }
        expectedVersion ??= page.version;
      }
      final data = page.data;
      offset += data.length;
      if (maxBytes != null && offset > maxBytes) {
        throw DshRemoteException('workspace-file/too-large', '"$path" exceeds $maxBytes bytes', {
          'path': path,
          'limit': maxBytes,
        });
      }
      if (data.isNotEmpty) await onChunk(data);
      onProgress?.call(offset, page.bytes ?? total);
      if (page.eof || data.isEmpty) return offset;
    }
  }

  Future<DshWorkspaceText> workbenchBridgeReadFileText(
    CliSessionRef ref,
    String path, {
    int offset = 1,
    int limit = 500,
  }) async {
    final map = await _postBridgeFileJson(
      workbenchBridgeFileReadTextPath,
      'workbench.bridge.file.readText',
      {'engine': ref.engine.wire, 'rawId': ref.rawId, 'path': path, 'offset': offset, 'limit': limit},
    );
    return DshWorkspaceText.fromJson(map, offset: offset);
  }

  Future<DshWorkspaceListing> workbenchBridgeListWorkspace(CliSessionRef ref, String path) async {
    final map = await _postBridgeFileJson(
      workbenchBridgeFileListPath,
      'workbench.bridge.file.list',
      {'engine': ref.engine.wire, 'rawId': ref.rawId, 'path': path.isEmpty ? '.' : path},
    );
    return DshWorkspaceListing.fromJson(map, fallbackPath: path);
  }

  DshConnection _bridgeConnection(String path) {
    final carrier = this.carrier;
    if (carrier is! DshHttpCarrier) {
      throw DshRemoteException(
        'workbench-bridge/unsupported',
        'this connection cannot reach the workbench-bridge route',
        {'path': path},
      );
    }
    return carrier.connection;
  }
}

void _requireSafeId(String value, String name) {
  if (value.isEmpty || value.length > 256 || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw ArgumentError.value(value, name);
  }
}

class _BridgeResponse {
  const _BridgeResponse(this.statusCode, this.body, {this.etag});

  final int statusCode;
  final Uint8List body;
  final String? etag;

  String get text => utf8.decode(body, allowMalformed: true);
}

Future<_BridgeResponse> _bridgeGet(
  DshConnection connection,
  Uri uri, {
  String? ifNoneMatch,
  required int maxBytes,
  required Duration timeout,
  Future<void>? cancelSignal,
}) async {
  final http = HttpClient()
    ..connectionTimeout = connection.connectTimeout
    ..autoUncompress = true;
  HttpClientRequest? request;
  var cancelled = false;
  var timedOut = false;
  var finished = false;
  Timer? timer;

  void abortAll(Object reason) {
    request?.abort(reason);
    http.close(force: true);
  }

  timer = Timer(timeout, () {
    if (finished || cancelled) return;
    timedOut = true;
    abortAll(TimeoutException('GET ${uri.path} timed out', timeout));
  });

  if (cancelSignal != null) {
    unawaited(
      cancelSignal.then((_) {
        if (finished || timedOut || cancelled) return;
        cancelled = true;
        timer?.cancel();
        abortAll(const DshTransportException('GET aborted'));
      }, onError: (_) {}),
    );
  }

  try {
    if (cancelled) throw const DshTransportException('GET aborted');
    request = await http.openUrl('GET', uri);
    if (cancelled) throw const DshTransportException('GET aborted');
    final req = request;
    req.followRedirects = false;
    if (connection.hostHeader case final host?) {
      final parsed = Uri.tryParse('http://$host');
      if (parsed == null || parsed.host.isEmpty) {
        throw ArgumentError.value(host, 'hostHeader', 'expected host or host:port');
      }
      req.headers.host = parsed.host;
      req.headers.port = parsed.hasPort ? parsed.port : 80;
    }
    if (connection.cookie case final cookie?) {
      req.headers.set(HttpHeaders.cookieHeader, cookie.header);
    }
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (ifNoneMatch != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, ifNoneMatch);
    final response = await req.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (builder.length + chunk.length > maxBytes) {
        throw DshProtocolException('GET ${uri.path}: response exceeds $maxBytes bytes');
      }
      builder.add(chunk);
    }
    return _BridgeResponse(
      response.statusCode,
      builder.takeBytes(),
      etag: response.headers.value(HttpHeaders.etagHeader),
    );
  } on TimeoutException catch (error) {
    throw DshTransportException('GET ${uri.path} timed out', error);
  } on SocketException catch (error) {
    if (timedOut) throw DshTransportException('GET ${uri.path} timed out', error);
    throw DshTransportException('GET ${uri.path} failed: ${error.message}', error);
  } on HttpException catch (error) {
    if (timedOut) throw DshTransportException('GET ${uri.path} timed out', error);
    throw DshTransportException('GET ${uri.path} failed: ${error.message}', error);
  } on HandshakeException catch (error) {
    throw DshTransportException('TLS handshake failed: ${error.message}', error);
  } catch (error) {
    if (timedOut) throw DshTransportException('GET ${uri.path} timed out', error);
    if (cancelled) throw DshTransportException('GET ${uri.path} aborted', error);
    rethrow;
  } finally {
    finished = true;
    timer.cancel();
    http.close(force: true);
  }
}
