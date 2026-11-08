/// `dsh-voice-mode` — speech in, speech out, captions, and its settings.
///
/// Everything the plugin exposes to a client lives under one prefix,
/// `/voice-mode` (`BASE_PATH` in `dsh-voice-mode/lib/index.js:2917`). The
/// prefix route itself answers a capability probe
/// (`{ok, name, enabled, active}`), which is *not* a health check on the
/// sub-routes: any unknown child path under it is swallowed by that prefix and
/// answers the same JSON, so a `200` on `/voice-mode/whatever` proves nothing
/// about the route you meant to reach.
///
/// Every handler begins with `denyNonLoopback`, and the mutating ones with
/// `denyCrossOrigin`; on a Host reached through a tunnel that refuses the
/// request, the plugin has to be driven through the dsh-go bridge instead of
/// these routes.
///
/// The live channel is [VoiceModeStream] over `GET /voice-mode/stream`:
/// one connection per tab, at most eight at a time (`429 too_many_streams`), a
/// repeat connection with the same `tabId` replacing the older one with a
/// `replaced` frame, `retry: 3000`, and a `: hb` comment every 25 s. The first
/// three frames are always `mode`, `focus` and `display`.
///
/// Audio never travels over this channel as a file: `audio` frames carry one
/// sentence per pair of frames, `chunkId: 0` with base64 [VoiceAudioFrame.audio]
/// and `chunkId: 1` with `final: true` and the sentence's [VoiceAudioFrame.text].
/// The sentence id is monotonic across turns for the whole Host
/// (`TtsQueue.seq`), so a client drops anything at or below the highest id it
/// has already seen rather than assuming a per-turn numbering.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'carrier.dart';
import 'connection.dart';
import 'dsbot_api.dart' show DsBotSseEvent, SseParser;
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

const voiceModeBasePath = '/voice-mode';
const voiceModeConfigPath = '$voiceModeBasePath/config';
const voiceModeTogglePath = '$voiceModeBasePath/toggle';
const voiceModeCancelPath = '$voiceModeBasePath/cancel';
const voiceModeFocusPath = '$voiceModeBasePath/focus';
const voiceModeModePath = '$voiceModeBasePath/mode';
const voiceModeSettingsPath = '$voiceModeBasePath/settings';
const voiceModeStreamPath = '$voiceModeBasePath/stream';
const voiceModeVoicesPath = '$voiceModeBasePath/voices';
const voiceModeCorrectPath = '$voiceModeBasePath/correct';
const voiceModePreviewPath = '$voiceModeBasePath/preview';
const voiceModeModelsStatusPath = '$voiceModeBasePath/models/status';

/// The plugin's own heartbeat is every 25 s; three missed beats is a dead
/// stream, not a quiet one.
const voiceModeStreamIdle = Duration(seconds: 75);

const _maxJsonBytes = 256 * 1024;

/// `/voice-mode/preview` returns an encoded sample; every engine's is far
/// below this.
const _maxPreviewBytes = 4 * 1024 * 1024;

// -----------------------------------------------------------------------------
// Settings
// -----------------------------------------------------------------------------

/// How speech is triggered.
enum VoiceModeTrigger {
  /// Tap to start, tap to stop.
  toggle('toggle'),

  /// Hold the key.
  hold('hold'),

  /// One turn, then the microphone goes out.
  once('once');

  const VoiceModeTrigger(this.wire);
  final String wire;

  static VoiceModeTrigger parse(Object? value) =>
      values.firstWhere((m) => m.wire == value, orElse: () => VoiceModeTrigger.toggle);
}

/// Whether the reply is read back, and when.
enum VoiceReadAloud {
  /// Only while the session is in voice mode.
  voice('voice'),

  /// Every reply of the focused session, even with the microphone off.
  always('always'),
  off('off');

  const VoiceReadAloud(this.wire);
  final String wire;

  static VoiceReadAloud parse(Object? value) =>
      values.firstWhere((m) => m.wire == value, orElse: () => VoiceReadAloud.voice);
}

/// How speaking over the reply interrupts it.
enum VoiceBargeIn {
  auto('auto'),
  manual('manual'),

  /// Echo-gated detection: the reply only yields once the microphone hears
  /// more than [VoiceModeSettings.echoGateDb] over the playback level.
  detect('detect');

  const VoiceBargeIn(this.wire);
  final String wire;

  static VoiceBargeIn parse(Object? value) =>
      values.firstWhere((m) => m.wire == value, orElse: () => VoiceBargeIn.detect);
}

/// The TTS engine the Host synthesizes with.
enum VoiceTtsEngine {
  edge('edge'),
  kokoro('kokoro'),
  vits('vits');

  const VoiceTtsEngine(this.wire);
  final String wire;

  static VoiceTtsEngine parse(Object? value) =>
      values.firstWhere((e) => e.wire == value, orElse: () => VoiceTtsEngine.edge);
}

/// `/voice-mode/settings`. Readable whole; writable only when
/// [managedBy] is [VoiceSettingsOwner.plugin] — a Host that owns the settings
/// (`settingsScopeRef` set) answers `409 settings_managed` to every write and
/// the value must be changed in the Host's own settings panel.
///
/// Only the fields this client reads or writes are modelled; the route sends
/// all of them, and [raw] keeps every one for a caller that needs another.
class VoiceModeSettings {
  const VoiceModeSettings({
    this.ttsEngine = VoiceTtsEngine.edge,
    this.kokoroModel = 'int8',
    this.voice = 'zh-CN-XiaoxiaoNeural',
    this.rate = 1.1,
    this.interruptLevel = 0,
    this.silenceMs = 1500,
    this.idleTimeoutMinutes = 5,
    this.modelHost = '',
    this.autoSend = true,
    this.autoResume = false,
    this.mode = VoiceModeTrigger.toggle,
    this.readAloud = VoiceReadAloud.voice,
    this.showCaptions = true,
    this.showStatusBar = true,
    this.bargeInMode = VoiceBargeIn.detect,
    this.echoGateDb = 6,
    this.spokenFormat = true,
    this.senseVoice = true,
    this.wakeWord = '',
    this.toolBeep = false,
    this.senseITN = true,
    this.captionFontSize = 0,
    this.captionMaxWidth = 1,
    this.backchannelYield = true,
    this.bargeInSalvage = true,
    this.llmCorrect = false,
    this.yieldMs = 1500,
    this.raw = const {},
  });

