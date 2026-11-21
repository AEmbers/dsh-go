// A tap inside a genui card becomes the line genui's own web client sends:
// `[genui-action] <its action> <JSON payload>` (docs/design/plugin-ui-v3.md
// §3.2). These check the payload shapes against genui's panel dispatch —
// grouped controls send nothing of their own, the form's submit carries them.

import 'dart:convert';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_dialect_genui.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_dialect_genui_tap.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

GenuiCard cardOf(List<Object?> items) => genuiToPluginView({'items': items}).card;

/// The single control a card drew for [label].
GenuiControl only(GenuiCard card, String label) =>
    card.controls.values.singleWhere((c) => c.label == label);

String actionId(GenuiCard card, String label) =>
    card.controls.entries.singleWhere((e) => e.value.label == label).key;

PluginAction tap(String id, Map<String, Object?> args, [PluginActionSource source = PluginActionSource.button]) =>
    PluginAction(id: id, args: args, source: source, path: 'p');

Map<String, Object?> payloadOf(String? line) {
  expect(line, isNotNull);
  final body = line!.substring('[genui-action] '.length);
  final space = body.indexOf(' ');
  return jsonDecode(body.substring(space + 1)) as Map<String, Object?>;
}

String actionOf(String? line) {
  final body = line!.substring('[genui-action] '.length);
  return body.substring(0, body.indexOf(' '));
}

void main() {
  group('a tap comes back as genui writes it', () {
    test('a button sends its label, and the action name it was drawn with', () {
      final card = cardOf([
        {'type': 'button', 'label': '重跑', 'action': 'rerun'},
      ]);
      final line = genuiActionText(card, tap(actionId(card, '重跑'), const {}));
      expect(actionOf(line), 'rerun');
      expect(payloadOf(line), {'type': 'button', 'label': '重跑'});
    });

    test('a select sends the picked value and its own id', () {
      final card = cardOf([
        {
          'type': 'select',
          'label': '环境',
          'id': 'env',
          'action': 'pick',
          'options': ['dev', 'prod'],
        },
      ]);
      final line = genuiActionText(card, tap(actionId(card, '环境'), {'value': 'prod'}, PluginActionSource.change));
      expect(actionOf(line), 'pick');
      expect(payloadOf(line), {'type': 'select', 'value': 'prod', 'id': 'env'});
    });

    test('a select without an id sends the value alone', () {
      final card = cardOf([
        {
          'type': 'select',
          'label': '环境',
          'action': 'pick',
          'options': ['dev', 'prod'],
        },
      ]);
      final line = genuiActionText(card, tap(actionId(card, '环境'), {'value': 'dev'}, PluginActionSource.change));
      expect(payloadOf(line), {'type': 'select', 'value': 'dev'});
    });

    test('a radio sends the picked value and nothing else', () {
      final card = cardOf([
        {
          'type': 'radio',
          'label': '分支',
          'action': 'branch',
          'options': ['main', 'dev'],
        },
      ]);
      final line = genuiActionText(card, tap(actionId(card, '分支'), {'value': 'dev'}, PluginActionSource.change));
      expect(payloadOf(line), {'type': 'radio', 'value': 'dev'});
    });

    test('a checkbox sends its label and whether it is on', () {
      final card = cardOf([
        {'type': 'checkbox', 'label': '强制', 'action': 'force'},
      ]);
      final line = genuiActionText(card, tap(actionId(card, '强制'), {'value': true}, PluginActionSource.change));
      expect(payloadOf(line), {'type': 'checkbox', 'label': '强制', 'checked': true});
    });

    test('a switch sends only its new state', () {
      final card = cardOf([
        {'type': 'switch', 'label': '自动', 'action': 'auto'},
      ]);
      final line = genuiActionText(card, tap(actionId(card, '自动'), {'value': false}, PluginActionSource.change));
      expect(payloadOf(line), {'type': 'switch', 'checked': false});
    });

    test('a grouped radio stays silent until the form is sent', () {
      final card = cardOf([
        {
          'type': 'radio',
          'label': '分支',
          'group': 'branch',
          'action': 'branch',
          'options': ['main', 'dev'],
        },
      ]);
      // No onChange: the plugin view never reports this control on its own.
      final node = genuiToPluginView({
        'items': [
          {
            'type': 'radio',
            'label': '分支',
            'group': 'branch',
            'action': 'branch',
            'options': ['main', 'dev'],
          },
        ],
      }).view!;
      expect(jsonEncode(node).contains('"onChange"'), isFalse);
      expect(card.controls.values, isNotEmpty);
    });
  });

  group('a form sends every member it collected', () {
    final items = <Object?>[
      {
        'type': 'input',
        'label': '分支名',
        'id': 'branch',
        'placeholder': 'feat/x',
      },
      {
        'type': 'radio',
        'label': '范围',
        'group': 'scope',
        'options': ['小', '大'],
      },
      {'type': 'submit', 'label': '提交', 'action': 'grade', 'groups': ['branch', 'scope']},
    ];

    test('answers carry the radios, fields carry the filled inputs', () {
      final card = cardOf(items);
      final control = only(card, '提交');
      expect(control.binds, hasLength(2));
      final line = genuiActionText(
        card,
        tap(actionId(card, '提交'), {
          'values': {control.binds[0]: 'feat/login', control.binds[1]: '大'},
        }, PluginActionSource.submit),
      );
      expect(actionOf(line), 'grade');
      expect(payloadOf(line), {
        'type': 'submit',
        'answers': {'scope': '大'},
        'fields': {'branch': 'feat/login'},
        'total': 2,
        'answered': 2,
      });
    });

    test('an empty input is left out of the fields', () {
      final card = cardOf(items);
      final control = only(card, '提交');
      final line = genuiActionText(
        card,
        tap(actionId(card, '提交'), {
          'values': {control.binds[0]: '  ', control.binds[1]: '小'},
        }, PluginActionSource.submit),
      );
      final payload = payloadOf(line);
      expect(payload.containsKey('fields'), isFalse);
      expect(payload['answered'], 1);
    });

    test('the run of fields before a submit becomes its body; a field after it does not', () {
      final card = cardOf([
        {
          'type': 'input',
          'label': '甲',
          'id': 'a',
        },
        {'type': 'submit', 'label': '提交', 'action': 'go'},
        {
          'type': 'input',
          'label': '乙',
          'id': 'b',
        },
      ]);
      expect(only(card, '提交').binds, hasLength(1));
    });
  });

  group('a tap that answers nothing', () {
    test('an unknown id sends nothing', () {
      expect(genuiActionText(GenuiCard.empty, tap('genui.9', const {})), isNull);
    });

    test('a control without an action name sends nothing', () {
      final card = cardOf([
        {
          'type': 'input',
          'label': '甲',
          'id': 'a',
        },
      ]);
      expect(genuiActionText(card, tap(actionId(card, '甲'), const {}, PluginActionSource.change)), isNull);
    });

    test('a value of the wrong shape sends nothing', () {
      final card = cardOf([
        {
          'type': 'select',
          'label': '环境',
          'action': 'pick',
          'options': ['dev'],
        },
      ]);
      final id = actionId(card, '环境');
      expect(genuiActionText(card, tap(id, const {}, PluginActionSource.change)), isNull);
      expect(genuiActionText(card, tap(id, {'value': 3}, PluginActionSource.change)), isNull);
    });
  });
}
