/// The owner's own journeys, from Teams: the relay, with [JourneyBridge] as
/// its doorbell handler, talking to intersyntactic's agent host on this
/// machine. In a chat with the bot, "journeys" offers the active ones to open;
/// what the owner says goes into the one open, its replies come back, and
/// its questions arrive as cards with Yes and No.
///
///   TEAMS_APP_ID=...        the bot's app id
///   TEAMS_APP_SECRET=...    its client secret
///   TEAMS_TENANT_ID=...     the tenant it is registered in, which is also
///                           the only tenant whose activities are taken
///   TEAMS_OWNER=...         the one actor whose messages reach a journey,
///                           `teams:<tenant>/<Entra object id>`; without it
///                           the bot tells whoever writes what theirs is
///   AGENT_HOST=http://127.0.0.1:8900   where the agent host listens
///   PORT=8087, HOST=127.0.0.1 as for the relay
///
///   env-run ENS_TEAMS_APP_ID:TEAMS_APP_ID \
///     ENS_TEAMS_APP_SECRET:TEAMS_APP_SECRET \
///     ENS_TEAMS_TENANT_ID:TEAMS_TENANT_ID -- dart run bin/teams_journey.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:is_shapes/is_shapes.dart';
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
  final owner = switch (env['TEAMS_OWNER']) {
    null || '' => null,
    final s =>
      ActorId.parse(s.toLowerCase()) ??
          (throw ArgumentError.value(s, 'TEAMS_OWNER', 'is not an actor id')),
  };
  if (owner == null) {
    stderr.writeln('warning: no TEAMS_OWNER: nobody is let in');
  }
  final host = Uri.parse(env['AGENT_HOST'] ?? 'http://127.0.0.1:8900');
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

  final bridge = JourneyBridge(
    journeys: AgentHostClient(host),
    owner: owner,
    send: connector.send,
    update: connector.update,
    log: stderr.writeln,
  );
  final relay = TeamsRelay(
    spec: TeamsSourceSpec(appId: appId, tenantAllowlist: {tenantId}),
    keys: keys,
    onDoorbell: bridge.onDoorbell,
  );
  final server = await HttpServer.bind(address, port);
  stdout.writeln(
    'teams journey listening on ${address.address}:${server.port}, '
    'agent host $host',
  );
  await for (final req in server) {
    unawaited(relay.handle(req));
  }
}
