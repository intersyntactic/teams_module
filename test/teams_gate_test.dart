import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(setUpKeys);
  _recordedTests();

  group('takes', () {
    test('a message in a one-to-one chat, with its text', () {
      final d = _gate(message());
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.status, 200);
      expect(d.invokeResponse, isNull);
      final said = d.event! as TeamsMessage;
      expect(said.tenant, tenant);
      expect(said.conversation, 'a:1personal');
      expect(said.conversationType, 'personal');
      expect(said.id, '1730881234567');
      expect(said.serviceUrl, Uri.parse(serviceUrl));
      expect(said.timestamp, '2026-11-06T10:00:00.000Z');
      expect(said.from, TeamsUserId.parse('29:1ada'));
      expect(
        said.fromAadObjectId,
        EntraObjectId.parse('ada00000-0000-4000-8000-000000000001'),
      );
      expect(said.bot, appBot);
      expect(said.text, 'Looks right to me');
      expect(said.entities, isNull);
      expect(said.replyTo, isNull);
    });

    test('a message in a channel, with what it replies under', () {
      final d = _gate({...message(), 'replyToId': '1730881000000'});
      expect((d.event! as TeamsMessage).replyTo, '1730881000000');
    });

    test('an edit, with what Teams calls the change', () {
      final d = _gate({
        ...message(text: 'Looks right to me now'),
        'type': 'messageUpdate',
        'channelData': {
          'tenant': {'id': tenant},
          'eventType': 'editMessage',
        },
      });
      final edited = d.event! as TeamsMessageUpdate;
      expect(edited.text, 'Looks right to me now');
      expect(edited.channelEventType, 'editMessage');
    });

    test('a delete, with what Teams calls the change', () {
      final d = _gate(
        {
          ...message(),
          'type': 'messageDelete',
          'channelData': {
            'tenant': {'id': tenant},
            'eventType': 'softDeleteMessage',
          },
        }..remove('text'),
      );
      final deleted = d.event! as TeamsMessageDelete;
      expect(deleted.id, '1730881234567');
      expect(deleted.channelEventType, 'softDeleteMessage');
    });

    test('another invoke it was told to take, by its name', () {
      final d = _gate(
        {...cardAction(), 'name': 'task/fetch'},
        spec: TeamsSourceSpec(
          botAppIds: {appBot},
          tenantAllowlist: {tenant},
          wakeInvokes: {'task/fetch'},
        ),
      );
      final invoked = d.event! as TeamsInvoke;
      expect(invoked.name, 'task/fetch');
      expect(invoked.value!.object('action').string('verb'), 'approve');
    });

    test('a message action submitted, with the message it was opened on', () {
      // As the docs give a message action's submitAction; not yet measured.
      final d = _gate({
        ...cardAction(),
        'name': 'composeExtension/submitAction',
        'value': {
          'commandId': callSettingsCommandId,
          'commandContext': 'message',
          'messagePayload': {
            'id': '1730881000000',
            'body': <String, Object?>{},
          },
          'data': {'model': 'opus', 'effort': 'high'},
        },
      });
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.invokeResponse, isNull);
      final submitted = d.event! as TeamsMessageActionSubmit;
      expect(submitted.command, callSettingsCommandId);
      expect(
        submitted.messageRef,
        TeamsMessageRef.of('a:1personal', '1730881000000'),
      );
      expect(submitted.data!.asUncheckedMap(), {
        'model': 'opus',
        'effort': 'high',
      });
    });

    test('a card action, responded to with the acknowledgement', () {
      final d = _gate(cardAction());
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.invokeResponse!.asUncheckedMap(), {
        'statusCode': 200,
        'type': 'application/vnd.microsoft.activity.message',
        'value': 'Got it',
      });
      final pressed = d.event! as TeamsCardAction;
      expect(pressed.card, '1730881000000');
      expect(pressed.verb, CardActionVerb.approve);
    });

    test('an audience given as a list', () {
      final t = signedToken(
        claims: {
          ...tokenClaims(),
          'aud': ['someone', appId],
        },
      );
      expect(_gate(message(), token: t).outcome, TeamsGateOutcome.trigger);
    });

    test('a second bot from the same endpoint, named by its token', () {
      final d = _gate(
        {
          ...message(),
          'recipient': {'id': '28:${otherAppId.toUpperCase()}', 'name': 'B'},
        },
        token: signedToken(claims: {...tokenClaims(), 'aud': otherAppId}),
        spec: TeamsSourceSpec(
          botAppIds: {appBot, otherBot},
          tenantAllowlist: {tenant},
        ),
      );
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.event!.bot, otherBot);
    });

    test('the claim spelled serviceUrl, as the docs spell it', () {
      final claims = tokenClaims()
        ..remove('serviceurl')
        ..['serviceUrl'] = serviceUrl;
      final t = signedToken(claims: claims);
      expect(_gate(message(), token: t).outcome, TeamsGateOutcome.trigger);
    });

    test('a key named by x5t alone', () {
      final t = signedToken(
        header: {'typ': 'JWT', 'alg': 'RS256', 'x5t': 'k1'},
      );
      expect(_gate(message(), token: t).outcome, TeamsGateOutcome.trigger);
    });

    test('a token inside the clock skew at either end', () {
      final late_ = signedToken(
        claims: {...tokenClaims(), 'exp': nowSeconds - 240},
      );
      final early = signedToken(
        claims: {...tokenClaims(), 'nbf': nowSeconds + 240},
      );
      expect(_gate(message(), token: late_).outcome, TeamsGateOutcome.trigger);
      expect(_gate(message(), token: early).outcome, TeamsGateOutcome.trigger);
    });

    test('an install, which carries what messaging first needs', () {
      final d = _gate(
        {...message(), 'type': 'installationUpdate', 'action': 'add'}
          ..remove('text'),
      );
      expect(d.outcome, TeamsGateOutcome.trigger);
      final installed = d.event! as TeamsInstallationUpdate;
      expect(installed.action, 'add');
      expect(installed.serviceUrl, Uri.parse(serviceUrl));
    });

    test('a quoted reply, with the entities that say what it quotes', () {
      // The quotedReply entity as a Reply in a one-to-one chat carried it,
      // seen in a recorded body on 2026-11-14. The gate passes entities on
      // unread, which is what this proves.
      final entities = [
        {
          'type': 'mention',
          'mentioned': {'id': '28:$appId', 'name': 'Bot'},
          'text': '<at>Bot</at>',
        },
        {
          'type': 'quotedReply',
          'quotedReply': {
            'messageId': '1730881000000',
            'senderId': '29:1ada',
            'senderName': 'Ada',
            'preview': 'Looks right to me',
            'validatedMessageReference': true,
          },
        },
      ];
      final d = _gate({
        ...message(
          text: '<quoted messageId="1730881000000"/> <at>Bot</at> not quite',
        ),
        'entities': entities,
      });
      expect(d.outcome, TeamsGateOutcome.trigger);
      final said = d.event! as TeamsMessage;
      expect(
        jsonEncode([for (final e in said.entities!) e.asUncheckedMap()]),
        jsonEncode(entities),
      );
      expect(said.text, startsWith('<quoted messageId='));
    });

    test('a tenant in upper case, matched and passed on in lower', () {
      final upper = tenant.toUpperCase();
      final d = _gate({
        ...message(),
        'channelData': {
          'tenant': {'id': upper},
        },
      }, spec: TeamsSourceSpec(botAppIds: {appBot}, tenantAllowlist: {upper}));
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.event!.tenant, tenant);
    });

    test('a conversation update, with who joined', () {
      final d = _gate(
        {
          ...message(),
          'type': 'conversationUpdate',
          'membersAdded': [
            {'id': '28:$appId'},
          ],
        }..remove('text'),
      );
      final changed = d.event! as TeamsConversationUpdate;
      expect(changed.added, [TeamsUserId.parse('28:$appId')]);
      expect(changed.removed, isEmpty);
    });
  });

  group('ignores', () {
    test('a quiet activity type', () {
      final d = _gate({...message(), 'type': 'typing'}..remove('text'));
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.status, 200);
      expect(d.event, isNull);
    });

    test('a type it was told to wake on that no event is read as', () {
      final d = _gate(
        {...message(), 'type': 'typing'}..remove('text'),
        spec: TeamsSourceSpec(
          botAppIds: {appBot},
          tenantAllowlist: {tenant},
          wakeActivityTypes: {'typing'},
        ),
      );
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.reason, 'no event is read from typing');
      expect(d.event, isNull);
    });

    test('an invoke it was not built for, with no response to give', () {
      final d = _gate({...cardAction(), 'name': 'composeExtension/query'});
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.invokeResponse, isNull);
    });

    test('an invoke it answers with a dialog, waking no one', () {
      final card = JsonObject.of({'type': 'AdaptiveCard', 'version': '1.5'});
      final spec = TeamsSourceSpec(
        botAppIds: {appBot},
        tenantAllowlist: {tenant},
        invokeResponses: {
          'composeExtension/fetchTask': teamsDialog(
            title: 'Call settings',
            card: card,
          ),
        },
      );
      final fetch = {...cardAction(), 'name': 'composeExtension/fetchTask'};
      final d = _gate(fetch, spec: spec);
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.reason, 'answered invoke composeExtension/fetchTask');
      expect(d.event, isNull);
      expect(d.invokeResponse!.asUncheckedMap(), {
        'task': {
          'type': 'continue',
          'value': {
            'title': 'Call settings',
            'card': {
              'contentType': 'application/vnd.microsoft.card.adaptive',
              'content': {'type': 'AdaptiveCard', 'version': '1.5'},
            },
          },
        },
      });
      // Teams re-sends what it got no response to; the retry gets the same.
      expect(
        _gate(fetch, spec: spec).invokeResponse!.asUncheckedMap(),
        d.invokeResponse!.asUncheckedMap(),
      );
    });
  });

  group('takes each of', () {
    // An edit, a delete and its undo all carry the message's id.
    test('a message, its edit, its delete and the undo', () {
      for (final (type, eventType, at) in [
        ('message', null, '2026-11-16T02:19:00.000Z'),
        ('messageUpdate', 'editMessage', '2026-11-16T02:19:49.762Z'),
        ('messageDelete', 'softDeleteMessage', '2026-11-16T02:20:07.000Z'),
        ('messageUpdate', 'undeleteMessage', '2026-11-16T02:20:09.000Z'),
      ]) {
        final d = _gate({
          ...message(),
          'type': type,
          'timestamp': at,
          'channelData': {
            'tenant': {'id': tenant},
            'eventType': ?eventType,
          },
        });
        expect(d.outcome, TeamsGateOutcome.trigger, reason: '$type at $at');
      }
    });
  });

  group('refuses', () {
    void refused(TeamsGateDecision d, int status, Matcher reason) {
      expect(d.outcome, TeamsGateOutcome.reject);
      expect(d.status, status);
      expect(d.reason, reason);
      expect(d.event, isNull);
      expect(d.invokeResponse, isNull);
    }

    test('when no app id is configured', () {
      refused(
        _gate(message(), spec: const TeamsSourceSpec(botAppIds: {})),
        401,
        contains('app ids'),
      );
    });

    test('a sign-in invoke, which carries a token or a code', () {
      for (final name in ['signin/tokenExchange', 'signin/verifyState']) {
        refused(
          _gate({...cardAction(), 'name': name}),
          403,
          contains('sign-in invoke'),
        );
      }
    });

    test('a token for none of the bots', () {
      final t = signedToken(claims: {...tokenClaims(), 'aud': otherAppId});
      refused(_gate(message(), token: t), 401, contains('none of these bots'));
    });

    test('a token whose audience names two of the bots', () {
      final t = signedToken(
        claims: {
          ...tokenClaims(),
          'aud': [appId, otherAppId],
        },
      );
      refused(
        _gate(
          message(),
          token: t,
          spec: TeamsSourceSpec(
            botAppIds: {appBot, otherBot},
            tenantAllowlist: {tenant},
          ),
        ),
        401,
        contains('2 of these bots'),
      );
    });

    test("one bot's token carrying an activity addressed to another", () {
      // Both bots are served here, and the token is genuinely for the first;
      // the body is the only thing naming the second.
      refused(
        _gate(
          {
            ...message(),
            'recipient': {'id': '28:$otherAppId', 'name': 'Other'},
          },
          spec: TeamsSourceSpec(
            botAppIds: {appBot, otherBot},
            tenantAllowlist: {tenant},
          ),
        ),
        401,
        contains('recipient'),
      );
    });

    test('an activity with no recipient', () {
      refused(
        _gate({...message()}..remove('recipient')),
        401,
        contains('recipient'),
      );
    });

    test('a body over the cap', () {
      final d = teamsGate(
        spec: TeamsSourceSpec(botAppIds: {appBot}),
        keys: keys,
        headers: {'Authorization': 'Bearer ${signedToken()}'},
        body: utf8.encode(jsonEncode(message())),
        now: now,
        maxBodyBytes: 10,
      );
      refused(d, 413, contains('over cap'));
    });

    test('a request with no bearer token', () {
      refused(_gate(message(), headers: {}), 401, contains('bearer'));
      refused(
        _gate(message(), headers: {'Authorization': 'Basic abc'}),
        401,
        contains('bearer'),
      );
    });

    test('a token that is not three parts', () {
      refused(_gate(message(), token: 'a.b'), 401, contains('three parts'));
    });

    test('an unsigned token that says alg none', () {
      String seg(Object o) => b64(utf8.encode(jsonEncode(o)));
      final t = '${seg({'alg': 'none', 'kid': 'k1'})}.${seg(tokenClaims())}.';
      refused(_gate(message(), token: t), 401, contains('alg none'));
    });

    test('a token that names an HMAC algorithm', () {
      final t = signedToken(header: {'alg': 'HS256', 'kid': 'k1'});
      refused(_gate(message(), token: t), 401, contains('HS256'));
    });

    test('a token from a key not in the set', () {
      final t = signedToken(header: {'alg': 'RS256', 'kid': 'rotated-out'});
      refused(_gate(message(), token: t), 401, contains('not in the key set'));
    });

    test('claims changed after signing', () {
      final [h, _, s] = signedToken().split('.');
      final forged = b64(
        utf8.encode(jsonEncode({...tokenClaims(), 'aud': 'another-bot'})),
      );
      refused(
        _gate(message(), token: '$h.$forged.$s'),
        401,
        contains('bad signature'),
      );
    });

    test('a signature the wrong length for its key', () {
      final [h, c, _] = signedToken().split('.');
      refused(
        _gate(message(), token: '$h.$c.${b64([1, 2, 3])}'),
        401,
        contains('wrong length'),
      );
    });

    test('a token from another issuer', () {
      final t = signedToken(
        claims: {...tokenClaims(), 'iss': 'https://sts.windows.net/x/'},
      );
      refused(_gate(message(), token: t), 401, contains('issuer'));
    });

    test('a token for another bot', () {
      final t = signedToken(claims: {...tokenClaims(), 'aud': 'another-bot'});
      refused(_gate(message(), token: t), 401, contains('audience'));
    });

    test('a token past its expiry and the skew', () {
      final t = signedToken(
        claims: {...tokenClaims(), 'exp': nowSeconds - 301},
      );
      refused(_gate(message(), token: t), 401, contains('expired'));
    });

    test('a token not yet valid, beyond the skew', () {
      final t = signedToken(
        claims: {...tokenClaims(), 'nbf': nowSeconds + 301},
      );
      refused(_gate(message(), token: t), 401, contains('not valid'));
    });

    test('a token with no expiry', () {
      final t = signedToken(claims: tokenClaims()..remove('exp'));
      refused(_gate(message(), token: t), 401, contains('no expiry'));
    });

    test('a token with no serviceurl claim', () {
      final t = signedToken(claims: tokenClaims()..remove('serviceurl'));
      refused(_gate(message(), token: t), 401, contains('no serviceurl'));
    });

    test('a serviceurl claim that is not the activity\'s', () {
      final t = signedToken(
        claims: {...tokenClaims(), 'serviceurl': 'https://elsewhere.example/'},
      );
      refused(_gate(message(), token: t), 401, contains('does not match'));
    });

    test('an activity from another channel', () {
      refused(
        _gate({...message(), 'channelId': 'slack'}),
        403,
        contains('not msteams'),
      );
    });

    test('a Teams activity signed by a key not endorsed for Teams', () {
      final t = signedToken(
        key: otherKey,
        header: {'alg': 'RS256', 'kid': 'k2'},
      );
      refused(_gate(message(), token: t), 403, contains('not endorsed'));
    });

    test('a tenant not on the allowlist, or no tenant at all', () {
      final other = {
        ...message(),
        'channelData': {
          'tenant': {'id': 'someone-else'},
        },
      };
      refused(_gate(other), 403, contains('someone-else'));
      final none = {
        ...message(),
        'conversation': {'id': 'a:1personal'},
      }..remove('channelData');
      refused(_gate(none), 403, contains('not allowed'));
    });

    test('a body that is not a JSON object', () {
      refused(
        _gate(message(), body: utf8.encode('[1]')),
        400,
        contains('JSON'),
      );
    });

    test('an activity missing what every activity has', () {
      refused(
        _gate(message()..remove('conversation')),
        400,
        contains('conversation'),
      );
    });
  });

  test('cannot tell a body from the one the token came with: '
      'the documented limit, pinned', () {
    // The token is valid; the body is not the one Microsoft sent with it.
    // Nothing the gate can check catches that, because no documented check
    // of the token covers the body (see the library comment, point 2).
    final d = _gate(message(text: 'words Ada never typed'));
    expect(d.outcome, TeamsGateOutcome.trigger);
    expect((d.event! as TeamsMessage).text, 'words Ada never typed');
  });

  group('the key set', () {
    test('passes over a key of another type', () {
      expect(keys.byId('ec1'), isNull);
      expect(keys.byId('k1')!.endorsements, {'msteams', 'skype'});
    });

    test('refuses a malformed RSA key', () {
      expect(
        () => BotFrameworkKeys.parse(
          JsonObject.decode(
            jsonEncode({
              'keys': [
                {'kty': 'RSA', 'kid': 'bad', 'n': '***', 'e': 'AQAB'},
              ],
            }),
          ),
        ),
        throwsA(isA<JsonFieldException>()),
      );
    });
  });
}

