// `dsh-voice-mode` as the app sees it — the plugin's own live channel
// (`GET /voice-mode/stream`) and its settings route. See
// packages/dsh_client/lib/src/voice_mode_api.dart for the wire side.
//
// The plugin owns the microphone, the TTS queue and the four switches; the app
// is a second screen onto them, so almost everything here is a mirror: the
// Host broadcasts a frame when something changes and this controller applies
// it. The three things the app actually decides are which session is focused
// (so `always` reading and captions follow the open chat), on/off for the
// microphone, and the settings the user edits.
//
// A connection that cannot open the stream (a relay carrier never reaches
// `/voice-mode/*`) still gets the settings and the toggle, and falls back to a
// slow `/config` poll for the switches, marked [VoiceModeSnapshot.degraded].
// Playback is not here: the Host sends `audio` effects through the native
// capability channel, which the plugin's own panels consume.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'plugins_state.dart';

/// Beat of the `/config` fallback while the live channel is unavailable.
const voiceModeFallbackPoll = Duration(seconds: 5);

/// First reconnect delay; doubles up to [voiceModeReconnectMax].
const voiceModeReconnectMin = Duration(seconds: 1);
const voiceModeReconnectMax = Duration(seconds: 30);

/// The plugin's name in the profile, for the settings row that opens its page.
const voiceModeBundleName = 'dsh-voice-mode';

/// The plugin as the host installed it; null while unknown or not offered.
final voiceModePluginProvider = Provider<AsyncValue<PluginBundle?>>((ref) {
  return ref
      .watch(installedPluginsProvider)
      .whenData((bundles) => bundles?.where((b) => b.name == voiceModeBundleName).firstOrNull);
});

/// Everything the app mirrors about the plugin, in one immutable value.
///
/// A `changed` value is a new snapshot, so a widget can compare whole boards
/// instead of remembering which sub-field it read.
class VoiceModeSnapshot {
  const VoiceModeSnapshot({
    this.mode = VoiceModeMode.off,
    this.focus = VoiceModeFocus.none,
    this.display = const VoiceModeDisplay(),
    this.turns = const {},
    this.tts,
    this.models,
    this.settings,
    this.owner = VoiceSettingsOwner.plugin,
    this.lastLatencyStage,
    this.degraded = false,
    this.serving = true,
    this.error,
  });

  /// Where the microphone stands, host-wide (there is only ever one).
  final VoiceModeMode mode;

  /// The session this tab says it is looking at.
  final VoiceModeFocus focus;

  /// Reading aloud, captions, status bar — mirrored so two devices agree.
  final VoiceModeDisplay display;

  /// Per-session turn state from `turn` frames.
  final Map<String, VoiceTurnState> turns;

  /// The last `tts-*` frame: an engine failure shows here.
  final VoiceTtsEvent? tts;

  /// Local model readiness, when it has been read.
  final VoiceModelsStatus? models;

  /// The user's settings, when they have been read.
  final VoiceModeSettings? settings;

  /// Who owns the settings: the plugin itself, or a dsh-side store.
  final VoiceSettingsOwner owner;

  /// `first-llm-token` / `first-sentence-text`, kept only to show a latency chip.
  final String? lastLatencyStage;

  /// The live channel is unavailable, so the switches come from `/config`.
  final bool degraded;

  /// False once the host answers 404: the plugin is not installed or is off.
  final bool serving;

  /// The last transport failure, while a stale snapshot is still worth showing.
  final Object? error;

  bool get listening => mode.listening;

  bool get ownedByThisSession => mode.active != null && mode.active == focus.sessionId;

  /// A growing `tts-skip` streak means the cloud engine is unreachable.
  bool get engineStruggling => (tts?.streak ?? 0) >= 3;

  bool get canEditSettings => owner.writable && settings != null;

  VoiceTurnState turnOf(String sessionId) => turns[sessionId] ?? VoiceTurnState.idle;

