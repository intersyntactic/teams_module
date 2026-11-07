/// The Teams module: Peter's replies, approvals and corrections from
/// Microsoft Teams, taken in as nodes on a line
/// (https://github.com/enspyrco/intersyntactic/issues/1089).
///
/// So far, the way in: [TeamsShim], the endpoint Teams posts to; [teamsGate],
/// which every delivery passes first; and the keys it checks signatures
/// against, [BotFrameworkKeys], fetched by [BotFrameworkKeySource].
library;

export 'src/bot_framework_keys.dart';
export 'src/key_source.dart';
export 'src/teams_gate.dart';
export 'src/teams_shim.dart';
