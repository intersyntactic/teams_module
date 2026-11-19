import 'dart:convert';

import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// The message the gate reads [activity] as, under a token that names the
/// activity's service URL, as Microsoft's do.
TeamsMessage messageOf(Map<String, Object?> activity) =>
    teamsGate(
          spec: TeamsSourceSpec(botAppIds: {appBot}, tenantAllowlist: {tenant}),
          keys: keys,
          headers: {
            'Authorization':
                'Bearer ${signedToken(claims: {...tokenClaims(), 'serviceurl': activity['serviceUrl']})}',
          },
          body: utf8.encode(jsonEncode(activity)),
          now: now,
          hasSeen: (_) => false,
        ).event!
        as TeamsMessage;

final ada = ActorId.parse(
  'teams:$tenant/ada00000-0000-4000-8000-000000000001',
)!;
final agentId = ActorId.parse('agent:demo')!;

/// [activity] said in the conversation [conversation].
Map<String, Object?> inConversation(
  String conversation,
  Map<String, Object?> activity,
) {
  (activity['conversation']! as Map<String, Object?>)['id'] = conversation;
  return activity;
}

/// [activity] arriving through the Bot Connector at [url].
Map<String, Object?> through(String url, Map<String, Object?> activity) =>
    activity..['serviceUrl'] = url;

