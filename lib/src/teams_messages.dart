import 'package:checked_json/checked_json.dart';
import 'package:is_agent_shapes/is_agent_shapes.dart';
import 'package:is_shapes/is_shapes.dart';

import 'teams_post.dart';
import 'teams_receiver.dart' show teamsActor;

/// Where something was said in Teams: what a reply needs to go back there.
typedef _Origin = ({Uri serviceUrl, String conversation, String activity});

/// What people say to the bot in Teams, written as [UserSaid], and the
/// [ReplyText]s that answer them, described as [TeamsPost]s.
///
/// It never sends. What it offers goes to [append], the journey path; what
/// would leave goes to [post], which hands it to the airlock. Where a reply
/// goes is read from what it [ReplyText.answers], so a reply never lands in
/// whichever chat spoke last.
final class TeamsMessages {
  TeamsMessages({required this.append, required this.post, required this.log});

  /// Appends a node to the journey path and returns its id.
  final TurnId Function(Object node) append;

  /// A post for the airlock to decide.
  final void Function(TeamsPost post) post;

  final void Function(String) log;

  final _origins = <TurnId, _Origin>{};

  /// What was said and where, by the very node, while its append runs: the
  /// journey path can deliver it, and an agent answer it, before append
  /// returns its id.
  final _saying = Map<UserSaid, _Origin>.identity();

  /// Writes a `teams_message` doorbell as [UserSaid] and returns its id.
  /// Null for any other doorbell, one with no sender Teams names, or one
  /// with no words.
  TurnId? said(JsonObject bell) {
    if (bell.stringOrNull('event') != 'teams_message') return null;
    final author = teamsActor(bell);
    if (author == null) {
      log('teams messages: a message with no tenant or Entra user');
      return null;
    }
    final text = _plain(bell.stringOrNull('text') ?? '');
    if (text.isEmpty) return null;
    final activity = bell.string('activity');
    final source = SourceMessageId.parse(activity);
    if (source == null) {
      log('teams messages: a message whose activity id is "$activity"');
      return null;
    }
    final node = UserSaid(author: author, source: source, text: text);
    _saying[node] = (
      serviceUrl: Uri.parse(bell.string('service_url')),
      conversation: bell.string('conversation'),
      activity: activity,
    );
    final id = append(node);
    if (_saying.remove(node) case final origin?) _origins[id] = origin;
    return id;
  }

  /// A node the journey path delivers: a [UserSaid] of ours is noted by its
  /// id, and a [ReplyText] to one becomes a post under it.
  void delivered(TurnId id, Object node) {
    switch (node) {
      case UserSaid():
        if (_saying.remove(node) case final origin?) _origins[id] = origin;
      case ReplyText(:final answers, :final text):
        final origin = _origins[answers];
        if (origin == null) return; // Said somewhere other than Teams.
        post(
          TeamsPost(
            serviceUrl: origin.serviceUrl,
            conversation: origin.conversation,
            replyToId: origin.activity,
            activity: {'type': 'message', 'text': text},
          ),
        );
    }
  }

  /// Text without Teams' `<at>…</at>` mentions and quote tags.
  static String _plain(String text) => text
      .replaceAll(RegExp(r'<at>[^<]*</at>'), '')
      .replaceAll(RegExp(r'<quoted[^>]*/>'), '')
      .trim();
}
