/// The Teams module: what people say and press in Microsoft Teams, taken in
/// as nodes on a trajectory, and the way back out to them.
///
/// The way in: [TeamsRelay], the endpoint Teams posts to; [teamsGate],
/// which every delivery passes first; and the keys it checks signatures
/// against, [BotFrameworkKeys], fetched by [BotFrameworkKeySource]; and
/// [recordEvent], which records each accepted body with the logbook's one
/// writer; and [teamsRecordedEvent], which reads a recorded body back into
/// the same event, for whatever reads the logbook; and
/// [TeamsEventTranslator], which translates each recorded event into the
/// docking station's terms. And the way out: [translateTeamsReply], which
/// translates a reply into Teams' terms and which the
/// `teams-reply-translator` program prints, and [teamsPostRequest] and
/// [teamsUpdateRequest], which describe a message as a request for a web
/// driver to sign and send. The module holds no bot secret and sends
/// nothing itself.
library;

export 'src/bot_framework_keys.dart';
export 'src/key_source.dart';
export 'src/record_event.dart';
export 'src/teams_event.dart';
export 'src/teams_event_translator.dart';
export 'src/teams_gate.dart';
export 'src/teams_ids.dart';
export 'src/teams_post.dart';
export 'src/teams_reply.dart';
export 'src/teams_requests.dart';
export 'src/teams_relay.dart';
