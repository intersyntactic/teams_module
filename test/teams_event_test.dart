import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final _url = Uri.parse('https://smba.trafficmanager.net/amer/');
final _bot = BotAppId.parse('00000000-0000-0000-0000-00000000b07a')!;
final _trajectory = TrajectoryId.parse('ab' * 32)!;

/// [s] as the gate would read it.
TeamsUserId? _user(String s) => TeamsUserId.parse(s);
EntraObjectId? _entra(String s) => EntraObjectId.parse(s);

/// One of every case, each with every field it has.
List<TeamsEvent> _everyCase() {
  final common = (
    conversation: '19:chan@thread.tacv2;messageid=1794700000000',
    id: '1794712228139',
    tenant: 'tenant-1',
    conversationType: 'channel',
    timestamp: '2026-11-15T09:45:11.000Z',
    from: _user('29:1ada'),
    fromAadObjectId: _entra('ada00000-0000-4000-8000-000000000001'),
    channel: '19:chan@thread.tacv2',
    team: '19:team@thread.tacv2',
  );
  return [
    TeamsMessage(
      conversation: common.conversation,
      id: common.id,
      serviceUrl: _url,
      bot: _bot,
      tenant: common.tenant,
      conversationType: common.conversationType,
      timestamp: common.timestamp,
      from: common.from,
      fromAadObjectId: common.fromAadObjectId,
      channel: common.channel,
      team: common.team,
      text: '<at>CAM</at> look',
      mentions: [TeamsMention(id: _user('28:app-id')!, name: 'CAM')],
      quote: TeamsQuote(
        messageId: '1794611050347',
        senderId: _user('29:1bea')!,
        senderName: 'Bea',
        preview: 'Good morning!',
      ),
      replyTo: '1794700000000',
      attachments: [
        TeamsAttachmentReference(
          contentType: 'application/vnd.microsoft.teams.file.download.info',
          name: 'plan.docx',
          contentUrl: Uri.parse('https://x.sharepoint.com/sites/s/plan.docx'),
        ),
      ],
    ),
    TeamsMessageUpdate(
      conversation: common.conversation,
      id: common.id,
      serviceUrl: _url,
      bot: _bot,
      tenant: common.tenant,
      text: 'now',
      mentions: [TeamsMention(id: _user('29:1bea')!)],
      channelEventType: 'editMessage',
    ),
    TeamsMessageDelete(
      conversation: common.conversation,
      id: common.id,
      serviceUrl: _url,
      bot: _bot,
      channelEventType: 'softDeleteMessage',
    ),
    TeamsCardAction(
      conversation: common.conversation,
      id: 'f:9001',
      serviceUrl: _url,
      bot: _bot,
      from: common.from,
      card: '1794700000000',
      verb: CardActionVerb.close,
      trajectory: _trajectory,
    ),
    TeamsMessageActionOpen(
      conversation: common.conversation,
      id: 'f:9002',
      serviceUrl: _url,
      bot: _bot,
      command: TeamsMessageAction.callSettings,
      message: '1794700000000',
    ),
    TeamsMessageActionSubmit(
      conversation: common.conversation,
      id: 'f:9003',
      serviceUrl: _url,
      bot: _bot,
      command: TeamsMessageAction.callSettings,
      message: '1794700000000',
    ),
    TeamsConversationUpdate(
      conversation: common.conversation,
      id: common.id,
      serviceUrl: _url,
      bot: _bot,
      added: [_user('28:app-id')!, _user('29:1bea')!],
      removed: [_user('29:1ada')!],
    ),
    TeamsInstallationUpdate(
      conversation: common.conversation,
      id: common.id,
      serviceUrl: _url,
      bot: _bot,
      action: InstallationAction.add,
    ),
  ];
}

/// [event]'s projection as the relay writes it.
String _written(TeamsEvent event) =>
    jsonEncode(event.projection().asUncheckedMap());

