/// The Teams module: what people say and press in Microsoft Teams, taken in
/// as nodes on a trajectory, and the way back out to them.
///
/// So far, the way in: [TeamsRelay], the endpoint Teams posts to; [teamsGate],
/// which every delivery passes first; and the keys it checks signatures
/// against, [BotFrameworkKeys], fetched by [BotFrameworkKeySource]; and
/// [recordEvent], which records each accepted body with the record's one
/// writer; and [teamsRecordedEvent], which reads a recorded body back into
/// the same event, for whatever reads the record; and [TeamsReading], which
/// tells the docking station what each recorded event is. Then
/// [TeamsReceiver], which reads each event as the annotation shapes it
/// writes, and a [StandInTrajectory] to write them to until the module meets
/// a real trajectory; and [TeamsTranslator], which turns a Teams message
/// into a `UserSaid` and the agent's `ReplyText` into a [TeamsPost]. And the
/// way out: [teamsPostRequest] and [teamsUpdateRequest], which describe a
/// message as a request for a web driver to sign and send. The module holds
/// no bot secret and sends nothing itself.
library;

export 'src/bot_framework_keys.dart';
export 'src/key_source.dart';
export 'src/record_event.dart';
export 'src/stand_in_trajectory.dart';
export 'src/teams_event.dart';
export 'src/teams_gate.dart';
export 'src/teams_ids.dart';
export 'src/teams_authors.dart';
export 'src/teams_conversation.dart';
export 'src/teams_translator.dart';
export 'src/teams_post.dart';
export 'src/teams_reading.dart';
export 'src/teams_reply.dart';
export 'src/teams_requests.dart';
export 'src/teams_receiver.dart';
export 'src/teams_relay.dart';