  static VoiceModeSettings fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return VoiceModeSettings(
      ttsEngine: VoiceTtsEngine.parse(map['ttsEngine']),
      kokoroModel: asString(map['kokoroModel']) ?? 'int8',
      voice: asString(map['voice']) ?? 'zh-CN-XiaoxiaoNeural',
      rate: asNum(map['rate'])?.toDouble() ?? 1.1,
      interruptLevel: asInt(map['interruptLevel']) ?? 0,
      silenceMs: asInt(map['silenceMs']) ?? 1500,
      idleTimeoutMinutes: asInt(map['idleTimeoutMinutes']) ?? 5,
      modelHost: asString(map['modelHost']) ?? '',
      autoSend: asBool(map['autoSend']) ?? true,
      autoResume: asBool(map['autoResume']) ?? false,
      mode: VoiceModeTrigger.parse(map['mode']),
      readAloud: VoiceReadAloud.parse(map['readAloud']),
      showCaptions: asBool(map['showCaptions']) ?? true,
      showStatusBar: asBool(map['showStatusBar']) ?? true,
      bargeInMode: VoiceBargeIn.parse(map['bargeInMode']),
      echoGateDb: asInt(map['echoGateDb']) ?? 6,
      spokenFormat: asBool(map['spokenFormat']) ?? true,
      senseVoice: asBool(map['senseVoice']) ?? true,
      wakeWord: asString(map['wakeWord']) ?? '',
      toolBeep: asBool(map['toolBeep']) ?? false,
      senseITN: asBool(map['senseITN']) ?? true,
      captionFontSize: asInt(map['captionFontSize']) ?? 0,
      captionMaxWidth: asInt(map['captionMaxWidth']) ?? 1,
      backchannelYield: asBool(map['backchannelYield']) ?? true,
      bargeInSalvage: asBool(map['bargeInSalvage']) ?? true,
      llmCorrect: asBool(map['llmCorrect']) ?? false,
      yieldMs: asInt(map['yieldMs']) ?? 1500,
      raw: map,
    );
  }

  final VoiceTtsEngine ttsEngine;

  /// `int8` or `fp32`, only meaningful for [VoiceTtsEngine.kokoro].
  final String kokoroModel;
  final String voice;

  /// 0.5–2.
  final double rate;

  /// 0 = the reply keeps playing, 1 = …, 2 = immediate.
  final int interruptLevel;

  /// 500–30000 ms of quiet that ends an utterance.
  final int silenceMs;

  /// 1–120 minutes before the microphone goes out by itself.
  final int idleTimeoutMinutes;
  final String modelHost;
  final bool autoSend;
  final bool autoResume;
  final VoiceModeTrigger mode;
  final VoiceReadAloud readAloud;
  final bool showCaptions;
  final bool showStatusBar;
  final VoiceBargeIn bargeInMode;

  /// 3–12 dB over the playback level before a reply yields.
  final int echoGateDb;

  /// Whether the Host tells the model to speak in a spoken-friendly way.
  final bool spokenFormat;
  final bool senseVoice;
  final String wakeWord;
  final bool toolBeep;
  final bool senseITN;

  /// 0 → 12 px, 1 → 14 px, 2 → 16 px, 3 → 18 px.
  final int captionFontSize;

  /// 0 → 60 vw, 1 → 70 vw, 2 → 86 vw.
  final int captionMaxWidth;

  /// A short "mm-hmm" during playback yields the reply instead of counting
  /// as an interruption.
  final bool backchannelYield;

  /// Whether speech that starts an interruption is salvaged as the next
  /// prompt instead of being thrown away.
  final bool bargeInSalvage;
  final bool llmCorrect;

  /// 500–3000 ms of frames dropped after a yield.
  final int yieldMs;

  /// Every field the route sent, including the ones not modelled above.
  final JsonMap raw;

  VoiceModeSettings copyWith({
    VoiceTtsEngine? ttsEngine,
    String? kokoroModel,
    String? voice,
    double? rate,
    int? interruptLevel,
    int? silenceMs,
    int? idleTimeoutMinutes,
    String? modelHost,
    bool? autoSend,
    bool? autoResume,
    VoiceModeTrigger? mode,
    VoiceReadAloud? readAloud,
    bool? showCaptions,
    bool? showStatusBar,
    VoiceBargeIn? bargeInMode,
    int? echoGateDb,
    bool? spokenFormat,
    bool? senseVoice,
    String? wakeWord,
    bool? toolBeep,
    bool? senseITN,
    int? captionFontSize,
    int? captionMaxWidth,
    bool? backchannelYield,
    bool? bargeInSalvage,
    bool? llmCorrect,
    int? yieldMs,
  }) {
    return VoiceModeSettings(
      ttsEngine: ttsEngine ?? this.ttsEngine,
      kokoroModel: kokoroModel ?? this.kokoroModel,
      voice: voice ?? this.voice,
      rate: rate ?? this.rate,
      interruptLevel: interruptLevel ?? this.interruptLevel,
      silenceMs: silenceMs ?? this.silenceMs,
      idleTimeoutMinutes: idleTimeoutMinutes ?? this.idleTimeoutMinutes,
      modelHost: modelHost ?? this.modelHost,
      autoSend: autoSend ?? this.autoSend,
      autoResume: autoResume ?? this.autoResume,
      mode: mode ?? this.mode,
      readAloud: readAloud ?? this.readAloud,
      showCaptions: showCaptions ?? this.showCaptions,
      showStatusBar: showStatusBar ?? this.showStatusBar,
      bargeInMode: bargeInMode ?? this.bargeInMode,
      echoGateDb: echoGateDb ?? this.echoGateDb,
      spokenFormat: spokenFormat ?? this.spokenFormat,
      senseVoice: senseVoice ?? this.senseVoice,
      wakeWord: wakeWord ?? this.wakeWord,
      toolBeep: toolBeep ?? this.toolBeep,
      senseITN: senseITN ?? this.senseITN,
      captionFontSize: captionFontSize ?? this.captionFontSize,
      captionMaxWidth: captionMaxWidth ?? this.captionMaxWidth,
      backchannelYield: backchannelYield ?? this.backchannelYield,
      bargeInSalvage: bargeInSalvage ?? this.bargeInSalvage,
      llmCorrect: llmCorrect ?? this.llmCorrect,
      yieldMs: yieldMs ?? this.yieldMs,
      raw: raw,
    );
  }

  /// Only the fields that differ from [other]; what a write should send, so a
  /// stale client never overwrites a field it did not mean to touch.
  Map<String, Object?> diffFrom(VoiceModeSettings other) {
    final next = <String, Object?>{
      'ttsEngine': ttsEngine.wire,
      'kokoroModel': kokoroModel,
      'voice': voice,
      'rate': rate,
      'interruptLevel': interruptLevel,
      'silenceMs': silenceMs,
      'idleTimeoutMinutes': idleTimeoutMinutes,
      'modelHost': modelHost,
      'autoSend': autoSend,
      'autoResume': autoResume,
      'mode': mode.wire,
      'readAloud': readAloud.wire,
      'showCaptions': showCaptions,
      'showStatusBar': showStatusBar,
      'bargeInMode': bargeInMode.wire,
      'echoGateDb': echoGateDb,
      'spokenFormat': spokenFormat,
      'senseVoice': senseVoice,
      'wakeWord': wakeWord,
      'toolBeep': toolBeep,
      'senseITN': senseITN,
      'captionFontSize': captionFontSize,
      'captionMaxWidth': captionMaxWidth,
      'backchannelYield': backchannelYield,
      'bargeInSalvage': bargeInSalvage,
      'llmCorrect': llmCorrect,
      'yieldMs': yieldMs,
    };
    final prev = <String, Object?>{
      'ttsEngine': other.ttsEngine.wire,
      'kokoroModel': other.kokoroModel,
      'voice': other.voice,
      'rate': other.rate,
      'interruptLevel': other.interruptLevel,
      'silenceMs': other.silenceMs,
      'idleTimeoutMinutes': other.idleTimeoutMinutes,
      'modelHost': other.modelHost,
      'autoSend': other.autoSend,
      'autoResume': other.autoResume,
      'mode': other.mode.wire,
      'readAloud': other.readAloud.wire,
      'showCaptions': other.showCaptions,
      'showStatusBar': other.showStatusBar,
      'bargeInMode': other.bargeInMode.wire,
      'echoGateDb': other.echoGateDb,
      'spokenFormat': other.spokenFormat,
      'senseVoice': other.senseVoice,
      'wakeWord': other.wakeWord,
      'toolBeep': other.toolBeep,
      'senseITN': other.senseITN,
      'captionFontSize': other.captionFontSize,
      'captionMaxWidth': other.captionMaxWidth,
      'backchannelYield': other.backchannelYield,
      'bargeInSalvage': other.bargeInSalvage,
      'llmCorrect': other.llmCorrect,
      'yieldMs': other.yieldMs,
    };
    return {
      for (final entry in next.entries)
        if (prev[entry.key] != entry.value) entry.key: entry.value,
    };
  }
}

