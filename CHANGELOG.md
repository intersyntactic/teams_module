# Changelog

Each version is tagged `vX.Y.Z` on main, and the services that use this
package pin that tag.

## 0.0.3

- "The record" is "the logbook" throughout: prose, doc comments, the
  relay's 500 text (`refused by the logbook: <why>`), the live test (now
  `logbook_live_test.dart`, run with `LOGBOOK_LIVE*`), and the relay's
  socket variable. The verb "record" (recordEvent, Recorded, RecordRefused,
  ...) is unchanged.
- The relay reads its logbook socket from `LOGBOOK_SOCKET`, and from its
  older name `JOURNAL_SOCKET` when that is unset.

## 0.0.2

- The readings come from `is_admission_vocabulary` 0.1.0, not
  `is_docking_station`: the same types and wire, in a package that holds
  no service.
- `teamsConversationPathPrefix(serviceUrl, conversation)`: the path every
  request to a conversation starts with, `<region>/v3/conversations/<id>/`,
  with the id percent-encoded and escapes in upper case. The requests are
  built with it, and so is any rule granting a conversation's path, so the
  two can't spell the id differently.

## 0.0.1

- Every reading names the bot it was sent to, as `addressedTo`.
- A "Close trajectory" message action, read as
  `PersonAskedToCloseTrajectory`.
- The requests answering events: replies as Adaptive Cards with a context
  footer, split to fit, and the trajectory-open card.
- One relay serves a pool of bots.
