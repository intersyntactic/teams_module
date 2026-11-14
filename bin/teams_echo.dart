/// A TEST bot: the relay, with an event handler that responds through the
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
/// Hand the secret over from wherever you keep secrets rather than typing
/// it, so it never touches a shell history.
///
/// In Teams: say anything and it echoes; say "card" and it sends a card
/// with Approve and Not yet; press one and the card is edited to say so.
/// Adding the bot to a chat gets a hello, sent without being asked.
///
/// Each "card" appends an example to a [StandInJourneyPath], as a module's pass
/// would, and the card shows it: "card" again is a later pass saying the
/// same, and "card done" one saying something new. Each press writes what
/// [TeamsReceiver] reads it as to that journey path, and the log names each
/// node.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_annotation_shapes/is_annotation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';

/// An example of what a module shows on a card: its key, the same on every
/// pass, and wording that a later pass may change.
final class _Example {
  const _Example(this.key, this.wording);
  @identity
  final String key;
  final _Wording wording;
}

final class _Wording extends Value {
  const _Wording(this.text);
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
        Approval(:final target) ||
        Seen(:final target) => ' of ${_short(target.exact)}',
        Withdrawal<Approval>(:final target) => ' of ${_short(target)}',
        _ => '',
      };
      stderr.writeln('echo: appended ${_short(id)} ${node.runtimeType}$of');
    },
    encodeOther: (node) => switch (node) {
      _Example(:final key, :final wording) => {
        'shape': 'Example',
        'key': key,
        'wording': wording.text,
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
    onEvent: (event) => _respond(echo, event),
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
final _examples = <String, _Example>{};

Future<void> _respond(_Echo echo, TeamsEvent event) async {
  final connector = echo.connector;
  final serviceUrl = event.serviceUrl;
  final conversation = event.conversation;
  stderr.writeln('echo: ${event.runtimeType} in $conversation');
  try {
    switch (event) {
      case TeamsMessage(:final text):
        final said = _plain(text ?? '');
        if (said.toLowerCase().split(' ') case ['card', ...final words]) {
          final example = _Example(
            'Example 3: tidy the README',
            _Wording(words.isEmpty ? 'as planned' : words.join(' ')),
          );
          final target = Target(
            exact: echo.journeyPath.append(example),
            anchor: SemanticAnchor.of(utf8.encode('Example:${example.key}')),
          );
          // A later pass that says the same arrives already approved.
          final by = event.actor;
          final stance = by == null
              ? Stance.open
              : echo.receiver.stanceOf(by, target.exact);
          final id = await connector.send(serviceUrl, conversation, {
            'type': 'message',
            'attachments': [_card(example, stance: stance)],
          });
          _examples[id] = example;
          echo.receiver.show(id, target, conversation: conversation);
          stderr.writeln(
            'echo: card $id shows ${_short(target.exact)}, ${stance.name}',
          );
        } else {
          await connector.reply(serviceUrl, conversation, event.id, {
            'type': 'message',
            'text': 'echo: $said',
          });
        }
      case TeamsCardAction(:final verb, :final card?):
        echo.receiver.read(event).inOrder.forEach(echo.journeyPath.append);
        final by = event.actor;
        if (by == null) return;
        // The card's own id: what the button was pressed on. Edit reopens
        // the choice on that card alone; any other press may change what
        // every card showing the same version says.
        final like = echo.receiver.cardsLike(card, conversation: conversation);
        final editing = verb == 'edit';
        for (final other in editing ? like.where((c) => c == card) : like) {
          final example = _examples[other];
          final target = echo.receiver.targetOf(other);
          if (example == null || target == null) continue;
          final stance = echo.receiver.stanceOf(by, target.exact);
          await connector.update(serviceUrl, conversation, other, {
            'type': 'message',
            'attachments': [_card(example, stance: stance, editing: editing)],
          });
          stderr.writeln('echo: card $other edited, ${stance.name}');
        }
      case TeamsInstallationUpdate(:final action) when action != 'remove':
        await _hello(connector, serviceUrl, conversation);
      case TeamsConversationUpdate(:final added, :final recipient)
          when added.contains(recipient):
        await _hello(connector, serviceUrl, conversation);
      default:
    }
  } on BotConnectorException catch (e) {
    stderr.writeln('echo: $e');
  }
}

Future<void> _hello(
  BotConnector connector,
  Uri serviceUrl,
  String conversation,
) => connector.send(serviceUrl, conversation, {
  'type': 'message',
  'text':
      'Hello: this is a test bot. Say anything and I echo it; '
      'say "card" for a card with buttons.',
});

/// Text with Teams' `<at>…</at>` mention markup and quote tags taken out.
String _plain(String text) => text
    .replaceAll(RegExp(r'<at>[^<]*</at>'), '')
    .replaceAll(RegExp(r'<quoted[^>]*/>'), '')
    .trim();

/// The first eight hex digits of [id], enough to tell nodes apart in a log.
String _short(TurnId id) => id.hex.substring(0, 8);

/// The card for [example], as the presser's annotations of its version add up
/// ([stance]), and the actions that make sense from there (Nick,
/// 2026-11-10). Approved offers only Edit, which writes nothing and reopens
/// the choice on that card ([editing]); open, reopened or held off offers
/// Approve and Not yet.
Map<String, Object?> _card(
  _Example example, {
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
        'text': example.key,
        'weight': 'Bolder',
        'wrap': true,
      },
      {
        'type': 'TextBlock',
        'text': 'Wording: ${example.wording.text}',
        'wrap': true,
      },
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
