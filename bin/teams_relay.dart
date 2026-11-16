/// Run behind TLS (a reverse proxy): Teams posts only to https. The relay
/// holds no Microsoft secret, only the bot's app id, which the bot's own
/// manifest prints.
///
///   TEAMS_APP_ID=...                 the bot's Microsoft app id: the
///                                    audience every token must name
///   TEAMS_TENANT_ALLOWLIST=t1,t2     tenants whose activities are taken;
///                                    empty is "any correctly signed tenant"
///                                    and should only be used in tests
///   PORT=8087                        optional; a non-port aborts
///   HOST=127.0.0.1                   optional; the address to bind. The
///                                    default is loopback, for a proxy on
///                                    the same machine.
///   JOURNAL_SOCKET=/run/...sock      the record's writer's Unix socket:
///                                    every accepted request's body is
///                                    recorded through it as an `arrived`
///                                    entry, byte for byte, before Teams
///                                    gets a response. Required.
///
/// The relay keeps no record of its own: the record has one writer, which
/// knows the relay by its user, and the relay sends it what arrives.
///
/// The bot's messaging endpoint is `https://<host>/api/messages`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_teams_module/is_teams_module.dart';

/// The source the relay's events are recorded under: the same as before,
/// so old and new events read alike.
const _source = 'teams';

Future<void> main() async {
  final env = Platform.environment;
  final appId = env['TEAMS_APP_ID'] ?? '';
  if (appId.isEmpty) {
    // Refuse to start rather than serve an endpoint that refuses everyone
    // for a reason nobody reads.
    stderr.writeln('abort: TEAMS_APP_ID not set');
    exit(78);
  }
  final allow = {
    for (final t in (env['TEAMS_TENANT_ALLOWLIST'] ?? '').split(','))
      if (t.trim().isNotEmpty) t.trim().toLowerCase(),
  };
  if (allow.isEmpty) {
    stderr.writeln(
      'warning: TEAMS_TENANT_ALLOWLIST is empty; any correctly signed '
      'tenant will be accepted',
    );
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

  final record = env['JOURNAL_SOCKET'] ?? '';
  if (record.isEmpty) {
    // A relay that can't record what arrives must not respond 200 to it.
    stderr.writeln('abort: JOURNAL_SOCKET not set');
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
    spec: TeamsSourceSpec(appId: appId, tenantAllowlist: allow),
    keys: keys,
    record: (body) => recordEvent(record, source: _source, bytes: body),
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
