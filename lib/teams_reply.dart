/// teams-reply alone: the renderer that follows the record, and only what
/// it uses. Its source id names the files its build reads, so it imports
/// none of the module's way in (no signature checking, no Bot Connector):
/// whoever checks a rendered post reads only the code that could have
/// rendered it.
library;

export 'src/journal_reader.dart';
export 'src/record_event.dart';
export 'src/teams_reply.dart';
