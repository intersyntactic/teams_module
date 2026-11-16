import 'dart:convert';

import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// The event the gate reads [activity] as. The bodies are hand-written:
/// no edit, delete or restore has reached the record yet.
TeamsEvent eventOf(Map<String, Object?> activity) => teamsGate(
  spec: const TeamsSourceSpec(appId: appId, tenantAllowlist: {tenant}),
  keys: keys,
  headers: {
    'Authorization':
        'Bearer ${signedToken(claims: {...tokenClaims(), 'serviceurl': activity['serviceUrl']})}',
  },
  body: utf8.encode(jsonEncode(activity)),
  now: now,
  hasSeen: (_) => false,
).event!;

/// [message] as Teams' [type], with `channelData.eventType` [eventType].
Map<String, Object?> changed(
  String type,
  String? eventType, {
  String text = 'Looks wrong to me',
}) {
  return message(text: text)
    ..['type'] = type
    ..['channelData'] = {
      'tenant': {'id': tenant},
      'eventType': ?eventType,
    };
}

WhatChanged? changeOf(Map<String, Object?> activity) =>
    teamsChange(eventOf(activity), entraOf: (_) => null);

void main() {
  setUpAll(setUpKeys);

  test('an edit is Edited, with the new words', () {
    final c = changeOf(changed('messageUpdate', 'editMessage'));
    expect(
      c,
      isA<Edited>()
          .having((e) => e.text, 'text', 'Looks wrong to me')
          .having((e) => e.quotes, 'quotes', isNull),
    );
  });

  test('an edit carries what it now quotes, read as a message is', () {
    final a = changed('messageUpdate', 'editMessage')
      ..['text'] = '<quoted messageId="1730881000000"/>\nThis one'
      ..['entities'] = [
        {
          'type': 'quotedReply',
          'quotedReply': {
            'messageId': '1730881000000',
            'senderId': '29:1bea',
            'senderName': 'Bea',
            'preview': 'Good morning!',
          },
        },
      ];
    final c = changeOf(a)! as Edited;
    expect(c.text, 'This one');
    expect(c.quotes?.source.value, 'a:1personal|1730881000000');
    expect(c.quotes?.preview, 'Good morning!');
  });

  test('a delete is Deleted, whoever deleted it', () {
    final a = changed('messageDelete', 'softDeleteMessage')
      ..['from'] = {'id': '29:1bea', 'name': 'Bea'};
    expect(changeOf(a), isA<Deleted>());
  });

  test('a restore is Restored', () {
    expect(
      changeOf(changed('messageUpdate', 'undeleteMessage')),
      isA<Restored>(),
    );
  });

  test('an update Teams gives no kind, or an unknown one, is nothing', () {
    expect(changeOf(changed('messageUpdate', null)), isNull);
    expect(changeOf(changed('messageUpdate', 'pinMessage')), isNull);
  });

  test('an edit to no words that quotes nothing is nothing', () {
    expect(changeOf(changed('messageUpdate', 'editMessage', text: '')), isNull);
  });

  test('a message is not a change', () {
    expect(changeOf(message()), isNull);
  });
}