  VoiceModeSnapshot copyWith({
    VoiceModeMode? mode,
    VoiceModeFocus? focus,
    VoiceModeDisplay? display,
    Map<String, VoiceTurnState>? turns,
    VoiceTtsEvent? tts,
    VoiceModelsStatus? models,
    VoiceModeSettings? settings,
    VoiceSettingsOwner? owner,
    String? lastLatencyStage,
    bool? degraded,
    bool? serving,
    Object? error,
    bool clearError = false,
  }) => VoiceModeSnapshot(
    mode: mode ?? this.mode,
    focus: focus ?? this.focus,
    display: display ?? this.display,
    turns: turns ?? this.turns,
    tts: tts ?? this.tts,
    models: models ?? this.models,
    settings: settings ?? this.settings,
    owner: owner ?? this.owner,
    lastLatencyStage: lastLatencyStage ?? this.lastLatencyStage,
    degraded: degraded ?? this.degraded,
    serving: serving ?? this.serving,
    error: clearError ? null : (error ?? this.error),
  );
}

/// The plugin's live state for the active host.
class VoiceModeController extends Notifier<VoiceModeSnapshot> {
  VoiceModeStream? _stream;
  StreamSubscription<VoiceModeEvent>? _events;
  Timer? _reconnect;
  Timer? _fallback;
  Duration _backoff = voiceModeReconnectMin;

  /// The tab id this controller introduces itself with, stable for the whole
  /// life of the host [build] wired — a reconnect has to arrive under the same
  /// id, because that is what makes the Host replace its dead connection
  /// instead of counting a new client (it refuses more than eight). One id per
  /// host also means `syncFocus` can compare against it before a stream exists.
  String _tabId = VoiceModeStream.newTabId();

  /// Read freshness within the current host: only the latest `_load` writes.
  int _ticket = 0;

  /// The host these callbacks belong to; a rebuilt controller reads another.
  DshClient? _owner;

  /// Bumped by every [build] and never reset, so a value is never reused: an
  /// old reply carrying `generation == _generation` cannot be a stale one.
  int _generation = 0;
  bool _disposed = false;

  /// The session this page means to keep focused, as opposed to the one the
  /// Host currently holds. A stream that dies takes the Host's focus with it
  /// (`dsh-voice-mode` clears it and broadcasts `focus{null,null}` when the
  /// connection that owned the tab closes), so the app has to be able to say
  /// it again on its own: nothing else re-runs `syncFocus` on a reconnect.
  String? _wantedFocus;

  /// Whether [client] may still write: the same host [build] wired, and the
  /// generation [build] handed out is still the current one.
  bool _live(DshClient client, int generation) =>
      !_disposed && generation == _generation && identical(client, _owner);

  @override
  VoiceModeSnapshot build() {
    _stream?.close();
    _stream = null;
    unawaited(_events?.cancel());
    _events = null;
    _reconnect?.cancel();
    _reconnect = null;
    _fallback?.cancel();
    _fallback = null;
    _backoff = voiceModeReconnectMin;
    // Never reset `_ticket`: a fresh host must not make an old ticket current
    // again. The generation, bumped here and monotonic for the controller's
    // life, is what retires every callback of the host [build] is leaving.
    final generation = ++_generation;
    // A fresh host gets a fresh tab id: the one the previous host knew must not
    // be presented to this one, or the Host takes the newcomer for a reconnect
    // of a connection it already dropped.
    _tabId = VoiceModeStream.newTabId();
    // And a fresh intent: the session id meant something on the host being
    // left, and posting it to the new one names a conversation that need not
    // exist there. The page states its own focus through `syncFocus`.
    _wantedFocus = null;
    _disposed = false;
    final conn = ref.watch(activeConnectionProvider).value;
    _owner = conn?.client;
    ref.onDispose(() {
      _disposed = true;
      _reconnect?.cancel();
      _fallback?.cancel();
      _reconnect = null;
      _fallback = null;
      unawaited(_events?.cancel());
      _events = null;
      _stream?.close();
      _stream = null;
    });
    if (conn == null) return const VoiceModeSnapshot(serving: false);
    unawaited(_load(conn.client, generation));
    // `build` must not read `state` (it is not initialized yet), so decide the
    // degraded mode here and hand it back as the first frame instead.
    final live = conn.client.carrier is DshHttpCarrier;
    if (live) {
      _listen(conn.client, generation);
    } else {
      _pollConfig(conn.client, generation);
    }
    return VoiceModeSnapshot(degraded: !live);
  }

