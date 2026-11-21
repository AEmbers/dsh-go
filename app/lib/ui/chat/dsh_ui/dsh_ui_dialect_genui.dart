// The genui dialect of the ```dsh-ui fence (docs/design/plugin-ui-v3.md §3.2).
//
// `@changfenhuang/dsh-genui` teaches the model a JSON of its own under the
// same fence name: a root `{title?, items}` without `type`, and components
// such as `stat`, `card`, `col`, `keyvalue`. Its blocks map onto a read-only
// plugin view (v2) drawn by the app's renderer; a part with no native
// counterpart becomes one quiet 「… · 在网页版查看」 tag, never an error.
//
// Pure: decoded JSON in, plugin-view JSON out. The vocabulary follows the
// plugin's published SKILL.md (0.15.0); none of its code is used.

import 'dart:convert';
import 'dart:math' as math;

import '../../../l10n/l10n.dart';

/// Component names only genui writes: the app's own model cards never use
/// them at the root.
const genuiOnlyTypes = {
  'col', 'grid', 'card', 'carousel', 'divider', 'spacer', 'arrow', 'hero', //
  'stat', 'badge', 'progress', 'list', 'table', 'keyvalue', 'avatar', 'image',
  'image-group', 'audio', 'video', 'timeline', 'file-tree', 'breadcrumb', 'diff',
  'json', 'code', 'icon', 'blocks', 'plot', 'echart', 'button', 'input', 'select',
  'checkbox', 'radio', 'switch', 'slider', 'textarea', 'tabs', 'accordion', 'copy',
  'link', 'submit', 'svg', 'mermaid', 'diagram', 'scene3d', 'quiz', 'map',
};

/// The prefix of every action id a genui control answers under. genui's own
/// action names are free text (they may hold spaces or CJK), while the plugin
/// view's ids must match `[A-Za-z0-9][A-Za-z0-9._:-]{0,63}` — so each control
/// gets a number here and the real name lives in its [GenuiControl].
const genuiActionPrefix = 'genui.';

/// The prefix of every genui control's binding; the app only keeps an input's
/// own action on the `bind` it was given.
const genuiBindPrefix = 'data.genui.f';

/// Whether [json] (a decoded fence) is genui's, not the app's own format.
bool isGenuiDialect(Object? json) {
  if (json is List) {
    return json.any((e) => e is Map && genuiOnlyTypes.contains(e['type']));
  }
  if (json is! Map) return false;
  final type = json['type'];
  if (type == null) return json['items'] is List;
  if (type is! String) return false;
  if (genuiOnlyTypes.contains(type)) return true;
  // Names both formats share, written the genui way.
  return switch (type) {
    'text' || 'callout' => json['content'] is String && json['text'] == null,
    'row' => json['items'] is List && json['children'] == null,
    'steps' => json['steps'] is List && json['items'] == null,
    'chart' => json['data'] is List && json['categories'] == null,
    _ => false,
  };
}

/// One interactive control in a genui card, by the action id it answers under.
///
/// The plugin view hands back only the id and whatever value changed, so what
/// genui needs — its own action name, the component type, the submission key —
/// is kept beside the action instead of inside it.
final class GenuiControl {
  const GenuiControl({
    required this.type,
    this.action,
    this.id,
    this.group,
    this.label = '',
    this.bind,
    this.binds = const [],
  });

  /// genui's own action name: free text, forwarded verbatim.
  final String? action;

  /// The genui component this came from (`button`, `select`, ...).
  final String type;

  /// genui's own `id`: the submission key of an input, textarea, select or
  /// slider, and what a select reports back with its value.
  final String? id;

  /// genui's `group`: a radio or checkbox that has one belongs to a form and
  /// never sends its own action.
  final String? group;

  final String label;

  /// The plugin-view binding this control owns, when it takes part in a form.
  final String? bind;

  /// For `submit`: the bindings of the controls it collects, in card order.
  final List<String> binds;

  GenuiControl withBinds(List<String> next) => GenuiControl(
    type: type,
    action: action,
    id: id,
    group: group,
    label: label,
    bind: bind,
    binds: next,
  );
}

/// What a card needs to answer its controls: the action each one answers
/// under, and the control behind each binding a form collects.
final class GenuiCard {
  const GenuiCard({required this.controls, required this.fields});

  static const empty = GenuiCard(controls: {}, fields: {});

  final Map<String, GenuiControl> controls;
  final Map<String, GenuiControl> fields;
}

/// A mapped block: the plugin view, or null when nothing in it can show.
final class GenuiMapping {
  const GenuiMapping(this.view, this.notes, [this.card = GenuiCard.empty]);

  final Map<String, Object?>? view;

  /// The controls and bindings this mapping made, so a tap can be answered.
  final GenuiCard card;

  /// JSON paths of the parts drawn as 「在网页版查看」 or dropped.
  final List<String> notes;
}

/// Maps a genui fence ([json], already decoded) to a v2 plugin view.
GenuiMapping genuiToPluginView(Object? json) {
  final m = _Mapper();
  String? title;
  List<Object?> items;
  if (json is List) {
    items = json;
  } else if (json is Map && json['type'] == null) {
    items = json['items'] is List ? json['items'] as List : const [];
    title = _str(json['title']);
  } else {
    items = [json];
  }
  final children = m.nodes(items, 'spec.items');
  if (children.isEmpty) return GenuiMapping(null, m.notes);
  final card = GenuiCard(controls: m.controls, fields: m.fields);
  return GenuiMapping(
    {'v': 2, 'type': 'stack', 'title': ?title, 'children': children},
    m.notes,
    card,
  );
}

String? _str(Object? v) => switch (v) {
  final String s when s.trim().isNotEmpty => s,
  final num n => n.toString(),
  _ => null,
};

String _cell(Object? v) => switch (v) {
  null => '',
  final String s => _inline(s),
  final num n => n is int || n == n.roundToDouble() ? n.toInt().toString() : n.toString(),
  final bool b => b ? '✓' : '',
  _ => '—',
};

