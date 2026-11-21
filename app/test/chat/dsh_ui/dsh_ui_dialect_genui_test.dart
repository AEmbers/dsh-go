// The genui dialect of the ```dsh-ui fence (docs/design/plugin-ui-v3.md
// §3.2): `@changfenhuang/dsh-genui` writes its own JSON under the same fence.
// Its blocks become a read-only plugin view, never 「格式有误 + 让它重发」.

import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_dialect_card.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_dialect_genui.dart';
import 'package:dsh_app/ui/chat/render/mermaid_preview.dart';
// The platform interface is what webview_flutter builds on; the app only
// depends on webview_flutter.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../../web/support/fake_webview.dart';

String j(Object json) => jsonEncode(json);

/// A status report the way genui's SKILL.md teaches it.
final report = j({
  'title': '本周构建',
  'items': [
    {
      'type': 'grid',
      'cols': 3,
      'items': [
        {'type': 'stat', 'label': '通过', 'value': '26', 'delta': '+4'},
        {'type': 'stat', 'label': '失败', 'value': '2', 'delta': '-1'},
        {'type': 'stat', 'label': '耗时', 'value': '6.2 分'},
      ],
    },
    {
      'type': 'table',
      'columns': ['任务', '状态', '耗时'],
      'types': ['text', 'badge', 'num'],
      'rows': [
        ['lint', '通过', 42],
        ['test', '失败', 318],
      ],
    },
    {
      'type': 'steps',
      'current': 1,
      'steps': [
        {'title': '拉代码'},
        {'title': '跑测试', 'desc': '第 2 个分片失败'},
        {'title': '发布'},
      ],
    },
    {'type': 'callout', 'tone': 'warning', 'title': '注意', 'content': '`test` 的 [日志](https://ci.example/1) 里有 ==超时=='},
    {'type': 'echart', 'preset': 'bar', 'data': []},
    {'type': 'button', 'label': '重跑', 'action': 'rerun'},
    {'type': 'submit', 'label': '提交', 'action': 'grade'},
  ],
});

