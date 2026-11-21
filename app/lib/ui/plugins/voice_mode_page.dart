// The `dsh-voice-mode` controls, as dsh-go draws them.
//
// The plugin does the listening, the transcoding and the talking itself: it
// owns `/voice-mode/*` and pushes every state change down one SSE feed, and it
// hands audio to the host as `audio` effects that the native media channel
// plays. What is left for the client is exactly three things, and this file is
// only those three:
//
//  - a mirror: `voiceModeProvider` follows the feed and the app reads it,
//  - two levers: start/stop listening for a chat, and stop/interrupt speech,
//  - the panel: read-aloud / captions / status-bar switches, the trigger mode,
//    and the engine knobs behind `POST /voice-mode/settings`.
//
// Nothing here synthesises or plays audio. The plugin's `read` message action
// and its captions strip already route through the native surfaces; a second
// player in the app would double every sentence.

import 'package:dsh_client/dsh_client.dart' hide SettingsSection;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/voice_mode_state.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/list_page_row.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_title_bar.dart';
import '../common/status_chip.dart';
import '../engine_settings/field_row.dart';
import '../features/feature_widgets.dart' show FeatureOffline;
import '../plugins/plugin_actions.dart' show togglePluginBundle;
import '../settings/settings_widgets.dart' show SettingsSection, SettingsSwitchTile;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The voice settings page (`vmodeTitle`), reachable from Settings and from the
/// chat's voice controls.
class VoiceModeSettingsPage extends ConsumerStatefulWidget {
  const VoiceModeSettingsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const VoiceModeSettingsPage());

  @override
  ConsumerState<VoiceModeSettingsPage> createState() => _VoiceModeSettingsPageState();
}

class _VoiceModeSettingsPageState extends ConsumerState<VoiceModeSettingsPage> {
  bool _enabling = false;

  Future<void> _enable(PluginBundle bundle) async {
    setState(() => _enabling = true);
    await togglePluginBundle(context, bundle, true);
    if (!mounted) return;
    setState(() => _enabling = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (ref.watch(activeConnectionProvider).value == null) {
      return AppPage.list(title: l10n.vmodeSettings, children: const [FeatureOffline()]);
    }
    final plugin = ref.watch(voiceModePluginProvider).value;
    if (plugin == null) {
      return AppPage.list(
        title: l10n.vmodeSettings,
        children: [
          EmptyView(
            icon: AppIcons.voice,
            title: l10n.vmodeNotServed,
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
          ),
        ],
      );
    }
    if (!plugin.enabled) {
      return AppPage.list(
        title: l10n.vmodeSettings,
        children: [
          EmptyView(
            icon: AppIcons.voice,
            title: l10n.vmodeNotEnabled,
            message: plugin.description,
            actionLabel: _enabling ? l10n.vmodeEnabling : l10n.vmodeEnable,
            onAction: _enabling ? null : () => _enable(plugin),
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
          ),
        ],
      );
    }
    final snapshot = ref.watch(voiceModeProvider);
    return AppPage.list(
      title: l10n.vmodeSettings,
      children: [
        if (snapshot.degraded) _DegradedNote(reconnecting: snapshot.serving),
        const _DisplaySection(),
        const SizedBox(height: 24),
        const _TriggerSection(),
        const SizedBox(height: 24),
        const _EngineSection(),
        const SizedBox(height: 24),
        const _ModelSection(),
        SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
      ],
    );
  }
}

/// Everything about whether the plugin's words reach the user, without a chat.
class _DisplaySection extends ConsumerWidget {
  const _DisplaySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final snapshot = ref.watch(voiceModeProvider);
    final display = snapshot.display;
    final editable = snapshot.settings != null;
    return SettingsSection(
      title: l10n.vmodeSettings,
      children: [
        FieldSegmentRow<VoiceReadAloud>(
          title: l10n.vmodeReadAloud,
          segments: [
            PillSegment(VoiceReadAloud.voice, l10n.vmodeReadAloudVoice),
            PillSegment(VoiceReadAloud.always, l10n.vmodeReadAloudAlways),
            PillSegment(VoiceReadAloud.off, l10n.vmodeReadAloudOff),
          ],
          selected: display.readAloud,
          onChanged: editable
              ? (value) => ref.read(voiceModeProvider.notifier).setDisplay(readAloud: value)
              : null,
        ),
        SettingsSwitchTile(
          icon: AppIcons.info,
          title: l10n.vmodeShowCaptions,
          value: display.showCaptions,
          onChanged: editable
              ? (value) => ref.read(voiceModeProvider.notifier).setDisplay(showCaptions: value)
              : null,
        ),
        SettingsSwitchTile(
          icon: AppIcons.more,
          title: l10n.vmodeShowStatusBar,
          value: display.showStatusBar,
          onChanged: editable
              ? (value) => ref.read(voiceModeProvider.notifier).setDisplay(showStatusBar: value)
              : null,
        ),
        if (!snapshot.canEditSettings)
          ListPageRow(
            leading: Icon(AppIcons.lock, size: 20, color: DshColors.of(context).textTertiary),
            title: l10n.vmodeSettingsManaged,
          ),
      ],
    );
  }
}