  /// Reads the settings and the model status; both are one-shot.
  Future<void> _load(DshClient client, int generation) async {
    final ticket = ++_ticket;
    bool stale() => !_live(client, generation) || ticket != _ticket;
    try {
      final results = await Future.wait<Object?>([
        client.readVoiceModeSettings(),
        _orNull(client.readVoiceModelsStatus()),
        _orNull(client.readVoiceModeConfig()),
      ]);
      if (stale()) return;
      final view = results[0] as VoiceSettingsView?;
      final models = results[1] as VoiceModelsStatus?;
      final config = results[2] as Map<String, Object?>?;
      final display = config == null || config.isEmpty ? null : _displayOf(config);
      final mode = config == null || config.isEmpty ? null : _modeOf(config);
      state = state.copyWith(
        settings: view?.value,
        owner: view?.managedBy,
        models: models,
        display: display,
        mode: mode,
        serving: true,
        clearError: true,
      );
    } on DshHttpException catch (error) {
      if (stale()) return;
      if (error.statusCode == 404) {
        state = const VoiceModeSnapshot(serving: false);
        return;
      }
      state = state.copyWith(error: error);
    } catch (error) {
      if (stale()) return;
      state = state.copyWith(error: error);
    }
  }

  static VoiceModeDisplay _displayOf(Map<String, Object?> config) => VoiceModeDisplay(
    readAloud: VoiceReadAloud.parse(config['readAloud']),
    showCaptions: _asBool(config['showCaptions']) ?? true,
    showStatusBar: _asBool(config['showStatusBar']) ?? true,
  );

  /// `/config` carries `active` (the session the microphone is open for) but
  /// not the owning tab, so the fallback mode has no owner.
  static VoiceModeMode _modeOf(Map<String, Object?> config) =>
      VoiceModeMode(active: _asString(config['active']), ownerTabId: _asString(config['ownerTabId']));

  /// Subscribes to the plugin's own SSE channel. Only a direct HTTP carrier
  /// can reach it; a relay falls back to `/config` (handled in `build`).
  void _listen(DshClient client, int generation) {
    // Same tab id on every listen: the Host replaces the connection it dropped
    // for this tab instead of counting a second client.
    final stream = _stream = VoiceModeStream(client, tabId: _tabId);
    _events = stream.events.listen(
      (event) => _apply(client, generation, event),
      onError: (Object error) {
        if (!_live(client, generation)) return;
        state = state.copyWith(degraded: true, error: error);
        _scheduleReconnect(client, generation);
      },
      onDone: () {
        if (!_live(client, generation)) return;
        state = state.copyWith(degraded: true);
        _scheduleReconnect(client, generation);
      },
    );
  }

  void _scheduleReconnect(DshClient client, int generation) {
    _reconnect?.cancel();
    if (!_live(client, generation)) return;
    // A new stream, not a re-listen: the Host closes the old one for good.
    unawaited(_events?.cancel());
    _events = null;
    _stream?.close();
    _stream = null;
    final delay = _backoff;
    _backoff = Duration(
      milliseconds: (_backoff.inMilliseconds * 2).clamp(
        voiceModeReconnectMin.inMilliseconds,
        voiceModeReconnectMax.inMilliseconds,
      ),
    );
    _reconnect = Timer(delay, () {
      if (!_live(client, generation)) return;
      _listen(client, generation);
    });
    _pollConfig(client, generation);
  }

  /// Slow `/config` beat while the live channel is down.
  void _pollConfig(DshClient client, int generation) {
    if (_fallback != null || !_live(client, generation)) return;
    _fallback = Timer.periodic(voiceModeFallbackPoll, (timer) async {
      if (!_live(client, generation)) {
        timer.cancel();
        return;
      }
      try {
        final config = await client.readVoiceModeConfig();
        if (!_live(client, generation)) return;
        state = state.copyWith(mode: _modeOf(config), display: _displayOf(config));
      } catch (_) {
        // Keep the old values; the reconnect timer is the real retry.
      }
    });
  }

