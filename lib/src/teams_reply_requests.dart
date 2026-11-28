/// The requests that post a reply in a Teams conversation, and what each
/// one posted, for the airlock to grant, sign and send.
library;

import 'dart:convert';

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart' show WritesReplyRequests;
import 'package:is_outcome_vocabulary/is_outcome_vocabulary.dart'
    show NothingRan, Outcome, Ran, StoppedPartway;
import 'package:is_web_request_vocabulary/is_web_request_vocabulary.dart'
    show
        BodyToKeep,
        BytesBody,
        Method,
        NoBody,
        ProposedRequest,
        TextBody,
        WebResponse;
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show RepliesUnderWebAddress, ReplyContent, ServerAssignedMessageId;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show WebPath;

import 'teams_reply.dart';

/// Teams' writer of reply requests: each message of the reply as
/// [drawTeamsReply] draws it, at most [teamsReplyMaxMessages], posted to the
/// Bot Connector as `POST {prefix}activities`, where the prefix is the
/// conversation's as the logbook recorded it. Pure: no sign-in, no I/O.
final class TeamsReplyRequests
    implements WritesReplyRequests<RepliesUnderWebAddress> {
  const TeamsReplyRequests();

  @override
  List<ProposedRequest> draw(
    RepliesUnderWebAddress to,
    TrajectoryId trajectory,
    ReplyContent content,
  ) {
    final path = WebPath.parse('${to.prefix.pathPrefix.value}activities');
    if (path == null || !to.admitsAddress(to.prefix.origin, path)) {
      throw ArgumentError.value(to, 'to', 'has no path for activities');
    }
    return [
      for (final activity in drawTeamsReply(
        content.text.value,
        trajectory: trajectory,
        footer: content.footer?.value,
        maxMessages: teamsReplyMaxMessages,
      ))
        ProposedRequest(
          to.prefix.origin,
          method: Method.post,
          path: path,
          headers: const {'content-type': 'application/json; charset=utf-8'},
          body: jsonEncode(activity),
          // The Bot Connector answers `{"id": "<the message's id>"}`.
          keep: BodyToKeep.text,
        ),
    ];
  }

  @override
  Outcome<ServerAssignedMessageId> posted(WebResponse response) {
    final status = response.status;
    if (status >= 400 && status < 500) {
      return NothingRan(
        'Teams refused the message, HTTP $status'
        '${response.refusedBecause == null ? '' : ': ${response.refusedBecause}'}',
      );
    }
    if (status < 200 || status >= 300) {
      return StoppedPartway(
        why: 'Teams answered HTTP $status; the message may have posted',
        done: null,
      );
    }
    final id = switch (response.body) {
      TextBody(:final text) => _idIn(text),
      NoBody() || BytesBody() => null,
    };
    return id == null
        ? const StoppedPartway(
            why: 'Teams answered 2xx with no message id; it may have posted',
            done: null,
          )
        : Ran(id);
  }
}

/// The `id` of the Bot Connector's `{"id": ...}` answer, or null.
ServerAssignedMessageId? _idIn(String body) {
  try {
    return ServerAssignedMessageId.parse(JsonObject.decode(body).string('id'));
  } on FormatException {
    return null;
  }
}
