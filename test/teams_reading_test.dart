import 'dart:convert';
import 'dart:typed_data';

import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show Approved, HeldOff;
import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_docking_port/is_docking_port.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// [activity] as the docking port hands it over: the body the relay
/// records, `{at, source, bytes}`, read back from its `arrived` entry.
Event recorded(Map<String, Object?> activity) {
  final body = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'at': '2026-11-15T09:45:11.754675Z',
        'source': 'teams',
        'bytes': base64Encode(utf8.encode(jsonEncode(activity))),
      }),
    ),
  );
  return Event.read(EntryHash.of(body), body)!;
}

/// Every one of [activities], folded from the start, as the docking port
/// folds them: the readings in order, and the state after the last.
(TeamsReadingState, List<Reading>) fold(
  Iterable<Map<String, Object?>> activities,
) {
  const reading = TeamsReading();
  var state = reading.start;
  final readings = <Reading>[];
  for (final a in activities) {
    final (next, r) = reading.step(state, recorded(a));
    state = next;
    readings.add(r);
  }
  return (state, readings);
}

final ada = ActorId.parse(
  'teams:$tenant/ada00000-0000-4000-8000-000000000001',
)!;
final bea = ActorId.parse(
  'teams:$tenant/bea00000-0000-4000-8000-000000000002',
)!;
final bot = ActorId.parse('teams:$tenant/bot:$appId')!;

Map<String, Object?> fromBea(String id) => {
  ...message(id: id, text: '<at>Bot</at> hi'),
  'from': {
    'id': '29:1bea',
    'aadObjectId': 'bea00000-0000-4000-8000-000000000002',
    'name': 'Bea',
  },
};

/// [activity], replying to Bea's message [id] as a Reply in a chat does.
Map<String, Object?> quotingBea(Map<String, Object?> activity, String id) => {
  ...activity,
  'text': '<quoted messageId="$id"/>\n${activity['text']}',
  'entities': [
    {
      'type': 'quotedReply',
      'quotedReply': {
        'messageId': id,
        'senderId': '29:1bea',
        'senderName': 'Bea',
        'preview': 'hi',
      },
    },
  ],
};

/// Ada pressing the button whose verb is [verb] on card `1730881000000`.
Map<String, Object?> pressed(String verb) {
  final press = cardAction();
  ((press['value']! as Map)['action']! as Map)['verb'] = verb;
  return press;
}

/// CAM added to [conversation] by Ada, with anyone in [alsoAdded], as
/// Teams sent it on 15 Nov.
Map<String, Object?> added({
  String id = 'f:24c8730b',
  List<String> alsoAdded = const [],
}) => {
  ...message(id: id),
  'type': 'conversationUpdate',
  'membersAdded': [
    {'id': '28:$appId'},
    for (final a in alsoAdded) {'id': a},
  ],
}..remove('text');

