/// The Teams module: Peter's replies, approvals and corrections from
/// Microsoft Teams, taken in as nodes on a line
/// (https://github.com/enspyrco/intersyntactic/issues/1089).
///
/// So far, the gate every inbound delivery passes first: [teamsGate], with
/// the key set it checks signatures against, [BotFrameworkKeys].
library;

export 'src/bot_framework_keys.dart';
export 'src/teams_gate.dart';
