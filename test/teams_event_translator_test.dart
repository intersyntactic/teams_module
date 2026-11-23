import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict;
import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_content_id/is_content_id.dart' show ObjectId;
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// [activity] as the docking station hands it over: written as the relay
/// writes it, and read back from its `teams-event` entry.
RelayedEvent recorded(Map<String, Object?> activity) =>
    recordedBytes(utf8.encode(jsonEncode(activity)));

/// [bytes] as the relay records them, read back from its entry.
RelayedEvent recordedBytes(List<int> bytes) {
  final (kind, body) = encodeRelayedEvent(
    teamsEventSource,
    at: DateTime.utc(2026, 11, 15, 9, 45, 11),
    bytes: Uint8List.fromList(bytes),
  );
  return RelayedEvent.read(_recordedId(body), kind, body)!;
}

/// The id the logbook gives a `teams-event` entry holding [body]: the hash
/// of its whole text, header included.
ObjectId _recordedId(Uint8List body) => ObjectId.of(
  Uint8List.fromList([...utf8.encode('teams-event\n-\n'), ...body]),
);

/// Every one of [activities], folded from the start, as the docking station
/// folds them: the translated events in order, and the state after the last.
(TeamsEventTranslatorState, List<TranslatedEvent>) fold(
  Iterable<Map<String, Object?>> activities,
) {
  const translator = TeamsEventTranslator();
  var state = translator.start;
  final translated = <TranslatedEvent>[];
  for (final a in activities) {
    final (next, r) = translator.step(state, recorded(a));
    state = next;
    translated.add(r);
  }
  return (state, translated);
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

/// The message action [command], opened on message `1730881000000` and
/// submitted with [data], as the docs give a submitAction (not yet
/// measured).
Map<String, Object?> messageActionSubmitted(
  String command,
  Map<String, Object?> data,
) => {
  ...cardAction(),
  'name': 'composeExtension/submitAction',
  'value': {
    'commandId': command,
    'commandContext': 'message',
    'messagePayload': {'id': '1730881000000', 'body': <String, Object?>{}},
    'data': data,
  },
}..remove('replyToId');

/// Ada pressing the button whose verb is [verb] on card `1730881000000`.
Map<String, Object?> pressed(String verb) {
  final press = cardAction();
  ((press['value']! as Map)['action']! as Map)['verb'] = verb;
  return press;
}

/// The trajectory the replies in these tests were posted in.
final trajectoryHex = 'c1' * 32;

/// Ada pressing "Close trajectory" on reply `1730881000000`, its data naming
/// [trajectory] as the Teams drawing of a reply writes it, or naming none.
Map<String, Object?> closePressed({String? trajectory}) {
  final press = pressed('close');
  ((press['value']! as Map)['action']! as Map)['data'] = {
    'trajectory': ?trajectory,
  };
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
    test(
      'is MessageSaid, with its UserSaid, in its conversation, under its id',
      () {
        final (_, [r]) = fold([message()]);
        final said = r as MessageSaid;
        expect(
          said.addressInExternalSystem,
          AddressInExternalSystem.parse('teams:a:1personal'),
        );
        expect(said.key, EventKey.parse('message:1730881234567'));
        expect(said.from, ada);
        expect(said.message.value, 'a:1personal|1730881234567');
        expect(said.node.text, 'Looks right to me');
      },
    );

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
      final said = r as MessageSaid;
      expect(said.addressInExternalSystem.value, 'teams:$thread');
      expect(
        said.containingAddress,
        AddressInExternalSystem.parse('teams:$channel'),
      );
      expect(said.node.text, 'test');
    });

    test('in a chat sits inside nothing', () {
      final (_, [r]) = fold([message()]);
      expect((r as MessageSaid).containingAddress, isNull);
    });

    test('delivered twice has one key', () {
      final (_, [a, b]) = fold([message(), message()]);
      expect((a as MessageSaid).key, (b as MessageSaid).key);
    });

    test('quoting someone heard from names them, from the fold alone', () {
      final (_, [_, r]) = fold([
        fromBea('act-1'),
        quotingBea(message(id: 'act-2', text: '<at>Bot</at>'), 'act-1'),
      ]);
      // Only an @-mention on a quote says "look at this", with no words.
      expect((r as MessageSaid).node.text, isEmpty);
      final quotes = r.node.quotes!;
      expect((quotes.author as KnownAuthor).actor, bea);
      expect(quotes.source.value, 'a:1personal|act-1');
    });

    test('quoting with words carries them and the quote', () {
      final (_, [r]) = fold([
        quotingBea(message(id: 'act-2', text: 'not quite'), 'act-1'),
      ]);
      expect((r as MessageSaid).node.text, 'not quite');
      expect(r.node.quotes!.source.value, 'a:1personal|act-1');
    });

    test('quoting a bot names the bot, which needs nothing learnt first', () {
      final (_, [r]) = fold([
        {
          ...quotingBea(message(id: 'act-2', text: 'this one'), 'act-0'),
          'entities': [
            {
              'type': 'quotedReply',
              'quotedReply': {'messageId': 'act-0', 'senderId': '28:$appId'},
            },
          ],
        },
      ]);
      expect(
        ((r as MessageSaid).node.quotes!.author as KnownAuthor).actor,
        bot,
      );
    });

    test('by another bot is MessageSaid too: a bot is a user', () {
      final (_, [r]) = fold([
        {
          ...message(id: 'act-2', text: 'Build 41 failed'),
          'from': {'id': '28:other-bot', 'name': 'CI'},
        },
      ]);
      expect((r as MessageSaid).from.value, 'teams:$tenant/bot:other-bot');
      expect(r.node.text, 'Build 41 failed');
    });

    test('quoting themselves, the first time heard from, names them', () {
      // Bea's earlier message never reached the bot: no @-mention.
      final (_, [r]) = fold([quotingBea(fromBea('act-2'), 'act-1')]);
      expect(
        ((r as MessageSaid).node.quotes!.author as KnownAuthor).actor,
        bea,
      );
    });

    test('quoting someone not yet heard from names them as Teams showed', () {
      final (_, [r]) = fold([
        quotingBea(message(id: 'act-2', text: '<at>Bot</at>'), 'act-1'),
      ]);
      final author = (r as MessageSaid).node.quotes!.author as UnknownAuthor;
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
    test('of CAM is ActorsJoinedAddress, by whom it was added', () {
      final (_, [r]) = fold([added()]);
      final joined = r as ActorsJoinedAddress;
      expect(
        joined.addressInExternalSystem,
        AddressInExternalSystem.parse('teams:a:1personal'),
      );
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
      final joined = r as ActorsJoinedAddress;
      expect(
        joined.addressInExternalSystem,
        AddressInExternalSystem.parse('teams:$team'),
      );
      expect(joined.containingAddress, isNull);
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
      expect((r as ActorsJoinedAddress).containingAddress, isNull);
    });

    test('names a person heard from, and leaves out one never heard from', () {
      final (_, [_, r]) = fold([
        fromBea('act-1'),
        added(alsoAdded: ['29:1bea', '29:1cyd']),
      ]);
      expect((r as ActorsJoinedAddress).joiners, [bot, bea]);
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
      expect(a, isA<ActorsJoinedAddress>());
      expect(b, isA<NothingToAdmit>());
    });
  });

  group('a press on a card', () {
    test('of Approve is ShownMessageJudged for that card: ApprovedVerdict', () {
      final (_, [r]) = fold([pressed('approve')]);
      final responded = r as ShownMessageJudged;
      expect(
        responded.addressInExternalSystem,
        AddressInExternalSystem.parse('teams:a:1personal'),
      );
      expect(responded.key, EventKey.parse('invoke:f:9001'));
      expect(responded.from, ada);
      expect(responded.to.value, 'a:1personal|1730881000000');
      expect(responded.verdict, isA<ApprovedVerdict>());
    });

    test('of Not yet is ShownMessageJudged for that card: HeldOffVerdict', () {
      final (_, [r]) = fold([pressed('notyet')]);
      expect((r as ShownMessageJudged).verdict, isA<HeldOffVerdict>());
    });

    test('of Close is PersonAskedToCloseTrajectory, naming that reply and '
        'the trajectory its data names', () {
      final (_, [r]) = fold([closePressed(trajectory: trajectoryHex)]);
      final asked = r as PersonAskedToCloseTrajectory;
      expect(
        asked.addressInExternalSystem,
        AddressInExternalSystem.parse('teams:a:1personal'),
      );
      expect(asked.key, EventKey.parse('invoke:f:9001'));
      expect(asked.from, ada);
      expect(asked.addressedTo, bot);
      expect(asked.message.value, 'a:1personal|1730881000000');
      expect(asked.trajectory, TrajectoryId.parse(trajectoryHex));
    });

    test('of the Close on a reply drawTeamsReply drew names the '
        'trajectory '
        'it was built with', () {
      final trajectory = TrajectoryId.parse(trajectoryHex)!;
      final reply = drawTeamsReply('hi', trajectory: trajectory).last;
      final card = JsonObject.decode(jsonEncode(reply))
          .objects('attachments')
          .single
          .object('content');
      final close = card.objects('actions').single;
      final press = pressed(close.string('verb'));
      ((press['value']! as Map)['action']! as Map)['data'] = close
          .object('data')
          .asUncheckedMap();
      final (_, [r]) = fold([press]);
      expect((r as PersonAskedToCloseTrajectory).trajectory, trajectory);
    });

    test('of Close passes on any trajectory its data names: the docking '
        'station closes it only while it is open at this address', () {
      final elsewhere = 'd2' * 32;
      final (_, [r]) = fold([closePressed(trajectory: elsewhere)]);
      expect(
        (r as PersonAskedToCloseTrajectory).trajectory,
        TrajectoryId.parse(elsewhere),
      );
    });

    test('of Close naming no trajectory, or not one in lower-case hex, is '
        'nothing to admit', () {
      for (final press in [
        closePressed(),
        pressed('close'),
        closePressed(trajectory: trajectoryHex.toUpperCase()),
        closePressed(trajectory: 'c1' * 31),
      ]) {
        final (_, [r]) = fold([press]);
        expect(r, isA<NothingToAdmit>(), reason: '$press');
      }
    });

    test('a message action submitted, whatever its command or data, is '
        'nothing to admit: no message action closes a trajectory', () {
      for (final submitted in [
        messageActionSubmitted(callSettingsCommandId, {'model': 'x'}),
        // The retired "Close trajectory" action, from an old package.
        messageActionSubmitted('closeTrajectory', {'confirm': true}),
        messageActionSubmitted('closeTrajectory', {
          'confirm': true,
          'trajectory': trajectoryHex,
        }),
      ]) {
        final (_, [r]) = fold([submitted]);
        expect(r, isA<NothingToAdmit>(), reason: '$submitted');
      }
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
      expect((b as ShownMessageJudged).to, (a as ShownMessageJudged).to);
    });
  });

  group('nothing to admit, for now', () {
    test('an edit or a delete, until a shape says what a message became', () {
      final (_, translated) = fold([
        {...message(text: 'now'), 'type': 'messageUpdate'},
        {...message(), 'type': 'messageDelete'}..remove('text'),
      ]);
      expect(translated, everyElement(isA<NothingToAdmit>()));
    });

    test('a press of Edit, which only reopens the choice on a card', () {
      final (_, [r]) = fold([pressed('edit')]);
      expect(r, isA<NothingToAdmit>());
    });

    test('bytes that are not an activity, with the state left as it was', () {
      const translator = TeamsEventTranslator();
      final (state, r) = translator.step(
        translator.start,
        recordedBytes(utf8.encode('not json')),
      );
      expect(r, isA<NothingToAdmit>());
      expect(state, same(translator.start));
    });
  });

  group('the state', () {
    test('given to a step is never changed by it', () {
      const translator = TeamsEventTranslator();
      final before = translator.start;
      translator.step(before, recorded(fromBea('act-1')));
      expect(before.entraIdOf(TeamsUserId.parse('29:1bea')!), isNull);
    });

    test('is the same one back when the event teaches nothing new', () {
      final (state, _) = fold([fromBea('act-1')]);
      final (again, _) = const TeamsEventTranslator().step(
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
        closePressed(trajectory: trajectoryHex),
      ];
      String described(TranslatedEvent r) => switch (r) {
        MessageSaid() => 'said ${r.key} ${r.from} ${r.node.quotes?.author}',
        ActorsJoinedAddress() => 'joined ${r.key} ${r.joiners}',
        MessageChanged() => 'changed ${r.key}',
        ShownMessageJudged() => 'responded ${r.key} ${r.to} ${r.verdict}',
        PersonAskedToCloseTrajectory() =>
          'asked to close ${r.key} ${r.from} ${r.message}',
        NothingToAdmit() => 'nothing',
      };
      expect(
        fold(activities).$2.map(described),
        fold(activities).$2.map(described),
      );
    });
  });

  group('replyEndpoint', () {
    test('is the conversation at its service URL, for every event', () {
      final (_, translated) = fold([
        added(),
        fromBea('act-1'),
        pressed('approve'),
        closePressed(trajectory: trajectoryHex),
      ]);
      final chat = teamsReplyEndpoint(Uri.parse(serviceUrl), 'a:1personal');
      expect(chat, isNotNull);
      expect(
        translated.map((r) => (r as AddressedEvent).replyEndpoint),
        everyElement(chat),
      );
    });

    test('in a channel thread is the thread, so a reply lands in it', () {
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
      expect(
        (r as MessageSaid).replyEndpoint,
        teamsReplyEndpoint(Uri.parse(serviceUrl), thread),
      );
    });

    test('follows the service URL Teams sent, region and all', () {
      const au = 'https://smba.trafficmanager.net/au/';
      final (_, [r]) = fold([
        {...fromBea('act-1'), 'serviceUrl': au},
      ]);
      expect(
        (r as MessageSaid).replyEndpoint,
        teamsReplyEndpoint(Uri.parse(au), 'a:1personal'),
      );
    });
  });

  group('addressedTo', () {
    const otherAppId = '00000000-0000-0000-0000-0000000b07b2';
    final otherBot = ActorId.parse('teams:$tenant/bot:$otherAppId')!;

    test('is the bot each translated event was sent to', () {
      final (_, translated) = fold([
        added(),
        fromBea('act-1'),
        pressed('approve'),
        closePressed(trajectory: trajectoryHex),
      ]);
      expect(translated.map((r) => (r as AddressedEvent).addressedTo), [
        bot,
        bot,
        bot,
        bot,
      ]);
    });

    test('follows the recipient, so each pooled bot is named', () {
      final (_, [r]) = fold([
        {
          ...fromBea('act-1'),
          'recipient': {'id': '28:$otherAppId', 'name': 'Other'},
        },
      ]);
      expect((r as MessageSaid).addressedTo, otherBot);
    });

    test('is written and read back as the docking station and its readers '
        'do', () {
      final (_, translated) = fold([
        added(),
        fromBea('act-1'),
        pressed('approve'),
        closePressed(trajectory: trajectoryHex),
      ]);
      for (final r in translated.cast<AddressedEvent>()) {
        final written = encodeTranslatedEvent(r);
        expect(written.string('addressedTo'), bot.value);
        final stored = jsonEncode(written.asUncheckedMap());
        final read = decodeTranslatedEvent(JsonObject.decode(stored));
        expect(read.addressedTo, bot);
        expect(
          jsonEncode(encodeTranslatedEvent(read).asUncheckedMap()),
          stored,
        );
      }
    });
  });
}
