/// A TEST bot: the relay, with a doorbell handler that answers through the
/// Bot Connector. It proves the round trip on a test tenant before any real
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
///
/// Each "card" appends a step to a [StandInJourneyPath], as a module's pass
/// would, and the card shows it: "card" again is a later pass saying the
/// same, and "card done" one saying something new. Each press writes what
/// [TeamsReceiver] reads it as to that journey path, and the log names each
/// node.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:is_annotation_shapes/is_annotation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';

/// A stand-in for what a module shows on a card: a step, the same step on
/// every pass, and a note on it that a later pass may change.
final class _Step {
  const _Step(this.name, this.note);
  @identity
  final String name;
  final _Note note;
}

final class _Note extends Value {
  const _Note(this.text);
  final String text;
}

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

  late final StandInJourneyPath journeyPath;
  final receiver = TeamsReceiver(
    sameVersion: (a, b) => journeyPath.sameVersion(a, b),
    log: stderr.writeln,
  );
  journeyPath = StandInJourneyPath(
    deliver: (id, node) {
      receiver.delivered(id, node);
      final of = switch (node) {
        Approve(:final target) ||
        Seen(:final target) => ' of ${_short(target.exact)}',
        Withdraw<Approve>(:final target) => ' of ${_short(target)}',
        _ => '',
      };
      stderr.writeln('echo: appended ${_short(id)} ${node.runtimeType}$of');
    },
    encodeOther: (node) => switch (node) {
      _Step(:final name, :final note) => {
        'shape': 'Step',
        'name': name,
        'note': note.text,
      },
      _ => throw ArgumentError.value(node, 'node', 'no encoding'),
    },
  );
  final echo = (
    connector: connector,
    receiver: receiver,
    journeyPath: journeyPath,
  );

  final relay = TeamsRelay(
    spec: TeamsSourceSpec(appId: appId, tenantAllowlist: {tenantId}),
    keys: keys,
    onDoorbell: (bell) => _answer(echo, bell),
  );
  final server = await HttpServer.bind(address, port);
  stdout.writeln('teams echo listening on ${address.address}:${server.port}');
  await for (final req in server) {
    unawaited(relay.handle(req));
  }
}

typedef _Echo = ({
  BotConnector connector,
  TeamsReceiver receiver,
  StandInJourneyPath journeyPath,
});

/// What each card shows, by its activity id, to draw it again when edited.
final _steps = <String, _Step>{};

Future<void> _answer(_Echo echo, JsonObject bell) async {
  final connector = echo.connector;
  final serviceUrl = Uri.parse(bell.string('service_url'));
  final conversation = bell.string('conversation');
  final activity = bell.string('activity');
  stderr.writeln('echo: ${bell.string('event')} in $conversation');
  try {
    switch (bell.string('event')) {
      case 'teams_message':
        final said = _plain(bell.stringOrNull('text') ?? '');
        if (said.toLowerCase().split(' ') case ['card', ...final note]) {
          final step = _Step(
            'Step 3: tidy the README',
            _Note(note.isEmpty ? 'as planned' : note.join(' ')),
          );
          final target = Target(
            exact: echo.journeyPath.append(step),
            anchor: SemanticAnchor.of(utf8.encode('Step:${step.name}')),
          );
          // A later pass that says the same arrives already approved.
          final by = teamsActor(bell);
          final stance = by == null
              ? Stance.open
              : echo.receiver.stanceOf(by, target.exact);
          final id = await connector.send(serviceUrl, conversation, {
            'type': 'message',
            'attachments': [_card(step, stance: stance)],
          });
          _steps[id] = step;
          echo.receiver.show(id, target, conversation: conversation);
          stderr.writeln(
            'echo: card $id shows ${_short(target.exact)}, ${stance.name}',
          );
        } else {
          await connector.reply(serviceUrl, conversation, activity, {
            'type': 'message',
            'text': 'echo: $said',
          });
        }
      case 'teams_card_action':
        final verb = bell.object('value').object('action').stringOrNull('verb');
        echo.receiver.read(bell).inOrder.forEach(echo.journeyPath.append);
        final by = teamsActor(bell);
        if (by == null) return;
        // The card's own id: what the button was pressed on. Edit reopens
        // the choice on that card alone; any other press may change what
        // every card showing the same version says.
        final card = bell.string('reply_to');
        final like = echo.receiver.cardsLike(card, conversation: conversation);
        final editing = verb == 'edit';
        for (final other in editing ? like.where((c) => c == card) : like) {
          final step = _steps[other];
          final target = echo.receiver.targetOf(other);
          if (step == null || target == null) continue;
          final stance = echo.receiver.stanceOf(by, target.exact);
          await connector.update(serviceUrl, conversation, other, {
            'type': 'message',
            'attachments': [_card(step, stance: stance, editing: editing)],
          });
          stderr.writeln('echo: card $other edited, ${stance.name}');
        }
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

/// The first eight hex digits of [id], enough to tell nodes apart in a log.
String _short(TurnId id) => id.hex.substring(0, 8);

/// The card for [step], as the presser's annotations of its version add up
/// ([stance]), and the actions that make sense from there (Nick,
/// 2026-11-10). Approved offers only Edit, which writes nothing and reopens
/// the choice on that card ([editing]); open, reopened or held off offers
/// Approve and Not yet.
Map<String, Object?> _card(
  _Step step, {
  required Stance stance,
  bool editing = false,
}) => {
  'contentType': 'application/vnd.microsoft.card.adaptive',
  'content': {
    r'$schema': 'http://adaptivecards.io/schemas/adaptive-card.json',
    'type': 'AdaptiveCard',
    'version': '1.5',
    'body': [
      {
        'type': 'TextBlock',
        'text': step.name,
        'weight': 'Bolder',
        'wrap': true,
      },
      {'type': 'TextBlock', 'text': 'Note: ${step.note.text}', 'wrap': true},
      if (!editing && stance != Stance.open)
        {
          'type': 'TextBlock',
          'text': stance == Stance.approved ? 'Approved.' : 'Not yet: noted.',
          'wrap': true,
          'isSubtle': true,
        },
    ],
    'actions': [
      for (final (verb, title)
          in stance == Stance.approved && !editing
              ? [('edit', 'Edit')]
              : [('approve', 'Approve'), ('notyet', 'Not yet')])
        {'type': 'Action.Execute', 'title': title, 'verb': verb},
    ],
  },
};
