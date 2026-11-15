# is_teams_module

The Teams module for intersyntactic. It lets a journey take part in Microsoft
Teams: what a journey shows a person arrives as a message or a card, and what
they say and press there comes back as nodes on its journey path. The modules
on that path never learn Teams exists; a module that wants a person's review
or approval plugs into this one rather than speaking Teams itself.

## Shape

```
Teams ──POST (Bot Framework JWT)──▶ Teams relay ──event, with content────▶ receiver
                                     │  checks the token against            │  writes nodes,
                                     │  Microsoft's public keys; responds   │  feeds the journey
                                     │  a card action with "Got it"         ▼
                                     │  at once; drops repeats       Bot Connector REST
                                     │  by activity id               (posts and edits cards)
```

Three things about it are forced by Teams:

- **The relay holds no secret.** Microsoft signs with a private key and the
  relay checks against the published public keys, so all it needs is the
  bot's app id.
- **An event carries the message and what was submitted.** A card
  submission exists nowhere but the request that delivers it, and the bot
  can't read a chat back, so there is nothing to fetch later.
- **Repeats are dropped by activity id.** Teams re-sends anything it gets
  no response to within 15 seconds, so duplicates are ordinary traffic.

v1 mirrors what is addressed to the bot: card actions, form submissions and
@-mentions, which in a one-to-one chat is every message. It asks for no Graph
permissions, so an organisation's IT has one thing to do: upload the app.

## What Teams sends, and how it is read

The docking port gives this module's reading every arrival from the relay,
in the record's order, and the reading says what each one is: something
said, a conversation joined, or nothing to admit. These are the facts about
Teams that reading rests on. Each says whether it was **measured** (seen in
bytes Teams really sent, with where) or is **unmeasured** (from Microsoft's
documentation or inference only).

**Conversations and threads.**

- A one-to-one chat's conversation id is `a:…`. Measured, in Hart's tenant.
  A group chat's is `19:…@thread.v2` by Microsoft's documentation; none is
  in the record, so unmeasured here.
- In a channel, every message names its *thread*, not the channel:
  `conversation.id` is `<channel id>;messageid=<the thread's first post>`.
  A new post's thread is itself: its id and the `messageid` are the same.
  A reply carries its thread's first post's id. `channelData.replyChain.id`
  repeats that id, and `channelData.channel.id` is the channel. Measured on
  15 Nov in the "AI Forensic Agents" team, Hart's tenant, for a new post and
  a reply.
- So each thread is a conversation of its own, and an answer sent back to
  its id lands in the thread. The reading names the channel as the
  conversation the thread sits within.
- A reply in a channel has `replyToId` null and no `quotedReply` entity:
  the thread is the reply. Measured, 15 Nov. In a chat, a Reply is
  different: `replyToId` is null too, but a `quotedReply` entity names the
  message quoted, and the text starts with `<quoted messageId=…/>`.
  Measured in a one-to-one chat on 14 Nov. A Reply in a group chat is
  unmeasured.
- A Teams message id is the millisecond it was posted (`1794736789259` is
  09:59:49.259 UTC on 15 Nov), unique only within its conversation. So a
  message is named by both: `<conversation>|<message id>`. Measured.
- Every message measured so far was posted in a team's **General** channel,
  whose id is also the team's id. A post in any other channel is
  unmeasured: it should arrive with that channel's id in
  `channelData.channel.id` and the team's in `channelData.team.id`.

**Joins.**

- Adding the bot to a team is one join that Teams sends as two activities
  at the same moment: a `conversationUpdate` (`channelData.eventType`
  `teamMemberAdded`, with the bot in `membersAdded`) and an
  `installationUpdate` with `action` `add`. Both arrive in the team's
  General channel, whichever channel the installer picked (that one is in
  `channelData.settings.selectedChannel`). The reading takes the
  `conversationUpdate` as the join and the `installationUpdate` as nothing,
  so one join is read once. Measured on 15 Nov, for two teams in Hart's
  tenant.
- Installing the bot in a one-to-one chat sends the same pair, and its
  `membersAdded` names both the person and the bot. Measured, 15 Nov.
- Taking the bot out sends an `installationUpdate` with `action` `remove`.
  Measured in a one-to-one chat, 15 Nov.
- The join's `from` is whoever added the bot. Measured.

**Who someone is.**

