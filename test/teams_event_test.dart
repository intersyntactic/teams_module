import 'package:checked_json/checked_json.dart';
import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final _url = Uri.parse('https://smba.trafficmanager.net/amer/');

/// [s] as the gate would read it.
TeamsUserId? _user(String s) => TeamsUserId.parse(s);
EntraObjectId? _entra(String s) => EntraObjectId.parse(s);

void main() {
  test('a press says its verb', () {
    final pressed = TeamsCardAction(
      conversation: 'a:1',
      id: 'act-4',
      serviceUrl: _url,
      card: 'card-1',
      value: JsonObject.of({
        'action': {'verb': 'approve'},
      }),
    );
    expect(pressed.verb, 'approve');
  });

  test('the actor is the tenant and Entra user, in lower case', () {
    final said = TeamsMessage(
      conversation: 'a:1',
      id: 'act-1',
      serviceUrl: _url,
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
      tenant: tenant,
      from: from == null ? null : _user(from),
    );
    expect(sentBy(from: '28:app-id').actor, isNull);
    expect(sentBy(tenant: 't').actor, isNull);
    expect(sentBy(tenant: 't', from: '29:1ada').actor, isNull);
    expect(sentBy(tenant: 't', from: '28:').actor, isNull);
  });

  group('a quote', () {
    TeamsMessage replying(List<Map<String, Object?>> entities) => TeamsMessage(
      conversation: '19:chat@thread.v2',
      id: '1794712228139',
      serviceUrl: _url,
      entities: [for (final e in entities) JsonObject.of(e)],
    );

    // As a group-chat Reply with @CAM carried it, witnessed 2026-11-15.
    const mention = {
      'type': 'mention',
      'mentioned': {'id': '28:app-id', 'name': 'CAM'},
      'text': '<at>CAM</at>',
    };
    const quoted = {
      'type': 'quotedReply',
      'quotedReply': {
        'messageId': '1794611050347',
        'senderId': '29:1bea',
        'senderName': 'Bea',
        'preview': 'Good morning!',
        'time': '2026-11-13T23:04:10.3470000Z',
        'validatedMessageReference': true,
      },
    };

    test('is read from the quotedReply entity, past a mention', () {
      final q = replying([mention, quoted]).quote!;
      expect(q.messageId, '1794611050347');
      expect(q.senderId, _user('29:1bea'));
      expect(q.senderName, 'Bea');
      expect(q.preview, 'Good morning!');
    });

    test('is absent from a message that quotes nothing', () {
      expect(replying([mention]).quote, isNull);
      expect(
        TeamsMessage(conversation: 'a:1', id: 'a', serviceUrl: _url).quote,
        isNull,
      );
    });

    test('needs both the message and its author', () {
      Map<String, Object?> without(String key) => {
        'type': 'quotedReply',
        'quotedReply': {...(quoted['quotedReply']! as Map<String, Object?>)}
          ..remove(key),
      };
      expect(replying([without('messageId')]).quote, isNull);
      expect(replying([without('senderId')]).quote, isNull);
      final named = replying([without('senderName')]).quote!;
      expect(named.senderName, isNull);
    });
  });

  group('a message ref', () {
    test('is a journey path source and back, unchanged', () {
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
