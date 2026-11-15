/// The Teams module: what people say and press in Microsoft Teams, taken in
/// as nodes on a journey path, and the way back out to them.
///
/// So far, the way in: [TeamsRelay], the endpoint Teams posts to; [teamsGate],
/// which every delivery passes first; and the keys it checks signatures
/// against, [BotFrameworkKeys], fetched by [BotFrameworkKeySource]; and
/// [teamsWitnessedEvent], which reads a body the relay witnessed back into
/// the same event, for whatever reads the airlock's journal. Then
/// [TeamsReceiver], which reads each event as the annotation shapes it
/// writes, and a [StandInJourneyPath] to write them to until the module meets
/// a real journey path; and [TeamsTranslator], which turns a Teams message
/// into a `UserSaid` and the agent's `ReplyText` into a [TeamsPost]. And the
/// way out: [BotConnector], which holds the bot's secret and speaks as it.
library;

export 'src/bot_connector.dart';
export 'src/bot_framework_keys.dart';
export 'src/key_source.dart';
export 'src/stand_in_journey_path.dart';
export 'src/teams_event.dart';
export 'src/teams_gate.dart';
export 'src/teams_conversation.dart';
export 'src/teams_translator.dart';
export 'src/teams_post.dart';
export 'src/teams_receiver.dart';
export 'src/teams_relay.dart';
