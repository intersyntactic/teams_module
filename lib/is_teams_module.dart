/// The Teams module: what people say and press in Microsoft Teams, taken in
/// as nodes on a trajectory, and the way back out to them.
///
/// The way in: [TeamsDeliveryCheck], the Teams check is_relay's
/// `RelayServer` runs on every delivery before recording it; [teamsGate],
/// the checks it makes; and the keys it checks signatures against,
/// [BotFrameworkKeys], fetched by [BotFrameworkKeySource]; and
/// [teamsRecordedEvent], which reads a recorded body back into
/// the same event, for whatever reads the logbook; and
/// [TeamsEventTranslator], which translates each recorded event into the
/// docking station's terms. Translators bring things in; drawings take
/// things out. The way out: [drawTeamsReply], the Teams drawing of a reply,
/// and [TeamsReplyRequests], the requests that post it and what each one
/// posted, for the airlock to grant and sign; and [teamsPostRequest] and
/// [teamsUpdateRequest], which describe a message as a request for a web
/// driver to sign and send. The module holds no bot secret and sends
/// nothing itself.
library;

export 'src/bot_framework_keys.dart';
export 'src/key_source.dart';
export 'src/teams_delivery_check.dart';
export 'src/teams_event.dart';
export 'src/teams_event_translator.dart';
export 'src/teams_gate.dart';
export 'src/teams_ids.dart';
export 'src/teams_post.dart';
export 'src/teams_reply.dart';
export 'src/teams_reply_requests.dart';
export 'src/teams_requests.dart';