/// Who owns the settings on this Host.
enum VoiceSettingsOwner {
  /// The plugin writes its own overrides file; `POST /settings` works.
  plugin('plugin'),

  /// The Host owns them; writes answer `409 settings_managed`.
  dsh('dsh');

  const VoiceSettingsOwner(this.wire);
  final String wire;

  static VoiceSettingsOwner parse(Object? value) =>
      values.firstWhere((o) => o.wire == value, orElse: () => VoiceSettingsOwner.plugin);

  bool get writable => this == VoiceSettingsOwner.plugin;
}

/// What `GET /voice-mode/settings` answered.
class VoiceSettingsView {
  const VoiceSettingsView({required this.managedBy, required this.value});

  static VoiceSettingsView fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return VoiceSettingsView(
      managedBy: VoiceSettingsOwner.parse(map['managedBy']),
      value: VoiceModeSettings.fromJson(map['value']),
    );
  }

  final VoiceSettingsOwner managedBy;
  final VoiceModeSettings value;
}

// -----------------------------------------------------------------------------
// Live state
// -----------------------------------------------------------------------------

/// `mode`: which session the microphone belongs to.
///
/// The microphone is owned by exactly one session at a time and only one tab
/// drives it ([ownerTabId]); when that tab disconnects the Host waits 8 s and
/// then yields the session by itself.
class VoiceModeMode {
  const VoiceModeMode({this.active, this.ownerTabId});

  static const off = VoiceModeMode();

