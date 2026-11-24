import 'dart:async';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

import 'credential.dart';
import 'openai_accounts.dart';

/// Swaps a sign-in's refresh token for new tokens at OpenAI.
typedef RefreshesTokens = Future<TokenReply> Function(ChatGptSignIn signIn);

/// Refreshes [signIn] at OpenAI: `grant_type=refresh_token` with the issued
/// client id and the API as `resource`, and no `scope`.
Future<TokenReply> refreshAtOpenAi(ChatGptSignIn signIn) => requestTokens({
  'grant_type': 'refresh_token',
  'client_id': signIn.clientId,
  'refresh_token': signIn.refreshToken,
  'resource': openAiResource,
});

/// An access token, ready for one request. Never printed.
final class AccessToken {
  const AccessToken._(this.value);

  final String value;

  @override
  String toString() => 'an access token';
}

/// One ChatGPT sign-in, kept in its own writable [file], and the only
/// thing that refreshes it.
///
/// Each refresh rotates the refresh token and kills the old one, so the new
/// sign-in is written to [file] (a temporary file beside it, then a rename)
/// before its access token is used, and only one refresh runs at a time:
/// two at once would each spend the same refresh token, and the second
/// would kill the sign-in.
final class SignInFile {
  SignInFile(
    this.file,
    this._signIn, {
    this._refresh = refreshAtOpenAi,
    this._now = DateTime.now,
    void Function(String line)? log,
  }) : _log = log ?? _silent;

  final File file;
  ChatGptSignIn _signIn;
  final RefreshesTokens _refresh;
  final DateTime Function() _now;

  /// For whoever runs the driver. Never a token.
  final void Function(String line) _log;

  static void _silent(String _) {}

  /// The refresh underway, which every caller waits on, or null.
  Future<Outcome<AccessToken>>? _refreshing;

  /// Set once OpenAI says the sign-in is dead: only a new one helps.
  String? _dead;

  ChatGptSignIn get signIn => _signIn;

  /// Each file in [directory] not starting with `.`, named for its model
  /// sign-in, as a [SignInFile]. A dot file is a write that never finished.
  static Future<Map<ModelSignInName, SignInFile>> load(
    Directory directory, {
    RefreshesTokens refresh = refreshAtOpenAi,
    DateTime Function() now = DateTime.now,
    void Function(String line)? log,
  }) async {
    final loaded = <ModelSignInName, SignInFile>{};
    await for (final file in directory.list()) {
      if (file is! File) continue;
      final name = file.uri.pathSegments.last;
      if (name.startsWith('.')) continue;
      final signIn =
          ModelSignInName.parse(name) ??
          (throw FormatException('not a model sign-in name', name));
      final Credential credential;
      try {
        credential = Credential.parse(await file.readAsString());
      } on FormatException catch (e) {
        throw FormatException('$signIn: ${e.message}');
      }
      loaded[signIn] = switch (credential) {
        ChatGptSignIn() => SignInFile(
          file,
          credential,
          refresh: refresh,
          now: now,
          log: log,
        ),
      };
    }
    return loaded;
  }

  /// An access token that is good now, refreshing first when one is due.
  Future<Outcome<AccessToken>> accessToken() async {
    if (_dead case final why?) return Refused('sign in again: $why');
    if (!_signIn.canUsePlan) {
      return Refused('signed in without ${ChatGptSignIn.planScope}');
    }
    if (_now().isBefore(_signIn.refreshAt)) {
      return Ran(AccessToken._(_signIn.accessToken));
    }
    return _refreshing ??= _rotate().whenComplete(() => _refreshing = null);
  }

  Future<Outcome<AccessToken>> _rotate() async {
    final before = _signIn;
    final reply = await _refresh(before);
    switch (reply) {
      case Tokens():
        final after = ChatGptSignIn.fromTokens(
          clientId: before.clientId,
          hostId: before.hostId,
          accessToken: reply.accessToken,
          refreshToken: reply.refreshToken,
          idToken: reply.idToken ?? before.idToken,
          expiresIn: reply.expiresIn,
          earliestRefreshAt: reply.earliestRefreshAt,
          scopes: reply.scopes ?? before.scopes,
          now: _now(),
        );
        // The old refresh token is dead now, so the new one is kept in
        // memory even when the write fails: it is the only live one.
        _signIn = after;
        try {
          await _write(after);
          _log(
            '${file.path}: refreshed, good until '
            '${after.expiresAt.toIso8601String()}',
          );
        } on FileSystemException catch (e) {
          _log(
            '${file.path}: refreshed but not written (${e.osError ?? e.message}); '
            'a restart now loses this sign-in',
          );
        }
        if (!after.canUsePlan) {
          return Refused('refreshed without ${ChatGptSignIn.planScope}');
        }
        return Ran(AccessToken._(after.accessToken));
      case TokenRefused(signInAgain: true):
        _dead = '$reply';
        _log('${file.path}: refresh refused: $reply; sign in again');
        return Refused('sign in again: $reply');
      case TokenRefused():
        _log('${file.path}: refresh failed: $reply');
        // Not yet expired: the token in hand still works.
        if (_now().isBefore(before.expiresAt)) {
          return Ran(AccessToken._(before.accessToken));
        }
        return Refused('could not refresh: $reply');
    }
  }

  Future<void> _write(ChatGptSignIn signIn) async {
    final name = file.uri.pathSegments.last;
    final temporary = File('${file.parent.path}/.$name.tmp');
    await temporary.writeAsString(signIn.encode(), flush: true);
    await temporary.rename(file.path);
  }
}