void _recordedTests() {
  group('a recorded body', () {
    final bodies = <String, Map<String, Object?>>{
      'message': {
        ...message(),
        'replyToId': '1730881000000',
        'entities': [
          {'type': 'mention', 'text': '<at>Bot</at>'},
        ],
      },
      'edit': {
        ...message(text: 'now'),
        'type': 'messageUpdate',
        'channelData': {
          'tenant': {'id': tenant},
          'eventType': 'editMessage',
        },
      },
      'delete': {
        ...message(),
        'type': 'messageDelete',
        'channelData': {
          'tenant': {'id': tenant},
          'eventType': 'softDeleteMessage',
        },
      }..remove('text'),
      'card action': cardAction(),
      'conversation update': {
        ...message(),
        'type': 'conversationUpdate',
        'membersAdded': [
          {'id': '28:$appId'},
        ],
        'membersRemoved': [
          {'id': '29:1bea'},
        ],
      }..remove('text'),
      'install': {...message(), 'type': 'installationUpdate', 'action': 'add'}
        ..remove('text'),
    };
    for (final MapEntry(key: kind, value: activity) in bodies.entries) {
      test('reads a $kind as the gate does', () {
        final body = utf8.encode(jsonEncode(activity));
        final gated = _gate(activity, body: body).event!;
        expect(_described(teamsRecordedEvent(body)!), _described(gated));
      });
    }

    test('is not checked again: a tenant the gate would refuse still reads, '
        'in lower case', () {
      final other = {
        ...message(),
        'channelData': {
          'tenant': {'id': 'OTHER-TENANT'},
        },
      };
      final body = utf8.encode(jsonEncode(other));
      expect(_gate(other, body: body).status, 403);
      expect(teamsRecordedEvent(body)!.tenant, 'other-tenant');
    });

    test('of a type no event is read as is null', () {
      final typing = {...message(), 'type': 'typing'}..remove('text');
      expect(teamsRecordedEvent(utf8.encode(jsonEncode(typing))), isNull);
    });

    test('that is not an activity throws a FormatException', () {
      expect(
        () => teamsRecordedEvent(utf8.encode('[1]')),
        throwsFormatException,
      );
      expect(() => teamsRecordedEvent([0xff]), throwsFormatException);
      expect(
        () => teamsRecordedEvent(utf8.encode('{"type":"message"}')),
        throwsFormatException,
      );
    });
  });
}

