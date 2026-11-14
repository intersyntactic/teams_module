import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(setUpKeys);

  group('takes', () {
    test('a message in a one-to-one chat, with its text', () {
      final d = _gate(message());
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.status, 200);
      expect(d.invokeResponse, isNull);
      expect(d.seenKey, jsonEncode(['a:1personal', '1730881234567']));
      final said = d.event! as TeamsMessage;
      expect(said.tenant, tenant);
      expect(said.conversation, 'a:1personal');
      expect(said.conversationType, 'personal');
      expect(said.id, '1730881234567');
      expect(said.serviceUrl, Uri.parse(serviceUrl));
      expect(said.timestamp, '2026-11-06T10:00:00.000Z');
      expect(said.from, '29:1ada');
      expect(said.fromAadObjectId, 'oid-ada');
      expect(said.recipient, '28:$appId');
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
        spec: const TeamsSourceSpec(
          appId: appId,
          tenantAllowlist: {tenant},
          wakeInvokes: {'task/fetch'},
        ),
      );
      final invoked = d.event! as TeamsInvoke;
      expect(invoked.name, 'task/fetch');
      expect(invoked.value!.object('action').string('verb'), 'approve');
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
      expect(pressed.verb, 'approve');
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
      // seen in a witnessed body on 2026-11-14. The gate passes entities on
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
      }, spec: TeamsSourceSpec(appId: appId, tenantAllowlist: {upper}));
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
      expect(changed.added, ['28:$appId']);
      expect(changed.removed, isEmpty);
    });
  });

  group('ignores', () {
    test('a quiet activity type, but still marks it seen', () {
      final d = _gate({...message(), 'type': 'typing'}..remove('text'));
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.status, 200);
      expect(d.event, isNull);
      expect(d.seenKey, isNotNull);
    });

    test('a type it was told to wake on that no event is read as', () {
      final d = _gate(
        {...message(), 'type': 'typing'}..remove('text'),
        spec: const TeamsSourceSpec(
          appId: appId,
          tenantAllowlist: {tenant},
          wakeActivityTypes: {'typing'},
        ),
      );
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.reason, 'no event is read from typing');
      expect(d.event, isNull);
      expect(d.seenKey, isNotNull);
    });

    test('an invoke it was not built for, with no response to give', () {
      final d = _gate({...cardAction(), 'name': 'composeExtension/query'});
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.invokeResponse, isNull);
    });

    test('an activity already seen', () {
      final seen = <String>{};
      final first = _gate(message(), hasSeen: seen.contains);
      seen.add(first.seenKey!);
      final again = _gate(message(), hasSeen: seen.contains);
      expect(again.outcome, TeamsGateOutcome.ignore);
      expect(again.event, isNull);
    });

    test('a card action re-sent, still responded to as the first was', () {
      final seen = {_gate(cardAction()).seenKey!};
      final again = _gate(cardAction(), hasSeen: seen.contains);
      expect(again.outcome, TeamsGateOutcome.ignore);
      expect(again.invokeResponse!.string('value'), 'Got it');
    });

    test('the same activity id in another conversation is not a repeat', () {
      final seen = {_gate(message()).seenKey!};
      final elsewhere = {
        ...message(),
        'conversation': {'id': '19:group@thread.v2', 'tenantId': tenant},
      };
      expect(
        _gate(elsewhere, hasSeen: seen.contains).outcome,
        TeamsGateOutcome.trigger,
      );
    });
  });

  group('refuses', () {
    void refused(TeamsGateDecision d, int status, Matcher reason) {
      expect(d.outcome, TeamsGateOutcome.reject);
      expect(d.status, status);
      expect(d.reason, reason);
      expect(d.event, isNull);
      expect(d.invokeResponse, isNull);
      // An unauthenticated request never reaches the seen set.
      expect(d.seenKey, isNull);
    }

    test('when no app id is configured', () {
      refused(
        _gate(message(), spec: const TeamsSourceSpec(appId: '')),
        401,
        contains('app id'),
      );
    });

    test('a body over the cap', () {
      final d = teamsGate(
        spec: const TeamsSourceSpec(appId: appId),
        keys: keys,
        headers: {'Authorization': 'Bearer ${signedToken()}'},
        body: utf8.encode(jsonEncode(message())),
        now: now,
        maxBodyBytes: 10,
      );
      refused(d, 401, contains('over cap'));
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

TeamsGateDecision _gate(
  Map<String, Object?> activity, {
  String? token,
  Map<String, String>? headers,
  TeamsSourceSpec spec = const TeamsSourceSpec(
    appId: appId,
    tenantAllowlist: {tenant},
  ),
  bool Function(String)? hasSeen,
  List<int>? body,
}) => teamsGate(
  spec: spec,
  keys: keys,
  headers: headers ?? {'Authorization': 'Bearer ${token ?? signedToken()}'},
  body: body ?? utf8.encode(jsonEncode(activity)),
  now: now,
  hasSeen: hasSeen,
);