final _link = RegExp(r'\[([^\]\n]+)\]\([^)\s]+\)');
final _mark = RegExp(r'==([^=\n]+)==');

/// genui's inline marks the app's restricted text doesn't read: a link keeps
/// its words, a highlight its text. `**bold**` and `` `code` `` stay.
String _inline(String s) => s.replaceAllMapped(_link, (m) => m[1]!).replaceAllMapped(_mark, (m) => m[1]!);

/// Tone words → the plugin view's (good / warn / bad / info / muted).
String? _tone(Object? v) => switch (v) {
  'success' || 'good' => 'good',
  'warn' || 'warning' => 'warn',
  'danger' || 'error' || 'bad' => 'bad',
  'info' || 'accent' => 'info',
  'muted' => 'muted',
  _ => null,
};

/// Tone words → a named colour for a card's tint or a text run.
String? _toneColor(Object? v) => switch (v) {
  'success' => 'green',
  'warning' || 'warn' => 'amber',
  'danger' || 'error' => 'red',
  'info' || 'accent' => 'blue',
  _ => null,
};

final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

class _Mapper {
  final notes = <String>[];

  /// genui's own submission key → the bind handed to the plugin view, so a
  /// value edited in the card comes back under the name genui uses.
  final _ids = <String, String>{};

  /// Action id → the control it belongs to, and binding → the control that
  /// owns it. Both outlive the mapping: the card answers taps from here.
  final controls = <String, GenuiControl>{};
  final fields = <String, GenuiControl>{};

  /// How many binds this card has handed out.
  int _binds = 0;

  /// Maps a component list. Placeholders in a row with the same words fold
  /// into one; parts with nothing to show drop out.
  List<Map<String, Object?>> nodes(Object? raw, String path) {
    if (raw is! List) return const [];
    final out = <Map<String, Object?>>[];
    // Where the run of bound fields just before a `submit` starts in [out];
    // the submit takes that run as its form body.
    var runStart = -1;
    for (final (i, item) in raw.indexed) {
      final at = '$path[$i]';
      final mapped = node(item, at);
      if (mapped == null) continue;
      if (item is Map && item['type'] == 'submit') {
        final body = runStart >= 0 ? out.sublist(runStart) : const <Map<String, Object?>>[];
        if (runStart >= 0) out.removeRange(runStart, out.length);
        // The form collects exactly the bound controls before it, in card
        // order; the submit's control has to know them to build its answer.
        final binds = [
          for (final child in body)
            if (child['bind'] case final String bind) bind,
        ];
        if (mapped['submit'] case final String submit) {
          final control = controls[submit];
          if (control != null) controls[submit] = control.withBinds(binds);
        }
        if (body.isNotEmpty) mapped['children'] = body;
        out.add(mapped);
        runStart = -1;
        continue;
      }
      final last = out.isEmpty ? null : out.last;
      if (last != null && last['type'] == 'tag' && mapped['type'] == 'tag' && last['text'] == mapped['text']) {
        continue;
      }
      if (_isBound(mapped)) {
        if (runStart < 0) runStart = out.length;
      } else {
        runStart = -1;
      }
      out.add(mapped);
    }
    return out;
  }

  /// Whether [node] holds a value the enclosing form collects.
  static bool _isBound(Map<String, Object?> node) {
    final bind = node['bind'];
    return bind is String && bind.startsWith(genuiBindPrefix);
  }

  Map<String, Object?> web(String path, String kind) {
    notes.add(path);
    return {'type': 'tag', 'text': appL10n.viewUiDialectWebOnly(kind), 'tone': 'muted'};
  }

  Map<String, Object?> text(
    String text, {
    String? size,
    String? weight,
    String? color,
    String? align,
    bool muted = false,
  }) => {
    'type': 'text',
    'text': text,
    if (muted) 'tone': 'muted',
    if (size != null || weight != null || color != null || align != null)
      'style': {'size': ?size, 'weight': ?weight, 'color': ?color, 'align': ?align},
  };

  Map<String, Object?> stack(List<Map<String, Object?>> children, {Map<String, Object?>? style}) => {
    'type': 'stack',
    'style': ?style,
    'children': children,
  };

