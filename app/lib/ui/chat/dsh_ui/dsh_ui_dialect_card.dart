// A ```dsh-ui block written in another plugin's format (genui), drawn as a
// plugin view (docs/design/plugin-ui-v3.md §3.2). What has no native
// counterpart reads 「… · 在网页版查看」; what does — buttons, fields, forms —
// is live, and a tap goes back into the conversation as the same
// `[genui-action] …` line genui's own web client sends.
//
// The card is the view's own opaque surface (the colour every v2 contrast
// check is made against), at the size of the app's dsh-ui cards: radius 20,
// 16 all round. A glass card around it would show the surface as a second
// box inside the first.

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../media/media_viewer.dart' show openGalleryPictures;
import 'dsh_ui_blocks.dart';
import 'dsh_ui_dialect_genui.dart' show GenuiCard;
import 'dsh_ui_dialect_genui_tap.dart' show genuiActionText;
import 'dsh_ui_model.dart';
import 'dsh_ui_plugin.dart' show PluginAction, PluginActionHandler;
import 'dsh_ui_plugin_controls.dart';
import 'dsh_ui_plugin_controls_state.dart';
import 'dsh_ui_plugin_styles.dart';
import 'dsh_ui_scope.dart';
import 'dsh_ui_style.dart';
import 'dsh_ui_widgets.dart';

class DshUiDialectCard extends StatefulWidget {
  const DshUiDialectCard({super.key, required this.view, this.animate = false});

  final DshUiView view;

  /// Charts grow once, right after the reply finished streaming.
  final bool animate;

  @override
  State<DshUiDialectCard> createState() => _DshUiDialectCardState();
}

class _DshUiDialectCardState extends State<DshUiDialectCard> {
  late final PluginDraftController _drafts = PluginDraftController()..addListener(_changed);

  /// What the card knows about its own controls; empty for a fence that has
  /// none, which is most of them.
  GenuiCard get _card => widget.view.genui ?? GenuiCard.empty;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _drafts.removeListener(_changed);
    _drafts.dispose();
    super.dispose();
  }

  /// One tap, turned back into the line genui sends. Delivered as an ordinary
  /// prompt on the queue: the action is a new turn of its own, not something
  /// to steer into the reply that is still streaming.
  Future<bool> _act(PluginAction action) async {
    final text = genuiActionText(_card, action);
    if (text == null) return false;
    final send = DshUiScope.maybeOf(context)?.onAction;
    if (send == null) return false;
    return send(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final surface = Color(0xFF000000 | DshUiPluginPalette.surface.at(dark));
    final ink = Color(0xFF000000 | DshUiPluginPalette.ink.at(dark));
    final edge = Color(0xFF000000 | DshUiPluginPalette.muted.at(dark)).withValues(alpha: 0.18);
    final PluginActionHandler? handler = DshUiScope.maybeOf(context)?.onAction == null ? null : _act;
    _drafts.setHandler(handler);
    _drafts.syncInputs(widget.view.nodes.whereType<DshUiInput>());
    return DecoratedBox(
      key: const ValueKey('dsh-ui-dialect-card'),
      decoration: ShapeDecoration(
        color: surface,
        shape: Squircle.border(AppShape.lg, side: BorderSide(color: edge)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(DshUiMetrics.cardPadding),
        child: PluginControlsScope(
          controller: _drafts,
          child: DshUiPluginScope(
            animate: widget.animate,
            onAction: handler,
            child: DshUiPictureViewer(
              open: openGalleryPictures,
              child: DshUiPluginStyles(
                view: widget.view,
                boundary: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.view.title case final title?) ...[
                      Semantics(
                        header: true,
                        child: Text(title, style: theme.textTheme.titleMedium?.copyWith(color: ink)),
                      ),
                      const SizedBox(height: 12),
                    ],
                    DshUiNodeView(node: widget.view.root),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
