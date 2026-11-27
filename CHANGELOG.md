# Changelog

Each version is tagged `vX.Y.Z` on main, and the services that use this
package pin that tag.

## 0.0.14

- A reply's footer says the turn and the step: `turn 3 · step 7 · context
  …`. A turn is a person's message through to its final reply; a step is
  one model call and what it caused. `teams-reply-drawing` takes
  `--step N` beside `--turn N`, both counted from 0, and shows each
  counted from 1. `replyFooter` takes `step`.
- `--turn` without `--step` is a loop from before steps had a name, whose
  `--turn` carries the step: its footer is exactly what 0.0.13 printed. That
  reading goes once every running loop sends both.

## 0.0.13

- The reply types (`RepliesUnderWebAddress`, `ReplyContent`, `ReplyText`,
  `ServerAssignedMessageId`) come from is_conversation_reply_vocabulary
  ^0.1.0. is_docking_station_api ^0.8.0 no longer re-exports them, and
  is_reply_requests_api ^0.2.0 uses them, so the module and everything it
  hands a reply endpoint to share one `ReplyEndpoint`. is_reply_vocabulary
  is gone. No behaviour change: `teams-reply-drawing` prints exactly what
  0.0.12 printed.

## 0.0.12

- `TeamsReplyRequests` implements is_reply_requests_api's
  `WritesWebAddressReplyRequests`, so the airlock can post a Teams reply as
  it posts a Slack one. `draw` gives each message of the reply, as
  `drawTeamsReply` draws it, as a `POST {prefix}activities` under the
  recorded `RepliesUnderWebAddress`, with no sign-in (the airlock sets the
  one it granted) and the response's body kept. `posted` reads the Bot
  Connector's `{"id"}` from that body: `Ran` with the id, `NothingRan` for a
  4xx, `StoppedPartway` with nothing done when it can't be told.
- The footer comes in with the reply's `ReplyContent`, decided with it,
  rather than being worked out here.
- `postTeamsReplyDrawing` and `teamsPostToEndpoint` are gone.
  `teams-reply-drawing` stays until the airlock posts replies itself; it
  now signs `TeamsReplyRequests`' requests, and prints exactly what 0.0.11
  printed.
- On is_effects ^0.17.0, which re-exports nothing, so the module depends on
  is_model_vocabulary, is_reply_vocabulary, is_sign_in_vocabulary and
  is_web_address_vocabulary directly.

## 0.0.11

- is_docking_station_api ^0.7.0, which brings is_reply_vocabulary 0.2.0.
  The lock holds the version set frozen at 05:51 UTC on 25 Nov, the same set
  as the other builds that compile this package in. No code change.

## 0.0.10

- Every dependency at its newest on pub.dev, so the builds that compile
  this package in lock the same versions: is_effects ^0.15.0 and
  is_docking_station_api ^0.6.0 (its JSON is unchanged from 0.5.0). No code
  change: the module names neither `Outcome.Refused` nor `ModelReply`.

## 0.0.9

- On is_docking_station_api ^0.5.0, where a reply endpoint is the sealed
  `ReplyEndpoint`. The translator gives Teams' as
  `RepliesUnderWebAddress(teamsReplyEndpoint(...))`: the Bot Connector
  takes a reply under a web address that names the conversation.
  `teams-reply-drawing`'s `--reply-endpoint` is unchanged, still the
  address prefix itself.

## 0.0.8

- The relay keeps no seen set, so a 200 always means recorded. A copy Teams
  re-sent while the first was still being recorded used to get a 200
  unrecorded; if the first copy's record then failed, the event was lost.
  Every copy is now recorded, and the docking station decides each event
  once. The gate's `hasSeen` and `TeamsGateDecision.seenKey` are gone with
  it, and `TeamsRelay`'s `seenFor` and `seenMax`.
- A chunked body over the cap no longer crashes the relay. Reading it
  stopped by cancelling the body, after which the refusal's `detachSocket`
  threw an `Error` the relay didn't catch. The body is now paused, not
  cancelled. A body cut short is a 400.
- One budget per request, 12 seconds by default, covers the keys, the body
  and the record, inside Teams' 15. `TeamsRelay.bodyTimeout` is
  `TeamsRelay.budget`, and `record` is given what is left of it:
  `record(body, within)`, which the relay passes to `recordEvent`'s
  `timeout`. It used to be 10 seconds for the body plus 10 for the record.
- is_effects ^0.14.3, so the relay and `teams-reply-drawing` build at the
  same versions as the is_flight_rules 0.6.0 window. Its
  `decodeAddressPrefix` refuses a `--reply-endpoint` with keys other than
  `origin` and `pathPrefix`.

## 0.0.7

- The way out is a drawing: translators bring things in, drawings take
  things out. `teams-reply-translator` is `teams-reply-drawing` (`dart
  compile exe bin/teams_reply_drawing.dart`); `teamsTextActivities` is
  `drawTeamsReply`, the cards alone, pure; `translateTeamsReply` is
  `postTeamsReplyDrawing`, the drawing addressed and signed as the
  requests that would post it. Arguments, output and exit codes are
  unchanged. `TeamsEventTranslator` stays a translator.
- The "Close trajectory" message action is gone: from the app package's
  manifest (`tool/app_package.dart`, which now has a `composeExtensions`
  section only with `--settings-action`), and `closeTrajectoryCommandId`
  and `closeTrajectoryConfirmParameter` with it. It opened on any message
  and so could name no trajectory; a trajectory is closed from the menu on
  its replies' cards. A submission from a package that still has it is
  `NothingToAdmit`, as every message action's is.

## 0.0.6

- `teams-message` is `teams-reply-translator` (`dart compile exe
  bin/teams_reply_translator.dart`), and `teamsMessageRequests` is
  `translateTeamsReply`: it translates a reply into Teams' terms and
  prints the requests, which the loop proposes to the airlock; it sends
  and proposes nothing itself. Arguments, output and exit codes are
  unchanged.

## 0.0.5

- is_docking_station_api 0.4.0, where a module's "reading" is its
  translator: `TeamsReading` is `TeamsEventTranslator`, implementing
  `TranslatesRelayedEvents`, and `TeamsReadingState` is
  `TeamsEventTranslatorState`. Each step gives a `TranslatedEvent`; the
  cases are unchanged.
- Every translated event names its `replyEndpoint`: the conversation at
  the service URL Teams sent, which the gate holds to the token's
  `serviceurl` claim, from `teamsReplyEndpoint`. is_effects ^0.14.2, whose
  `AddressPrefix` is is_web_address_vocabulary's.
- The relay records each event as a `teams-event` entry, `{"at", "bytes"}`,
  written by the docking station contract's `encodeRelayedEvent`, so only
  the relay's user can write one. `recordEvent` takes a
  `RelayedEventSource`, and `teamsEventSource` is the relay's and the
  translator's.
- `TeamsTranslator`, `TeamsReceiver`, `StandInTrajectory`, `TeamsAuthors`
  and `TeamsConversation` are gone: the way in from before the docking
  station, which no program ran. `teamsSaid`, which the translator uses
  for every message, is kept, in `teams_said.dart`.
- Every reply's last message carries "Close trajectory" in its card's
  menu (`Action.Execute`, verb `close`, `mode: secondary`), under the
  footer, its data naming the trajectory the reply is in
  (`{"trajectory": "<hex>"}`), so a press on an old reply closes that
  reply's trajectory. `teams-message` takes `--trajectory`, a
  `TrajectoryId` in hex, on every reply, and the translator reads it back
  into `PersonAskedToCloseTrajectory.trajectory` (`TeamsCardAction`'s
  `trajectory`). A Close naming none is `NothingToAdmit`.
  `teamsTrajectoryOpenCard` is gone: no separate card says a trajectory
  opened.
- The "Close trajectory" message action is `NothingToAdmit`: it opens on
  any message, so it can name no trajectory.
- The relay reads its logbook socket from `LOGBOOK_SOCKET` only; the
  `JOURNAL_SOCKET` fallback is gone, as infra's unit now sets the new name.

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