  Map<String, Object?>? node(Object? raw, String path) {
    if (raw is String) return _str(raw) == null ? null : text(_inline(raw));
    if (raw is! Map) {
      notes.add(path);
      return null;
    }
    final type = raw['type'];
    if (type is! String) {
      notes.add(path);
      return null;
    }
    switch (type) {
      case 'button':
        return _button(raw, path);
      case 'input':
        return _field(raw, path, kind: 'input');
      case 'textarea':
        return _field(raw, path, kind: 'textarea');
      case 'select':
        return _field(raw, path, kind: 'select');
      case 'radio':
        return _field(raw, path, kind: 'radio');
      case 'checkbox':
        return _field(raw, path, kind: 'checkbox');
      case 'switch':
        return _field(raw, path, kind: 'switch');
      case 'slider':
        return _field(raw, path, kind: 'slider');
      case 'submit':
        return _submit(raw, path);
      case 'quiz':
        return _quiz(raw, path);
      case 'text':
        return _text(raw);
      case 'row':
      case 'col':
      case 'grid':
      case 'card':
      case 'carousel':
        return _container(type, raw, path);
      case 'hero':
        return _hero(raw);
      case 'stat':
        return _stat(raw, path);
      case 'badge':
        final label = _str(raw['label']);
        return label == null ? null : {'type': 'badge', 'text': label, 'tone': ?_tone(raw['tone'])};
      case 'avatar':
        final name = _str(raw['name']);
        return name == null ? null : {'type': 'tag', 'text': name};
      case 'progress':
        return _progress(raw);
      case 'list':
        return _list(raw, path);
      case 'table':
        return _table(raw, path);
      case 'keyvalue':
        return _keyValue(raw, path);
      case 'timeline':
        return _timeline(raw, path);
      case 'steps':
        return _steps(raw, path);
      case 'callout':
        return _callout(raw);
      case 'chart':
        return _chart(raw, path);
      case 'code':
        final code = raw['code'];
        return code is String ? {'type': 'codeBlock', 'code': code, 'language': ?_str(raw['lang'])} : null;
      case 'diff':
        return _diff(raw);
      case 'json':
        return {
          'type': 'codeBlock',
          'language': 'json',
          'code': const JsonEncoder.withIndent('  ').convert(raw['value']),
        };
      case 'copy':
        final body = raw['text'];
        if (body is! String) return null;
        final code = {'type': 'codeBlock', 'code': body};
        final label = _str(raw['label']);
        return label == null ? code : stack([text(label, size: 'caption', muted: true), code], style: {'gap': 'S'});
      case 'link':
        final label = _str(raw['label']) ?? _str(raw['href']);
        return label == null ? null : text(label);
      case 'breadcrumb':
        final parts = [for (final p in raw['items'] is List ? raw['items'] as List : const []) ?_str(p)];
        return parts.isEmpty ? null : text(parts.join(' › '), size: 'caption', muted: true);
      case 'divider':
        final label = _str(raw['label']);
        return label == null
            ? {'type': 'divider'}
            : stack(
                [
                  {'type': 'divider'},
                  text(label, size: 'caption', weight: 'medium', align: 'center', muted: true),
                ],
                style: {'gap': 'S'},
              );
      case 'spacer':
        return {'type': 'spacer', 'size': 'M'};
      case 'arrow' || 'icon':
        // Decoration between blocks: the app's spacing already separates them.
        return null;
      case 'tabs':
        return _sections('tabs', raw['tabs'], path, label: 'label');
      case 'accordion':
        return _sections('accordion', raw['items'], path, label: 'title');
      case 'image':
        return _image(raw, path);
      case 'image-group':
        return _imageGroup(raw, path);
      case 'audio':
        return web(path, appL10n.viewUiDialectKindAudio);
      case 'video':
        return web(path, appL10n.viewUiDialectKindVideo);
      case 'echart':
        return _echart(raw, path);
      case 'plot':
        return _plot(raw, path);
      case 'mermaid':
        return _mermaid(raw);
      case 'diagram' || 'svg' || 'blocks':
        return web(path, appL10n.viewUiDialectKindDiagram);
      case 'scene3d':
        return web(path, appL10n.viewUiDialectKindScene);
      case 'file-tree':
        return web(path, appL10n.viewUiDialectKindFiles);
      case 'map':
        return web(path, appL10n.viewUiDialectKindMap);
    }
    return web(path, appL10n.viewUiDialectKindOther);
  }

  Map<String, Object?>? _text(Map raw) {
    final content = _str(raw['content'] ?? raw['text']);
    if (content == null) return null;
    final size = raw['size'];
    final tone = raw['tone'];
    final align = switch (raw['align'] ?? (raw['center'] == true ? 'center' : null)) {
      'center' => 'center',
      'right' => 'end',
      _ => null,
    };
    final (String? s, String? w) = switch (size) {
      'display' => ('title', 'semibold'),
      'h1' => ('subtitle', 'semibold'),
      'h2' || 'h3' => ('body', 'semibold'),
      'caption' => ('caption', null),
      _ => (raw['mono'] == true ? 'mono' : null, null),
    };
    return text(
      _inline(content),
      size: s,
      weight: w,
      color: _toneColor(tone),
      align: align,
      muted: tone == 'muted' || size == 'muted' || size == 'caption',
    );
  }

  Map<String, Object?>? _container(String type, Map raw, String path) {
    final rawItems = raw['items'];
    final children = nodes(rawItems, '$path.items');
    if (type == 'carousel') {
      if (children.isEmpty) return null;
      return {
        'type': 'carousel',
        'items': [
          for (final (i, child) in children.take(8).indexed)
            {
              'label': _str(child['title']) ?? '${i + 1}',
              'children': [child],
            },
        ],
      };
    }
    if (type == 'card') {
      final heading = <Map<String, Object?>>[
        if (_str(raw['eyebrow']) case final eyebrow?) text(eyebrow, size: 'caption', muted: true),
        if (_str(raw['title']) case final title?) text(title, weight: 'semibold'),
      ];
      if (children.isEmpty && heading.isEmpty) return null;
      final accent = raw['accent'];
      final tint = accent is String && _hex.hasMatch(accent) ? accent : _toneColor(raw['tone']);
      return stack(
        [...heading, ...children],
        style: {'card': tint == null ? 'surface' : 'tinted', 'background': ?tint, 'gap': 'M'},
      );
    }
    if (children.isEmpty) return null;
    if (type == 'grid') {
      // A grid of figures reads best as the app's row of metrics: aligned
      // columns, no box around each number.
      if (children.every((c) => c['type'] == 'metric')) return {'type': 'row', 'children': children};
      final cols = raw['cols'];
      return {'type': 'grid', 'columns': cols is num ? cols.toInt().clamp(1, 4) : 2, 'children': children};
    }
    if (type == 'col') return stack(children);
    // A row of `col`s that all say how wide they are keeps those widths.
    final widths = [
      for (final item in rawItems is List ? rawItems : const [])
        if (item is Map && item['type'] == 'col' && item['width'] is num) (item['width'] as num).toDouble(),
    ];
    final weighted = widths.length == children.length && widths.length <= 8;
    return {
      'type': 'row',
      if (weighted)
        'style': {
          'columns': [for (final w in widths) (w / 100 * 12).round().clamp(1, 12)],
        },
      'children': children,
    };
  }

