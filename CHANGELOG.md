# Changelog

Each version is tagged `vX.Y.Z` on main, and the services that use this
package pin that tag.

## 0.0.5

- is_docking_station_api 0.4.0, where a module's "reading" is its
  translator: `TeamsReading` is `TeamsEventTranslator`, implementing
  `TranslatesRelayedEvents`, and `TeamsReadingState` is
  `TeamsEventTranslatorState`. Each step gives a `TranslatedEvent`; the
  cases are unchanged. Pinned to docking_station a12f25e until 0.4.0 is
  published at the fresh-logbook cutover.
- `TeamsTranslator`, `TeamsReceiver`, `StandInTrajectory`, `TeamsAuthors`
  and `TeamsConversation` are gone: the way in from before the docking
  station, which no program ran. `teamsSaid`, which the translator uses
  for every message, is kept, in `teams_said.dart`.

## 0.0.4

- `teams-message`, a program (`dart compile exe bin/teams_message.dart`):
  a reply's text on stdin; the conversation's reply endpoint as the logbook
  recorded it (`--reply-endpoint`, is_effects' `AddressPrefix` JSON,
  `{"origin", "pathPrefix"}`) and `--sign-in` as arguments; on stdout, the
  Teams requests that post it, as one JSON array of is_effects'
  `encodeProposedRequest`. Optional `--turn`, `--context-tokens` and
  `--context-window` make the footer (`turn 3 · context 152k of 200k
  (76%)`). A reply goes out as at most 10 messages; past that the last
  says it was cut off. It reaches no network.
- `teamsReplyEndpoint(serviceUrl, conversation)`, an `AddressPrefix` made
  of `teamsConversationOrigin` and `teamsConversationPathPrefix` (now a
  `PathPrefix`); `teamsPostToEndpoint` builds a request from a recorded
  one.
- is_effects ^0.14.0. `TeamsRequestsAnsweringEvents`, `teamsReplyRequests`
  and `teamsTrajectoryOpenedRequests` are gone with the interface they
  implemented: a reply is built by `teams-message` from the recorded
  endpoint, never from the relayed event. Every request built here is a
  `ProposedRequest` (the airlock alone makes a `GrantedRequest`), and
  `teams-message` prints `encodeProposedRequest`.
- `is_docking_station_api` ^0.3.0, the vocabulary's new name (it depends on
  neither logbook package, and reads an operator's trajectory close). The
  tests take `ObjectId` from `is_content_id`, so `is_logbook_client` is no
  longer a dependency at all.

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
