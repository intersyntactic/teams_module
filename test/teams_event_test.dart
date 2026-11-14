import 'package:checked_json/checked_json.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final _url = Uri.parse('https://smba.trafficmanager.net/amer/');

void main() {
  test('a press says its verb', () {
    final pressed = TeamsPressed(
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
