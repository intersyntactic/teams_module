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
///   AGENT_HOST=http://127.0.0.1:8899   where the agent host listens: the
///                           one the app is connected to, which sends it
///                           the model credentials it uses
///   PORT=8087, HOST=127.0.0.1 as for the relay
///   TRACE=1                 also logs each event the host sends (but its
///                           deltas) and each post to a stream, with what
///                           Teams answered
///
///   env-run ENS_TEAMS_APP_ID:TEAMS_APP_ID \
///     ENS_TEAMS_APP_SECRET:TEAMS_APP_SECRET \
///     ENS_TEAMS_TENANT_ID:TEAMS_TENANT_ID -- dart run bin/teams_journey.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:intersyntactic_protocol/intersyntactic_protocol.dart'
    show
        JourneyPathId,
        LoggedEvent,
        ReplyText,
        RepoChoice,
        RunSummary,
        StartRun;
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
  final host = Uri.parse(env['AGENT_HOST'] ?? 'http://127.0.0.1:8899');
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

  final trace = env['TRACE'] == '1';
  final Journeys journeys = AgentHostClient(host);
  final bridge = JourneyBridge(
    journeys: trace ? _Traced(journeys) : journeys,
    owner: owner,
    send: connector.send,
    post: trace ? _tracedPost(connector.post) : connector.post,
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

/// [post], logging what each post to a stream was and what Teams answered.
Future<String?> Function(Uri, String, Map<String, Object?>) _tracedPost(
  Future<String?> Function(Uri, String, Map<String, Object?>) post,
) => (url, conversation, activity) async {
  final info = (activity['entities'] as List<Object?>?)?.firstOrNull;
  final text = '${activity['text'] ?? ''}'.replaceAll('\n', ' ');
  final what =
      '${activity['type']} to ${activity['replyToId']} $info '
      '"${text.length > 60 ? '${text.substring(0, 60)}…' : text}"';
  try {
    final id = await post(url, conversation, activity);
    stderr.writeln('trace: post $what: $id');
    return id;
  } catch (e) {
    stderr.writeln('trace: post $what: $e');
    rethrow;
  }
};

/// [Journeys], logging each connection to a journey's events and each event
/// but the reply's deltas.
final class _Traced implements Journeys {
  _Traced(this._inner);

  final Journeys _inner;

  @override
  Future<List<RunSummary>> list() => _inner.list();

  @override
  Future<String?> say(JourneyPathId journey, String text) async {
    final why = await _inner.say(journey, text);
    stderr.writeln('trace: say: ${why ?? 'taken'}');
    return why;
  }

  @override
  Future<String?> stop(JourneyPathId journey) => _inner.stop(journey);

  @override
  Future<List<RepoChoice>> repos() => _inner.repos();

  @override
  Future<({RunSummary? started, String? why})> start(StartRun run) async {
    final r = await _inner.start(run);
    stderr.writeln('trace: start: ${r.started?.id.value ?? r.why}');
    return r;
  }

  @override
  Stream<LoggedEvent> events(
    JourneyPathId journey, {
    required int after,
    required DateTime? afterAt,
  }) {
    stderr.writeln('trace: events of ${journey.value} after $after ($afterAt)');
    return _inner
        .events(journey, after: after, afterAt: afterAt)
        .map((e) {
          if (e.event is! ReplyText) {
            stderr.writeln('trace: event ${e.seq} ${e.event.runtimeType}');
          }
          return e;
        })
        // Logged, and not handled: the error goes on to the bridge.
        .handleError(
          (_) {},
          test: (e) {
            stderr.writeln('trace: events: $e');
            return false;
          },
        );
  }
}
