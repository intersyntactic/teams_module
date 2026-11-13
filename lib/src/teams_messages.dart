import 'package:checked_json/checked_json.dart';
import 'package:is_agent_shapes/is_agent_shapes.dart';
import 'package:is_shapes/is_shapes.dart';

import 'teams_post.dart';
import 'teams_receiver.dart' show teamsActor;

/// A Teams message by where it was said: an activity id names a message only
/// within its conversation.
typedef _Where = ({String conversation, String activity});

/// What people say to the bot in Teams, read as [UserSaid], and the
/// [ReplyText]s that answer them, described as [TeamsPost]s.
///
/// It describes and never acts: what [said] returns is for the journey path
/// to append, and what [answer] returns is for the airlock to decide. Where
/// a reply goes is read from what it [ReplyText.answers], so a reply never
/// lands in whichever chat spoke last.
///
/// The journey path delivers to it in the order it appends, so a [UserSaid]
/// reaches [heard] before any [ReplyText] to it reaches [answer].
final class TeamsMessages {
  TeamsMessages({required this.log});

  final void Function(String) log;

  /// The Bot Connector endpoint for each conversation, from its doorbells.
  final _serviceUrls = <String, Uri>{};

  /// Where each [UserSaid] heard here was said, by its id.
  final _heard = <TurnId, _Where>{};

  /// A `teams_message` doorbell as [UserSaid]. Null for any other doorbell,
  /// one with no sender Teams names, or one with no words.
  ///
  /// Its [UserSaid.source] is the conversation and the activity, which
  /// together name one Teams message.
  UserSaid? said(JsonObject bell) {
    if (bell.stringOrNull('event') != 'teams_message') return null;
    final author = teamsActor(bell);
    if (author == null) {
      log('teams messages: a message with no tenant or Entra user');
      return null;
    }
    final text = _plain(bell.stringOrNull('text') ?? '');
    if (text.isEmpty) return null;
    final conversation = bell.string('conversation');
    final activity = bell.string('activity');
    final source = SourceMessageId.parse(_source(conversation, activity));
    if (source == null) {
      log('teams messages: a message from "$conversation" "$activity"');
      return null;
    }
    _serviceUrls[conversation] = Uri.parse(bell.string('service_url'));
    return UserSaid(author: author, source: source, text: text);
  }

  /// Notes [id] as [said], if it was said in a Teams conversation this
  /// module has heard from.
  void heard(TurnId id, UserSaid said) {
    final where = _where(said.source);
    if (where != null && _serviceUrls.containsKey(where.conversation)) {
      _heard[id] = where;
    }
  }

  /// [reply] as a post under what it answers. Null when that was said
  /// somewhere other than Teams.
  TeamsPost? answer(ReplyText reply) {
    final where = _heard[reply.answers];
    if (where == null) return null;
    return TeamsPost(
      serviceUrl: _serviceUrls[where.conversation]!,
      conversation: where.conversation,
      replyToId: where.activity,
      activity: {'type': 'message', 'text': reply.text},
    );
  }

  /// A Teams message's source id: its conversation, then `|` and its
  /// activity. It is split at the last `|`, so only the activity id has to
  /// be free of one; Teams' are the millisecond they were sent, in digits,
  /// which is also why one alone can name two messages in two chats.
  static String _source(String conversation, String activity) =>
      '$conversation|$activity';

  static _Where? _where(SourceMessageId source) {
    final s = source.value;
    final bar = s.lastIndexOf('|');
    if (bar <= 0 || bar == s.length - 1) return null;
    return (conversation: s.substring(0, bar), activity: s.substring(bar + 1));
  }

  /// Text without Teams' `<at>…</at>` mentions and quote tags.
  static String _plain(String text) => text
      .replaceAll(RegExp(r'<at>[^<]*</at>'), '')
      .replaceAll(RegExp(r'<quoted[^>]*/>'), '')
      .trim();
}
