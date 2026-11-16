# is_teams_reply

teams-reply: the renderer that draws a Teams reply's body from entries
already recorded in an intersyntactic journal. An agent's reply reaches
Teams only as a body drawn this way, so a post carries no words a tool put
in it (https://github.com/enspyrco/intersyntactic/issues/1147).

```dart
import 'package:is_teams_reply/is_teams_reply.dart';

switch (teamsReply([Entry('turn', bytes)])) {
  case Body(:final text): // the activity JSON to send
  case Refusal(:final why): // nothing is sent
}
```

It is pure: no clock, no randomness, no I/O, and no package imports, so
the same entries always draw the same body, and this package's archive
holds every line that can change one.

## Its id

A renderer is named by the sha256 of its published archive: the value a
`pubspec.lock` records for it, and pub.dev reports as `archive_sha256`.
Check one without running anything:

```
curl -sL https://pub.dev/api/archives/is_teams_reply-0.1.0.tar.gz | shasum -a 256
```

It runs inside the follower in the `teams_reply/` app beside this package,
built with that id compiled in.
