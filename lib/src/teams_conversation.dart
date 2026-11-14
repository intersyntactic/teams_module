/// Where a Teams conversation is reached: offered to the journey path the
/// first time the bot hears from it, and again whenever Teams moves it, so
/// a module that restarts reads it back with everything else.
final class TeamsConversation {
  const TeamsConversation({required this.id, required this.serviceUrl});

  /// The Bot Framework conversation id.
  final String id;

  /// The Bot Connector endpoint for the conversation's region.
  final Uri serviceUrl;
}
