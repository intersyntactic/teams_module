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
///   TEAMS_JOURNAL_DIR=/var/lib/...   the airlock's journal: every accepted
///                                    request's body is witnessed there,
///                                    byte for byte, before Teams gets a
///                                    response. Required.
///
/// Run it from source (`dart run`), not as a compiled executable: the
/// journal names the code that writes each entry by hashing its own source,
/// and refuses to open without it, so a compiled relay won't start.
///
/// The bot's messaging endpoint is `https://<host>/api/messages`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_teams_module/is_teams_module.dart';

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

  final journalDir = env['TEAMS_JOURNAL_DIR'] ?? '';
  if (journalDir.isEmpty) {
    // A relay that can't record what arrives must not respond 200 to it.
    stderr.writeln('abort: TEAMS_JOURNAL_DIR not set');
    exit(78);
  }
  final Journal? journal;
  try {
    journal = Journal.open(Directory(journalDir));
  } on Exception catch (e) {
    stderr.writeln('abort: journal at $journalDir: $e');
    exit(73);
  }
  if (journal == null) {
    stderr.writeln(
      'abort: the journal cannot name its own code, as in a compiled build; '
      'run the relay from source with dart run',
    );
    exit(78);
  }
  // Give up the journal's claim on its folder when told to stop, so the next
  // start can take it: in a container the relay is the same pid every time,
  // and a claim left behind would refuse it. A kill that can't be caught
  // still leaves one; the abort then names the file to delete.
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      journal!.close();
      exit(0);
    });
  }
  // The relay only witnesses: it hands the airlock no run, so nothing is
  // decided here, and anything that asked would be refused.
  final airlock = RecordedAirlock<Object?>(
    journal,
    decide: (_, _) =>
        const Deny('the Teams relay decides nothing', by: DecidedBy.rules),
    narrows: (_, _) => false,
  );
  final teams = ArrivalSource.parse('teams')!;

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
    witness: (body) => airlock.witness(body, source: teams),
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
