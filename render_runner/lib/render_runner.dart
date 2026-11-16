/// The render runner every renderer is built into, and only what it uses:
/// the record's read socket, its writer, and the wire forms of the
/// airlock's decision about a post and of the `rendered` entry answering it.
/// A renderer is a published package holding only the pure function from
/// entries to a body; a small app composes it with [RenderRunner], built
/// with the renderer's id as `-Drenderer=<id>`.
library;

export 'package:is_airlock_api/is_airlock_api.dart'
    show DecidedPost, Rendered, RendererId;
export 'package:is_effects/is_effects.dart' show Outcome, Ran, Refused;

export 'src/journal_reader.dart';
export 'src/runner.dart';
export 'src/write_entry.dart';
