import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_relay/is_relay.dart' show RefusalStatus;
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

final _dialog = teamsDialog(
  title: 'Call settings',
  card: JsonObject.of({'type': 'AdaptiveCard', 'version': '1.5'}),
);

void main() {
  setUpAll(setUpKeys);
  _recordedTests();

  group('takes', () {
    test('a message in a one-to-one chat, with its text', () {
      final d = _gate(message());
      expect(_response(d), isNull);
      final said = _event(d) as TeamsMessage;
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
      expect(said.mentions, isEmpty);
      expect(said.quote, isNull);
      expect(said.replyTo, isNull);
      expect(said.attachments, isEmpty);
    });

    test('a message in a channel, with what it replies under', () {
      final d = _gate({...message(), 'replyToId': '1730881000000'});
      expect((_event(d) as TeamsMessage).replyTo, '1730881000000');
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
      final edited = _event(d) as TeamsMessageUpdate;
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
      final deleted = _event(d) as TeamsMessageDelete;
      expect(deleted.id, '1730881234567');
      expect(deleted.channelEventType, 'softDeleteMessage');
    });

    test('call settings opened, answered with the dialog', () {
      final d = _gate(_messageAction('composeExtension/fetchTask'));
      final opened = _event(d) as TeamsMessageActionOpen;
      expect(opened.command, TeamsMessageAction.callSettings);
      expect(opened.message, '1730881000000');
      expect(_response(d)!.asUncheckedMap(), {
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
        _response(_gate(_messageAction('composeExtension/fetchTask')))!
            .asUncheckedMap(),
        _response(d)!.asUncheckedMap(),
      );
    });

    test('call settings submitted, with the message, not what was in it', () {
      // As the docs give a message action's submitAction; not yet measured.
      final d = _gate(_messageAction('composeExtension/submitAction'));
      expect(_response(d), isNull);
      final submitted = _event(d) as TeamsMessageActionSubmit;
      expect(submitted.command, TeamsMessageAction.callSettings);
      expect(
        submitted.messageRef,
        TeamsMessageRef.of('a:1personal', '1730881000000'),
      );
      expect(
        jsonEncode(submitted.projection().asUncheckedMap()),
        isNot(contains('opus')),
      );
    });

    test('a card action, responded to with the acknowledgement', () {
      final d = _gate(cardAction());
      expect(_response(d)!.asUncheckedMap(), {
        'statusCode': 200,
        'type': 'application/vnd.microsoft.activity.message',
        'value': 'Got it',
      });
      final pressed = _event(d) as TeamsCardAction;
      expect(pressed.card, '1730881000000');
      expect(pressed.verb, CardActionVerb.approve);
      expect(pressed.trajectory, isNull);
    });

    test("a Close, with the trajectory its card's data names", () {
      final press = cardAction();
      (press['value']! as Map<String, Object?>)['action'] = {
        'type': 'Action.Execute',
        'verb': 'close',
        'data': {'trajectory': 'cd' * 32},
      };
      final pressed = _event(_gate(press)) as TeamsCardAction;
      expect(pressed.verb, CardActionVerb.close);
      expect(pressed.trajectory?.hex, 'cd' * 32);
    });

    test('a card action with a verb our cards never send, as no verb', () {
      final press = cardAction();
      (press['value']! as Map<String, Object?>)['action'] = {'verb': 'other'};
      expect((_event(_gate(press)) as TeamsCardAction).verb, isNull);
    });

    test('an audience given as a list', () {
      final t = signedToken(
        claims: {
          ...tokenClaims(),
          'aud': ['someone', appId],
        },
      );
      _event(_gate(message(), token: t));
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
      expect(_event(d).bot, otherBot);
    });

    test('the claim spelled serviceUrl, as the docs spell it', () {
      final claims = tokenClaims()
        ..remove('serviceurl')
        ..['serviceUrl'] = serviceUrl;
      _event(_gate(message(), token: signedToken(claims: claims)));
    });

    test('a key named by x5t alone', () {
      final t = signedToken(
        header: {'typ': 'JWT', 'alg': 'RS256', 'x5t': 'k1'},
      );
      _event(_gate(message(), token: t));
    });

    test('a token inside the clock skew at either end', () {
      final late_ = signedToken(
        claims: {...tokenClaims(), 'exp': nowSeconds - 240},
      );
      final early = signedToken(
        claims: {...tokenClaims(), 'nbf': nowSeconds + 240},
      );
      _event(_gate(message(), token: late_));
      _event(_gate(message(), token: early));
    });

    test('an install, which carries what messaging first needs', () {
      final d = _gate(
        {...message(), 'type': 'installationUpdate', 'action': 'add'}
          ..remove('text'),
      );
      final installed = _event(d) as TeamsInstallationUpdate;
      expect(installed.action, InstallationAction.add);
      expect(installed.serviceUrl, Uri.parse(serviceUrl));
    });

    test('a tenant in upper case, matched and passed on in lower', () {
      final upper = tenant.toUpperCase();
      final d = _gate({
        ...message(),
        'channelData': {
          'tenant': {'id': upper},
        },
      }, spec: TeamsSourceSpec(botAppIds: {appBot}, tenantAllowlist: {upper}));
      expect(_event(d).tenant, tenant);
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
      final changed = _event(d) as TeamsConversationUpdate;
      expect(changed.added, [TeamsUserId.parse('28:$appId')]);
      expect(changed.removed, isEmpty);
    });

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
        expect(d, isA<TeamsActivityTaken>(), reason: '$type at $at');
      }
    });
  });

  group('reads from a message', () {
    // As a group-chat Reply with @CAM carried them, recorded 2026-11-15.
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
    TeamsMessage carrying(List<Map<String, Object?>> entities) =>
        _event(_gate({...message(), 'entities': entities})) as TeamsMessage;

    test('who it mentions, and the name Teams showed', () {
      final m = carrying([mention, quoted]).mentions.single;
      expect(m.id, TeamsUserId.parse('28:app-id'));
      expect(m.name, 'CAM');
    });

    test('a mention naming no channel account, as none', () {
      expect(
        carrying([
          {
            'type': 'mention',
            'mentioned': {'id': 'tag:everyone', 'name': 'Everyone'},
          },
        ]).mentions,
        isEmpty,
      );
    });

    test('what it quotes, from the quotedReply entity past a mention', () {
      final q = carrying([mention, quoted]).quote!;
      expect(q.messageId, '1794611050347');
      expect(q.senderId, TeamsUserId.parse('29:1bea'));
      expect(q.senderName, 'Bea');
      expect(q.preview, 'Good morning!');
    });

    test('no quote from a message that quotes nothing', () {
      expect(carrying([mention]).quote, isNull);
    });

    test('a quote only with both the message and its author', () {
      Map<String, Object?> without(String key) => {
        'type': 'quotedReply',
        'quotedReply': {...(quoted['quotedReply']! as Map<String, Object?>)}
          ..remove(key),
      };
      expect(carrying([without('messageId')]).quote, isNull);
      expect(carrying([without('senderId')]).quote, isNull);
      expect(carrying([without('senderName')]).quote!.senderName, isNull);
    });

    test('what it carried, by reference, never a grant to read it', () {
      final said = _event(
        _gate({
          ...message(),
          'attachments': [
            {
              'contentType':
                  'application/vnd.microsoft.teams.file.download.info',
              'contentUrl':
                  'https://x.sharepoint.com/sites/s/plan.docx?tempauth=t#f',
              'name': 'plan.docx',
              'content': {
                'downloadUrl': 'https://x.sharepoint.com/dl?tempauth=t',
              },
            },
            {
              'contentType': 'image/*',
              'contentUrl': 'https://user:pass@smba.example:8443/a/1',
            },
            {'contentType': 'text/html', 'content': '<p>hi</p>'},
            {'contentType': 'x', 'contentUrl': 'not a url'},
            {'name': 'no type'},
          ],
        }),
      ) as TeamsMessage;
      expect(
        [
          for (final a in said.attachments)
            (a.contentType, a.name, '${a.contentUrl}'),
        ],
        [
          (
            'application/vnd.microsoft.teams.file.download.info',
            'plan.docx',
            'https://x.sharepoint.com/sites/s/plan.docx',
          ),
          ('image/*', null, 'https://smba.example:8443/a/1'),
          ('text/html', null, 'null'),
          ('x', null, 'null'),
        ],
      );
    });
  });

  group('refuses', () {
    void refused(TeamsGateDecision d, TeamsRefusal refusal) => expect(
      d,
      isA<TeamsActivityRefused>().having((r) => r.refusal, 'refusal', refusal),
    );

    test('each refusal with a fixed reason and a status that is no 2xx', () {
      for (final r in TeamsRefusal.values) {
        expect(r.reason, isNotEmpty);
        expect(r.status.code, greaterThanOrEqualTo(400));
      }
      expect(TeamsRefusal.kindNotRecorded.status, RefusalStatus.forbidden);
    });

    test('when no app id is configured', () {
      refused(
        _gate(message(), spec: const TeamsSourceSpec(botAppIds: {})),
        TeamsRefusal.noBotAppIds,
      );
    });

    test('a kind it has no case for, whatever it is called', () {
      for (final activity in <Map<String, Object?>>[
        {...message(), 'type': 'typing'}..remove('text'),
        {...message(), 'type': 'messageReaction'}..remove('text'),
        {...message(), 'type': 'event', 'name': 'tokens/response'},
        {...message(), 'type': 'endOfConversation'},
        {...cardAction(), 'name': 'signin/tokenExchange'},
        {...cardAction(), 'name': 'signin/verifyState'},
        {...cardAction(), 'name': 'SignIn/tokenExchange'},
        {...cardAction(), 'name': 'composeExtension/query'},
        {...cardAction(), 'name': 'task/fetch'},
        {...cardAction()}..remove('name'),
      ]) {
        refused(_gate(activity), TeamsRefusal.kindNotRecorded);
      }
    });

    test('a message action the manifest does not declare', () {
      for (final name in [
        'composeExtension/fetchTask',
        'composeExtension/submitAction',
      ]) {
        // The retired "Close trajectory" action, from an old package.
        refused(
          _gate(_messageAction(name, command: 'closeTrajectory')),
          TeamsRefusal.kindNotRecorded,
        );
      }
    });

    test('call settings opened, with no dialog to open', () {
      refused(
        _gate(
          _messageAction('composeExtension/fetchTask'),
          spec: TeamsSourceSpec(botAppIds: {appBot}, tenantAllowlist: {tenant}),
        ),
        TeamsRefusal.kindNotRecorded,
      );
    });

    test('a token for none of the bots', () {
      final t = signedToken(claims: {...tokenClaims(), 'aud': otherAppId});
      refused(_gate(message(), token: t), TeamsRefusal.tokenAudience);
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
        TeamsRefusal.tokenAudience,
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
        TeamsRefusal.recipientNotTokenBot,
      );
    });

    test('an activity with no recipient', () {
      refused(
        _gate({...message()}..remove('recipient')),
        TeamsRefusal.recipientNotTokenBot,
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
      refused(d, TeamsRefusal.bodyTooLarge);
    });

    test('a request with no bearer token', () {
      refused(_gate(message(), headers: {}), TeamsRefusal.noBearerToken);
      refused(
        _gate(message(), headers: {'Authorization': 'Basic abc'}),
        TeamsRefusal.noBearerToken,
      );
    });

    test('a token that is not three parts', () {
      refused(_gate(message(), token: 'a.b'), TeamsRefusal.tokenUnreadable);
    });

    test('an unsigned token that says alg none', () {
      String seg(Object o) => b64(utf8.encode(jsonEncode(o)));
      final t = '${seg({'alg': 'none', 'kid': 'k1'})}.${seg(tokenClaims())}.';
      refused(_gate(message(), token: t), TeamsRefusal.tokenAlgorithm);
    });

    test('a token that names an HMAC algorithm', () {
      final t = signedToken(header: {'alg': 'HS256', 'kid': 'k1'});
      refused(_gate(message(), token: t), TeamsRefusal.tokenAlgorithm);
    });

    test('a token that names no key', () {
      final t = signedToken(header: {'alg': 'RS256'});
      refused(_gate(message(), token: t), TeamsRefusal.tokenNamesNoKey);
    });

    test('a token from a key not in the set', () {
      final t = signedToken(header: {'alg': 'RS256', 'kid': 'rotated-out'});
      refused(_gate(message(), token: t), TeamsRefusal.tokenKeyUnknown);
    });

    test('claims changed after signing', () {
      final [h, _, s] = signedToken().split('.');
      final forged = b64(
        utf8.encode(jsonEncode({...tokenClaims(), 'aud': 'another-bot'})),
      );
      refused(
        _gate(message(), token: '$h.$forged.$s'),
        TeamsRefusal.badSignature,
      );
    });

    test('a signature the wrong length for its key', () {
      final [h, c, _] = signedToken().split('.');
      refused(
        _gate(message(), token: '$h.$c.${b64([1, 2, 3])}'),
        TeamsRefusal.badSignature,
      );
    });

    test('a token from another issuer', () {
      final t = signedToken(
        claims: {...tokenClaims(), 'iss': 'https://sts.windows.net/x/'},
      );
      refused(_gate(message(), token: t), TeamsRefusal.tokenIssuer);
    });

    test('a token for another bot', () {
      final t = signedToken(claims: {...tokenClaims(), 'aud': 'another-bot'});
      refused(_gate(message(), token: t), TeamsRefusal.tokenAudience);
    });

    test('a token past its expiry and the skew', () {
      final t = signedToken(
        claims: {...tokenClaims(), 'exp': nowSeconds - 301},
      );
      refused(_gate(message(), token: t), TeamsRefusal.tokenExpired);
    });

    test('a token not yet valid, beyond the skew', () {
      final t = signedToken(
        claims: {...tokenClaims(), 'nbf': nowSeconds + 301},
      );
      refused(_gate(message(), token: t), TeamsRefusal.tokenNotYetValid);
    });

    test('a token with no expiry', () {
      final t = signedToken(claims: tokenClaims()..remove('exp'));
      refused(_gate(message(), token: t), TeamsRefusal.tokenNoExpiry);
    });

    test('a token with no serviceurl claim', () {
      final t = signedToken(claims: tokenClaims()..remove('serviceurl'));
      refused(_gate(message(), token: t), TeamsRefusal.noServiceUrlClaim);
    });

    test("a serviceurl claim that is not the activity's", () {
      final t = signedToken(
        claims: {...tokenClaims(), 'serviceurl': 'https://elsewhere.example/'},
      );
      refused(_gate(message(), token: t), TeamsRefusal.serviceUrlMismatch);
    });

    test('an activity from another channel', () {
      refused(
        _gate({...message(), 'channelId': 'slack'}),
        TeamsRefusal.notTeams,
      );
    });

    test('a Teams activity signed by a key not endorsed for Teams', () {
      final t = signedToken(
        key: otherKey,
        header: {'alg': 'RS256', 'kid': 'k2'},
      );
      refused(_gate(message(), token: t), TeamsRefusal.keyNotEndorsed);
    });

    test('a tenant not on the allowlist, or no tenant at all', () {
      final other = {
        ...message(),
        'channelData': {
          'tenant': {'id': 'someone-else'},
        },
      };
      refused(_gate(other), TeamsRefusal.tenantNotAllowed);
      final none = {
        ...message(),
        'conversation': {'id': 'a:1personal'},
      }..remove('channelData');
      refused(_gate(none), TeamsRefusal.tenantNotAllowed);
    });

    test('a body that is not a JSON object', () {
      refused(
        _gate(message(), body: utf8.encode('[1]')),
        TeamsRefusal.bodyNotJson,
      );
    });

    test('an activity missing what every activity has', () {
      refused(
        _gate(message()..remove('conversation')),
        TeamsRefusal.activityMalformed,
      );
    });
  });

  test('cannot tell a body from the one the token came with: '
      'the documented limit, pinned', () {
    // The token is valid; the body is not the one Microsoft sent with it.
    // Nothing the gate can check catches that, because no documented check
    // of the token covers the body (see the library comment, point 2).
    final d = _gate(message(text: 'words Ada never typed'));
    expect((_event(d) as TeamsMessage).text, 'words Ada never typed');
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
  group('a recorded projection', () {
    final activities = <String, Map<String, Object?>>{
      'message': {
        ...message(),
        'replyToId': '1730881000000',
        'entities': [
          {
            'type': 'mention',
            'mentioned': {'id': '28:$appId', 'name': 'Bot'},
            'text': '<at>Bot</at>',
          },
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
      'call settings opened': _messageAction('composeExtension/fetchTask'),
      'call settings submitted': _messageAction(
        'composeExtension/submitAction',
      ),
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
    for (final MapEntry(key: kind, value: activity) in activities.entries) {
      test('of a $kind reads back as the event the gate made', () {
        final gated = _event(_gate(activity));
        final read = teamsRecordedEvent(projectedBytes(activity));
        expect(read.runtimeType, gated.runtimeType);
        expect(
          jsonEncode(read.projection().asUncheckedMap()),
          jsonEncode(gated.projection().asUncheckedMap()),
        );
      });
    }

    test('that is a raw activity, or not JSON, throws a FormatException', () {
      expect(
        () => teamsRecordedEvent(utf8.encode(jsonEncode(message()))),
        throwsFormatException,
      );
      expect(
        () => teamsRecordedEvent(utf8.encode('[1]')),
        throwsFormatException,
      );
      expect(() => teamsRecordedEvent([0xff]), throwsFormatException);
    });
  });
}

/// A message action's invoke, [name], for [command], opened on a message.
Map<String, Object?> _messageAction(
  String name, {
  String command = callSettingsCommandId,
}) => {
  ...cardAction(),
  'name': name,
  'value': {
    'commandId': command,
    'commandContext': 'message',
    'messagePayload': {'id': '1730881000000', 'body': <String, Object?>{}},
    'data': {'model': 'opus', 'effort': 'high'},
  },
};

/// The event [d] took; fails the test when it refused.
TeamsEvent _event(TeamsGateDecision d) => switch (d) {
  TeamsActivityTaken(:final event) => event,
  TeamsActivityRefused(:final refusal) => fail('refused: ${refusal.reason}'),
};

/// The response [d] answers with; fails the test when it refused.
JsonObject? _response(TeamsGateDecision d) => switch (d) {
  TeamsActivityTaken(:final response) => response,
  TeamsActivityRefused(:final refusal) => fail('refused: ${refusal.reason}'),
};

TeamsGateDecision _gate(
  Map<String, Object?> activity, {
  String? token,
  Map<String, String>? headers,
  TeamsSourceSpec? spec,
  List<int>? body,
}) => teamsGate(
  spec:
      spec ??
      TeamsSourceSpec(
        botAppIds: {appBot},
        tenantAllowlist: {tenant},
        callSettingsDialog: _dialog,
      ),
  keys: keys,
  headers: headers ?? {'Authorization': 'Bearer ${token ?? signedToken()}'},
  body: body ?? utf8.encode(jsonEncode(activity)),
  now: now,
);