/// A message's projection with [change] made to it.
JsonObject _messageWith(void Function(Map<String, Object?> p) change) {
  final p = Map<String, Object?>.of(
    jsonDecode(_written(_everyCase().first)) as Map<String, Object?>,
  );
  change(p);
  return JsonObject.of(p);
}

void main() {
  group('a projection', () {
    test('reads back as the event it was made from, for every case', () {
      for (final event in _everyCase()) {
        final read = TeamsEvent.fromProjection(
          JsonObject.decode(_written(event)),
        );
        expect(read.runtimeType, event.runtimeType);
        expect(_written(read), _written(event), reason: '${event.runtimeType}');
      }
    });

    test('is the same bytes every time for the same event', () {
      for (final event in _everyCase()) {
        expect(_written(event), _written(event));
      }
    });

    test('starts with its version and case', () {
      final p = _everyCase().first.projection();
      expect(p.keys.take(2), ['projection', 'kind']);
      expect(p.raw('projection'), teamsProjectionVersion);
      expect(p.string('kind'), 'message');
    });

    test('leaves out a field that is null or empty', () {
      final p = TeamsMessage(
        conversation: 'a:1',
        id: '1',
        serviceUrl: _url,
        bot: _bot,
      ).projection();
      expect(p.keys, [
        'projection',
        'kind',
        'conversation',
        'id',
        'serviceUrl',
        'bot',
      ]);
    });

    test('keeps a card press to its verb and trajectory', () {
      final p = _everyCase().whereType<TeamsCardAction>().single.projection();
      expect(p.string('verb'), 'close');
      expect(p.string('trajectory'), 'ab' * 32);
      expect(p.has('value'), isFalse);
    });

    group('is refused when it', () {
      void refused(JsonObject p) =>
          expect(() => TeamsEvent.fromProjection(p), throwsFormatException);

      test('is of another version, or none', () {
        refused(_messageWith((p) => p['projection'] = 2));
        refused(_messageWith((p) => p['projection'] = '1'));
        refused(_messageWith((p) => p.remove('projection')));
      });

      test('names a case there is none of', () {
        refused(_messageWith((p) => p['kind'] = 'invoke'));
        refused(_messageWith((p) => p.remove('kind')));
      });

      test('has a field its case has not', () {
        refused(_messageWith((p) => p['value'] = {'token': 'x'}));
        // A card press's field, on a message.
        refused(_messageWith((p) => p['verb'] = 'approve'));
      });

      test('has a field no nested part has', () {
        refused(
          _messageWith(
            (p) => p['quote'] = {
              ...(p['quote']! as Map<String, Object?>),
              'time': 'x',
            },
          ),
        );
        refused(
          _messageWith(
            (p) => p['attachments'] = [
              {'contentType': 'text/html', 'content': '<p>hi</p>'},
            ],
          ),
        );
        refused(
          _messageWith(
            (p) => p['mentions'] = [
              {'id': '29:1bea', 'text': '<at>Bea</at>'},
            ],
          ),
        );
      });

      test('has a field of the wrong type or form', () {
        refused(_messageWith((p) => p['id'] = 42));
        refused(_messageWith((p) => p['bot'] = 'not a guid'));
        refused(_messageWith((p) => p['from'] = '30:1ada'));
        refused(_messageWith((p) => p['fromAadObjectId'] = 'oid-ada'));
        refused(
          _messageWith(
            (p) => p['mentions'] = [
              {'id': 'nobody'},
            ],
          ),
        );
      });

      test('is a raw activity', () {
        refused(
          JsonObject.of({
            'type': 'message',
            'id': '1',
            'serviceUrl': '$_url',
            'conversation': {'id': 'a:1'},
          }),
        );
      });
    });
  });

  test('the actor is the tenant and Entra user, in lower case', () {
    final said = TeamsMessage(
      conversation: 'a:1',
      id: 'act-1',
      serviceUrl: _url,
      bot: _bot,
      tenant: 'TENANT-1',
      fromAadObjectId: _entra('ADA00000-0000-4000-8000-000000000001'),
    );
    expect(
      '${said.actor}',
      'teams:tenant-1/ada00000-0000-4000-8000-000000000001',
    );
  });

  test('a bot is an actor too, by its app id, in lower case', () {
    final said = TeamsMessage(
      conversation: 'a:1',
      id: 'act-1',
      serviceUrl: _url,
      bot: _bot,
      tenant: 'TENANT-1',
      from: _user('28:App-Id'),
    );
    expect('${said.actor}', 'teams:tenant-1/bot:app-id');
  });

  test('an Entra user is a person, whatever the channel id', () {
    final said = TeamsMessage(
      conversation: 'a:1',
      id: 'act-1',
      serviceUrl: _url,
      bot: _bot,
      tenant: 'tenant-1',
      from: _user('28:app-id'),
      fromAadObjectId: _entra('ada00000-0000-4000-8000-000000000001'),
    );
    expect(
      '${said.actor}',
      'teams:tenant-1/ada00000-0000-4000-8000-000000000001',
    );
  });

  test('no actor without a tenant, or with a sender that is neither', () {
    TeamsMessage sentBy({String? tenant, String? from}) => TeamsMessage(
      conversation: 'a:1',
      id: 'a',
      serviceUrl: _url,
      bot: _bot,
      tenant: tenant,
      from: from == null ? null : _user(from),
    );
    expect(sentBy(from: '28:app-id').actor, isNull);
    expect(sentBy(tenant: 't').actor, isNull);
    expect(sentBy(tenant: 't', from: '29:1ada').actor, isNull);
    expect(sentBy(tenant: 't', from: '28:').actor, isNull);
  });
  group('a message ref', () {
    test('is a trajectory source and back, unchanged', () {
      final ref = TeamsMessageRef.of('19:chat@thread.v2', '1794727863400')!;
      expect(ref.source.value, '19:chat@thread.v2|1794727863400');
      expect(TeamsMessageRef.fromSource(ref.source), ref);
    });

    test('splits a source at its last bar, so only the message id must be '
        'free of one', () {
      final ref = TeamsMessageRef.fromSource(
        SourceMessageId.parse('a:odd|chat|1794727863400')!,
      )!;
      expect(ref.conversation, 'a:odd|chat');
      expect(ref.message, '1794727863400');
    });

    test(
      'is not made of an empty part, whitespace, or a message with a bar',
      () {
        for (final (c, m) in [
          ('', '1'),
          ('a:1', ''),
          ('a 1', '1'),
          ('a:1', '1 2'),
          ('a:1', '1|2'),
        ]) {
          expect(TeamsMessageRef.of(c, m), isNull, reason: '"$c" "$m"');
        }
        expect(
          TeamsMessageRef.fromSource(SourceMessageId.parse('no-bar')!),
          isNull,
        );
        expect(
          TeamsMessageRef.fromSource(SourceMessageId.parse('a:1|')!),
          isNull,
        );
      },
    );

    test('names an event by its conversation and id', () {
      final said = TeamsMessage(
        conversation: 'a:1',
        id: '42',
        serviceUrl: _url,
        bot: _bot,
      );
      expect(said.ref, TeamsMessageRef.of('a:1', '42'));
    });
  });

  group('ids', () {
    test('a Teams user id is a 28: or 29: channel account', () {
      expect(TeamsUserId.parse('29:1bea')?.isBot, isFalse);
      expect(TeamsUserId.parse('28:app-id')?.isBot, isTrue);
      for (final bad in ['', '29:', '30:1bea', 'a:1personal', '29:1 bea']) {
        expect(TeamsUserId.parse(bad), isNull, reason: bad);
      }
    });

    test('an Entra object id is a GUID, held in lower case', () {
      expect(
        EntraObjectId.parse('DE2CB25C-8A68-4ED2-B777-F322F2A08E67')?.value,
        'de2cb25c-8a68-4ed2-b777-f322f2a08e67',
      );
      for (final bad in ['', 'oid-ada', '29:1bea', 'de2cb25c-8a68-4ed2-b777']) {
        expect(EntraObjectId.parse(bad), isNull, reason: bad);
      }
    });
  });
}
