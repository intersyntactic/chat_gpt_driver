import 'dart:convert';

import 'package:checked_json/checked_json.dart';

/// A model sign-in's secret. Each kind is a way a ChatGPT plan can be signed
/// in, so a new kind is a new case here, never a change to the caller.
sealed class Credential {
  const Credential();

  /// [raw], a sign-in's credential file, or a [FormatException] naming what
  /// is wrong with it but never its secret.
  static Credential parse(String raw) {
    final Object? json;
    try {
      json = decodeJsonRefusingDuplicateKeysAndUnsafeIntegers(raw);
    } on FormatException catch (e) {
      // The message names at most a key, never a value.
      throw FormatException(
        'credential is not JSON the driver reads: ${e.message}',
      );
    }
    return switch (json) {
      {'kind': 'chatgpt-sign-in'} => ChatGptSignIn._fromJson(json),
      {'kind': final String kind} => throw FormatException(
        'not a kind of model sign-in: $kind',
      ),
      _ => throw const FormatException('credential names no kind'),
    };
  }
}

/// One "Sign in with ChatGPT" (OAuth with PKCE), owned by one host. Its
/// refresh token rotates on every refresh and the old one dies, so this is
/// state: each refresh gives a new [ChatGptSignIn] that replaces the last.
final class ChatGptSignIn extends Credential {
  const ChatGptSignIn._({
    required this.clientId,
    required this.hostId,
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    required this.expiresAt,
    required this.earliestRefreshAt,
    required this.scopes,
  });

  /// The scope that lets the access token spend the plan. A sign-in
  /// without it is identity only.
  static const planScope = 'chatgpt.tokens.use.direct';

  /// The `oaiapp_…` id OpenAI issued at registration; never
  /// `dynamic_agent_client`.
  final String clientId;

  /// The `ext_agent_host_id` this sign-in was made for: the host that
  /// refreshes it.
  final String hostId;

  final String accessToken;
  final String refreshToken;

  /// Kept as the hint for signing in again; never checked or used here.
  final String? idToken;

  final DateTime expiresAt;
  final DateTime earliestRefreshAt;
  final List<String> scopes;

  bool get canUsePlan => scopes.contains(planScope);

  /// Five minutes before expiry, never before [earliestRefreshAt].
  DateTime get refreshAt {
    final due = expiresAt.subtract(const Duration(minutes: 5));
    return earliestRefreshAt.isAfter(due) ? earliestRefreshAt : due;
  }

  /// A sign-in from OpenAI's token reply at [now]. An `expires_in` that is
  /// absent or past a year reads as an hour; one of zero or less as now.
  /// No refresh is due within a minute of the reply, so a token that comes
  /// back already due is not refreshed again at once.
  factory ChatGptSignIn.fromTokens({
    required String clientId,
    required String hostId,
    required String accessToken,
    required String refreshToken,
    required String? idToken,
    required num? expiresIn,
    required DateTime? earliestRefreshAt,
    required List<String> scopes,
    required DateTime now,
  }) {
    final seconds = expiresIn == null || expiresIn > _maxExpiresIn
        ? 3600
        : (expiresIn <= 0 ? 0 : expiresIn.toInt());
    final soonest = now.add(const Duration(minutes: 1));
    return ChatGptSignIn._(
      clientId: clientId,
      hostId: hostId,
      accessToken: accessToken,
      refreshToken: refreshToken,
      idToken: idToken,
      expiresAt: now.add(Duration(seconds: seconds)).toUtc(),
      earliestRefreshAt: switch (earliestRefreshAt) {
        final at? when at.isAfter(soonest) => at.toUtc(),
        _ => soonest.toUtc(),
      },
      scopes: List.unmodifiable(scopes),
    );
  }

  static const _maxExpiresIn = 366 * 24 * 60 * 60;

  static ChatGptSignIn _fromJson(Map<Object?, Object?> json) => switch (json) {
    {
      'client_id': final String clientId,
      'host_id': final String hostId,
      'access_token': final String accessToken,
      'refresh_token': final String refreshToken,
      'expires_at': final String expiresAt,
      'earliest_refresh_at': final String earliestRefreshAt,
      'scopes': final List<Object?> scopes,
    }
        when clientId.isNotEmpty &&
            !_unissued(clientId) &&
            hostId.isNotEmpty &&
            accessToken.isNotEmpty &&
            refreshToken.isNotEmpty &&
            scopes.every((s) => s is String) =>
      ChatGptSignIn._(
        clientId: clientId,
        hostId: hostId,
        accessToken: accessToken,
        refreshToken: refreshToken,
        idToken: switch (json['id_token']) {
          final String t => t,
          _ => null,
        },
        expiresAt: _time(expiresAt, 'expires_at'),
        earliestRefreshAt: _time(earliestRefreshAt, 'earliest_refresh_at'),
        scopes: List.unmodifiable([for (final s in scopes) '$s']),
      ),
    _ => throw const FormatException(
      'a chatgpt-sign-in holds an issued client_id, host_id, access_token, '
      'refresh_token, expires_at, earliest_refresh_at and scopes',
    ),
  };

  static bool _unissued(String clientId) =>
      const {'dynamic_agent_client'}.contains(clientId);

  static DateTime _time(String raw, String field) =>
      DateTime.tryParse(raw)?.toUtc() ??
      (throw FormatException('$field is not a time'));

  /// The credential file's text: what [Credential.parse] reads back.
  String encode() => const JsonEncoder.withIndent('  ').convert({
    'kind': 'chatgpt-sign-in',
    'client_id': clientId,
    'host_id': hostId,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'id_token': ?idToken,
    'expires_at': expiresAt.toIso8601String(),
    'earliest_refresh_at': earliestRefreshAt.toIso8601String(),
    'scopes': scopes,
  });

  @override
  String toString() => 'a chatgpt-sign-in';
}