void main() {
  setUpAll(setUpKeys);

  late StandInTrajectory trajectory;
  late TeamsTranslator teams;
  late List<TeamsPost> posted;

  /// Every node appended, in order, as a trajectory's store keeps them.
  late List<(TurnId, Object)> stored;

  /// What the agent does when a [UserSaid] reaches it, if anything.
  void Function(TurnId id, UserSaid said)? agent;

  /// What the composition does with a Teams message: the translator reads it, and
  /// the trajectory appends what it read, the conversation first.
  TurnId? say(Map<String, Object?> activity) {
    final read = teams.said(messageOf(activity));
    if (read == null) return null;
    if (read.joined case final joined?) trajectory.append(joined);
    return trajectory.append(read.said);
  }

  /// The composition delivering [node] to the module's acceptors.
  void deliverTo(TeamsTranslator module, TurnId id, Object node) {
    switch (node) {
      case TeamsConversation joined:
        module.joined(joined);
      case UserSaid said:
        module.heard(id, said);
      case ReplyText reply:
        if (module.answer(reply) case final post?) posted.add(post);
    }
  }

  setUp(() {
    posted = [];
    stored = [];
    agent = null;
    teams = TeamsTranslator(authors: TeamsAuthors());
    // The composition: each node goes to the acceptor bound to its shape,
    // and a post the module describes goes to the airlock (here, a list).
    trajectory = StandInTrajectory(
      deliver: (id, node) {
        stored.add((id, node));
        deliverTo(teams, id, node);
        if (node case UserSaid said) agent?.call(id, said);
      },
      encodeOther: (node) => switch (node) {
        TeamsConversation(:final id, :final serviceUrl) => {
          'shape': 'TeamsConversation',
          'id': id,
          'service_url': '$serviceUrl',
        },
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
        messageOf(message(id: 'act-1', text: 'Is the draft ready?')),
      );
      expect(got?.said.author, ada);
      expect(got?.said.source.value, 'a:1personal|act-1');
      expect(got?.said.text, 'Is the draft ready?');
    });

    test('loses the @-mention of the bot, which is how a group says it', () {
      final got = teams.said(
        messageOf(message(text: '<at>Bot</at> Is the draft ready?')),
      );
      expect(got?.said.text, 'Is the draft ready?');
    });

    test('by another bot is read as UserSaid too: a bot is a user', () {
      final got = teams.said(
        messageOf({
          ...message(id: 'act-2', text: 'Build 41 failed'),
          'from': {'id': '28:other-bot', 'name': 'CI'},
        }),
      );
      expect(got?.said.author.value, 'teams:$tenant/bot:other-bot');
      expect(got?.said.text, 'Build 41 failed');
    });

    test('from someone Teams does not name reads as nothing', () {
      final a = message()..remove('from');
      expect(teams.said(messageOf(a)), isNull);
    });

    test('with no words reads as nothing', () {
      expect(teams.said(messageOf(message(text: '<at>Bot</at>'))), isNull);
    });
  });

  group('a Reply', () {
    /// [activity] quoting message [id] by [senderId], as a recorded Reply
    /// carried it.
    Map<String, Object?> quoting(
      Map<String, Object?> activity, {
      required String id,
      required String senderId,
      String? senderName,
    }) => {
      ...activity,
      'text': '<quoted messageId="$id"/>\n${activity['text']}',
      'entities': [
        {
          'type': 'quotedReply',
          'quotedReply': {
            'messageId': id,
            'senderId': senderId,
            'senderName': ?senderName,
            'preview': 'Good morning!',
          },
        },
      ],
    };

    final bea = ActorId.parse(
      'teams:$tenant/bea00000-0000-4000-8000-000000000002',
    )!;
    Map<String, Object?> fromBea(String id) => {
      ...message(id: id, text: '<at>Bot</at> hi'),
      'from': {
        'id': '29:1bea',
        'aadObjectId': 'bea00000-0000-4000-8000-000000000002',
        'name': 'Bea',
      },
    };

    test('of only an @-mention says "look at this", by whom it quotes', () {
      teams.said(messageOf(fromBea('act-1')));
      final got = teams
          .said(
            messageOf(
              quoting(
                message(id: 'act-2', text: '<at>Bot</at>'),
                id: 'act-0',
                senderId: '29:1bea',
                senderName: 'Bea',
              ),
            ),
          )!
          .said;
      expect(got.author, ada);
      expect(got.text, isEmpty);
      expect(got.quotes!.source.value, 'a:1personal|act-0');
      expect((got.quotes!.author as KnownAuthor).actor, bea);
    });

    test('with words carries them and the quote', () {
      final got = teams
          .said(
            messageOf(
              quoting(
                message(id: 'act-2', text: 'not quite'),
                id: 'act-1',
                senderId: '29:1ada',
              ),
            ),
          )!
          .said;
      expect(got.text, 'not quite');
      expect((got.quotes!.author as KnownAuthor).actor, ada);
    });

    test('names its quoted author by the record alone: someone never heard '
        'from is not in it, with the name Teams showed', () {
      final got = teams
          .said(
            messageOf(
              quoting(
                message(id: 'act-2', text: '<at>Bot</at>'),
                id: 'act-0',
                senderId: '29:1bea',
                senderName: 'Bea',
              ),
            ),
          )!
          .said;
      expect((got.quotes!.author as UnknownAuthor).displayName, 'Bea');
      // The only words of it the trajectory has, since it never got there.
      expect(got.quotes!.preview, 'Good morning!');
    });

    test('learns from a message that reads as nothing', () {
      expect(
        teams.said(messageOf({...fromBea('act-1'), 'text': '<at>Bot</at>'})),
        isNull,
      );
      final got = teams
          .said(
            messageOf(
              quoting(
                message(id: 'act-2', text: 'see'),
                id: 'act-1',
                senderId: '29:1bea',
              ),
            ),
          )!
          .said;
      expect((got.quotes!.author as KnownAuthor).actor, bea);
    });

    test('names someone heard from in another chat, through the authors '
        'every chat shares', () {
      final authors = TeamsAuthors();
      final chatA = TeamsTranslator(authors: authors);
      final chatB = TeamsTranslator(authors: authors);
      chatA.said(messageOf(inConversation('19:a@thread.v2', fromBea('a-1'))));
      final got = chatB
          .said(
            messageOf(
              quoting(
                message(id: 'act-2', text: '<at>Bot</at>'),
                id: 'act-0',
                senderId: '29:1bea',
              ),
            ),
          )!
          .said;
      expect((got.quotes!.author as KnownAuthor).actor, bea);
      // A translator with authors of its own knows nothing of chat A.
      final alone = TeamsTranslator(authors: TeamsAuthors())
          .said(
            messageOf(
              quoting(
                message(id: 'act-3', text: '<at>Bot</at>'),
                id: 'act-0',
                senderId: '29:1bea',
              ),
            ),
          )!
          .said;
      expect(alone.quotes!.author, isA<UnknownAuthor>());
    });

    test('names someone the authors learnt from any event, not only a '
        'message', () {
      final authors = TeamsAuthors()
        ..learn(
          TeamsCardAction(
            conversation: 'a:1personal',
            id: 'f:1',
            serviceUrl: Uri.parse(serviceUrl),
            bot: appBot,
            from: TeamsUserId.parse('29:1bea'),
            fromAadObjectId: EntraObjectId.parse(
              'bea00000-0000-4000-8000-000000000002',
            ),
          ),
        );
      expect(
        authors.entraIdOf(TeamsUserId.parse('29:1bea')!),
        EntraObjectId.parse('BEA00000-0000-4000-8000-000000000002'),
      );
      expect(authors.entraIdOf(TeamsUserId.parse('29:1ada')!), isNull);
    });

    test('learns nothing from an id in the wrong form: the gate reads it as '
        'absent', () {
      TeamsMessage sentBy(String from, String aad) => messageOf({
        ...message(id: 'm-$from'),
        'from': {'id': from, 'aadObjectId': aad, 'name': 'Bea'},
      });
      final wrongEntra = sentBy('29:1bea', 'oid-bea');
      final wrongUser = sentBy(
        'a:1personal',
        'bea00000-0000-4000-8000-000000000002',
      );
      expect(wrongEntra.fromAadObjectId, isNull);
      expect(wrongUser.from, isNull);
      final authors = TeamsAuthors()
        ..learn(wrongEntra)
        ..learn(wrongUser);
      expect(authors.entraIdOf(TeamsUserId.parse('29:1bea')!), isNull);
    });

    test('of a bot names the bot, which needs no record', () {
      final got = teams
          .said(
            messageOf(
              quoting(
                message(id: 'act-2', text: 'this one'),
                id: 'act-0',
                senderId: '28:$appId',
              ),
            ),
          )!
          .said;
      expect(
        (got.quotes!.author as KnownAuthor).actor.value,
        'teams:$tenant/bot:$appId',
      );
    });
  });

  group('a conversation', () {
    test('is offered the first time it is heard from', () {
      final got = teams.said(messageOf(message()));
      expect(got?.joined?.id, 'a:1personal');
      expect(got?.joined?.serviceUrl, Uri.parse(serviceUrl));
    });

    test('is not offered again once joined', () {
      say(message(id: 'act-1'));
      expect(teams.said(messageOf(message(id: 'act-2')))?.joined, isNull);
    });

    test('is offered again when Teams moves it', () {
      say(message(id: 'act-1'));
      final moved = 'https://smba.trafficmanager.net/emea/';
      final got = teams.said(messageOf(through(moved, message(id: 'act-2'))));
      expect(got?.joined?.serviceUrl, Uri.parse(moved));
    });

    test('is joined only when the trajectory delivers it', () {
      teams.said(messageOf(message(id: 'act-1')));
      expect(teams.said(messageOf(message(id: 'act-2')))?.joined, isNotNull);
    });
  });

  group('a reply', () {
    test('to what was said here is described as a post under it', () {
      final asked = say(message(id: 'act-1'))!;
      trajectory.append(ReplyText(by: agentId, answers: asked, text: 'It is.'));
      expect(posted.single.serviceUrl, Uri.parse(serviceUrl));
      expect(posted.single.conversation, 'a:1personal');
      expect(posted.single.replyToId, 'act-1');
      expect(posted.single.activity, {'type': 'message', 'text': 'It is.'});
    });

    test('given while what it answers is still being delivered is posted', () {
      // An agent that answers at once, inside the delivery of what it
      // answers: before the append that wrote it has returned.
      agent = (id, said) => trajectory.append(
        ReplyText(by: agentId, answers: id, text: 'At once.'),
      );
      say(message(id: 'act-2'));
      expect(posted.single.replyToId, 'act-2');
      expect(posted.single.activity['text'], 'At once.');
    });

    test('after a restart is posted, from what the trajectory replays', () {
      final asked = say(message(id: 'act-3'))!;
      // A new module, knowing only what the trajectory hands it back:
      // copies, as a store would read them, not the nodes appended.
      final restarted = TeamsTranslator(authors: TeamsAuthors());
      for (final (id, node) in stored) {
        deliverTo(restarted, id, switch (node) {
          TeamsConversation(:final id, :final serviceUrl) => TeamsConversation(
            id: id,
            serviceUrl: serviceUrl,
          ),
          UserSaid(:final author, :final source, :final text) => UserSaid(
            author: author,
            source: source,
            text: text,
          ),
          _ => node,
        });
      }
      deliverTo(
        restarted,
        asked,
        ReplyText(by: agentId, answers: asked, text: 'Back again.'),
      );
      expect(posted.single.replyToId, 'act-3');
      expect(posted.single.serviceUrl, Uri.parse(serviceUrl));
    });

    test('goes through where Teams moved the conversation since', () {
      final asked = say(message(id: 'act-1'))!;
      final moved = 'https://smba.trafficmanager.net/emea/';
      say(through(moved, message(id: 'act-2')));
      trajectory.append(ReplyText(by: agentId, answers: asked, text: 'Moved.'));
      expect(posted.single.serviceUrl, Uri.parse(moved));
    });

    test('to what was said by someone not in Teams is not posted', () {
      final elsewhere = trajectory.append(
        UserSaid(
          author: ActorId.parse('slack:T1/U1')!,
          source: SourceMessageId.parse('C0123|1731456789.000100')!,
          text: 'hello',
        ),
      );
      trajectory.append(
        ReplyText(by: agentId, answers: elsewhere, text: 'Hi.'),
      );
      expect(posted, isEmpty);
    });

    test('from a Teams chat never joined is a broken path, said aloud', () {
      final unjoined = UserSaid(
        author: ada,
        source: SourceMessageId.parse('a:9never|act-1')!,
        text: 'hello',
      );
      expect(() => trajectory.append(unjoined), throwsStateError);
    });

    test('goes to the conversation of what it answers, not the newest', () {
      final first = say(message(id: 'act-1'))!;
      say(inConversation('a:2other', message(id: 'act-9')));
      trajectory.append(
        ReplyText(by: agentId, answers: first, text: 'To the first.'),
      );
      expect(posted.single.conversation, 'a:1personal');
      expect(posted.single.replyToId, 'act-1');
    });

    test('finds its conversation even if the id has a bar in it', () {
      final asked = say(inConversation('19:a|b@thread.v2', message()))!;
      trajectory.append(
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
      trajectory.append(
        ReplyText(by: agentId, answers: second, text: 'To the group.'),
      );
      expect(posted.single.conversation, '19:group@thread.v2');
    });
  });
}