  static VoiceModeMode fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return VoiceModeMode(active: asString(map['active']), ownerTabId: asString(map['ownerTabId']));
  }

  /// The session the microphone is open for, or null when it is closed.
  final String? active;

  /// The tab that opened it.
  final String? ownerTabId;

  bool get listening => active != null;

  bool ownedBy(String? sessionId) => active != null && active == sessionId;

  /// The microphone is open for another session, so this one must ask for it.
  bool heldByOther(String? sessionId) => active != null && active != sessionId;
}

/// `focus`: which session the tab is looking at. Reading aloud (`always`) and
/// captions follow the focus, not the microphone.
class VoiceModeFocus {
  const VoiceModeFocus({this.sessionId, this.tabId});

  static const none = VoiceModeFocus();

  static VoiceModeFocus fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return VoiceModeFocus(sessionId: asString(map['sessionId']), tabId: asString(map['tabId']));
  }

  final String? sessionId;
  final String? tabId;

  bool get focused => sessionId != null;
}

/// `display`: the three switches the user can flip mid-session, mirrored so a
/// second device shows the same.
class VoiceModeDisplay {
  const VoiceModeDisplay({this.readAloud = VoiceReadAloud.voice, this.showCaptions = true, this.showStatusBar = true});

  static VoiceModeDisplay fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return VoiceModeDisplay(
      readAloud: VoiceReadAloud.parse(map['readAloud']),
      showCaptions: asBool(map['showCaptions']) ?? true,
      showStatusBar: asBool(map['showStatusBar']) ?? true,
    );
  }

  final VoiceReadAloud readAloud;
  final bool showCaptions;
  final bool showStatusBar;
}

/// `turn` of one session: where the speaking turn stands.
enum VoiceTurnState {
  /// Nothing in flight.
  idle('idle'),

  /// The microphone is capturing.
  listening('listening'),

  /// The utterance has been sent and is being finalized.
  finalizing('finalizing'),

  /// The reply is being received.
  responding('responding'),

  /// The reply is being spoken.
  speaking('speaking'),
  unknown('');

  const VoiceTurnState(this.wire);
  final String wire;

  static VoiceTurnState parse(Object? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => VoiceTurnState.unknown);

  bool get busy => this != idle && this != unknown;
}

/// `turn` frame: only sent when the state actually changed.
class VoiceTurn {
  const VoiceTurn({required this.sessionId, required this.state, this.turn});

  static VoiceTurn? fromJson(Object? json) {
    final map = asMap(json);
    final sessionId = asString(map?['sessionId']);
    if (map == null || sessionId == null || sessionId.isEmpty) return null;
    return VoiceTurn(sessionId: sessionId, state: VoiceTurnState.parse(map['state']), turn: asInt(map['turn']));
  }

  final String sessionId;
  final VoiceTurnState state;

  /// The Host's turn number, when the frame carries one.
  final int? turn;
}

/// `latency`: a timing mark, so the UI can show where the first token went.
class VoiceLatency {
  const VoiceLatency({required this.sessionId, required this.stage});

  static VoiceLatency? fromJson(Object? json) {
    final map = asMap(json);
    final sessionId = asString(map?['sessionId']);
    if (map == null || sessionId == null) return null;
    return VoiceLatency(sessionId: sessionId, stage: asString(map['stage']) ?? '');
  }

  final String sessionId;

  /// `first-llm-token` or `first-sentence-text`.
  final String stage;
}

/// `tool`: the reply invoked a tool, which is a natural pause in speech.
class VoiceToolNotice {
  const VoiceToolNotice({required this.sessionId, required this.name});

  static VoiceToolNotice? fromJson(Object? json) {
    final map = asMap(json);
    final sessionId = asString(map?['sessionId']);
    if (map == null || sessionId == null) return null;
    return VoiceToolNotice(sessionId: sessionId, name: asString(map['name']) ?? '');
  }

  final String sessionId;
  final String name;
}

/// One half of a spoken sentence.
///
/// The pair is `chunkId: 0` (base64 [audio], [final] false) then `chunkId: 1`
/// ([final] true, [text], empty [audio]). [sentenceId] is monotonic over the
/// whole Host, across turns and sessions.
class VoiceAudioFrame {
  const VoiceAudioFrame({
    required this.sessionId,
    required this.sentenceId,
    required this.chunkId,
    required this.finalChunk,
    this.audio,
    this.text,
    this.mime = '',
  });

  /// Decodes both halves; returns null when the frame carries no sentence at
  /// all (no session id).
  static VoiceAudioFrame? fromJson(Object? json) {
    final map = asMap(json);
    final sessionId = asString(map?['sessionId']);
    if (map == null || sessionId == null || sessionId.isEmpty) return null;
    return VoiceAudioFrame(
      sessionId: sessionId,
      sentenceId: asInt(map['sentenceId']) ?? 0,
      chunkId: asInt(map['chunkId']) ?? 0,
      finalChunk: map['final'] == true,
      audio: asString(map['audio']),
      text: asString(map['text']),
      mime: asString(map['mime']) ?? '',
    );
  }

  final String sessionId;

  /// Monotonic across the Host; compare, never index.
  final int sentenceId;
  final int chunkId;

  /// The closing half: [text] is the sentence that was spoken.
  final bool finalChunk;

  /// Base64 audio on the opening half; empty on the closing one.
  final String? audio;

  /// The sentence, on the closing half.
  final String? text;
  final String mime;

  /// The decoded bytes, or null on the closing half.
  Uint8List? decode() {
    final encoded = audio;
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } on FormatException {
      return null;
    }
  }

  bool get isFinal => finalChunk;
}

/// Why the local model files could not be fetched.
enum VoiceModelError {
  checksumOrDownloadFailed('checksum_or_download_failed'),
  missingFile('missing_file'),
  unknown('');

  const VoiceModelError(this.wire);
  final String wire;

  static VoiceModelError parse(Object? value) =>
      values.firstWhere((e) => e.wire == value, orElse: () => VoiceModelError.unknown);
}