void main() {
  group('detection', () {
    test('genui roots: an items envelope, a bare genui component, a root list', () {
      expect(isGenuiDialect(jsonDecode(report)), isTrue);
      expect(isGenuiDialect({'type': 'stat', 'label': 'a', 'value': '1'}), isTrue);
      expect(
        isGenuiDialect([
          {'type': 'keyvalue', 'pairs': []},
        ]),
        isTrue,
      );
      expect(isGenuiDialect({'type': 'text', 'content': '你好'}), isTrue);
      expect(isGenuiDialect({'type': 'steps', 'steps': []}), isTrue);
    });

    test("the app's own format is never taken for genui", () {
      expect(
        isGenuiDialect({
          'type': 'stack',
          'children': [
            {'type': 'metric', 'label': 'a', 'value': 1},
          ],
        }),
        isFalse,
      );
      expect(isGenuiDialect({'type': 'text', 'text': '你好'}), isFalse);
      expect(
        isGenuiDialect([
          {'type': 'metric', 'label': 'a', 'value': 1},
        ]),
        isFalse,
      );
      expect(
        isGenuiDialect({
          'type': 'steps',
          'items': ['a'],
        }),
        isFalse,
      );
      expect(isGenuiDialect('nope'), isFalse);
    });
  });

  group('mapping', () {
    test('a status report becomes a plugin view, marked genui', () {
      final parsed = parseDshUiUncached(report);
      expect(parsed, isA<DshUiParsed>());
      final view = (parsed as DshUiParsed).view;
      expect(view.dialect, 'genui');
      expect(view.version, 2);
      expect(view.title, '本周构建');
      // A button and a submit are live: the card answers the model itself,
      // through the plugin view's own actions rather than an option list.
      expect(view.answerNodes, isEmpty);
      final actions = view.nodes.whereType<DshUiActions>().toList();
      expect(actions, hasLength(1));
      expect([for (final b in actions.single.items) b.label], ['重跑']);
      // The submit is a form of its own: what it collects is the run of bound
      // controls before it, and here there is none.
      final form = view.nodes.whereType<DshUiControlContainer>().single;
      expect(form.kind, 'form');
      expect(form.submitLabel, '提交');
      expect(form.submit, isNotNull);
      expect(form.inputs, isEmpty);

      final metrics = view.nodes.whereType<DshUiMetric>().toList();
      expect([for (final m in metrics) m.label], ['通过', '失败', '耗时']);
      expect([for (final m in metrics) m.tone], [DshUiTone.good, DshUiTone.bad, null]);
      expect(metrics.first.caption, '+4');

      final table = view.nodes.whereType<DshUiTable>().single;
      expect([for (final c in table.columns) c.label], ['任务', '状态', '耗时']);

      final steps = view.nodes.whereType<DshUiSteps>().single;
      expect(
        [for (final s in steps.items) s.status],
        [DshUiStepStatus.done, DshUiStepStatus.current, DshUiStepStatus.todo],
      );
      expect(steps.items[1].detail, '第 2 个分片失败');

      // A callout is a tinted panel: the title in the tone's colour, then the words.
      final texts = [for (final n in view.nodes.whereType<DshUiText>()) n.text];
      expect(
        texts,
        containsAllInOrder(['注意', '`test` 的 日志 里有 超时']),
        reason: 'links keep their words, highlights their text',
      );
      final panel = view.nodes.whereType<DshUiLayout>().firstWhere(
        (l) => l.children.whereType<DshUiText>().any((t) => t.text == '注意'),
      );
      expect(view.styles[panel.path]?.card, DshUiCardStyle.tinted);
    });

    test('parts without a native counterpart read 「… · 在网页版查看」; a run of them folds into one', () {
      final view = (parseDshUiUncached(report) as DshUiParsed).view;
      final tags = [
        for (final n in view.nodes)
          if (n is DshUiControlDisplay && n.kind == 'tag') n.text,
      ];
      expect(tags, [appL10n.viewUiDialectWebOnly(appL10n.viewUiDialectKindChart)]);
      expect(view.nodes.whereType<DshUiPlaceholder>(), isEmpty, reason: 'no grey 「这部分无法显示」 rows');
      expect([for (final i in view.issues) i.path], contains('spec.items[4]'));
    });

    test('genui chart data become categories and aligned series', () {
      final view = (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'chart',
              'kind': 'bars',
              'horizontal': true,
              'series': [
                {
                  'label': '今年',
                  'data': [
                    {'label': 'Q1', 'value': 30},
                    {'label': 'Q2', 'value': 45},
                  ],
                },
                {
                  'label': '去年',
                  'data': [
                    {'label': 'Q2', 'value': 20},
                  ],
                },
              ],
            },
          ],
        }),
      ) as DshUiParsed).view;
      final chart = view.nodes.whereType<DshUiChart>().single;
      expect(chart.kind, DshUiChartKind.hbar);
      expect(chart.categories, ['Q1', 'Q2']);
      expect([for (final s in chart.series) s.name], ['今年', '去年']);
      expect(chart.series[1].values, [null, 20]);
    });

    test('keyvalue, list aliases, timeline, tabs and code map to their native components', () {
      final view = (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'keyvalue',
              'pairs': [
                {'key': '版本', 'value': '0.2.1'},
              ],
            },
            {
              'type': 'list',
              'items': [
                '纯文字',
                {'label': '标题', 'description': '说明'},
              ],
            },
            {
              'type': 'timeline',
              'items': [
                {'title': '发布', 'time': '10-30', 'desc': '公测'},
              ],
            },
            {
              'type': 'tabs',
              'tabs': [
                {
                  'label': '概览',
                  'items': [
                    {'type': 'text', 'content': '内容'},
                  ],
                },
              ],
            },
            {'type': 'code', 'lang': 'ts', 'code': 'const a = 1'},
            {
              'type': 'json',
              'value': {'ok': true},
            },
          ],
        }),
      ) as DshUiParsed).view;
      final kv = view.nodes.whereType<DshUiKeyValue>().single;
      expect(kv.items.single.label, '版本');
      final list = view.nodes.whereType<DshUiList>().single;
      expect([for (final i in list.items) (i.title, i.subtitle)], [('纯文字', null), ('标题', '说明')]);
      final containers = view.nodes.whereType<DshUiControlContainer>().toList();
      expect([for (final c in containers) c.kind], ['timeline', 'tabs']);
      expect(containers.first.sections.single.label, '10-30 · 发布');
      final code = [
        for (final n in view.nodes)
          if (n is DshUiControlDisplay && n.kind == 'codeBlock') (n.language, n.text),
      ];
      expect(code.first, ('ts', 'const a = 1'));
      expect(code.last.$1, 'json');
    });

    test('only inline images show; a host or web address reads 「图片 · 在网页版查看」', () {
      const pixel =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final view = (parseDshUiUncached(
        j({
          'items': [
            {'type': 'image', 'src': pixel, 'alt': '点'},
            {'type': 'image', 'src': '/mmx-files/a.png'},
            {'type': 'image', 'src': 'https://example.com/a.png'},
          ],
        }),
      ) as DshUiParsed).view;
      expect(view.nodes.whereType<DshUiImage>(), hasLength(1));
      final tags = [
        for (final n in view.nodes)
          if (n is DshUiControlDisplay && n.kind == 'tag') n.text,
      ];
      expect(tags, [appL10n.viewUiDialectWebOnly(appL10n.viewUiDialectKindImage)]);
    });

    test('stat spark → metric trend (last 30), progress ring → ring, image-group → gallery', () {
      const pixel =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final view = (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'stat',
              'label': '余额',
              'value': '¥12',
              'spark': [for (var i = 0; i < 40; i++) i],
            },
            {
              'type': 'stat',
              'label': '坏的',
              'value': '1',
              'spark': [1, 'x'],
            },
            {'type': 'progress', 'variant': 'ring', 'value': 40, 'label': '额度'},
            {
              'type': 'image-group',
              'items': [
                {'src': pixel, 'alt': '一', 'caption': '第一张'},
                {'src': 'https://example.com/b.png', 'alt': '外链'},
                {'src': pixel, 'alt': '二'},
              ],
            },
          ],
        }),
      ) as DshUiParsed).view;
      final metrics = view.nodes.whereType<DshUiMetric>().toList();
      expect(metrics.first.trend, [for (var i = 10; i < 40; i++) i.toDouble()]);
      expect(metrics.last.trend, isNull, reason: 'a spark that is not all numbers is left out, not noted');
      expect(view.nodes.whereType<DshUiProgress>().single.ring, isTrue);
      final gallery = view.nodes.whereType<DshUiGallery>().single;
      expect(gallery.items.map((i) => i.image.alt), ['一', '二'], reason: 'only inline pictures');
      expect(gallery.items.first.caption, '第一张');
      expect(gallery.items.every((i) => i.action == null), isTrue);
    });

    test('a block with nothing to show stays a quiet fallback, marked genui (no resend)', () {
      final parsed = parseDshUiUncached(
        j({
          'items': [
            {'type': 'arrow', 'dir': 'down'},
            {'type': 'icon', 'name': 'Nodes'},
          ],
        }),
      );
      expect(parsed, isA<DshUiInvalid>());
      expect((parsed as DshUiInvalid).dialect, 'genui');
    });

    test('a genui block may use the panel budget; the app format keeps its 16 KiB limit', () {
      final rows = [
        for (var i = 0; i < 50; i++) ['任务 $i', '这一行的说明写得比较长，用来把整块撑过十六 KiB。' * 6, '$i'],
      ];
      final big = j({
        'items': [
          {
            'type': 'table',
            'columns': ['任务', '说明', '序号'],
            'rows': rows,
          },
          {
            'type': 'list',
            'items': [for (var i = 0; i < 50; i++) '第 $i 条：这一条也写得很长很长，帮整块越过模型卡的上限'],
          },
        ],
      });
      expect(utf8.encode(big).length, greaterThan(DshUiLimits.hardBytes));
      expect(parseDshUiUncached(big), isA<DshUiParsed>());

      final own = j({
        'type': 'stack',
        'children': [
          for (var i = 0; i < 120; i++) {'type': 'text', 'text': '这一段写得很长很长很长很长很长很长很长很长很长。' * 2 + '$i'},
        ],
      });
      expect(utf8.encode(own).length, greaterThan(DshUiLimits.hardBytes));
      expect(parseDshUiUncached(own), isA<DshUiInvalid>());
      expect((parseDshUiUncached(own) as DshUiInvalid).dialect, isNull);
    });

    test("the mapped tree answers under its own ids, never genui's own names", () {
      final mapping = genuiToPluginView(jsonDecode(report));
      final text = jsonEncode(mapping.view);
      // A tap comes back as the plugin view's id; what the id means lives in
      // the card, so the tree never carries genui's free-form action name.
      expect(text.contains('"rerun"'), isFalse);
      expect(text.contains('"grade"'), isFalse);
      expect(mapping.card.controls.values.map((c) => c.action), containsAll(['rerun', 'grade']));
    });

    test('mapping is total on hostile input', () {
      for (final input in <Object?>[
        null,
        42,
        'x',
        <Object?>[],
        {'items': 'nope'},
        {
          'items': [null, 1, 'a', <Object?>[], {}],
        },
        {
          'items': [
            {'type': 'table', 'columns': 'x', 'rows': 3},
            {'type': 'chart', 'data': 'x'},
            {
              'type': 'grid',
              'cols': 'x',
              'items': [
                {'type': 'stat'},
              ],
            },
            {'type': 'card'},
            {'type': 'tabs', 'tabs': 'x'},
            {
              'type': 'steps',
              'current': 'x',
              'steps': [1, null],
            },
          ],
        },
      ]) {
        expect(() => genuiToPluginView(input), returnsNormally, reason: '$input');
      }
    });
  });

  group('embedded diagrams and charts', () {
    setUpAll(loadTestFonts);

    test('a mermaid diagram is a code block tagged mermaid, which the app renders', () {
      final view = (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'mermaid',
              'code': 'graph TD;\n  A-->B;',
            },
          ],
        }),
      ) as DshUiParsed).view;
      final block = view.nodes.whereType<DshUiControlDisplay>().single;
      expect(block.kind, 'codeBlock');
      expect(block.language, 'mermaid');
      expect(block.text, 'graph TD;\n  A-->B;');
      // Nothing is dropped to the web page: the fence carries the whole source.
      expect(view.nodes.whereType<DshUiControlDisplay>().where((n) => n.kind == 'tag'), isEmpty);
    });

    test('a mermaid block without code is absent, not an empty box', () {
      final view = (parseDshUiUncached(
        j({
          'items': [
            {'type': 'mermaid', 'code': null},
            {'type': 'text', 'content': '在'},
          ],
        }),
      ) as DshUiParsed).view;
      expect(view.nodes.whereType<DshUiControlDisplay>(), isEmpty);
      expect([for (final n in view.nodes.whereType<DshUiText>()) n.text], contains('在'));
    });

    test('echart presets become native chart kinds; scatter keeps the web tag', () {
      DshUiChart chartFor(Object preset) => (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'echart',
              'preset': preset,
              'title': '销量',
              'data': [
                {'label': '一月', 'value': 3},
                {'label': '二月', 'value': 5},
              ],
            },
          ],
        }),
      ) as DshUiParsed).view.nodes.whereType<DshUiChart>().single;

      expect(chartFor('bar').kind, DshUiChartKind.bar);
      expect(chartFor('line').kind, DshUiChartKind.line);
      expect(chartFor('area').kind, DshUiChartKind.line);
      expect(chartFor('pie').kind, DshUiChartKind.donut);
      expect(chartFor('no-such-preset').kind, DshUiChartKind.bar, reason: 'bar is the default shape');

      final bars = chartFor('bar');
      expect(bars.categories, ['一月', '二月']);
      expect([for (final s in bars.series) s.values], [
        [3.0, 5.0],
      ]);
      expect(bars.caption, '销量');

      final scatter = (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'echart',
              'preset': 'scatter',
              'data': [
                {'label': 'a', 'value': 1},
              ],
            },
          ],
        }),
      ) as DshUiParsed).view;
      expect(scatter.nodes.whereType<DshUiChart>(), isEmpty);
      expect(
        [for (final n in scatter.nodes.whereType<DshUiControlDisplay>()) n.text],
        [appL10n.viewUiDialectWebOnly(appL10n.viewUiDialectKindChart)],
      );
    });

    test('echart named series line up on one set of categories', () {
      final chart = (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'echart',
              'preset': 'line',
              'series': [
                {
                  'name': '今年',
                  'data': [
                    {'label': 'Q1', 'value': 30},
                    {'label': 'Q2', 'value': 45},
                  ],
                },
                {
                  'name': '去年',
                  'data': [
                    {'label': 'Q2', 'value': 20},
                  ],
                },
              ],
            },
          ],
        }),
      ) as DshUiParsed).view.nodes.whereType<DshUiChart>().single;
      expect(chart.kind, DshUiChartKind.line);
      expect(chart.categories, ['Q1', 'Q2']);
      expect([for (final s in chart.series) s.name], ['今年', '去年']);
      expect(chart.series[1].values, [null, 20.0], reason: 'a short row is padded, not shifted');
    });

    test('plot samples an expression into a polyline over its domain', () {
      final chart = (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'plot',
              'title': '正弦',
              'xMin': 0,
              'xMax': 6,
              'series': [
                {'label': 'sin', 'expr': 'sin(x)'},
              ],
            },
          ],
        }),
      ) as DshUiParsed).view.nodes.whereType<DshUiChart>().single;
      expect(chart.kind, DshUiChartKind.line);
      expect(chart.categories, hasLength(40));
      expect(chart.categories.first, '0.00');
      expect(chart.categories.last, '6.00');
      final values = chart.series.single.values;
      expect(values, hasLength(40));
      // sin(0)=0, sin(π/2)≈1 — sampled coarsely, so allow a tenth.
      expect(values.first, closeTo(0, 0.001));
      final peak = values.map((v) => v ?? -2).reduce((a, b) => a > b ? a : b);
      expect(peak, closeTo(1, 0.1));
      expect(chart.series.single.name, 'sin');
      expect(chart.caption, '正弦');
    });

    test('plot keeps parameters and drops what it cannot evaluate', () {
      final view = (parseDshUiUncached(
        j({
          'items': [
            {
              'type': 'plot',
              'xMin': -1,
              'xMax': 1,
              'series': [
                {'expr': 'a*x', 'params': {'a': 2}},
                {'expr': 'no_such_function(x)'},
                {'label': 'no expr'},
              ],
            },
          ],
        }),
      ) as DshUiParsed).view;
      final chart = view.nodes.whereType<DshUiChart>().single;
      expect([for (final s in chart.series) s.name], ['a*x'], reason: 'a labelled name is optional');
      expect(chart.series.single.values.first, closeTo(-2, 0.001));
      expect(chart.series.single.values.last, closeTo(2, 0.001));
    });

    test('a plot with nowhere to go is the web tag, not an empty chart', () {
      for (final spec in <Object?>[
        {'type': 'plot'},
        {
          'type': 'plot',
          'xMin': 5,
          'xMax': 5,
          'series': [
            {'expr': 'x'},
          ],
        },
        {
          'type': 'plot',
          'xMin': 0,
          'xMax': 1,
          'series': [
            {'expr': ')))'},
          ],
        },
      ]) {
        final parsed = parseDshUiUncached(
          j({
            'items': [spec],
          }),
        );
        // Nothing to draw: either the block is dropped whole (genui's own
        // 「no resend」 fallback) or the plot is replaced by the web tag. What
        // never happens is an empty chart on screen.
        if (parsed is DshUiInvalid) continue;
        final view = (parsed as DshUiParsed).view;
        expect(view.nodes.whereType<DshUiChart>(), isEmpty, reason: '$spec');
      }
    });

    testWidgets('a mermaid fence in a plugin card offers the full-screen preview', (tester) async {
      WebViewPlatform.instance = FakeWebViewPlatform();
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: DshUiScope(
              sessionId: 's1',
              messageId: 'a1',
              state: DshUiState.live,
              onReply: (_) async => true,
              onAskResend: (_) async => true,
              child: DshUiBlock(
                source: j({
                  'items': [
                    {
                      'type': 'mermaid',
                      'code': 'graph TD;\n  A-->B;',
                    },
                  ],
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // Tagged as a diagram, not as the language name, and both the source and
      // the way into the renderer are on screen.
      expect(find.text(appL10n.chatMermaidChart), findsOneWidget);
      expect(find.text(appL10n.chatPreview), findsOneWidget);
      expect(find.textContaining('graph TD'), findsWidgets);

      await tester.tap(find.text(appL10n.chatPreview));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(MermaidPreviewPage), findsOneWidget);
    });

    testWidgets('an ordinary code fence in a plugin card keeps the copy header only', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: DshUiScope(
              sessionId: 's1',
              messageId: 'a1',
              state: DshUiState.live,
              onReply: (_) async => true,
              onAskResend: (_) async => true,
              child: DshUiBlock(
                source: j({
                  'items': [
                    {'type': 'code', 'lang': 'dart', 'code': 'void main() {}'},
                  ],
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(appL10n.chatMermaidChart), findsNothing);
      expect(find.text(appL10n.chatPreview), findsNothing);
    });
  });

  group('block', () {
    setUpAll(loadTestFonts);

    testWidgets('a genui block draws the read-only card, no resend', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SingleChildScrollView(
              child: DshUiScope(
                sessionId: 's1',
                messageId: 'a1',
                state: DshUiState.live,
                onReply: (_) async => true,
                onAskResend: (_) async => true,
                child: DshUiBlock(source: report),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DshUiDialectCard), findsOneWidget);
      expect(find.text('拉代码'), findsOneWidget);
      expect(find.text(appL10n.viewUiResend), findsNothing);
      expect(find.text(appL10n.viewUiInvalid), findsNothing);
      expect(
        find.byKey(const ValueKey('plugin-v2-attribution')),
        findsNothing,
        reason: 'model output, not a plugin surface',
      );
    });

    testWidgets('an unmappable genui block falls back without offering a resend', (tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: DshUiScope(
              sessionId: 's1',
              messageId: 'a1',
              state: DshUiState.live,
              onReply: (_) async => true,
              onAskResend: (_) async => true,
              child: DshUiBlock(
                source: j({
                  'items': [
                    {'type': 'arrow'},
                  ],
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(appL10n.viewUiDialectInvalid), findsOneWidget);
      expect(find.text(appL10n.viewUiResend), findsNothing);
    });
  });
}
