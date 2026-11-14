import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final _url = Uri.parse('https://smba.trafficmanager.net/amer/');

/// Every kind of arrival, each with every field it has set.
final everyKind = <TeamsArrival>[
  TeamsSaid(
    conversation: '19:c@thread.v2',
    id: '1794558994313',
    serviceUrl: _url,
    tenant: 'tenant-1',
    conversationType: 'groupChat',
    timestamp: '2026-11-14T00:00:00Z',
    from: '29:1ada',
    fromAadObjectId: 'oid-ada',
    recipient: '28:bot',
    text: '<at>Bot</at> hello',
    entities: [
      JsonObject.of({'type': 'mention'}),
    ],
    replyTo: '1794558990000',
  ),
  TeamsEdited(
    conversation: 'a:1',
    id: 'act-2',
    serviceUrl: _url,
    text: 'hello again',
    eventType: 'editMessage',
  ),
  TeamsDeleted(
    conversation: 'a:1',
    id: 'act-3',
    serviceUrl: _url,
    eventType: 'softDeleteMessage',
  ),
  TeamsPressed(
    conversation: 'a:1',
    id: 'act-4',
    serviceUrl: _url,
    card: 'card-1',
    value: JsonObject.of({
      'action': {'verb': 'approve'},
    }),
  ),
  TeamsInvoked(
    conversation: 'a:1',
    id: 'act-5',
    serviceUrl: _url,
    name: 'task/fetch',
    value: JsonObject.of({'x': 1}),
  ),
  TeamsMembersChanged(
    conversation: 'a:1',
    id: 'act-6',
    serviceUrl: _url,
    recipient: '28:bot',
    added: ['28:bot'],
    removed: ['29:1bea'],
  ),
  TeamsInstallChanged(
    conversation: 'a:1',
    id: 'act-7',
    serviceUrl: _url,
    action: 'add',
  ),
];

String _wire(TeamsArrival a) => jsonEncode(a.toJson().asUncheckedMap());

void main() {
  test('every kind reads back from its wire form as itself', () {
    for (final arrival in everyKind) {
      final back = TeamsArrival.fromJson(arrival.toJson());
      expect(back.runtimeType, arrival.runtimeType, reason: arrival.event);
      expect(_wire(back!), _wire(arrival), reason: arrival.event);
    }
  });

  test('every kind has its own event on the wire', () {
    expect(everyKind.map((a) => a.event).toSet(), hasLength(everyKind.length));
  });

  test('a message keeps what it replies under', () {
    final back = TeamsArrival.fromJson(everyKind.first.toJson())! as TeamsSaid;
    expect(back.replyTo, '1794558990000');
    expect(back.text, '<at>Bot</at> hello');
  });

  test('a press says its verb', () {
    expect((everyKind[3] as TeamsPressed).verb, 'approve');
  });

  test('an event no arrival is read as reads as nothing', () {
    final json = JsonObject.of({
      ...everyKind.last.toJson().asUncheckedMap(),
      'event': 'teams_typing',
    });
    expect(TeamsArrival.fromJson(json), isNull);
  });

  test('the actor is the tenant and Entra user, in lower case', () {
    final said = TeamsSaid(
      conversation: 'a:1',
      id: 'act-1',
      serviceUrl: _url,
      tenant: 'TENANT-1',
      fromAadObjectId: 'OID-Ada',
    );
    expect('${said.actor}', 'teams:tenant-1/oid-ada');
  });

  test('no actor without a tenant or an Entra user', () {
    expect(
      TeamsSaid(conversation: 'a:1', id: 'a', serviceUrl: _url).actor,
      isNull,
    );
    expect(
      TeamsSaid(
        conversation: 'a:1',
        id: 'a',
        serviceUrl: _url,
        tenant: 't',
      ).actor,
      isNull,
    );
  });
}