/// `asr-error` / `asr-progress` / `asr-ready`: the local ASR models.
class VoiceModelProgress {
  const VoiceModelProgress({this.file, this.percent, this.reason});

  static VoiceModelProgress fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return VoiceModelProgress(
      file: asString(map['file']),
      percent: asInt(map['percent']),
      reason: map['reason'] == null ? null : VoiceModelError.parse(map['reason']),
    );
  }

  /// The file being fetched, relative to the model cache.
  final String? file;

  /// 0–100 while downloading.
  final int? percent;
  final VoiceModelError? reason;
}

/// `tts-ready` / `tts-error` / `tts-skip` / `tts-idle`.
class VoiceTtsEvent {
  const VoiceTtsEvent({this.sessionId, this.engine, this.worker, this.text, this.streak = 0});

  static VoiceTtsEvent fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return VoiceTtsEvent(
      sessionId: asString(map['sessionId']),
      engine: asString(map['engine']),
      worker: asBool(map['worker']),
      text: asString(map['text']),
      streak: asInt(map['streak']) ?? 0,
    );
  }

  final String? sessionId;
  final String? engine;

  /// Whether the engine runs in a worker process.
  final bool? worker;

  /// The skipped sentence (truncated to 80 characters by the Host).
  final String? text;

  /// How many sentences in a row were skipped: a single skip is a hiccup, a
  /// growing streak means the cloud engine is unreachable.
  final int streak;
}

// -----------------------------------------------------------------------------
// Settings sheet, models, voices, preview
// -----------------------------------------------------------------------------

/// One row of `GET /voice-mode/voices`.
class VoiceCatalogEntry {
  const VoiceCatalogEntry({required this.id, this.label = '', this.locale = '0', this.gender = ''});

  static VoiceCatalogEntry? fromJson(Object? json) {
    // The Host forwards Edge's own list: `{Name, ShortName, Locale, Gender, …}`
    // in some versions and the client's lowercase form in others.
    final map = asMap(json);
    if (map == null) return null;
    final id = asString(map['ShortName']) ?? asString(map['shortName']) ?? asString(map['id']) ??
        asString(map['name']) ?? asString(map['Name']);
    if (id == null || id.isEmpty) return null;
    return VoiceCatalogEntry(
      id: id,
      label: asString(map['FriendlyName']) ?? asString(map['friendlyName']) ?? asString(map['label']) ?? id,
      locale: asString(map['Locale']) ?? asString(map['locale']) ?? '',
      gender: asString(map['Gender']) ?? asString(map['gender']) ?? '',
    );
  }

  /// The value to store in [VoiceModeSettings.voice].
  final String id;
  final String label;
  final String locale;
  final String gender;
}

/// `GET /voice-mode/models/status`: the local ASR model set plus the TTS
/// engine's readiness.
class VoiceModelsStatus {
  const VoiceModelsStatus({this.asrReady = false, this.ttsReady = false, this.engine = '', this.raw = const {}});

  static VoiceModelsStatus fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final tts = asMapOrEmpty(map['tts']);
    return VoiceModelsStatus(
      asrReady: asBool(map['ready']) ?? false,
      ttsReady: asBool(tts['ready']) ?? false,
      engine: asString(tts['engine']) ?? '',
      raw: map,
    );
  }

  final bool asrReady;
  final bool ttsReady;
  final String engine;
  final JsonMap raw;

  bool get ready => asrReady && ttsReady;
}

