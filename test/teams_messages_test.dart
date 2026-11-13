import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_agent_shapes/is_agent_shapes.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// The doorbell the gate makes of [activity], as the relay hands it on.
JsonObject bellOf(Map<String, Object?> activity) => teamsGate(
  spec: const TeamsSourceSpec(appId: appId, tenantAllowlist: {tenant}),
  keys: keys,
  headers: {'Authorization': 'Bearer ${signedToken()}'},
  body: utf8.encode(jsonEncode(activity)),
  now: now,
  hasSeen: (_) => false,
).doorbell!;

final ada = ActorId.parse('teams:$tenant/oid-ada')!;
final agentId = ActorId.parse('agent:demo')!;

void main() {
  setUpAll(setUpKeys);

  late StandInJourneyPath journeyPath;
  late TeamsMessages teams;
  late List<TeamsPost> posted;
  late List<String> logged;

  /// What the agent does when a [UserSaid] reaches it, if anything.
  void Function(TurnId id, UserSaid said)? agent;

  setUp(() {
    posted = [];
    logged = [];
    agent = null;
    journeyPath = StandInJourneyPath(
      deliver: (id, node) {
        teams.delivered(id, node);
        if (node case UserSaid said) agent?.call(id, said);
      },
      encodeOther: (node) => switch (node) {
        UserSaid(:final author, :final source, :final text) => {
          'shape': 'UserSaid',
          'author': '$author',
          'source': source.value,
          'text': text,
        },
        ReplyText(:final answers, :final text) => {
          'shape': 'ReplyText',
          'answers': '$answers',
          'text': text,
        },
        _ => throw ArgumentError.value(node, 'node', 'no encoding'),
      },
    );
    teams = TeamsMessages(
      append: journeyPath.append,
      post: posted.add,
      log: logged.add,
    );
  });

  group('what is said', () {
    test('is written as UserSaid: who, where, and what', () {
      UserSaid? got;
      agent = (_, said) => got = said;
      teams.said(bellOf(message(id: 'act-1', text: 'Is the draft ready?')));
      expect(got?.author, ada);
      expect(got?.source.value, 'act-1');
      expect(got?.text, 'Is the draft ready?');
    });

    test('loses the @-mention of the bot, which is how a group says it', () {
      UserSaid? got;
      agent = (_, said) => got = said;
      teams.said(bellOf(message(text: '<at>Bot</at> Is the draft ready?')));
      expect(got?.text, 'Is the draft ready?');
    });

    test('from someone Teams does not name writes nothing', () {
      final a = message()..remove('from');
      expect(teams.said(bellOf(a)), isNull);
      expect(logged.single, contains('no tenant or Entra user'));
    });

    test('with no words writes nothing', () {
      expect(teams.said(bellOf(message(text: '<at>Bot</at>'))), isNull);
    });

    test('a card press is not a message', () {
      expect(teams.said(bellOf(cardAction())), isNull);
    });
  });

  group('a reply', () {
    test('to what was said here is described as a post under it', () {
      final asked = teams.said(bellOf(message(id: 'act-1')))!;
      journeyPath.append(
        ReplyText(by: agentId, answers: asked, text: 'It is.'),
      );
      expect(posted.single.serviceUrl, Uri.parse(serviceUrl));
      expect(posted.single.conversation, 'a:1personal');
      expect(posted.single.replyToId, 'act-1');
      expect(posted.single.activity, {'type': 'message', 'text': 'It is.'});
    });

    test('given while what it answers is still being delivered is posted', () {
      // An agent that answers at once, inside the delivery of what it
      // answers: before the append that wrote it has returned.
      agent = (id, said) => journeyPath.append(
        ReplyText(by: agentId, answers: id, text: 'At once.'),
      );
      teams.said(bellOf(message(id: 'act-2')));
      expect(posted.single.replyToId, 'act-2');
      expect(posted.single.activity['text'], 'At once.');
    });

    test('to what was not said here is not posted', () {
      final elsewhere = journeyPath.append(
        UserSaid(
          author: ada,
          source: SourceMessageId.parse('slack-1')!,
          text: 'hello',
        ),
      );
      journeyPath.append(
        ReplyText(by: agentId, answers: elsewhere, text: 'Hi.'),
      );
      expect(posted, isEmpty);
    });

    test('goes to the conversation of what it answers, not the newest', () {
      final first = teams.said(bellOf(message(id: 'act-1')))!;
      final other = message(id: 'act-9');
      (other['conversation']! as Map<String, Object?>)['id'] = 'a:2other';
      teams.said(bellOf(other));
      journeyPath.append(
        ReplyText(by: agentId, answers: first, text: 'To the first.'),
      );
      expect(posted.single.conversation, 'a:1personal');
      expect(posted.single.replyToId, 'act-1');
    });
  });
}
