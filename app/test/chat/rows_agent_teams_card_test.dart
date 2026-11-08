// agent-teams' `agent_teams_create` call writes no `meta["dsh-go/view"]`:
// the plugin only puts the team identity in the call's `meta`. The card is
// recognised by tool name + result identity, and it must behave like any
// other plugin card in the row model: never hidden in a tool group, and it
// stays in the stream when a finished turn folds.

import 'dart:convert';

import 'package:dsh_app/ui/agents/team_activity_page.dart' show agentTeamsCreateToolName;
import 'package:dsh_app/ui/agents/team_inline_card.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_chat.dart';

final _t0 = DateTime(2026, 10, 25, 9);

TurnTrace _trace(int startSeq, int endSeq, {String reason = 'completed'}) => TurnTrace(
  turn: startSeq,
  startSeq: startSeq,
  start: _t0,
  spans: const [],
  endSeq: endSeq,
  end: _t0.add(const Duration(seconds: 30)),
  endReason: TurnEndReason(reason),
);

TurnTrace _running(int startSeq) => TurnTrace(turn: startSeq, startSeq: startSeq, start: _t0, spans: const []);

/// The `presentationMeta` the plugin actually emits for a successful create:
/// `{team_id, team_name, captain_session_id, phase, members?}`.
Map<String, Object?> _teamMeta({
  String teamId = 'team-1',
  String? teamName = 'alpha',
  String? captain = 's1',
}) => {
  'team_id': teamId,
  'team_name': ?teamName,
  'captain_session_id': captain,
  'phase': 'running',
  'members': [
    {'id': 'm1', 'name': 'boundary', 'role': 'reviewer', 'status': 'active'},
  ],
};

ToolChatItem _tool(int seq, String id) => ToolChatItem(
  callId: id,
  name: 'weather_card',
  arguments: jsonEncode({'city': id}),
  status: ToolStatus.succeeded,
  seq: seq,
);

ToolChatItem _create(int seq, String id, {Object? meta}) => ToolChatItem(
  callId: id,
  name: agentTeamsCreateToolName,
  arguments: jsonEncode({'team_name': 'alpha'}),
  status: ToolStatus.succeeded,
  seq: seq,
  meta: meta ?? _teamMeta(),
);

List<String> _shape(List<ChatRow> rows) => [
  for (final row in rows) ...[
    switch (row) {
      ToolCallRow(:final card) => '${row.runtimeType} ${row.key} ${card.name}',
      _ => '${row.runtimeType} ${row.key}',
    },
    if (row is TurnProcessRow) ...[
      for (final inner in row.rows)
        switch (inner) {
          ToolCallRow(:final card) => '  ${inner.key} ${card.name}',
          ToolGroupRow(:final tools) => '  ${inner.key} [${tools.map((t) => t.callId).join(',')}]',
          _ => '  ${inner.runtimeType} ${inner.key}',
        },
    ],
    if (row is ToolGroupRow) '  [${row.tools.map((t) => t.callId).join(',')}] live=${row.live}',
  ],
];

void main() {
  test('a create call with an identity counts; one without does not', () {
    expect(hasToolCard(_create(1, 'c')), isTrue);
    // 没有 team_id：卡片画不出来，回落成普通工具行。
    expect(hasToolCard(_create(1, 'c', meta: {'team_name': 'alpha'})), isFalse);
    expect(hasToolCard(_create(1, 'c', meta: 'nope')), isFalse);
    expect(hasToolCard(_create(1, 'c', meta: {'team_id': ''})), isFalse);
    // 其他工具即使带了同名 meta 也不算。
    expect(
      hasToolCard(
        ToolChatItem(
          callId: 'w',
          name: 'weather_card',
          arguments: '{}',
          status: ToolStatus.succeeded,
          seq: 1,
          meta: _teamMeta(),
        ),
      ),
      isFalse,
    );
  });

  test('a failed create still has no card (only a result carries identity)', () {
    final failed = ToolChatItem(
      callId: 'c',
      name: agentTeamsCreateToolName,
      arguments: '{}',
      status: ToolStatus.failed,
      seq: 1,
      meta: _teamMeta(),
    );
    expect(hasToolCard(failed), isFalse);
  });

  test('two creates in one turn: one card after another, in call order', () {
    final items = [
      user(1, '起两个团队'),
      _create(2, 'a', meta: _teamMeta(teamId: 'team-a', teamName: 'alpha')),
      _create(3, 'b', meta: _teamMeta(teamId: 'team-b', teamName: 'beta')),
    ];
    final metas = agentTeamsMetasOf(items.whereType<ToolChatItem>());
    expect(metas.map((m) => m.teamId), ['team-a', 'team-b']);
    expect(metas.map((m) => m.key), ['ateam-team-a', 'ateam-team-b']);
  });

  group('a finished turn folds', () {
    List<ChatItem> turn({required ToolChatItem middle}) => [
      user(1, '起一个团队做适配'),
      assistant(2, '', reasoning: '先建团队'),
      _tool(2, 'a'),
      middle,
      assistant(5, '团队已启动。'),
    ];

    test('the tool row goes in, the card stays out', () {
      final rows = deriveRows(items: turn(middle: _create(3, 'c')), turns: [_trace(0, 6)], foldTurns: true);
      expect(_shape(rows), [
        'UserRow u1',
        'TurnProcessRow tp0',
        '  AssistantRow a2',
        '  ta inline',
        '  tc rowOnly',
        'ToolCallRow tc cardOnly',
        'AssistantRow a5',
      ]);
    });

    test('a create without identity folds like any other tool call', () {
      final rows = deriveRows(
        items: turn(middle: _create(3, 'c', meta: {'team_name': 'alpha'})),
        turns: [_trace(0, 6)],
        foldTurns: true,
      );
      expect(_shape(rows), [
        'UserRow u1',
        'TurnProcessRow tp0',
        '  AssistantRow a2',
        '  ta inline',
        '  tc inline',
        'AssistantRow a5',
      ]);
    });
  });

  group('tool groups', () {
    /// `a b c` are ordinary calls; `w` is the create. [carded] decides whether
    /// `w` carries a team identity (or nothing, or an identity-less meta).
    List<ChatItem> calls({String? carded}) => [
      user(1, 'q'),
      for (final (i, id) in ['a', 'b', 'c', 'w'].indexed)
        if (id != 'w')
          _tool(2 + i, id)
        else
          _create(2 + i, id, meta: carded == null ? {'team_name': 'alpha'} : _teamMeta()),
    ];

    test('a create with a card is never hidden in a group', () {
      final rows = deriveRows(items: calls(carded: 'w'), turns: [_running(0)], running: true);
      expect(_shape(rows), [
        'UserRow u1',
        'ToolGroupRow gta',
        '  [a,b,c] live=false',
        'ToolCallRow tw inline',
      ]);
    });

    test('a create without identity hides in the group like any other call', () {
      final rows = deriveRows(items: calls(), turns: [_running(0)], running: true);
      expect(_shape(rows), ['UserRow u1', 'ToolGroupRow gta', '  [a,b,c,w] live=true']);
    });
  });
}