/// A synthesized sample, ready to play.
class VoicePreview {
  const VoicePreview({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

// -----------------------------------------------------------------------------
// The live channel
// -----------------------------------------------------------------------------

/// One frame of `GET /voice-mode/stream`, decoded into the shape the UI needs.
class VoiceModeEvent {
  const VoiceModeEvent(this.event, this.data);

  static VoiceModeEvent? fromSse(DsBotSseEvent frame) {
    // `message` is SseParser's default for a frame with no `event:` line, which
    // this Host never sends: every broadcast names its event.
    if (frame.event.isEmpty || frame.event == 'message') return null;
    return VoiceModeEvent(frame.event, asMapOrEmpty(frame.data));
  }

  /// `mode`, `focus`, `display`, `turn`, `tool`, `latency`, `audio`,
  /// `asr-error`, `asr-progress`, `asr-ready`, `tts-ready`, `tts-error`,
  /// `tts-skip`, `tts-idle`, or `replaced`.
  final String event;
  final JsonMap data;

  bool get isReplaced => event == 'replaced';

  VoiceModeMode? get mode => event == 'mode' ? VoiceModeMode.fromJson(data) : null;
  VoiceModeFocus? get focus => event == 'focus' ? VoiceModeFocus.fromJson(data) : null;
  VoiceModeDisplay? get display => event == 'display' ? VoiceModeDisplay.fromJson(data) : null;
  VoiceTurn? get turn => event == 'turn' ? VoiceTurn.fromJson(data) : null;
  VoiceToolNotice? get tool => event == 'tool' ? VoiceToolNotice.fromJson(data) : null;
  VoiceLatency? get latency => event == 'latency' ? VoiceLatency.fromJson(data) : null;
  VoiceAudioFrame? get audio => event == 'audio' ? VoiceAudioFrame.fromJson(data) : null;
  VoiceModelProgress? get model => const {'asr-error', 'asr-progress', 'asr-ready'}.contains(event)
      ? VoiceModelProgress.fromJson(data)
      : null;
  VoiceTtsEvent? get tts =>
      const {'tts-ready', 'tts-error', 'tts-skip', 'tts-idle'}.contains(event) ? VoiceTtsEvent.fromJson(data) : null;
}

/// The plugin's live channel.
///
/// One connection per client; pass a stable [tabId] so a reconnect replaces
/// the previous connection on the Host instead of leaving it to serve a dead
/// one for 8 s. The Host refuses more than eight, and a `replaced` frame means
/// another client took this tab id over — the caller should stop, not retry.
class VoiceModeStream {
  VoiceModeStream(this._client, {String? tabId}) : tabId = tabId ?? newTabId();

  final DshClient _client;

  /// The tab identity the Host uses to replace this connection on reconnect.
  final String tabId;

  StreamController<VoiceModeEvent>? _controller;
  HttpClient? _http;
  HttpClientRequest? _request;
  StreamSubscription<String>? _lines;
  var _closed = false;

  /// Opens the channel. Cancelling the subscription aborts the request.
  Stream<VoiceModeEvent> get events {
    final existing = _controller;
    if (existing != null) return existing.stream;
    final controller = _controller = StreamController<VoiceModeEvent>(onListen: _open, onCancel: close);
    return controller.stream;
  }

  Future<void> _open() async {
    final carrier = _client.carrier;
    if (carrier is! DshHttpCarrier) {
      _fail(const DshRemoteException('voice-mode/unsupported', 'this connection cannot reach /voice-mode/stream'));
      return;
    }
    final connection = carrier.connection;
    final http = _http = HttpClient()
      ..connectionTimeout = connection.connectTimeout
      ..autoUncompress = true;
    try {
      final uri = connection.resolve(voiceModeStreamPath, {'tabId': tabId});
      final req = _request = await http.openUrl('GET', uri);
      if (_closed) {
        req.done.ignore();
        req.abort();
        return;
      }
      req.followRedirects = false;
      if (connection.hostHeader case final host?) {
        final parsed = Uri.tryParse('http://$host');
        if (parsed != null && parsed.host.isNotEmpty) {
          req.headers.host = parsed.host;
          req.headers.port = parsed.hasPort ? parsed.port : 80;
        }
      }
      if (connection.cookie case final cookie?) {
        req.headers.set(HttpHeaders.cookieHeader, cookie.header);
      }
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await req.close().timeout(connection.connectTimeout);
      if (_closed) {
        await response.listen(null).cancel();
        return;
      }
      if (response.statusCode != 200) {
        final status = response.statusCode;
        await response.listen(null).cancel().catchError((Object _) {});
        _fail(switch (status) {
          429 => const DshRemoteException('voice-mode/too-many-streams', 'too many voice streams'),
          403 => const DshHttpException(403, 'voice-mode refused this client'),
          _ => DshHttpException(status, 'HTTP $status from $voiceModeStreamPath'),
        });
        return;
      }
      final parser = SseParser();
      _lines = response
          .timeout(voiceModeStreamIdle)
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final frame = parser.add(line);
              if (frame == null) return;
              final event = VoiceModeEvent.fromSse(frame);
              if (event == null || _controller?.isClosed != false) return;
              _controller!.add(event);
            },
            onError: (Object error) {
              _fail(error is TimeoutException ? DshTransportException('voice stream went quiet', error) : error);
            },
            onDone: _done,
            cancelOnError: true,
          );
    } on DshException catch (error) {
      _fail(error);
    } on Object catch (error) {
      _fail(DshTransportException('voice stream failed: $error', error));
    }
  }

  void _fail(Object error) {
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.addError(error);
      unawaited(controller.close());
    }
    unawaited(close());
  }

  void _done() {
    final controller = _controller;
    if (controller != null && !controller.isClosed) unawaited(controller.close());
  }

  /// Closes the connection. The Host notices and, when this tab owned the
  /// microphone, yields the session after 8 s.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _request?.abort();
    await _lines?.cancel();
    _lines = null;
    _http?.close(force: true);
    _http = null;
    final controller = _controller;
    if (controller != null && !controller.isClosed) await controller.close();
  }

  /// A tab id the Host accepts (1–64 characters). The Host keys the "one
  /// connection per tab" replacement on it, so it must stay stable across a
  /// reconnect of the same UI tab and differ between tabs.
  static String newTabId([String prefix = 'dsh-go']) {
    final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final noise = identityHashCode(Object()).toRadixString(36);
    final id = '$prefix-$micros-$noise';
    return id.length <= 64 ? id : id.substring(0, 64);
  }
}

// -----------------------------------------------------------------------------
// The client
// -----------------------------------------------------------------------------

extension VoiceModeApi on DshClient {
  /// `GET /voice-mode/config`: the small probe a client uses to learn the
  /// prefix and a handful of current values.
  Future<JsonMap> readVoiceModeConfig({Duration timeout = const Duration(seconds: 15)}) async {
    final connection = _voiceConnection(this, voiceModeConfigPath);
    final response = await connection.get(voiceModeConfigPath, timeout: timeout);
    _checkVoiceMode(response.statusCode, voiceModeConfigPath, response.text);
    final map = asMap(tryDecodeJson(response.text));
    if (map == null) throw const DshProtocolException('voice-mode config: not a JSON object');
    return map;
  }

  /// `GET /voice-mode/settings`.
  Future<VoiceSettingsView> readVoiceModeSettings({Duration timeout = const Duration(seconds: 15)}) async {
    final connection = _voiceConnection(this, voiceModeSettingsPath);
    final response = await connection.get(voiceModeSettingsPath, timeout: timeout);
    _checkVoiceMode(response.statusCode, voiceModeSettingsPath, response.text);
    return VoiceSettingsView.fromJson(tryDecodeJson(response.text));
  }