  Map<String, Object?>? _hero(Map raw) {
    final title = _str(raw['title']);
    final value = _str(raw['value']);
    final subtitle = _str(raw['subtitle']);
    final children = <Map<String, Object?>>[
      if (value != null)
        {
          'type': 'metric',
          'label': _str(raw['label']) ?? title ?? '',
          'value': value,
          'caption': ?_str(raw['delta']),
          'tone': ?_deltaTone(raw['delta']),
          'trend': ?_spark(raw['spark']),
          'style': {'size': 'display'},
        },
      if (value == null && title != null) text(title, size: 'title', weight: 'semibold'),
      if (value != null && title != null && raw['label'] != null) text(title, weight: 'semibold'),
      if (subtitle != null) text(_inline(subtitle), muted: true),
    ];
    if (children.isEmpty) return null;
    final tint = _toneColor(raw['tone']);
    return stack(children, style: {'card': 'tinted', 'background': ?tint, 'gap': 'S'});
  }

  String? _deltaTone(Object? delta) {
    final d = _str(delta)?.trim();
    if (d == null) return null;
    if (d.startsWith('+')) return 'good';
    if (d.startsWith('-') || d.startsWith('−')) return 'bad';
    return null;
  }

  Map<String, Object?>? _stat(Map raw, String path) {
    final label = _str(raw['label']);
    final value = _str(raw['value']);
    if (label == null || value == null) {
      notes.add(path);
      return null;
    }
    return {
      'type': 'metric',
      'label': label,
      'value': value,
      'caption': ?_str(raw['delta']),
      'tone': ?_deltaTone(raw['delta']),
      'trend': ?_spark(raw['spark']),
      if (raw['size'] == 'hero') 'style': {'size': 'display'},
    };
  }

  Map<String, Object?>? _progress(Map raw) {
    final value = raw['value'];
    if (value is! num) return null;
    return {
      'type': 'progress',
      'value': value,
      'max': 100,
      'label': ?_str(raw['label']),
      'caption': ?_str(raw['valueLabel']),
      if (raw['variant'] == 'ring') 'shape': 'ring',
    };
  }

  /// genui's `spark`: 2–60 numbers; the app's trend takes the last 30.
  static List<num>? _spark(Object? raw) {
    if (raw is! List || raw.length < 2 || !raw.every((v) => v is num && v.isFinite)) return null;
    final points = raw.cast<num>();
    return points.length > 30 ? points.sublist(points.length - 30) : points;
  }

  static const _titleKeys = ['title', 'label', 'name'];
  static const _descKeys = ['desc', 'description', 'content', 'text', 'body', 'detail'];

  Map<String, Object?>? _list(Map raw, String path) {
    final rawItems = raw['items'];
    if (rawItems is! List) return null;
    final items = <Map<String, Object?>>[];
    for (final (i, item) in rawItems.indexed) {
      if (item is String) {
        if (_str(item) != null) items.add({'title': _inline(item)});
        continue;
      }
      if (item is! Map) {
        notes.add('$path.items[$i]');
        continue;
      }
      String? first(List<String> keys) => [for (final k in keys) ?_str(item[k])].firstOrNull;
      final title = first(_titleKeys);
      final desc = first(_descKeys);
      if (title == null && desc == null) {
        notes.add('$path.items[$i]');
        continue;
      }
      items.add({'title': _inline(title ?? desc!), if (title != null && desc != null) 'subtitle': _inline(desc)});
    }
    return items.isEmpty ? null : {'type': 'list', 'items': items};
  }

  Map<String, Object?>? _table(Map raw, String path) {
    final columns = raw['columns'];
    final rows = raw['rows'];
    if (columns is! List || columns.isEmpty || rows is! List) return null;
    final types = raw['types'] is List ? raw['types'] as List : const [];
    final mapped = <List<String>>[];
    for (final (r, row) in rows.indexed) {
      if (row is! List) continue;
      mapped.add([
        for (var c = 0; c < columns.length; c++)
          c < types.length && types[c] == 'index' ? '${r + 1}' : (c < row.length ? _cell(row[c]) : ''),
      ]);
    }
    return {
      'type': 'table',
      'columns': [for (final c in columns) _cell(c)],
      'rows': mapped,
    };
  }

  Map<String, Object?>? _keyValue(Map raw, String path) {
    final pairs = raw['pairs'];
    if (pairs is! List) return null;
    final items = [
      for (final p in pairs)
        if (p is Map && _str(p['key']) != null) [_str(p['key'])!, _cell(p['value'])],
    ];
    return items.isEmpty ? null : {'type': 'keyValue', 'items': items};
  }

