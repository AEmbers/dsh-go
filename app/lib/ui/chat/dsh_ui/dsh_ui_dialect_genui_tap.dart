// What a tap inside a genui card sends back (docs/design/plugin-ui-v3.md
// §3.2).
//
// genui answers a control with a text message — one line, `[genui-action]
// <its action> <JSON payload>`, put into the conversation as the user's next
// turn. The plugin view only knows the id a control was drawn under, so this
// file turns (id + what changed) back into that line. The payload shapes are
// genui's own (lib/index.js, the panel's invoke): a control that is part of a
// form sends nothing itself, and the form's submit carries every member.

import 'dart:convert';

import 'dsh_ui_dialect_genui.dart';
import 'dsh_ui_plugin.dart';

/// The line genui itself would send, or null when this tap answers nothing.
String? genuiActionText(GenuiCard card, PluginAction action) {
  final control = card.controls[action.id];
  if (control == null) return null;
  final name = control.action;
  if (name == null) return null;
  final payload = switch (action.source) {
    PluginActionSource.submit => _submit(card, control, action.args),
    PluginActionSource.change => _change(control, action.args),
    PluginActionSource.button => {'type': 'button', 'label': control.label},
    // A row, an option list or a confirm is not how a genui control is drawn;
    // if one ever reaches here, it carries a plain value like a change does.
    _ => _change(control, action.args),
  };
  if (payload == null) return null;
  return '[genui-action] $name ${jsonEncode(payload)}';
}

/// A control that reports the moment it changes. genui sends the value the
/// user picked; a select also sends its own `id` so the panel can group it.
Map<String, Object?>? _change(GenuiControl control, Map<String, Object?> args) {
  final value = args['value'];
  return switch (control.type) {
    'select' => value is String
        ? {'type': 'select', 'value': value, 'id': ?control.id}
        : null,
    'radio' => value is String ? {'type': 'radio', 'value': value} : null,
    'checkbox' => value is bool
        ? {'type': 'checkbox', 'label': control.label, 'checked': value}
        : null,
    'switch' => value is bool ? {'type': 'switch', 'checked': value} : null,
    _ => null,
  };
}

/// The submit's answer: every member of the form, under genui's own key.
///
/// `answers` holds the radios that carry an answer id (genui scores them),
/// `fields` the free inputs and selects that were actually filled in. Both are
/// keyed by the name genui knows — `group` for a radio, `id` for a field — and
/// the bind is only how the value travelled.
Map<String, Object?>? _submit(
  GenuiCard card,
  GenuiControl control,
  Map<String, Object?> args,
) {
  final values = args['values'];
  if (values is! Map) return null;
  final answers = <String, Object?>{};
  final fields = <String, Object?>{};
  for (final bind in control.binds) {
    final member = card.fields[bind];
    if (member == null) continue;
    final value = values[bind];
    switch (member.type) {
      case 'radio':
        if (value is String) answers[member.group ?? member.id ?? bind] = value;
      case 'input' || 'textarea' || 'select' || 'slider':
        final text = value is String ? value.trim() : value;
        if (text == null || (text is String && text.isEmpty)) continue;
        fields[member.id ?? bind] = text;
    }
  }
  return {
    'type': 'submit',
    if (answers.isNotEmpty) 'answers': answers,
    if (fields.isNotEmpty) 'fields': fields,
    'total': control.binds.length,
    'answered': answers.length + fields.length,
  };
}