  /// `POST /voice-mode/settings` with only the changed fields.
  ///
  /// Throws [VoiceSettingsManagedException] when the Host owns the settings,
  /// and [VoiceSettingsRejectedException] for an unknown key or an out-of-range
  /// value (the route's message names the offending keys).
  Future<VoiceSettingsView> writeVoiceModeSettings(
    Map<String, Object?> patch, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (patch.isEmpty) throw ArgumentError.value(patch, 'patch', 'nothing to change');
    final connection = _voiceConnection(this, voiceModeSettingsPath);
    final response = await connection.postBytes(
      voiceModeSettingsPath,
      utf8.encode(jsonEncode(patch)),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxJsonBytes,
      timeout: timeout,
    );
    if (response.statusCode == 409) throw const VoiceSettingsManagedException();
    if (response.statusCode == 400) {
      throw VoiceSettingsRejectedException(_errorOf(response.text) ?? 'settings rejected');
    }
    _checkVoiceMode(response.statusCode, voiceModeSettingsPath, response.text);
    final map = asMapOrEmpty(tryDecodeJson(response.text));
    return VoiceSettingsView(
      managedBy: VoiceSettingsOwner.parse(map['managedBy'] ?? 'plugin'),
      value: VoiceModeSettings.fromJson(map['value']),
    );
  }

