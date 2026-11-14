# is_teams_module

The Teams module for intersyntactic. It lets a journey take part in Microsoft
Teams: what a journey shows a person arrives as a message or a card, and what
they say and press there comes back as nodes on its journey path. The modules
on that path never learn Teams exists; a module that wants a person's review
or approval plugs into this one rather than speaking Teams itself. The
questions its design left open are answered in
https://github.com/intersyntactic/teams_module/issues/1.

## Shape

```
Teams ──POST (Bot Framework JWT)──▶ Teams relay ──doorbell, with content──▶ receiver
                                     │  checks the token against            │  writes nodes,
                                     │  Microsoft's public keys; answers    │  feeds the journey
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
permissions, so an organisation's IT has one thing to do: upload the app.

## Status

The way in is here: the relay (`bin/teams_relay.dart`, `lib/src/teams_relay.dart`)
serves `POST /api/messages`, fetches Microsoft's keys and refreshes them every
12 hours (`lib/src/key_source.dart`), and passes each delivery through the gate
(`lib/src/teams_gate.dart`). The receiver (`lib/src/teams_receiver.dart`)
reads each doorbell as the annotation shapes it writes: an approval, a
holding off, a withdrawal. Until the module meets a real journey path it
writes them to a stand-in (`lib/src/stand_in_journey_path.dart`). The way out
is here too: `lib/src/bot_connector.dart` gets the bot's token and posts,
replies to and edits messages. Still to come: cards drawn from a shape's
fields.

## Testing on a test tenant

`bin/teams_echo.dart` is a test bot, not the module's shape: the relay with a
handler that answers through the Connector. It echoes text, sends a card with
Approve and Not yet when told "card", and edits the card when one is pressed.

```
TEAMS_APP_ID=<the bot's app id> TEAMS_APP_SECRET=<its client secret> \
  TEAMS_TENANT_ID=<the tenant it is registered in> dart run bin/teams_echo.dart
cloudflared tunnel --url http://127.0.0.1:8087   # a public https address
dart run tool/app_package.dart <app id> "Intersyntactic" 0.0.1   # build/appPackage.zip
```

Hand the secret over from wherever you keep secrets rather than typing it,
so it stays out of your shell's history. Set the bot's endpoint to the
tunnel's address plus `/api/messages`, upload the zip in the test tenant's
Teams, and message the bot. To replace a
package already uploaded, build it with a higher version: Teams refuses one
that isn't.

The icon is a journey path drawn as a transit map: the path in gold from its
root to its tip, two new paths branching off it at its nodes, and every node
a station coloured by who wrote it, people and agents alike.

## Running the relay

```
TEAMS_APP_ID=<the bot's app id> TEAMS_TENANT_ALLOWLIST=<tenant ids, comma-separated> \
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