class _TriggerSection extends ConsumerWidget {
  const _TriggerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final snapshot = ref.watch(voiceModeProvider);
    final mode = _triggerOf(snapshot.settings);
    return SettingsSection(
      title: l10n.vmodeTrigger,
      children: [
        FieldSegmentRow<VoiceModeTrigger>(
          title: l10n.vmodeTrigger,
          segments: [
            PillSegment(VoiceModeTrigger.toggle, l10n.vmodeTriggerToggle),
            PillSegment(VoiceModeTrigger.hold, l10n.vmodeTriggerHold),
            PillSegment(VoiceModeTrigger.once, l10n.vmodeTriggerOnce),
          ],
          selected: mode,
          onChanged: snapshot.canEditSettings
              ? (value) => ref.read(voiceModeProvider.notifier).setTrigger(value)
              : null,
        ),
      ],
    );
  }
}

class _EngineSection extends ConsumerWidget {
  const _EngineSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final snapshot = ref.watch(voiceModeProvider);
    final settings = snapshot.settings;
    final editable = snapshot.canEditSettings && settings != null;
    return SettingsSection(
      title: l10n.vmodeEngine,
      children: [
        FieldSegmentRow<VoiceTtsEngine>(
          title: l10n.vmodeEngine,
          segments: [
            PillSegment(VoiceTtsEngine.edge, l10n.vmodeEngineEdge),
            PillSegment(VoiceTtsEngine.kokoro, l10n.vmodeEngineKokoro),
            PillSegment(VoiceTtsEngine.vits, l10n.vmodeEngineVits),
          ],
          selected: settings?.ttsEngine ?? VoiceTtsEngine.edge,
          onChanged: editable
              ? (value) => ref.read(voiceModeProvider.notifier).updateSettings({'ttsEngine': value.wire})
              : null,
        ),
        if (settings != null)
          EngineFieldRow(
            title: l10n.vmodeVoice,
            subtitle: settings.voice,
            value: settings.voice,
            enabled: false,
          ),
        if (settings != null)
          EngineFieldRow(
            title: l10n.vmodeRate,
            value: l10n.vmodeRateValue(settings.rate.toStringAsFixed(2)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(AppIcons.decrement, size: 20),
                  tooltip: l10n.vmodeRate,
                  onPressed: editable
                      ? () => ref
                            .read(voiceModeProvider.notifier)
                            .updateSettings({'rate': _stepRate(settings.rate, -0.1)})
                      : null,
                ),
                IconButton(
                  icon: const Icon(AppIcons.increment, size: 20),
                  tooltip: l10n.vmodeRate,
                  onPressed: editable
                      ? () => ref
                            .read(voiceModeProvider.notifier)
                            .updateSettings({'rate': _stepRate(settings.rate, 0.1)})
                      : null,
                ),
              ],
            ),
          ),
        if (settings != null)
          FieldSegmentRow<VoiceBargeIn>(
            title: l10n.vmodeBargeIn,
            segments: [
              PillSegment(VoiceBargeIn.auto, l10n.vmodeBargeInAuto),
              PillSegment(VoiceBargeIn.manual, l10n.vmodeBargeInManual),
              PillSegment(VoiceBargeIn.detect, l10n.vmodeBargeInDetect),
            ],
            selected: settings.bargeInMode,
            onChanged: editable
                ? (value) => ref.read(voiceModeProvider.notifier).updateSettings({'bargeInMode': value.wire})
                : null,
          ),
        if (settings != null)
          EngineFieldRow(
            title: l10n.vmodeSilence,
            value: l10n.vmodeSilenceValue(settings.silenceMs),
            enabled: false,
          ),
        if (settings != null)
          EngineFieldRow(
            title: l10n.vmodeIdleTimeout,
            value: l10n.vmodeIdleTimeoutValue(settings.idleTimeoutMinutes),
            enabled: false,
          ),
      ],
    );
  }
}

class _ModelSection extends ConsumerWidget {
  const _ModelSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final snapshot = ref.watch(voiceModeProvider);
    final models = snapshot.models;
    final colors = DshColors.of(context);
    final ready = models?.ready ?? false;
    return SettingsSection(
      title: l10n.vmodeModelsReady,
      children: [
        ListPageRow(
          leading: Icon(
            ready ? AppIcons.success : AppIcons.warning,
            size: 20,
            color: ready ? colors.success : colors.warning,
          ),
          title: ready ? l10n.vmodeModelsReady : l10n.vmodeModelsNotReady,
          subtitle: models == null ? null : '${l10n.vmodeModelsAsr} · ${l10n.vmodeModelsTts}',
          trailing: TextButton(
            onPressed: () => ref.read(voiceModeProvider.notifier).retryModels(),
            child: Text(l10n.vmodeModelsRetry),
          ),
        ),
        if (snapshot.engineStruggling)
          ListPageRow(
            leading: Icon(AppIcons.warning, size: 20, color: colors.warning),
            title: l10n.vmodeEngineStruggling,
            subtitleColor: colors.warning,
          ),
      ],
    );
  }
}