  Map<String, Object?>? _timeline(Map raw, String path) {
    final rawItems = raw['items'];
    if (rawItems is! List) return null;
    final items = <Map<String, Object?>>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final title = _str(item['title']);
      if (title == null) continue;
      final time = _str(item['time']);
      final desc = _str(item['desc']);
      items.add({
        'label': time == null ? _inline(title) : '$time · ${_inline(title)}',
        'children': [if (desc != null) text(_inline(desc), muted: true)],
      });
    }
    return items.isEmpty ? null : {'type': 'timeline', 'items': items};
  }

  Map<String, Object?>? _steps(Map raw, String path) {
    final steps = raw['steps'] ?? raw['items'];
    if (steps is! List) return null;
    final current = raw['current'] is num ? (raw['current'] as num).toInt() : steps.length;
    final items = <Map<String, Object?>>[];
    for (final (i, step) in steps.indexed) {
      final title = step is Map ? _str(step['title'] ?? step['label']) : _str(step);
      if (title == null) continue;
      items.add({
        'label': _inline(title),
        'status': i < current ? 'done' : (i == current ? 'current' : 'todo'),
        if (step is Map && _str(step['desc']) != null) 'detail': _inline(_str(step['desc'])!),
      });
    }
    return items.isEmpty ? null : {'type': 'steps', 'items': items};
  }

  /// A tinted panel in the tone's colour: the title in that colour, the
  /// words in the reading colour.
  Map<String, Object?>? _callout(Map raw) {
    final content = _str(raw['content'] ?? raw['text']);
    final title = _str(raw['title']);
    if (content == null && title == null) return null;
    final color = _toneColor(raw['tone']) ?? 'blue';
    return stack(
      [
        if (title != null) text(_inline(title), weight: 'semibold', color: color),
        if (content != null) text(_inline(content)),
      ],
      style: {'card': 'tinted', 'background': color, 'gap': 'S'},
    );
  }

  Map<String, Object?>? _chart(Map raw, String path) {
    final kind = switch (raw['kind']) {
      'line' => 'line',
      'area' => 'area',
      'donut' => 'donut',
      'hbar' => 'hbar',
      _ => raw['horizontal'] == true ? 'hbar' : 'bar',
    };
    // genui: `data` for one series, or `series[].data`, each `{label, value}`.
    final rawSeries = <(String?, List)>[
      if (raw['series'] case final List list)
        for (final s in list)
          if (s is Map && s['data'] is List) (_str(s['label']), s['data'] as List),
    ];
    if (rawSeries.isEmpty && raw['data'] is List) rawSeries.add((null, raw['data'] as List));
    final categories = <String>[];
    for (final (_, data) in rawSeries) {
      for (final d in data) {
        final label = d is Map ? _str(d['label']) : null;
        if (label != null && !categories.contains(label)) categories.add(label);
      }
    }
    if (categories.isEmpty) return null;
    final series = [
      for (final (name, data) in rawSeries)
        {
          'name': ?name,
          'values': [
            for (final c in categories)
              () {
                final hit = data.whereType<Map>().where((d) => _str(d['label']) == c).firstOrNull;
                final v = hit?['value'];
                return v is num ? v : null;
              }(),
          ],
        },
    ];
    if (series.every((s) => (s['values'] as List).every((v) => v == null))) {
      return web(path, appL10n.viewUiDialectKindChart);
    }
    return {'type': 'chart', 'kind': kind, 'categories': categories, 'series': series};
  }

  Map<String, Object?>? _diff(Map raw) {
    final diffs = raw['diffs'];
    if (diffs is! List) return null;
    final out = StringBuffer();
    for (final d in diffs) {
      if (d is! Map) continue;
      if (out.isNotEmpty) out.writeln();
      out.writeln('--- ${_str(d['path']) ?? ''}');
      final before = d['oldText'];
      if (before is String) {
        for (final line in const LineSplitter().convert(before)) {
          out.writeln('-$line');
        }
      }
      final after = d['newText'];
      if (after is String) {
        for (final line in const LineSplitter().convert(after)) {
          out.writeln('+$line');
        }
      }
    }
    final code = out.toString().trimRight();
    return code.isEmpty ? null : {'type': 'codeBlock', 'language': 'diff', 'code': code};
  }

  Map<String, Object?>? _sections(String type, Object? raw, String path, {required String label}) {
    if (raw is! List) return null;
    final items = <Map<String, Object?>>[];
    for (final (i, section) in raw.indexed) {
      if (section is! Map) continue;
      final name = _str(section[label]) ?? '${i + 1}';
      items.add({'label': name, 'children': nodes(section['items'], '$path[$i].items')});
    }
    return items.isEmpty ? null : {'type': type, 'items': items.take(8).toList()};
  }

  /// Registers [control] and returns the action id it answers under.
  ///
  /// A fence in the chat has no panel identity to build genui's own ids from,
  /// so the card numbers its controls instead and keeps what each one means in
  /// [controls]. The id is all the plugin view hands back on a tap.
  String _act(GenuiControl control) {
    final id = '$genuiActionPrefix${controls.length}';
    controls[id] = control;
    if (control.bind case final bind?) fields[bind] = control;
    return id;
  }

  /// A control's submission key, or null when it takes part in no form.
  ///
  /// genui keys a value by `id` for inputs and `group` for radios and
  /// checkboxes; the mapper hands each bound control the next free bind in
  /// [genuiBindPrefix] instead of those names, so two controls can't collide
  /// inside the plugin view's flat binding namespace.
  String _bind(Object? raw) {
    final key = raw is Map ? (_str(raw['id']) ?? _str(raw['group'])) : null;
    if (key != null) {
      final known = _ids[key];
      if (known != null) return known;
    }
    // Keep genui's own key as the last segment whenever it is a legal binding
    // segment: the value then comes back under the name the model already
    // knows, with no side table to keep in step.
    var segment = key != null && _segment.hasMatch(key) ? key : 'f$_binds';
    var bind = '$genuiBindPrefix.$segment';
    for (var n = 2; _taken.containsKey(bind); n++) {
      segment = '${segment}_$n';
      bind = '$genuiBindPrefix.$segment';
    }
    _taken[bind] = true;
    _binds++;
    if (key != null) _ids[key] = bind;
    return bind;
  }

  /// Every bind handed out, so two controls never share one.
  final _taken = <String, bool>{};

  static final _segment = RegExp(r'^[A-Za-z_][A-Za-z0-9_-]{0,63}$');

  /// One pressable row. genui only gives a fence button an action; without one
  /// it is just its label, which is also what genui's own compiler does.
  Map<String, Object?>? _button(Map raw, String path) {
    final label = _str(raw['label']);
    final action = _str(raw['action']);
    if (label == null) return null;
    if (action == null) return text(_inline(label));
    final id = _act(GenuiControl(type: 'button', action: action, label: label));
    return {
      'type': 'actions',
      'items': [
        {'label': _inline(label), 'action': id},
      ],
    };
  }

  /// genui's six value-taking components, each onto the plugin view's own
  /// control of the same shape. `kind` is the genui type name.
  Map<String, Object?>? _field(Map raw, String path, {required String kind}) {
    final label = _str(raw['label']);
    if (label == null) return null;
    final bind = _bind(raw);
    final control = GenuiControl(
      type: kind,
      action: _str(raw['action']),
      id: _str(raw['id']),
      group: _str(raw['group']),
      label: label,
      bind: bind,
    );
    final id = _act(control);
    // genui sends a select, radio, checkbox or switch the moment it changes,
    // and never at all when it is grouped into a form — those send on submit.
    final instant = control.action != null && control.group == null;
    String? change() => instant ? id : null;
    switch (kind) {
      case 'input':
      case 'textarea':
        final input = <String, Object?>{
          'type': 'textField',
          'label': _inline(label),
          'bind': bind,
          'placeholder': ?_str(raw['placeholder']),
          'multiline': kind == 'textarea' || raw['rows'] != null,
          'maxLines': switch (raw['rows']) {
            final num n => n.toInt().clamp(1, 8),
            _ => kind == 'textarea' ? 4 : 1,
          },
        };
        // genui writes a multi-line box as a textarea with a row count and a
        // single-line one as an input; both take free text, so both are a
        // textField here.
        if (raw['value'] case final String v when v.isNotEmpty) input['value'] = v;
        return input;
      case 'select':
        final options = _choices(raw, 'options');
        if (options == null) return null;
        return {
          'type': 'select',
          'label': _inline(label),
          'bind': bind,
          'options': options,
          'value': ?_selectedOf(raw, options),
          'onChange': ?change(),
        };
      case 'radio':
        final options = _choices(raw, 'options');
        if (options == null) return null;
        return {
          'type': 'segmented',
          'label': _inline(label),
          'bind': bind,
          'options': options,
          'value': ?_selectedOf(raw, options),
          'onChange': ?change(),
        };
      case 'checkbox':
        // One tick box with its own label; a `group` only decides whether it
        // reports on its own or waits for the form's submit.
        return {
          'type': 'toggle',
          'label': _inline(label),
          'bind': bind,
          'value': raw['checked'] == true,
          'onChange': ?change(),
        };
      case 'switch':
        return {
          'type': 'toggle',
          'label': _inline(label),
          'bind': bind,
          'value': raw['checked'] == true,
          'onChange': ?change(),
        };
      case 'slider':
        var min = raw['min'] is num ? (raw['min'] as num).toDouble() : 0.0;
        var max = raw['max'] is num ? (raw['max'] as num).toDouble() : 100.0;
        if (!(max > min)) {
          min = 0;
          max = 100;
        }
        // The plugin view wants a whole number of steps between 1 and 1000; a
        // range that does not divide keeps its span and takes 100 of them.
        var step = raw['step'] is num ? (raw['step'] as num).toDouble() : 1.0;
        final count = step > 0 ? (max - min) / step : -1;
        if (count < 1 || count > 1000 || count % 1 != 0) step = (max - min) / 100;
        return {
          'type': 'slider',
          'label': _inline(label),
          'bind': bind,
          'min': min,
          'max': max,
          'step': step,
          'value': ?(raw['value'] is num
              ? (raw['value'] as num).clamp(min, max).toDouble()
              : null),
        };
    }
    return null;
  }

  /// genui option lists: plain strings or `{label, value?}`. Values are
  /// mandatory in the plugin view, so the label stands in when none is given.
  List<Map<String, Object?>>? _choices(Map raw, String field) {
    final options = raw[field];
    if (options is! List) return null;
    final out = <Map<String, Object?>>[];
    for (final option in options) {
      final label = _str(option is Map ? option['label'] : option);
      if (label == null) continue;
      final value = _str(option is Map ? option['value'] : null) ?? label;
      if (out.any((o) => o['value'] == value)) continue;
      out.add({'label': _inline(label), 'value': value});
    }
    return out.isEmpty ? null : out.take(24).toList();
  }

  /// The option a control starts on, by `selected` index or `value`.
  String? _selectedOf(Map raw, List<Map<String, Object?>> options) {
    final selected = raw['selected'];
    if (selected is num) {
      final i = selected.toInt();
      return i >= 0 && i < options.length ? options[i]['value'] as String : null;
    }
    final value = _str(selected) ?? _str(raw['value']);
    if (value == null) return null;
    return options.any((o) => o['value'] == value) ? value : null;
  }

  /// A submit button. The fields it collects are the bound controls directly
  /// before it in the same list — see [nodes].
  Map<String, Object?>? _submit(Map raw, String path) {
    final action = _str(raw['action']);
    final label = _str(raw['label']);
    if (action == null && raw['groups'] == null) {
      // Without an action and without a scored group, genui's own fence
      // renders nothing but the label.
      return label == null ? null : text(_inline(label));
    }
    return {
      'type': 'form',
      'label': '',
      'children': const <Object?>[],
      'submitLabel': _inline(label ?? appL10n.chatSubmit),
      'submit': _act(
        GenuiControl(type: 'submit', action: action ?? 'submit', label: label ?? ''),
      ),
    };
  }

  /// A scored question. genui keeps the answer local to the card; a fence has
  /// no card state that outlives a rebuild, so the options are plain reading
  /// here and the explanation shows with them.
  Map<String, Object?>? _quiz(Map raw, String path) {
    final question = _str(raw['question']);
    final options = raw['options'];
    if (question == null || options is! List) return null;
    final rows = [
      for (final option in options.take(8))
        if (_str(option is Map ? option['label'] : option) case final label?)
          text('· ${_inline(label)}'),
    ];
    if (rows.isEmpty) return null;
    final explanation = _str(raw['explanation']);
    return stack([
      text(_inline(question), weight: 'semibold'),
      ...rows,
      if (explanation != null) text(_inline(explanation), muted: true),
    ], style: {'gap': 'S'});
  }

  /// A chart drawn by the app from genui's own `echart` shorthand.
  ///
  /// `preset` names the shape; `data` is one labelled series and `series` is a
  /// list of `{name?, data?}` or bare number lists. `scatter` has no native
  /// chart, so it keeps the web-only tag.
  Map<String, Object?>? _echart(Map raw, String path) {
    final preset = _str(raw['preset']) ?? 'bar';
    if (preset == 'scatter') return web(path, appL10n.viewUiDialectKindChart);
    final kind = switch (preset) {
      'line' => 'line',
      'area' => 'area',
      'pie' => 'donut',
      _ => 'bar',
    };
    final rawSeries = <(String?, List)>[
      if (raw['series'] case final List list)
        for (final s in list)
          if (s is Map)
            (_str(s['name']), s['data'] is List ? s['data'] as List : const [])
          else if (s is List)
            (null, s),
    ];
    if (rawSeries.isEmpty && raw['data'] is List) rawSeries.add((null, raw['data'] as List));
    if (rawSeries.isEmpty) return web(path, appL10n.viewUiDialectKindChart);

    // Categories come from every series in turn, then each series is placed by
    // its own labels: a series that starts at the second category leaves the
    // first one empty instead of shifting its points left.
    final categories = <String>[];
    for (final (_, data) in rawSeries) {
      for (final (i, point) in data.indexed) {
        if (i >= 30) break;
        final name = (point is Map ? _str(point['label']) : null) ?? '${i + 1}';
        if (!categories.contains(name)) categories.add(name);
      }
    }
    final values = <List<num?>>[];
    for (final (_, data) in rawSeries) {
      final row = <num?>[];
      for (final (i, point) in data.indexed) {
        if (i >= 30) break;
        final name = (point is Map ? _str(point['label']) : null) ?? '${i + 1}';
        final column = categories.indexOf(name);
        while (row.length < column) {
          row.add(null);
        }
        row.add(point is Map ? (point['value'] is num ? point['value'] as num : null) : (point is num ? point : null));
      }
      values.add(row);
    }
    if (categories.isEmpty || values.every((r) => r.every((v) => v == null))) {
      return web(path, appL10n.viewUiDialectKindChart);
    }
    // Every column genui writes is one point per series; pad a short row so the
    // chart's own length check (values == categories) holds.
    final series = [
      for (final (i, row) in values.indexed)
        {
          'name': ?rawSeries[i].$1,
          'values': [for (var c = 0; c < categories.length; c++) c < row.length ? row[c] : null],
        },
    ];
    return {
      'type': 'chart',
      'kind': kind,
      if (kind == 'donut') 'series': series.take(1).toList() else 'series': series.take(6).toList(),
      'categories': categories,
      'caption': ?_str(raw['title']),
    };
  }

  /// An equation plot, sampled into a line chart.
  ///
  /// genui's `plot` carries expressions (`a*sin(b*x)`), which the plugin
  /// view's formula engine cannot evaluate, so the curve is sampled here and
  /// drawn as a polyline over `xMin..xMax`.
  Map<String, Object?>? _plot(Map raw, String path) {
    final rawSeries = raw['series'];
    if (rawSeries is! List) return null;
    final xMin = raw['xMin'] is num ? (raw['xMin'] as num).toDouble() : -10.0;
    final xMax = raw['xMax'] is num ? (raw['xMax'] as num).toDouble() : 10.0;
    if (!(xMax > xMin)) return null;
    const points = 40;
    final step = (xMax - xMin) / (points - 1);
    final series = <Map<String, Object?>>[];
    for (final s in rawSeries.take(8)) {
      if (s is! Map) continue;
      final expr = _str(s['expr']);
      if (expr == null) continue;
      final evaluator = _Expr(expr, s['params']);
      if (!evaluator.usable) continue;
      final values = <num?>[];
      for (var k = 0; k < points; k++) {
        final v = evaluator.at(xMin + step * k);
        values.add(v == null ? null : double.parse(v.toStringAsFixed(4)));
      }
      if (values.every((v) => v == null)) continue;
      series.add({'name': _str(s['label']) ?? expr, 'values': values});
    }
    if (series.isEmpty) return web(path, appL10n.viewUiDialectKindChart);
    return {
      'type': 'chart',
      'kind': 'line',
      'categories': [for (var k = 0; k < points; k++) (xMin + step * k).toStringAsFixed(2)],
      'series': series,
      'caption': ?_str(raw['title']),
    };
  }

  /// A mermaid diagram, shown as its source.
  ///
  /// The app has no mermaid renderer, but a `codeBlock` tagged `mermaid` is
  /// exactly what its code block turns into a full-screen diagram preview.
  Map<String, Object?>? _mermaid(Map raw) {
    final code = _str(raw['code']);
    if (code == null) return null;
    return {'type': 'codeBlock', 'language': 'mermaid', 'code': code};
  }

  /// Only inline bitmaps: genui's own image addresses are served by the host
  /// web page (`/mmx-files/…`, `https://…`), which a card in the chat can't
  /// fetch.
  static bool _inlineImage(Object? src) => src is String && src.startsWith('data:image/');

  Map<String, Object?>? _image(Map raw, String path) {
    final src = raw['src'];
    if (!_inlineImage(src)) return web(path, appL10n.viewUiDialectKindImage);
    return {'type': 'image', 'src': src, 'alt': ?_str(raw['alt']), 'caption': ?_str(raw['caption'])};
  }

  Map<String, Object?>? _imageGroup(Map raw, String path) {
    final items = raw['items'];
    if (items is! List) return null;
    final images = [
      for (final item in items)
        if (item is Map && _inlineImage(item['src']))
          {'src': item['src'], 'alt': ?_str(item['alt']), 'caption': ?_str(item['caption'])},
    ];
    if (images.isEmpty) return web(path, appL10n.viewUiDialectKindImage);
    final gallery = {'type': 'gallery', 'items': images.take(24).toList()};
    final title = _str(raw['title']);
    return title == null ? gallery : stack([text(title, weight: 'semibold'), gallery]);
  }
}

