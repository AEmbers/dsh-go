// The team card's own logic: which tool result folds into a card, and what the
// card knows before any snapshot arrives.
//
// The card reads live state, but the *anchor* comes from the tool result alone:
// `@nanmicoder/dsh-agent-teams` never writes `dsh-go/view`, so a card exists
// exactly when a succeeded `agent_teams_create` carries `team_id`. Everything
// below is pure and holds no widget.

import 'package:dsh_app/ui/agents/team_inline_card.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

ToolChatItem _call({
  String name = 'agent_teams_create',
  String arguments = '{}',
  ToolStatus status = ToolStatus.succeeded,
  Object? meta,
  String callId = 'c1',
}) => ToolChatItem(callId: callId, name: name, arguments: arguments, status: status, meta: meta);

Map<String, Object?> _meta({
  String? teamId = 'team-7f3a',
  String? teamName = 'deploy-sweep',
  String? captain = 'sess-captain',
  String? phase = 'running',
  List<Object?>? members,
}) => {
  'team_id': ?teamId,
  'team_name': ?teamName,
  'captain_session_id': ?captain,
  'phase': ?phase,
  'members': ?members,
};

void main() {
  group('agentTeamsCreateMetaOf', () {
    test('reads the published identity off the tool result', () {
      final meta = agentTeamsCreateMetaOf(
        _call(
          meta: _meta(
            members: [
              {'id': 'sess-captain', 'name': 'captain', 'role': 'captain', 'status': 'active'},
              {'id': 'sess-a', 'name': 'researcher', 'role': 'researcher', 'status': 'active'},
            ],
          ),
        ),
      );
      expect(meta, isNotNull);
      expect(meta!.teamId, 'team-7f3a');
      expect(meta.teamName, 'deploy-sweep');
      expect(meta.captainSessionId, 'sess-captain');
      expect(meta.phase, TeamPhase.running);
      expect(meta.members, hasLength(2));
      expect(meta.members.first.name, 'captain');
      expect(meta.members.last.openable, isTrue);
      expect(meta.key, 'ateam-team-7f3a');
    });

    test('a staged plan keeps its phase', () {
      final meta = agentTeamsCreateMetaOf(_call(meta: _meta(phase: 'staged')));
      expect(meta!.phase, TeamPhase.staged);
    });

    test('the id is the anchor, the name only decorates', () {
      final meta = agentTeamsCreateMetaOf(_call(meta: _meta(teamName: null)));
      expect(meta!.teamId, 'team-7f3a');
      // No name published: the id stands in, so the card never shows blank.
      expect(meta.teamName, 'team-7f3a');
      expect(meta.key, 'ateam-team-7f3a');
    });

    test('a CJK name is not an identity and is left alone', () {
      final meta = agentTeamsCreateMetaOf(_call(meta: _meta(teamName: '部署排查')));
      expect(meta!.teamName, '部署排查');
      expect(meta.teamId, 'team-7f3a');
    });

    test('no team_id means no card, whatever else is there', () {
      expect(agentTeamsCreateMetaOf(_call(meta: _meta(teamId: null))), isNull);
      expect(agentTeamsCreateMetaOf(_call(meta: _meta(teamId: ''))), isNull);
    });

    test('another tool, a failed call and a bare meta all fold nothing', () {
      expect(agentTeamsCreateMetaOf(_call(name: 'agent_teams_halt', meta: _meta())), isNull);
      expect(agentTeamsCreateMetaOf(_call(name: 'bash', meta: _meta())), isNull);
      expect(agentTeamsCreateMetaOf(_call(meta: _meta(), status: ToolStatus.failed)), isNull);
      expect(agentTeamsCreateMetaOf(_call(meta: _meta(), status: ToolStatus.running)), isNull);
      expect(agentTeamsCreateMetaOf(_call(meta: null)), isNull);
      expect(agentTeamsCreateMetaOf(_call(meta: 'not a map')), isNull);
    });

    test('a member row without a name is dropped, the rest survive', () {
      final meta = agentTeamsCreateMetaOf(
        _call(
          meta: _meta(
            members: [
              {'id': 'sess-a', 'name': 'researcher'},
              {'id': 'sess-b'},
              'garbage',
            ],
          ),
        ),
      );
      expect(meta!.members, hasLength(1));
      expect(meta.members.single.name, 'researcher');
    });

    test('a removed member cannot be opened', () {
      final meta = agentTeamsCreateMetaOf(
        _call(
          meta: _meta(
            members: [
              {'id': 'sess-a', 'name': 'researcher', 'status': 'removed'},
              {'id': '', 'name': 'writer'},
            ],
          ),
        ),
      );
      expect(meta!.members.first.openable, isFalse);
      expect(meta.members.last.openable, isFalse);
    });

    test('a summary-phase team still answers with the base phase', () {
      final meta = agentTeamsCreateMetaOf(_call(meta: _meta(phase: null)));
      expect(meta!.phase, TeamPhase.unknown);
      expect(meta.members, isEmpty);
    });
  });

  group('agentTeamsMetasOf', () {
    test('three teams in one turn become three cards, in call order', () {
      final metas = agentTeamsMetasOf([
        _call(callId: 'a', meta: _meta(teamId: 't1', teamName: 'one')),
        _call(callId: 'b', name: 'bash', meta: _meta(teamId: 't9')),
        _call(callId: 'c', meta: _meta(teamId: 't2', teamName: 'two')),
        _call(callId: 'd', meta: _meta(teamId: 't3', teamName: 'three')),
      ]);
      expect(metas.map((m) => m.teamId), ['t1', 't2', 't3']);
    });

    test('the same team twice in one turn draws once', () {
      final metas = agentTeamsMetasOf([
        _call(callId: 'a', meta: _meta()),
        _call(callId: 'b', meta: _meta()),
      ]);
      expect(metas, hasLength(1));
    });

    test('a turn that created nothing yields nothing', () {
      expect(agentTeamsMetasOf([_call(name: 'bash', meta: _meta())]), isEmpty);
      expect(agentTeamsMetasOf(const []), isEmpty);
    });
  });
}
