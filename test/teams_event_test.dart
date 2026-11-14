import 'package:checked_json/checked_json.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final _url = Uri.parse('https://smba.trafficmanager.net/amer/');

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
      fromAadObjectId: 'OID-Ada',
    );
    expect('${said.actor}', 'teams:tenant-1/oid-ada');
  });

  test('a bot is an actor too, by its app id, in lower case', () {
    final said = TeamsMessage(
      conversation: 'a:1',
      id: 'act-1',
      serviceUrl: _url,
      tenant: 'TENANT-1',
      from: '28:App-Id',
    );
    expect('${said.actor}', 'teams:tenant-1/bot:app-id');
  });

  test('an Entra user is a person, whatever the channel id', () {
    final said = TeamsMessage(
      conversation: 'a:1',
      id: 'act-1',
      serviceUrl: _url,
      tenant: 'tenant-1',
      from: '28:app-id',
      fromAadObjectId: 'oid-ada',
    );
    expect('${said.actor}', 'teams:tenant-1/oid-ada');
  });

  test('no actor without a tenant, or with a sender that is neither', () {
    TeamsMessage sentBy({String? tenant, String? from}) => TeamsMessage(
      conversation: 'a:1',
      id: 'a',
      serviceUrl: _url,
      tenant: tenant,
      from: from,
    );
    expect(sentBy(from: '28:app-id').actor, isNull);
    expect(sentBy(tenant: 't').actor, isNull);
    expect(sentBy(tenant: 't', from: '29:1ada').actor, isNull);
    expect(sentBy(tenant: 't', from: '28:').actor, isNull);
  });
}
