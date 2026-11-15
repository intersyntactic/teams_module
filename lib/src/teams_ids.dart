/// A Teams channel account id: `29:…` for a person, `28:<app id>` for a
/// bot. It names an account only to this bot, so it is not who the person
/// is anywhere else; that is their [EntraObjectId].
final class TeamsUserId {
  const TeamsUserId._(this.value);

  /// The id as Teams sent it.
  final String value;

  /// [s] as a channel account id; null unless it is `28:` or `29:` and more,
  /// with no whitespace, the only two kinds seen in a witnessed body.
  static TeamsUserId? parse(String s) =>
      RegExp(r'^2[89]:\S+$').hasMatch(s) ? TeamsUserId._(s) : null;

  /// Whether this is a bot's id, `28:<app id>`.
  bool get isBot => value.startsWith('28:');

  @override
  bool operator ==(Object other) =>
      other is TeamsUserId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A person's Entra object id: who they are across Microsoft 365, the same
/// in every chat and every app. A GUID, held in lower case.
final class EntraObjectId {
  const EntraObjectId._(this.value);

  /// The GUID, in lower case.
  final String value;

  /// [s] as an Entra object id; null unless it is a GUID, in either case.
  static EntraObjectId? parse(String s) =>
      _guid.hasMatch(s) ? EntraObjectId._(s.toLowerCase()) : null;

  static final _guid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  @override
  bool operator ==(Object other) =>
      other is EntraObjectId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
