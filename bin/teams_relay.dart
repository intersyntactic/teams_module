/// Run behind TLS (a reverse proxy): Teams posts only to https. The relay
/// holds no Microsoft secret, only the bots' app ids, which each bot's own
/// manifest prints. One endpoint serves every bot in the list.
///
///   TEAMS_APP_IDS=id1,id2            the bots' Microsoft app ids: every
///                                    token's audience must name exactly
///                                    one. Required; a non-GUID aborts
///   TEAMS_TENANT_ALLOWLIST=t1,t2     tenants whose activities are taken.
///                                    Required: empty would take any
///                                    correctly signed tenant, so it aborts
///   PORT=8087                        optional; a non-port aborts
///   HOST=127.0.0.1                   optional; the address to bind. The
///                                    default is loopback, for a proxy on
///                                    the same machine.
///   LOGBOOK_SOCKET=/run/...sock      the logbook's writer's Unix socket:
///                                    every accepted request's body is
///                                    recorded through it as a `teams-event`
///                                    entry, byte for byte, before Teams
///                                    gets a response. Required.
///   TEAMS_SETTINGS_DIALOG=card.json  optional; an Adaptive Card the call
///                                    settings message action opens, read
///                                    once at boot, so Teams' wait for it
///                                    asks no agent. Unreadable aborts
///
/// The relay keeps nothing of its own: the logbook has one writer, which
/// knows the relay by its user, and the relay sends it what arrives.
///
/// The bot's messaging endpoint is `https://<host>/api/messages`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:is_teams_module/is_teams_module.dart';

Future<void> main() async {
  final env = Platform.environment;
  final rawAppIds = [
    for (final s in (env['TEAMS_APP_IDS'] ?? '').split(','))
      if (s.trim().isNotEmpty) s.trim(),
  ];
  if (rawAppIds.isEmpty) {
    // Refuse to start rather than serve an endpoint that refuses everyone
    // for a reason nobody reads.
    stderr.writeln('abort: TEAMS_APP_IDS not set');
    exit(78);
  }
  final botAppIds = <BotAppId>{};
  for (final s in rawAppIds) {
    final id = BotAppId.parse(s);
    if (id == null) {
      stderr.writeln('abort: TEAMS_APP_IDS has "$s", which is not a GUID');
      exit(78);
    }
    botAppIds.add(id);
  }
  final allow = {
    for (final t in (env['TEAMS_TENANT_ALLOWLIST'] ?? '').split(','))
      if (t.trim().isNotEmpty) t.trim().toLowerCase(),
  };
  if (allow.isEmpty) {
    // Refuse to start rather than fail open: anyone in any tenant who
    // installs the bot would start journeys here. Tests that want any
    // tenant build a TeamsSourceSpec directly.
    stderr.writeln('abort: TEAMS_TENANT_ALLOWLIST not set');
    exit(78);
  }

  final rawPort = env['PORT'];
  final port = rawPort == null || rawPort.isEmpty
      ? 8087
      : int.tryParse(rawPort);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('abort: PORT "$rawPort" is not a port number');
    exit(78);
  }
  final rawHost = env['HOST'];
  final host = rawHost == null || rawHost.isEmpty ? '127.0.0.1' : rawHost;
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    stderr.writeln('abort: HOST "$host" is not an IP address');
    exit(78);
  }

  final dialogPath = env['TEAMS_SETTINGS_DIALOG'] ?? '';
  JsonObject? settingsCard;
  if (dialogPath.isNotEmpty) {
    try {
      settingsCard = JsonObject.decode(File(dialogPath).readAsStringSync());
    } on Exception catch (e) {
      stderr.writeln('abort: TEAMS_SETTINGS_DIALOG "$dialogPath": $e');
      exit(78);
    }
  }

  final logbookSocket = env['LOGBOOK_SOCKET'] ?? '';
  if (logbookSocket.isEmpty) {
    // A relay that can't record what arrives must not respond 200 to it.
    stderr.writeln('abort: LOGBOOK_SOCKET not set');
    exit(78);
  }
  // Not checked for at boot: the writer may start after the relay, and
  // until it answers, every message gets a 500 and Teams sends it again.

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final keys = BotFrameworkKeySource(
    get: (url) => _get(client, url),
    log: stderr.writeln,
  );
  // Fetch once at boot, so the first message from Teams doesn't wait on it
  // and a broken route to Microsoft shows up in the log straight away.
  if (await keys.keys() == null) {
    stderr.writeln('warning: no keys yet; requests get 503 until they arrive');
  }

  final relay = TeamsRelay(
    spec: TeamsSourceSpec(
      botAppIds: botAppIds,
      tenantAllowlist: allow,
      invokeResponses: {
        if (settingsCard case final card?)
          'composeExtension/fetchTask': teamsDialog(
            title: 'Call settings',
            card: card,
          ),
      },
    ),
    keys: keys,
    record: (body) =>
        recordEvent(logbookSocket, source: teamsEventSource, bytes: body),
  );
  final server = await HttpServer.bind(address, port);
  stdout.writeln('teams relay listening on ${address.address}:${server.port}');
  if (!address.isLoopback) {
    stderr.writeln(
      'warning: bound to ${address.address}, which serves plain HTTP; '
      'put TLS in front',
    );
  }
  await for (final req in server) {
    unawaited(relay.handle(req));
  }
}

Future<String> _get(HttpClient client, Uri url) async {
  final req = await client.getUrl(url);
  final res = await req.close().timeout(const Duration(seconds: 10));
  final body = await res
      .transform(utf8.decoder)
      .join()
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != HttpStatus.ok) {
    throw HttpException('GET $url: ${res.statusCode}', uri: url);
  }
  return body;
}
