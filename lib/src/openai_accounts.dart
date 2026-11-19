import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// OpenAI's sign-in server, where a code or a refresh token becomes tokens.
final openAiTokenEndpoint = Uri.parse(
  'https://auth.openai.com/api/accounts/oauth/token',
);

/// The API a sign-in's access token is for.
const openAiResource = 'https://api.openai.com/v1';

/// OpenAI's answer to a token request, read once.
sealed class TokenReply {
  const TokenReply();

  /// The reply to a token request: [status] and its [body]. Once both
  /// tokens are in it nothing else can fail it, since on a refresh the old
  /// refresh token is already dead: a field of the wrong kind reads as
  /// absent.
  static TokenReply parse(int status, String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      json = null;
    }
    if (status != 200) {
      final (code, description) = switch (json) {
        {'error': final String code, 'error_description': final String d} => (
          code,
          d,
        ),
        {'error': final String code} => (code, code),
        _ => ('http_$status', 'HTTP $status'),
      };
      return TokenRefused(
        code,
        _words(description),
        signInAgain: _deadRefresh.contains(code),
      );
    }
    return switch (json) {
      {
        'access_token': final String access,
        'refresh_token': final String refresh,
      }
          when access.isNotEmpty && refresh.isNotEmpty =>
        Tokens(
          accessToken: access,
          refreshToken: refresh,
          idToken: switch (json['id_token']) {
            final String t when t.isNotEmpty => t,
            _ => null,
          },
          expiresIn: switch (json['expires_in']) {
            final num n => n,
            _ => null,
          },
          scope: switch (json['scope']) {
            final String s => s,
            _ => null,
          },
          earliestRefreshAt: _time(json['earliest_refresh_at']),
        ),
      _ => const TokenRefused(
        'token_response',
        'the reply had no access or refresh token',
        signInAgain: false,
      ),
    };
  }

  /// Refresh-token errors that mean only a new sign-in helps.
  static const _deadRefresh = {
    'invalid_grant',
    'invalid_refresh_token',
    'token_expired',
    'refresh_token_expired',
    'refresh_token_invalidated',
    'refresh_token_reused',
  };

  /// Unix seconds or an ISO string; the docs name the field, not its format.
  static DateTime? _time(Object? v) => switch (v) {
    // Both ends compared: `abs()` of the most negative int is negative.
    final num n when n >= -_maxEpochSeconds && n <= _maxEpochSeconds =>
      DateTime.fromMillisecondsSinceEpoch((n * 1000).toInt(), isUtc: true),
    final String s => DateTime.tryParse(s)?.toUtc(),
    _ => null,
  };

  static const _maxEpochSeconds = 8640000000000;

  /// A refusal is kept for good, so a few words, not a body.
  static String _words(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

/// Both tokens, and what came with them.
final class Tokens extends TokenReply {
  const Tokens({
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    required this.expiresIn,
    required this.scope,
    required this.earliestRefreshAt,
  });

  final String accessToken;
  final String refreshToken;
  final String? idToken;
  final num? expiresIn;
  final String? scope;
  final DateTime? earliestRefreshAt;

  /// The granted scopes, or null when the reply did not say.
  List<String>? get scopes =>
      scope?.split(' ').where((s) => s.isNotEmpty).toList();

  @override
  String toString() => 'tokens';
}

/// No tokens, because of [code]. [signInAgain] is true when the sign-in is
/// dead and only a new one in the browser helps.
final class TokenRefused extends TokenReply {
  const TokenRefused(this.code, this.description, {required this.signInAgain});

  final String code;
  final String description;
  final bool signInAgain;

  @override
  String toString() => '$description ($code)';
}

/// Posts [form], form-encoded, to [endpoint]. A network failure is a
/// [TokenRefused] that does not ask for a new sign-in.
Future<TokenReply> requestTokens(
  Map<String, String> form, {
  Uri? endpoint,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final http = HttpClient();
  try {
    final request = await http
        .postUrl(endpoint ?? openAiTokenEndpoint)
        .timeout(timeout);
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.add(utf8.encode(Uri(queryParameters: form).query));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    return TokenReply.parse(response.statusCode, body);
  } on IOException catch (e) {
    return TokenRefused(
      'network',
      'could not reach OpenAI: ${e.runtimeType}',
      signInAgain: false,
    );
  } on TimeoutException {
    return const TokenRefused(
      'network',
      'OpenAI did not answer in time',
      signInAgain: false,
    );
  } finally {
    http.close(force: true);
  }
}
