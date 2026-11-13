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

/// [activity] said in the conversation [conversation].
Map<String, Object?> inConversation(
  String conversation,
  Map<String, Object?> activity,
) {
  (activity['conversation']! as Map<String, Object?>)['id'] = conversation;
  return activity;
}

void main() {
  setUpAll(setUpKeys);

  late StandInJourneyPath journeyPath;
  late TeamsMessages teams;
  late List<TeamsPost> posted;
  late List<String> logged;

  /// What the agent does when a [UserSaid] reaches it, if anything.
  void Function(TurnId id, UserSaid said)? agent;

  /// What the composition does with a doorbell: the module reads it, and
  /// the journey path appends what it read.
  TurnId? say(Map<String, Object?> activity) {
    final said = teams.said(bellOf(activity));
    return said == null ? null : journeyPath.append(said);
  }

  setUp(() {
    posted = [];
    logged = [];
    agent = null;
    teams = TeamsMessages(log: logged.add);
    // The composition: each node goes to the acceptor bound to its shape,
    // and a post the module describes goes to the airlock (here, a list).
    journeyPath = StandInJourneyPath(
      deliver: (id, node) {
        switch (node) {
          case UserSaid said:
            teams.heard(id, said);
            agent?.call(id, said);
          case ReplyText reply:
            if (teams.answer(reply) case final post?) posted.add(post);
        }
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
  });

  group('what is said', () {
    test('is read as UserSaid: who, where, and what', () {
      final got = teams.said(
        bellOf(message(id: 'act-1', text: 'Is the draft ready?')),
      );
      expect(got?.author, ada);
      expect(got?.source.value, 'a:1personal|act-1');
      expect(got?.text, 'Is the draft ready?');
    });

    test('loses the @-mention of the bot, which is how a group says it', () {
      final got = teams.said(
        bellOf(message(text: '<at>Bot</at> Is the draft ready?')),
      );
      expect(got?.text, 'Is the draft ready?');
    });

    test('from someone Teams does not name reads as nothing', () {
      final a = message()..remove('from');
      expect(teams.said(bellOf(a)), isNull);
      expect(logged.single, contains('no tenant or Entra user'));
    });

    test('with no words reads as nothing', () {
      expect(teams.said(bellOf(message(text: '<at>Bot</at>'))), isNull);
    });

    test('a card press is not a message', () {
      expect(teams.said(bellOf(cardAction())), isNull);
    });
  });

  group('a reply', () {
    test('to what was said here is described as a post under it', () {
      final asked = say(message(id: 'act-1'))!;
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
      say(message(id: 'act-2'));
      expect(posted.single.replyToId, 'act-2');
      expect(posted.single.activity['text'], 'At once.');
    });

    test('is found by what was said, not by the very object', () {
      // A journey path that stores what it appends delivers a copy read
      // back from the store, not the node the module returned.
      final said = teams.said(bellOf(message(id: 'act-3')))!;
      final store = StandInJourneyPath(
        deliver: (_, _) {},
        encodeOther: (_) => {'shape': 'UserSaid', 'source': 'act-3'},
      );
      final id = store.append(said);
      teams.heard(
        id,
        UserSaid(author: said.author, source: said.source, text: said.text),
      );
      final post = teams.answer(
        ReplyText(by: agentId, answers: id, text: 'From the store.'),
      );
      expect(post?.replyToId, 'act-3');
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

    test(
      'to a source shaped like ours from a chat never heard is not posted',
      () {
        final elsewhere = journeyPath.append(
          UserSaid(
            author: ada,
            source: SourceMessageId.parse('C0123|1731456789.000100')!,
            text: 'hello',
          ),
        );
        journeyPath.append(
          ReplyText(by: agentId, answers: elsewhere, text: 'Hi.'),
        );
        expect(posted, isEmpty);
      },
    );

    test('goes to the conversation of what it answers, not the newest', () {
      final first = say(message(id: 'act-1'))!;
      say(inConversation('a:2other', message(id: 'act-9')));
      journeyPath.append(
        ReplyText(by: agentId, answers: first, text: 'To the first.'),
      );
      expect(posted.single.conversation, 'a:1personal');
      expect(posted.single.replyToId, 'act-1');
    });

    test('finds its conversation even if the id has a bar in it', () {
      final asked = say(inConversation('19:a|b@thread.v2', message()))!;
      journeyPath.append(
        ReplyText(by: agentId, answers: asked, text: 'Still here.'),
      );
      expect(posted.single.conversation, '19:a|b@thread.v2');
    });

    test('finds its message when two chats share an activity id', () {
      // Teams' activity id is the millisecond it was sent: unique only
      // within one conversation.
      say(message(id: '1794558994313'));
      final second = say(
        inConversation('19:group@thread.v2', message(id: '1794558994313')),
      )!;
      journeyPath.append(
        ReplyText(by: agentId, answers: second, text: 'To the group.'),
      );
      expect(posted.single.conversation, '19:group@thread.v2');
    });
  });
}