/// A plot expression over `x`, e.g. `a*sin(b*x)+c`.
///
/// The plugin view's own formula engine reads arithmetic on `data.` paths
/// only, while genui's plots lean on `sin`, `cos`, `pow` and `pi`. So the
/// source is parsed here and sampled by the caller; an expression this cannot
/// read leaves [usable] false and the series is dropped rather than drawn
/// wrong.
class _Expr {
  _Expr(String source, Object? params) {
    final named = <String, double>{
      if (params is Map)
        for (final e in params.entries)
          if (e.key is String && e.value is num) e.key as String: (e.value as num).toDouble(),
    };
    final tokens = _lex(source);
    if (tokens == null) return;
    _root = _Reader(tokens, named).parse();
  }

  double Function(double)? _root;

  /// Whether the source parsed and can be sampled.
  bool get usable => _root != null;

  double? at(double x) {
    final f = _root;
    if (f == null) return null;
    final v = f(x);
    return v.isFinite ? v : null;
  }

  static List<_Token>? _lex(String source) {
    final out = <_Token>[];
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      if (_space(c)) {
        i++;
        continue;
      }
      if (_digit(c) || (c == '.' && i + 1 < source.length && _digit(source[i + 1]))) {
        final start = i;
        while (i < source.length && (_digit(source[i]) || source[i] == '.')) {
          i++;
        }
        final value = double.tryParse(source.substring(start, i));
        if (value == null) return null;
        out.add(_Token.number(value));
        continue;
      }
      if (_letter(c)) {
        final start = i;
        while (i < source.length && (_letter(source[i]) || _digit(source[i]))) {
          i++;
        }
        out.add(_Token.word(source.substring(start, i)));
        continue;
      }
      if ('+-*/%^(),'.contains(c)) {
        out.add(_Token.op(c));
        i++;
        continue;
      }
      return null;
    }
    return out;
  }

  static bool _space(String c) {
    final u = c.codeUnitAt(0);
    return u == 0x20 || u == 0x09 || u == 0x0a || u == 0x0d;
  }

  static bool _digit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  static bool _letter(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5a) || (u >= 0x61 && u <= 0x7a) || u == 0x5f;
  }
}

