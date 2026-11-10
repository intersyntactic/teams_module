# is_teams_module

The Teams module for intersyntactic. Peter, Hart's expert, works in Microsoft
Teams. This module lets him comment on Hart's report, correct it and approve
it from there, and Hart takes each of those in as a node on a journey path
without knowing Teams exists. The design is
https://github.com/enspyrco/intersyntactic/issues/1089; the questions it left
open are answered in https://github.com/intersyntactic/teams_module/issues/1.

## Shape

```
Teams ──POST (Bot Framework JWT)──▶ Teams relay ──doorbell, with content──▶ receiver
                                     │  checks the token against            │  writes nodes,
                                     │  Microsoft's public keys; answers    │  runs Hart's turn
                                     │  a card action with "Got it"         ▼
                                     │  at once; drops repeats       Bot Connector REST
                                     │  by activity id               (posts and edits cards)
```

It differs from the Slack module's shape in three ways, each forced by Teams:

- **The relay holds no secret.** Microsoft signs with a private key and the
  relay checks against the published public keys, so all it needs is the
  bot's app id.
- **The doorbell carries the message and what was submitted.** A card
  submission exists nowhere but the request that delivers it, so a doorbell
  that only said "something happened" would lose it.
- **Repeats are dropped by activity id.** Teams re-sends anything not
  answered within 15 seconds, so duplicates are ordinary traffic.

v1 mirrors what is addressed to the bot: card actions, form submissions and
@-mentions, which in a one-to-one chat is every message. It asks for no Graph
permissions, so Peter's IT has one thing to do: upload the app.

## Status

The way in is here: the relay (`bin/teams_relay.dart`, `lib/src/teams_relay.dart`)
serves `POST /api/messages`, fetches Microsoft's keys and refreshes them every
12 hours (`lib/src/key_source.dart`), and passes each delivery through the gate
(`lib/src/teams_gate.dart`). For now, a doorbell becomes a log line of ids.
Still to come: handing doorbells to a receiver, the receiver itself, and the
Bot Connector client that posts and edits cards.

## Running the relay

```
TEAMS_APP_ID=<the bot's app id> TEAMS_TENANT_ALLOWLIST=<Peter's tenant id> \
  dart run bin/teams_relay.dart
```

It listens on `127.0.0.1:8087` for a TLS proxy in front. The bot's messaging
endpoint is `https://<host>/api/messages`. For the arm64 box:

```
mkdir -p build
dart compile exe bin/teams_relay.dart --target-os linux --target-arch arm64 \
  -o build/teams_relay-linux-arm64
```

## Running the tests

```
dart pub get
dart test
```
