/// The follower every renderer is built into, and only what it uses: the
/// record's read socket, its writer, and the post entries' wire forms. A
/// renderer's own package holds only the pure function from entries to a
/// body; its `bin/` composes that with [RenderFollower], built with the
/// renderer's id as `-Drenderer=<id>`.
library;

export 'package:is_airlock_api/is_airlock_api.dart'
    show DecidedPost, Rendered, RendererId;
export 'package:is_effects/is_effects.dart' show Outcome, Ran, Refused;

export 'src/follower.dart';
export 'src/journal_reader.dart';
export 'src/write_entry.dart';