  /// `POST /voice-mode/toggle`: opens or closes the microphone for
  /// [sessionId].
  ///
  /// Opening is rate limited to two per two seconds per session (`429`), needs
  /// the plugin enabled (`403 voice_disabled`) and a live session
  /// (`403 unknown_session`). Answers the session now holding the microphone,
  /// which is a *different* session when another one took it in between.
  Future<String?> toggleVoiceMode({
    required String sessionId,
    required bool on,
    String? tabId,
    String? lang,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final body = <String, Object?>{
      'sessionId': sessionId,
      'on': on,
      if (tabId != null && tabId.isNotEmpty) 'tabId': tabId,
      if (lang != null && lang.isNotEmpty) 'lang': lang,
    };
    final connection = _voiceConnection(this, voiceModeTogglePath);
    final response = await connection.postBytes(
      voiceModeTogglePath,
      utf8.encode(jsonEncode(body)),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxJsonBytes,
      timeout: timeout,
    );
    _checkVoiceMode(response.statusCode, voiceModeTogglePath, response.text);
    return asString(asMapOrEmpty(tryDecodeJson(response.text))['active']);
  }

  /// `POST /voice-mode/cancel`: stops speaking for [sessionId].
  ///
  /// [reason] `interrupt` additionally abandons the turn, so the half-spoken
  /// reply is not resumed; [keepAsr] keeps the microphone from being reset,
  /// which is what a barge-in needs.
  Future<void> cancelVoiceMode({
    required String sessionId,
    bool keepAsr = false,
    String? reason,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final body = <String, Object?>{
      'sessionId': sessionId,
      if (keepAsr) 'keepAsr': true,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    };
    final connection = _voiceConnection(this, voiceModeCancelPath);
    final response = await connection.postBytes(
      voiceModeCancelPath,
      utf8.encode(jsonEncode(body)),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxJsonBytes,
      timeout: timeout,
    );
    _checkVoiceMode(response.statusCode, voiceModeCancelPath, response.text);
  }

  /// `POST /voice-mode/focus`: tells the Host which session this tab is
  /// looking at, which is what `readAloud: always` and the captions follow.
  /// Pass a null [sessionId] to drop the focus. An unknown session is
  /// `403 unknown_session`.
  Future<void> focusVoiceMode({
    required String? sessionId,
    required String tabId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (tabId.isEmpty || tabId.length > 64) throw ArgumentError.value(tabId, 'tabId');
    final body = <String, Object?>{'sessionId': sessionId, 'tabId': tabId};
    final connection = _voiceConnection(this, voiceModeFocusPath);
    final response = await connection.postBytes(
      voiceModeFocusPath,
      utf8.encode(jsonEncode(body)),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxJsonBytes,
      timeout: timeout,
    );
    _checkVoiceMode(response.statusCode, voiceModeFocusPath, response.text);
  }

  /// `POST /voice-mode/mode`: how the microphone is triggered.
  Future<void> setVoiceModeTrigger(
    VoiceModeTrigger mode, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final connection = _voiceConnection(this, voiceModeModePath);
    final response = await connection.postBytes(
      voiceModeModePath,
      utf8.encode(jsonEncode({'mode': mode.wire})),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxJsonBytes,
      timeout: timeout,
    );
    _checkVoiceMode(response.statusCode, voiceModeModePath, response.text);
  }

  /// `GET /voice-mode/voices`: the voices the current engine can speak with.
  Future<List<VoiceCatalogEntry>> listVoiceModeVoices({Duration timeout = const Duration(seconds: 30)}) async {
    final connection = _voiceConnection(this, voiceModeVoicesPath);
    final response = await connection.get(voiceModeVoicesPath, timeout: timeout);
    if (response.statusCode == 502) {
      throw const DshRemoteException('voice-mode/voice-list-unavailable', 'the voice list is unavailable');
    }
    _checkVoiceMode(response.statusCode, voiceModeVoicesPath, response.text);
    final list = asListOrEmpty(asMapOrEmpty(tryDecodeJson(response.text))['voices']);
    return [for (final row in list) ?VoiceCatalogEntry.fromJson(row)];
  }

  /// `GET /voice-mode/models/status`.
  Future<VoiceModelsStatus> readVoiceModelsStatus({Duration timeout = const Duration(seconds: 15)}) async {
    final connection = _voiceConnection(this, voiceModeModelsStatusPath);
    final response = await connection.get(voiceModeModelsStatusPath, timeout: timeout);
    _checkVoiceMode(response.statusCode, voiceModeModelsStatusPath, response.text);
    return VoiceModelsStatus.fromJson(tryDecodeJson(response.text));
  }

  /// `POST /voice-mode/models/retry`: re-fetches the local model files.
  Future<void> retryVoiceModels({
    VoiceModelKind kind = VoiceModelKind.asr,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final path = '$voiceModeBasePath/models/retry';
    final connection = _voiceConnection(this, path);
    final response = await connection.postBytes(
      path,
      utf8.encode(jsonEncode({'kind': kind.wire})),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxJsonBytes,
      timeout: timeout,
    );
    _checkVoiceMode(response.statusCode, path, response.text);
  }

  /// `POST /voice-mode/correct`: rewrites a recognized utterance so it reads
  /// like writing (`lang` is `zh` or `en`). Rate limited to ten a minute; on
  /// any failure the Host answers the text it was given, unchanged.
  Future<String> correctVoiceText(
    String text, {
    String lang = 'zh',
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final connection = _voiceConnection(this, voiceModeCorrectPath);
    final response = await connection.postBytes(
      voiceModeCorrectPath,
      utf8.encode(jsonEncode({'text': text, 'lang': lang})),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxJsonBytes,
      timeout: timeout,
    );
    final body = asMapOrEmpty(tryDecodeJson(response.text));
    if (response.statusCode != 200) return text;
    return asString(body['text']) ?? text;
  }

  /// `POST /voice-mode/preview`: a short sample in [voice].
  ///
  /// Rate limited to twenty a minute. A synthesis failure answers `502` with
  /// one of `preview_network`, `preview_engine`, `preview_text`,
  /// `preview_unknown`, compared by category rather than by message.
  Future<VoicePreview> previewVoice({
    required String voice,
    double? rate,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (voice.isEmpty || voice.length > 128) throw ArgumentError.value(voice, 'voice');
    final connection = _voiceConnection(this, voiceModePreviewPath);
    final response = await connection.postBytes(
      voiceModePreviewPath,
      utf8.encode(jsonEncode({'voice': voice, if (rate != null) 'rate': rate.clamp(0.5, 2.0)})),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxPreviewBytes,
      timeout: timeout,
    );
    if (response.statusCode == 502) {
      throw VoicePreviewFailedException(VoicePreviewError.parse(_errorOf(response.text)), _errorOf(response.text));
    }
    _checkVoiceMode(response.statusCode, voiceModePreviewPath, response.text);
    final type = response.contentType.isEmpty ? 'audio/mpeg' : response.contentType;
    return VoicePreview(bytes: response.body, contentType: type);
  }
}

/// Which local model set `POST /models/retry` re-fetches.
enum VoiceModelKind {
  asr('asr'),
  vad('vad'),
  sense('sense');

  const VoiceModelKind(this.wire);
  final String wire;
}

/// Why a preview failed, as the route's own code.
enum VoicePreviewError {
  network('preview_network'),
  engine('preview_engine'),
  text('preview_text'),
  unknown('preview_unknown');

  const VoicePreviewError(this.wire);
  final String wire;

  static VoicePreviewError parse(Object? value) =>
      values.firstWhere((e) => e.wire == value, orElse: () => VoicePreviewError.unknown);

  /// The engine could not reach its backend: retrying later may work.
  bool get retryable => this == network || this == engine;
}

// -----------------------------------------------------------------------------
// Plumbing
// -----------------------------------------------------------------------------

/// The [DshConnection] behind [client], or a clear failure: the voice routes
/// are Fetch routes on the Host, and a carrier that forwards only Remote
/// methods (the relay) cannot reach them.
DshConnection _voiceConnection(DshClient client, String path) {
  final carrier = client.carrier;
  if (carrier is! DshHttpCarrier) {
    throw DshRemoteException('voice-mode/unsupported', 'this connection cannot reach the voice routes', {
      'path': path,
    });
  }
  return carrier.connection;
}

String? _errorOf(String body) {
  final map = asMap(tryDecodeJson(body));
  return asString(map?['error']) ?? asString(map?['code']);
}

void _checkVoiceMode(int status, String path, String body) {
  if (status == 200 || status == 204) return;
  final code = asString(asMap(tryDecodeJson(body))?['code']);
  final error = asString(asMap(tryDecodeJson(body))?['error']);
  throw switch (code ?? status.toString()) {
    'voice_disabled' => const VoiceDisabledException(),
    'unknown_session' => const VoiceUnknownSessionException(),
    'rate_limited' => DshRemoteException('voice-mode/rate-limited', error ?? 'rate limited', {'path': path}),
    'method_not_allowed' => DshHttpException(405, '$path: wrong method', body: body),
    'internal' => DshRemoteException('voice-mode/internal', error ?? 'internal', {'path': path}),
    _ => DshHttpException(status, '$path: HTTP $status', body: body),
  };
}

// -----------------------------------------------------------------------------
// Failures
// -----------------------------------------------------------------------------

/// The plugin is installed but disabled: `403 voice_disabled`.
final class VoiceDisabledException extends DshException {
  const VoiceDisabledException() : super('voice mode is disabled on this host');
}

/// `403 unknown_session`: the Host has no such session any more.
final class VoiceUnknownSessionException extends DshException {
  const VoiceUnknownSessionException() : super('the host does not know that session');
}

/// `409 settings_managed`: the Host owns the voice settings, so they must be
/// changed in the Host's settings panel rather than written here.
final class VoiceSettingsManagedException extends DshException {
  const VoiceSettingsManagedException() : super('voice settings are managed by the host');
}

/// `400`: an unknown key or an out-of-range value.
final class VoiceSettingsRejectedException extends DshException {
  const VoiceSettingsRejectedException(super.message);
}

/// `502` from `/preview`.
final class VoicePreviewFailedException extends DshException {
  const VoicePreviewFailedException(this.reason, String? message) : super(message ?? 'preview failed');
  final VoicePreviewError reason;
}