/// Every field of [e], so two events can be compared whole.
String _described(TeamsEvent e) => jsonEncode({
  'kind': '${e.runtimeType}',
  'conversation': e.conversation,
  'id': e.id,
  'serviceUrl': '${e.serviceUrl}',
  'tenant': e.tenant,
  'conversationType': e.conversationType,
  'timestamp': e.timestamp,
  'from': e.from?.value,
  'fromAadObjectId': e.fromAadObjectId?.value,
  'bot': e.bot.value,
  ...switch (e) {
    TeamsMessage() => {
      'text': e.text,
      'entities': e.entities?.map((o) => o.asUncheckedMap()).toList(),
      'replyTo': e.replyTo,
    },
    TeamsMessageUpdate() => {
      'text': e.text,
      'entities': e.entities?.map((o) => o.asUncheckedMap()).toList(),
      'channelEventType': e.channelEventType,
    },
    TeamsMessageDelete() => {'channelEventType': e.channelEventType},
    TeamsCardAction() => {'card': e.card, 'value': e.value?.asUncheckedMap()},
    TeamsInvoke() => {'name': e.name, 'value': e.value?.asUncheckedMap()},
    TeamsMessageActionSubmit() => {
      'command': e.command,
      'message': e.message,
      'data': e.data?.asUncheckedMap(),
    },
    TeamsConversationUpdate() => {
      'added': [for (final u in e.added) u.value],
      'removed': [for (final u in e.removed) u.value],
    },
    TeamsInstallationUpdate() => {'action': e.action},
  },
});

TeamsGateDecision _gate(
  Map<String, Object?> activity, {
  String? token,
  Map<String, String>? headers,
  TeamsSourceSpec? spec,
  List<int>? body,
}) => teamsGate(
  spec: spec ?? TeamsSourceSpec(botAppIds: {appBot}, tenantAllowlist: {tenant}),
  keys: keys,
  headers: headers ?? {'Authorization': 'Bearer ${token ?? signedToken()}'},
  body: body ?? utf8.encode(jsonEncode(activity)),
  now: now,
);