  void _apply(DshClient client, int generation, VoiceModeEvent event) {
    if (!_live(client, generation)) return;
    // The first frame after a reconnect proves the channel again.
    var next = state.degraded ? state.copyWith(degraded: false, clearError: true) : state;
    // Set by the `focus` branch, acted on once [next] is the state: the
    // re-report goes through [syncFocus], whose own no-op check compares
    // against the state, so it has to see the cleared focus first.
    var reclaim = false;
    _backoff = voiceModeReconnectMin;
    _fallback?.cancel();
    _fallback = null;
    if (event.isReplaced) {
      // Another connection took this tab id; it owns the microphone now.
      next = next.copyWith(mode: VoiceModeMode.off);
    } else if (event.mode case final mode?) {
      next = next.copyWith(mode: mode);
    } else if (event.focus case final focus?) {
      next = next.copyWith(focus: focus);
      // A dropped stream takes the Host's focus with it: `dsh-voice-mode`
      // clears `focusedSessionId` and broadcasts `focus{null,null}` when the
      // connection that owned the tab closes. Nothing else re-runs `syncFocus`
      // on a reconnect (only a page event does), so the page states its intent
      // again here — otherwise 「每条回复」, turn/step and `/cancel` stay dead
      // for this session until the user switches away and back.
      //
      // Only a *cleared* focus counts. A frame naming another session means a
      // different tab took the focus on purpose, and claiming it back would
      // have two open pages taking turns: one Host value, last writer wins.
      reclaim = focus.sessionId == null && _wantedFocus != null;
    } else if (event.display case final display?) {
      next = next.copyWith(display: display);
    } else if (event.turn case final turn?) {
      final turns = {...next.turns};
      if (turn.state == VoiceTurnState.idle) {
        turns.remove(turn.sessionId);
      } else {
        turns[turn.sessionId] = turn.state;
      }
      next = next.copyWith(turns: turns);
    } else if (event.tts case final tts?) {
      next = next.copyWith(tts: tts);
    } else if (event.model != null && event.event == 'asr-ready') {
      // Model readiness changes rarely; re-read rather than guess from a frame.
      // The read belongs to the host this frame came from, not to whichever
      // host is active by the time it lands.
      unawaited(_reloadModels(client, generation));
    } else if (event.latency case final latency?) {
      next = next.copyWith(lastLatencyStage: latency.stage);
    }
    if (!identical(next, state)) state = next;
    if (reclaim) unawaited(syncFocus(_wantedFocus));
  }

  Future<void> _reloadModels(DshClient client, int generation) async {
    try {
      final models = await client.readVoiceModelsStatus();
      if (!_live(client, generation)) return;
      state = state.copyWith(models: models);
    } catch (_) {}
  }