enum _TokenKind { number, word, op }

class _Token {
  const _Token.number(this.number) : kind = _TokenKind.number, name = '', op = '';
  const _Token.word(this.name) : kind = _TokenKind.word, op = '', number = 0;
  const _Token.op(this.op) : kind = _TokenKind.op, name = '', number = 0;
  final _TokenKind kind;
  final double number;
  final String name;
  final String op;
}

/// Recursive descent: `+ -`, then `* / %`, then `^`, then a unary sign, then a
/// primary. Every level returns a curve or null, so a parse that lands exactly
/// on the end of the tokens is the whole expression.
class _Reader {
  _Reader(this.tokens, this.names);

  final List<_Token> tokens;
  final Map<String, double> names;
  int i = 0;

  double Function(double)? parse() {
    final body = _sum();
    if (body == null || i != tokens.length) return null;
    return body;
  }

  _Token? peek() => i < tokens.length ? tokens[i] : null;

  bool eat(String op) {
    final t = peek();
    if (t == null || t.kind != _TokenKind.op || t.op != op) return false;
    i++;
    return true;
  }

  double Function(double)? _sum() {
    final first = _product();
    if (first == null) return null;
    var acc = first;
    while (true) {
      final l = acc;
      if (eat('+')) {
        final r = _product();
        if (r == null) return null;
        acc = (v) => l(v) + r(v);
      } else if (eat('-')) {
        final r = _product();
        if (r == null) return null;
        acc = (v) => l(v) - r(v);
      } else {
        return acc;
      }
    }
  }

