/// The Teams module: Peter's replies, approvals and corrections from
/// Microsoft Teams, taken in as nodes on a journey path
/// (https://github.com/enspyrco/intersyntactic/issues/1089).
///
/// So far, the way in: [TeamsRelay], the endpoint Teams posts to; [teamsGate],
/// which every delivery passes first; and the keys it checks signatures
/// against, [BotFrameworkKeys], fetched by [BotFrameworkKeySource]. Then
/// [TeamsReceiver], which reads each doorbell as the annotation shapes it
/// writes, and a [StandInJourneyPath] to write them to until the module meets
/// a real journey path. And the way out: [BotConnector], which holds the bot's
/// secret and speaks as it.
library;

export 'src/bot_connector.dart';
export 'src/bot_framework_keys.dart';
export 'src/key_source.dart';
export 'src/stand_in_journey_path.dart';
export 'src/teams_gate.dart';
export 'src/teams_receiver.dart';
export 'src/teams_relay.dart';