class _DegradedNote extends StatelessWidget {
  const _DegradedNote({required this.reconnecting});

  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: ListPageCard(
        children: [
          ListPageRow(
            leading: Icon(AppIcons.warning, size: 20, color: colors.warning),
            title: reconnecting ? l10n.vmodeReconnecting : l10n.vmodeDegraded,
            subtitleColor: colors.warning,
          ),
        ],
      ),
    );
  }
}

/// The one line above the composer: the chat's voice state, its one button, and
/// a way into the settings.
class VoiceModeStrip extends ConsumerWidget {
  const VoiceModeStrip({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final snapshot = ref.watch(voiceModeProvider);
    final plugin = ref.watch(voiceModePluginProvider).value;
    if (plugin == null || !plugin.enabled) return const SizedBox.shrink();

    final turn = snapshot.turnOf(sessionId);
    final busy = turn == VoiceTurnState.listening || turn == VoiceTurnState.finalizing;
    final tone = _turnTone(snapshot, sessionId, turn);
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    final held = snapshot.mode.active != null && snapshot.mode.active != sessionId;
    // The plugin draws its own quiet line when voice is off; this one is the
    // control, so it only takes a row while there is something to control.
    final engaged =
        held || snapshot.listening || snapshot.engineStruggling || (turn != VoiceTurnState.idle && turn != VoiceTurnState.unknown);
    if (!engaged) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: colors.infoContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          StatusDot(tone: tone, size: 8),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _turnLabel(l10n, snapshot, sessionId, turn, held),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
            ),
          ),
          if (snapshot.engineStruggling)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: l10n.vmodeEngineStruggling,
                child: Icon(AppIcons.warning, size: 16, color: colors.warning),
              ),
            ),
          IconButton(
            icon: Icon(busy ? AppIcons.pause : AppIcons.voice, size: 20),
            tooltip: busy ? l10n.vmodeStopListening : l10n.vmodeStartListening,
            onPressed: held ? null : () => _toggle(ref, busy),
          ),
          if (turn == VoiceTurnState.speaking)
            IconButton(
              icon: const Icon(AppIcons.interrupt, size: 20),
              tooltip: l10n.vmodeInterrupt,
              onPressed: () => ref.read(voiceModeProvider.notifier).stop(sessionId),
            ),
        ],
      ),
    );
  }

  Future<void> _toggle(WidgetRef ref, bool busy) async {
    final controller = ref.read(voiceModeProvider.notifier);
    if (busy) {
      await controller.stop(sessionId, interrupt: false);
      return;
    }
    await controller.setListening(sessionId, true);
  }
}

// -----------------------------------------------------------------------------
// Vocabulary

VoiceModeTrigger _triggerOf(VoiceModeSettings? settings) => switch (settings?.mode) {
  VoiceModeTrigger.hold => VoiceModeTrigger.hold,
  VoiceModeTrigger.once => VoiceModeTrigger.once,
  _ => VoiceModeTrigger.toggle,
};

double _stepRate(double rate, double delta) {
  final next = (rate + delta).clamp(0.5, 2.0);
  return double.parse(next.toStringAsFixed(2));
}

StatusTone _turnTone(VoiceModeSnapshot snapshot, String sessionId, VoiceTurnState turn) {
  if (snapshot.mode.active != null && snapshot.mode.active != sessionId) return StatusTone.idle;
  return switch (turn) {
    VoiceTurnState.listening => StatusTone.busy,
    VoiceTurnState.finalizing => StatusTone.busy,
    VoiceTurnState.responding => StatusTone.ok,
    VoiceTurnState.speaking => StatusTone.ok,
    VoiceTurnState.idle => snapshot.listening ? StatusTone.ok : StatusTone.idle,
    VoiceTurnState.unknown => StatusTone.idle,
  };
}

String _turnLabel(L10n l10n, VoiceModeSnapshot snapshot, String sessionId, VoiceTurnState turn, bool held) {
  if (held) return l10n.vmodeHeldByOther;
  return switch (turn) {
    VoiceTurnState.listening => l10n.vmodeListening,
    VoiceTurnState.finalizing => l10n.vmodeBusy,
    VoiceTurnState.responding => l10n.vmodeThinking,
    VoiceTurnState.speaking => snapshot.engineStruggling ? l10n.vmodeEngineStruggling : l10n.vmodeSpeaking,
    VoiceTurnState.idle => snapshot.listening ? l10n.vmodeListening : l10n.vmodeOff,
    VoiceTurnState.unknown => l10n.vmodeOff,
  };
}

/// The bottom sheet the composer's own voice button opens: the same switches as
/// the settings page, one tap away from the sentence being written.
Future<void> showVoiceModeSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (context) {
      final l10n = context.l10n;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.vmodeTitle),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  kSheetGutter,
                  0,
                  kSheetGutter,
                  MediaQuery.paddingOf(context).bottom + 20,
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DisplaySection(),
                    SizedBox(height: 16),
                    _TriggerSection(),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