  double Function(double)? _product() {
    final first = _power();
    if (first == null) return null;
    var acc = first;
    while (true) {
      final l = acc;
      if (eat('*')) {
        final r = _power();
        if (r == null) return null;
        acc = (v) => l(v) * r(v);
      } else if (eat('/')) {
        final r = _power();
        if (r == null) return null;
        acc = (v) => l(v) / r(v);
      } else if (eat('%')) {
        final r = _power();
        if (r == null) return null;
        acc = (v) => l(v) % r(v);
      } else {
        return acc;
      }
    }
  }

  double Function(double)? _power() {
    final base = _unary();
    if (base == null) return null;
    if (!eat('^')) return base;
    final exp = _power();
    if (exp == null) return null;
    return (v) => math.pow(base(v), exp(v)).toDouble();
  }

  double Function(double)? _unary() {
    if (eat('-')) {
      final inner = _unary();
      if (inner == null) return null;
      return (v) => -inner(v);
    }
    if (eat('+')) return _unary();
    return _primary();
  }

  double Function(double)? _primary() {
    if (eat('(')) {
      final inner = _sum();
      if (inner == null || !eat(')')) return null;
      return inner;
    }
    final t = peek();
    if (t == null) return null;
    i++;
    if (t.kind == _TokenKind.number) {
      final value = t.number;
      return (v) => value;
    }
    if (t.kind != _TokenKind.word) return null;
    final name = t.name;
    if (eat('(')) {
      final arg = _sum();
      if (arg == null || !eat(')')) return null;
      final f = _function(name);
      if (f == null) return null;
      return (v) => f(arg(v));
    }
    if (name == 'x') return (v) => v;
    if (name == 'pi') return (_) => math.pi;
    if (name == 'e') return (_) => math.e;
    final fixed = names[name];
    if (fixed == null) return null;
    return (_) => fixed;
  }

  static double Function(double)? _function(String name) => switch (name) {
    'sin' => (v) => math.sin(v),
    'cos' => (v) => math.cos(v),
    'tan' => (v) => math.tan(v),
    'asin' => (v) => math.asin(v),
    'acos' => (v) => math.acos(v),
    'atan' => (v) => math.atan(v),
    'sqrt' => (v) => math.sqrt(v),
    'abs' => (v) => v.abs(),
    'exp' => (v) => math.exp(v),
    'log' => (v) => math.log(v),
    'floor' => (v) => v.floorToDouble(),
    'ceil' => (v) => v.ceilToDouble(),
    'round' => (v) => v.roundToDouble(),
    _ => null,
  };
}
