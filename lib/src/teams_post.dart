/// A message for a Teams conversation, described and not sent: the airlock
/// decides it by the journey path's rule for that conversation, and a driver
/// that holds the bot's secret ([BotConnector]) sends it. A stand-in for the
/// effect description effects-98 is shaping (enspyrco/intersyntactic#1090).
final class TeamsPost {
  const TeamsPost({
    required this.serviceUrl,
    required this.conversation,
    required this.activity,
    this.replyToId,
  });

  /// The Bot Connector endpoint for the conversation's region, from the
  /// activity that started it.
  final Uri serviceUrl;
  final String conversation;

  /// The message it answers, so Teams shows the reply under it.
  final String? replyToId;

  /// The Bot Framework activity to send.
  final Map<String, Object?> activity;
}