- Teams names a person to the bot by a channel id, `29:…`, which means
  nothing outside this bot, and by their Entra object id
  (`from.aadObjectId`), which is who they are across Microsoft 365. Someone
  is attributed as `teams:<tenant>/<Entra object id>`. A person Teams gives
  no Entra object id for is no one, so their message is not admitted.
  Measured: every person's message so far carried one.
- A bot is `28:<app id>` with no Entra object id, and is attributed as
  `teams:<tenant>/bot:<app id>`. To a journey, another bot is a user like
  anyone else. Measured for this bot in `membersAdded`, 15 Nov. A message
  *from* another bot is unmeasured.
- A quote names its author only by channel id and display name, never an
  Entra object id. So the author is named from earlier arrivals: if that
  person has sent something the record holds, the quote is attributed to
  them; otherwise it carries the display name Teams showed. Nothing is
  asked of Teams to find out. Measured shape, 14 Nov.

**What arrives at all.**

- The app's manifest asks for no resource-specific permissions (it has no
  `authorization` block). Without them, Teams delivers only messages that
  @mention the bot in a group chat or a channel; in a one-to-one chat every
  message arrives. Mention-only is from Microsoft's documentation: every
  group or channel message in the record mentions the bot, but no
  unmentioned post has been sent since the bot joined, so its absence is
  unmeasured.
- To be offered in a team at all, the manifest's bot must list the `team`
  scope. Measured on 15 Nov: without it, Teams showed only About, Share and
  Uninstall, and the admin centre's Add to team was greyed out.

**Edits and deletes.** An edit is a `messageUpdate` reusing the message's
id (`channelData.eventType` `editMessage`); a delete is a `messageDelete`
(`softDeleteMessage`). Both shapes are from hand-written test bodies, so
unmeasured. So is the arrival key planned for them,
`<type>:<id>@<timestamp>`, which rests on a redelivery keeping its
timestamp and a second edit getting a new one. A restored message
arriving as a `messageUpdate` with `undeleteMessage` is unmeasured too.
They are read as nothing to admit until there is a shape for what a
message became.

**Card presses (`Responded`).**

- A press is an `invoke` named `adaptiveCard/action`. It names its card
  only by the card's activity id, in `replyToId`, and says which button by
  `value.action.verb`. Measured through the gate on 10 Nov, and in a group
  chat on 13 Nov in Hart's tenant, where the echo bot edited the pressed
  card by that id. No press is in the record yet: it
  began on 15 Nov.
- The card's own `value.action.data` comes back from the Teams client,
  which can be made to send anything, so it is never read as which node a
  card shows. That is known only to whatever sent the card.
- A card's activity id comes back in the Bot Connector's response to
  sending it. Editing a card needs it, so that much is measured. Whether
  the record of a send keeps it, which a press needs in order to be traced
  to its node, is being decided with the airlock.
- Teams wants an invoke answered within about 15 seconds, and sends it
  again if not. The relay answers at once with a fixed message, before
  anything is admitted, and an edit to the card can follow later. While
  the press is handled, Teams greys the card out. Measured, 10 Nov.
- A press in a channel, and a card with inputs (a typed correction), are
  unmeasured.
- Until the docking port's contract has `Responded`, the reading takes a
  press as nothing to admit.

## Status

The way in is here: the relay (`bin/teams_relay.dart`, `lib/src/teams_relay.dart`)
serves `POST /api/messages`, fetches Microsoft's keys and refreshes them every
12 hours (`lib/src/key_source.dart`), and passes each delivery through the gate
(`lib/src/teams_gate.dart`). The receiver (`lib/src/teams_receiver.dart`)
reads each event as the annotation shapes it writes: an approval, a
holding off, a withdrawal. Until the module meets a real journey path it
writes them to a stand-in (`lib/src/stand_in_journey_path.dart`). The way out
is here too: `lib/src/bot_connector.dart` gets the bot's token and posts,
replies to and edits messages. Still to come: cards drawn from a shape's
fields.

## Testing on a test tenant

`bin/teams_echo.dart` is a test bot, not the module's shape: the relay with a
handler that responds through the Connector. It echoes text, sends a card with
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
JOURNAL_SOCKET=<the record's writer's Unix socket> \
  dart run bin/teams_relay.dart
```

It listens on `127.0.0.1:8087` for a TLS proxy in front. The bot's messaging
endpoint is `https://<host>/api/messages`. Every accepted request's body is
recorded with the record's one writer, as an `arrived` entry, before Teams
gets its response. The writer's sender table must let the relay's user send
`arrived`. The relay keeps no record of its own, so it builds and runs
compiled as well as from source.
For the arm64 box:

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
