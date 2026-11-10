/// A TEST bot: the relay, with a doorbell handler that answers through the
/// Bot Connector. It proves the round trip on a test tenant before any Hart
/// content goes near it, and it is not the module's shape: in the module
/// the relay never holds the secret, and the sender runs beside the agent.
///
///   TEAMS_APP_ID=...        the bot's app id
///   TEAMS_APP_SECRET=...    its client secret
///   TEAMS_TENANT_ID=...     the tenant it is registered in, which is also
///                           the only tenant whose activities are taken
///   PORT=8087, HOST=127.0.0.1 as for the relay
///
/// Run it through env-run so the secret never touches a shell history:
///
///   env-run TEAMS_TEST_APP_ID:TEAMS_APP_ID \
///     TEAMS_TEST_APP_SECRET:TEAMS_APP_SECRET \
///     TEAMS_TEST_TENANT_ID:TEAMS_TENANT_ID -- dart run bin/teams_echo.dart
///
/// In Teams: say anything and it echoes; say "card" and it sends a card
/// with Approve and Not yet; press one and the card is edited to say so.
/// Adding the bot to a chat gets a hello, sent without being asked.
library;

import 'dart:async';
import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:is_teams_module/is_teams_module.dart';

Future<void> main() async {
  final env = Platform.environment;
  String need(String name) {
    final v = env[name] ?? '';
    if (v.isEmpty) {
      stderr.writeln('abort: $name not set');
      exit(78);
    }
    return v;
  }

  final appId = need('TEAMS_APP_ID');
  final tenantId = need('TEAMS_TENANT_ID').toLowerCase();
  final connector = BotConnector(
    appId: appId,
    secret: need('TEAMS_APP_SECRET'),
    tenantId: tenantId,
  );
  final port = int.tryParse(env['PORT'] ?? '') ?? 8087;
  final address =
      InternetAddress.tryParse(env['HOST'] ?? '') ??
      InternetAddress.loopbackIPv4;

  final keys = BotFrameworkKeySource(
    get: (url) async {
      final r = await httpCall('GET', url, const {}, '');
      if (r.status != 200) throw HttpException('GET $url: ${r.status}');
      return r.body;
    },
    log: stderr.writeln,
  );
  if (await keys.keys() == null) stderr.writeln('warning: no keys yet');

  final relay = TeamsRelay(
    spec: TeamsSourceSpec(appId: appId, tenantAllowlist: {tenantId}),
    keys: keys,
    onDoorbell: (bell) => _answer(connector, bell),
  );
  final server = await HttpServer.bind(address, port);
  stdout.writeln('teams echo listening on ${address.address}:${server.port}');
  await for (final req in server) {
    unawaited(relay.handle(req));
  }
}

Future<void> _answer(BotConnector connector, JsonObject bell) async {
  final serviceUrl = Uri.parse(bell.string('service_url'));
  final conversation = bell.string('conversation');
  final activity = bell.string('activity');
  stderr.writeln('echo: ${bell.string('event')} in $conversation');
  try {
    switch (bell.string('event')) {
      case 'teams_message':
        final said = _plain(bell.stringOrNull('text') ?? '');
        if (said.toLowerCase() == 'card') {
          final id = await connector.send(serviceUrl, conversation, {
            'type': 'message',
            'attachments': [_card(state: null)],
          });
          stderr.writeln('echo: card sent as $id');
        } else {
          await connector.reply(serviceUrl, conversation, activity, {
            'type': 'message',
            'text': 'echo: $said',
          });
        }
      case 'teams_card_action':
        final verb = bell.object('value').object('action').stringOrNull('verb');
        // The card's own id: what the button was pressed on.
        final card = bell.string('reply_to');
        await connector.update(serviceUrl, conversation, card, {
          'type': 'message',
          'attachments': [_card(state: verb)],
        });
        stderr.writeln('echo: card $card edited for $verb');
      case 'teams_installation_update' || 'teams_conversation_update':
        if (bell.stringOrNull('action') == 'remove') return;
        final added = bell.stringsOrNull('members_added') ?? const [];
        final recipient = bell.stringOrNull('recipient');
        final botJoined =
            bell.string('event') == 'teams_installation_update' ||
            added.contains(recipient);
        if (botJoined) {
          await connector.send(serviceUrl, conversation, {
            'type': 'message',
            'text':
                'Hello: this is a test bot. Say anything and I echo it; '
                'say "card" for a card with buttons.',
          });
        }
    }
  } on BotConnectorException catch (e) {
    stderr.writeln('echo: $e');
  }
}

/// Text with Teams' `<at>…</at>` mention markup and quote tags taken out.
String _plain(String text) => text
    .replaceAll(RegExp(r'<at>[^<]*</at>'), '')
    .replaceAll(RegExp(r'<quoted[^>]*/>'), '')
    .trim();

/// The card for a node in [state]: what its annotations add up to, and the
/// actions that make sense from there (Nick, 2026-11-10). Approved offers
/// only Edit, which writes nothing and reopens the choice; open, reopened or
/// not yet offers Approve and Not yet.
Map<String, Object?> _card({required String? state}) => {
  'contentType': 'application/vnd.microsoft.card.adaptive',
  'content': {
    r'$schema': 'http://adaptivecards.io/schemas/adaptive-card.json',
    'type': 'AdaptiveCard',
    'version': '1.5',
    'body': [
      {
        'type': 'TextBlock',
        'text': 'Rung 3: the thermostat failed',
        'weight': 'Bolder',
        'wrap': true,
      },
      {'type': 'TextBlock', 'text': 'Level: supported', 'wrap': true},
      if (state case 'approve' || 'notyet')
        {
          'type': 'TextBlock',
          'text': state == 'approve' ? 'Approved.' : 'Not yet: noted.',
          'wrap': true,
          'isSubtle': true,
        },
    ],
    'actions': [
      for (final (verb, title)
          in state == 'approve'
              ? [('edit', 'Edit')]
              : [('approve', 'Approve'), ('notyet', 'Not yet')])
        {
          'type': 'Action.Execute',
          'title': title,
          'verb': verb,
          'data': {'node': 'rung-3'},
        },
    ],
  },
};