void main() {
  group('something said', () {
    test('is Said, with its UserSaid, in its conversation, under its id', () {
      final (_, [r]) = fold([message()]);
      final said = r as Said;
      expect(said.conversation, Conversation.parse('teams:a:1personal'));
      expect(said.key, EventKey.parse('message:1730881234567'));
      expect(said.from, ada);
      expect(said.message.value, 'a:1personal|1730881234567');
      expect(said.node.text, 'Looks right to me');
    });

    test('in a channel thread is in that thread, within its channel', () {
      // As a channel post arrived on 15 Nov: its conversation names the
      // thread by its first post, and a new post's first post is itself.
      const channel = '19:abc@thread.tacv2';
      const thread = '$channel;messageid=1794736789259';
      final (_, [r]) = fold([
        {
          ...message(id: '1794736789259', text: '<at>Bot</at> test'),
          'conversation': {
            'id': thread,
            'conversationType': 'channel',
            'tenantId': tenant,
          },
          'channelData': {
            'tenant': {'id': tenant},
            'channel': {'id': channel},
            'team': {'id': channel},
          },
        },
      ]);
      final said = r as Said;
      expect(said.conversation.value, 'teams:$thread');
      expect(said.within, Conversation.parse('teams:$channel'));
      expect(said.node.text, 'test');
    });

    test('in a chat sits inside nothing', () {
      final (_, [r]) = fold([message()]);
      expect((r as Said).within, isNull);
    });

    test('delivered twice has one key', () {
      final (_, [a, b]) = fold([message(), message()]);
      expect((a as Said).key, (b as Said).key);
    });

    test('quoting someone heard from names them, from the fold alone', () {
      final (_, [_, r]) = fold([
        fromBea('act-1'),
        quotingBea(message(id: 'act-2', text: '<at>Bot</at>'), 'act-1'),
      ]);
      final quotes = (r as Said).node.quotes!;
      expect((quotes.author as KnownAuthor).actor, bea);
      expect(quotes.source.value, 'a:1personal|act-1');
    });

    test('quoting themselves, the first time heard from, names them', () {
      // Bea's earlier message never reached the bot: no @-mention.
      final (_, [r]) = fold([quotingBea(fromBea('act-2'), 'act-1')]);
      expect(((r as Said).node.quotes!.author as KnownAuthor).actor, bea);
    });

    test('quoting someone not yet heard from names them as Teams showed', () {
      final (_, [r]) = fold([
        quotingBea(message(id: 'act-2', text: '<at>Bot</at>'), 'act-1'),
      ]);
      final author = (r as Said).node.quotes!.author as UnknownAuthor;
      expect(author.displayName, 'Bea');
    });

    test('by someone Teams names no Entra id for is nothing to admit', () {
      final (_, [r]) = fold([
        {
          ...message(),
          'from': {'id': '29:1ada', 'name': 'Ada'},
        },
      ]);
      expect(r, isA<NothingToAdmit>());
    });

    test('with no words and no quote is nothing to admit', () {
      final (_, [r]) = fold([message(text: '<at>Bot</at>')]);
      expect(r, isA<NothingToAdmit>());
    });
  });

  group('a join', () {
    test('of CAM is Joined, by whom it was added', () {
      final (_, [r]) = fold([added()]);
      final joined = r as Joined;
      expect(joined.conversation, Conversation.parse('teams:a:1personal'));
      expect(joined.key, EventKey.parse('conversationUpdate:f:24c8730b'));
      expect(joined.from, ada);
      expect(joined.joiners, [bot]);
    });

    test("of a team is the team's first channel itself, inside nothing", () {
      // As CAM's addition to a team arrived on 15 Nov: in the team's first
      // channel, whose id is the team's, with no channel of its own named.
      const team = '19:abc@thread.tacv2';
      final (_, [r]) = fold([
        {
          ...added(),
          'conversation': {
            'id': team,
            'conversationType': 'channel',
            'tenantId': tenant,
          },
          'channelData': {
            'tenant': {'id': tenant},
            'eventType': 'teamMemberAdded',
            'team': {'id': team},
          },
        },
      ]);
      final joined = r as Joined;
      expect(joined.conversation, Conversation.parse('teams:$team'));
      expect(joined.within, isNull);
    });

    test('naming its own conversation as its channel sits inside nothing', () {
      // The installationUpdate beside a team join named it so on 15 Nov.
      const team = '19:abc@thread.tacv2';
      final (_, [r]) = fold([
        {
          ...added(),
          'conversation': {
            'id': team,
            'conversationType': 'channel',
            'tenantId': tenant,
          },
          'channelData': {
            'tenant': {'id': tenant},
            'channel': {'id': team},
            'team': {'id': team},
          },
        },
      ]);
      expect((r as Joined).within, isNull);
    });

    test('names a person heard from, and leaves out one never heard from', () {
      final (_, [_, r]) = fold([
        fromBea('act-1'),
        added(alsoAdded: ['29:1bea', '29:1cyd']),
      ]);
      expect((r as Joined).joiners, [bot, bea]);
    });

    test('of no one it can name is nothing to admit', () {
      final (_, [r]) = fold([
        {...added(), 'membersAdded': <Object?>[]},
      ]);
      expect(r, isA<NothingToAdmit>());
    });

    test("is read once: the installationUpdate sent beside it isn't", () {
      final (_, [a, b]) = fold([
        added(),
        {...message(id: 'f:e8a5f8fa'), 'type': 'installationUpdate'}
          ..['action'] = 'add'
          ..remove('text'),
      ]);
      expect(a, isA<Joined>());
      expect(b, isA<NothingToAdmit>());
    });
  });

  group('a press on a card', () {
    test('of Approve is Responded to that card: Approved', () {
      final (_, [r]) = fold([pressed('approve')]);
      final responded = r as Responded;
      expect(responded.conversation, Conversation.parse('teams:a:1personal'));
      expect(responded.key, EventKey.parse('invoke:f:9001'));
      expect(responded.from, ada);
      expect(responded.to.value, 'a:1personal|1730881000000');
      expect(responded.response, isA<Approved>());
    });

    test('of Not yet is Responded to that card: HeldOff', () {
      final (_, [r]) = fold([pressed('notyet')]);
      expect((r as Responded).response, isA<HeldOff>());
    });

    test('naming no card is nothing to admit', () {
      final (_, [r]) = fold([pressed('approve')..remove('replyToId')]);
      expect(r, isA<NothingToAdmit>());
    });

    test('by someone Teams names no Entra id for is nothing to admit', () {
      final (_, [r]) = fold([
        {
          ...pressed('approve'),
          'from': {'id': '29:1ada', 'name': 'Ada'},
        },
      ]);
      expect(r, isA<NothingToAdmit>());
    });

    test("never reads the card's own data as what it shows", () {
      // The data comes back from the Teams client, which can send anything.
      final forged = pressed('approve');
      ((forged['value']! as Map)['action']! as Map)['data'] = {
        'node': 'someone-elses',
      };
      final (_, [a]) = fold([pressed('approve')]);
      final (_, [b]) = fold([forged]);
      expect((b as Responded).to, (a as Responded).to);
    });
  });

  group('nothing to admit, for now', () {
    test('an edit or a delete, until a shape says what a message became', () {
      final (_, readings) = fold([
        {...message(text: 'now'), 'type': 'messageUpdate'},
        {...message(), 'type': 'messageDelete'}..remove('text'),
      ]);
      expect(readings, everyElement(isA<NothingToAdmit>()));
    });

    test('a press of Edit, which only reopens the choice on a card', () {
      final (_, [r]) = fold([pressed('edit')]);
      expect(r, isA<NothingToAdmit>());
    });

    test('bytes that are not an activity, with the state left as it was', () {
      const reading = TeamsReading();
      final body = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'at': '2026-11-15T09:45:11Z',
            'source': 'teams',
            'bytes': base64Encode(utf8.encode('not json')),
          }),
        ),
      );
      final (state, r) = reading.step(
        reading.start,
        Event.read(EntryHash.of(body), body)!,
      );
      expect(r, isA<NothingToAdmit>());
      expect(state, same(reading.start));
    });
  });

  group('the state', () {
    test('given to a step is never changed by it', () {
      const reading = TeamsReading();
      final before = reading.start;
      reading.step(before, recorded(fromBea('act-1')));
      expect(before.entraIdOf(TeamsUserId.parse('29:1bea')!), isNull);
    });

    test('is the same one back when the event teaches nothing new', () {
      final (state, _) = fold([fromBea('act-1')]);
      final (again, _) = const TeamsReading().step(
        state,
        recorded(fromBea('act-2')),
      );
      expect(again, same(state));
    });

    test('folded again from the start reads every event the same', () {
      final activities = [
        added(),
        fromBea('act-1'),
        quotingBea(message(id: 'act-2', text: '<at>Bot</at>'), 'act-1'),
        pressed('notyet'),
      ];
      String described(Reading r) => switch (r) {
        Said() => 'said ${r.key} ${r.from} ${r.node.quotes?.author}',
        Joined() => 'joined ${r.key} ${r.joiners}',
        Changed() => 'changed ${r.key}',
        Responded() => 'responded ${r.key} ${r.to} ${r.response}',
        NothingToAdmit() => 'nothing',
      };
      expect(
        fold(activities).$2.map(described),
        fold(activities).$2.map(described),
      );
    });
  });
}