  /// Tells the Host which session this tab is looking at. `always` reading and
  /// captions follow it, so the chat calls this when it becomes the open one.
  Future<void> syncFocus(String? sessionId) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = _generation;
    // The id of the tab this controller *is*, not of the stream it happens to
    // hold: minting one here would post a different tab on every call before
    // the stream opens.
    final tabId = _tabId;
    if (state.focus.sessionId == sessionId && state.focus.tabId == tabId) return;
    try {
      await client.focusVoiceMode(sessionId: sessionId, tabId: tabId);
      if (!_live(client, generation)) return;
      // The intent, kept for the reconnect path: `null` counts too, so a page
      // that has been left does not come back to life on its own.
      _wantedFocus = sessionId;
      state = state.copyWith(focus: VoiceModeFocus(sessionId: sessionId, tabId: tabId));
    } catch (_) {
      // A closed session or a busy Host: the next turn re-syncs.
    }
  }

  /// Opens or closes the microphone for [sessionId]. Returns false when the
  /// Host kept it for another session (only one is open at a time).
  Future<bool> setListening(String sessionId, bool on) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return false;
    final generation = _generation;
    try {
      final active = await client.toggleVoiceMode(sessionId: sessionId, on: on, tabId: _tabId);
      if (!_live(client, generation)) return false;
      state = state.copyWith(mode: VoiceModeMode(active: active, ownerTabId: _tabId));
      return active == null || active == sessionId;
    } catch (error) {
      if (_live(client, generation)) state = state.copyWith(error: error);
      return false;
    }
  }

  /// Stops the turn; `interrupt` also abandons the reply instead of finishing it.
  Future<void> stop(String sessionId, {bool interrupt = true}) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    final generation = _generation;
    try {
      await client.cancelVoiceMode(
        sessionId: sessionId,
        reason: interrupt ? 'interrupt' : null,
      );
    } catch (error) {
      if (_live(client, generation)) state = state.copyWith(error: error);
    }
  }

  /// Flips one display switch on the Host, which broadcasts it to every client.
  Future<void> setDisplay({VoiceReadAloud? readAloud, bool? showCaptions, bool? showStatusBar}) async {
    final current = state.display;
    final next = VoiceModeDisplay(
      readAloud: readAloud ?? current.readAloud,
      showCaptions: showCaptions ?? current.showCaptions,
      showStatusBar: showStatusBar ?? current.showStatusBar,
    );
    state = state.copyWith(display: next);
    await updateSettings({
      if (readAloud != null) 'readAloud': readAloud.wire,
      'showCaptions': ?showCaptions,
      'showStatusBar': ?showStatusBar,
    });
  }

  /// Writes part of the settings. A Host that keeps its own settings answers
  /// 409 and this leaves the local copy alone.
  Future<VoiceSettingsWrite> updateSettings(Map<String, Object?> patch) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null || patch.isEmpty) return VoiceSettingsWrite.failed;
    final generation = _generation;
    try {
      final view = await client.writeVoiceModeSettings(patch);
      if (!_live(client, generation)) return VoiceSettingsWrite.saved;
      state = state.copyWith(
        settings: view.value,
        owner: view.managedBy,
        display: VoiceModeDisplay(
          readAloud: view.value.readAloud,
          showCaptions: view.value.showCaptions,
          showStatusBar: view.value.showStatusBar,
        ),
        clearError: true,
      );
      return VoiceSettingsWrite.saved;
    } on VoiceSettingsManagedException {
      if (_live(client, generation)) state = state.copyWith(owner: VoiceSettingsOwner.dsh);
      return VoiceSettingsWrite.managedByDsh;
    } on VoiceSettingsRejectedException catch (error) {
      if (_live(client, generation)) state = state.copyWith(error: error);
      return VoiceSettingsWrite.rejected;
    } catch (error) {
      if (_live(client, generation)) state = state.copyWith(error: error);
      return VoiceSettingsWrite.failed;
    }
  }

  /// Re-reads the settings (after the plugin's own page edited them).
  Future<void> reloadSettings() async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client != null) await _load(client, _generation);
  }

  /// `toggle` / `hold` / `once`: how the microphone button behaves.
  Future<VoiceSettingsWrite> setTrigger(VoiceModeTrigger mode) =>
      updateSettings({'mode': mode.wire});

  /// Asks the Host to fetch the model that is missing. Slow (a download), so
  /// the state comes back through the feed instead of the reply.
  Future<void> retryModels({VoiceModelKind kind = VoiceModelKind.asr}) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    try {
      final generation = _generation;
      await client.retryVoiceModels(kind: kind);
      await _reloadModels(client, generation);
    } catch (error) {
      if (!_disposed) state = state.copyWith(error: error);
    }
  }
}

/// Outcome of a settings write, so the page can say the right thing.
enum VoiceSettingsWrite { saved, managedByDsh, rejected, failed }

final voiceModeProvider = NotifierProvider.autoDispose<VoiceModeController, VoiceModeSnapshot>(
  VoiceModeController.new,
);

/// The turn state of one session, for the chat's own voice button.
final voiceTurnProvider = Provider.autoDispose.family<VoiceTurnState, String>((ref, sessionId) {
  return ref.watch(voiceModeProvider.select((s) => s.turnOf(sessionId)));
});

/// Whether the microphone is open for [sessionId] right now.
final voiceListeningProvider = Provider.autoDispose.family<bool, String>((ref, sessionId) {
  return ref.watch(voiceModeProvider.select((s) => s.mode.ownedBy(sessionId)));
});

/// The plugin serves this host at all (installed, on, reachable).
final voiceModeServingProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(voiceModeProvider.select((s) => s.serving)),
);


/// Awaits [future] and answers null when it fails, for the parts of the panel
/// that are worth showing even when one of their reads is missing.
Future<Object?> _orNull(Future<Object?> future) async {
  try {
    return await future;
  } on Object {
    return null;
  }
}

/// Reads a JSON boolean the way the Host writes it (`true` / `false`, and the
/// `"true"` form some settings files carry).
bool? _asBool(Object? value) => value is bool ? value : value == 'true' ? true : value == 'false' ? false : null;

/// Reads a JSON string, treating anything else as absent.
String? _asString(Object? value) => value is String ? value : null;
