import 'dart:convert';

import 'package:is_chat_gpt_driver/is_chat_gpt_driver.dart';
import 'package:test/test.dart';

Map<String, Object?> valid() => {
  'kind': 'chatgpt-sign-in',
  'client_id': 'oaiapp_abc',
  'host_id': 'urn:uuid:00000000-0000-4000-8000-000000000000',
  'access_token': 'a-secret-access-token',
  'refresh_token': 'a-secret-refresh-token',
  'expires_at': '2026-11-19T13:00:00.000Z',
  'earliest_refresh_at': '2026-11-19T12:01:00.000Z',
  'scopes': ['openid', ChatGptSignIn.planScope],
};

void main() {
  test('reads back what it writes', () {
    final signIn = Credential.parse(jsonEncode(valid())) as ChatGptSignIn;
    final again = Credential.parse(signIn.encode()) as ChatGptSignIn;
    expect(again.encode(), signIn.encode());
    expect(again.canUsePlan, isTrue);
    expect(again.refreshAt, DateTime.utc(2026, 11, 19, 12, 55));
  });

  test('never prints a token', () {
    final signIn = Credential.parse(jsonEncode(valid()));
    expect('$signIn', 'a chatgpt-sign-in');
  });

  for (final (why, change) in <(String, void Function(Map<String, Object?>))>[
    ('an unissued client', (m) => m['client_id'] = 'dynamic_agent_client'),
    ('no refresh token', (m) => m.remove('refresh_token')),
    ('an empty access token', (m) => m['access_token'] = ''),
    ('a scope that is not text', (m) => m['scopes'] = [1]),
  ]) {
    test('refuses $why, naming no secret', () {
      final json = valid();
      change(json);
      expect(
        () => Credential.parse(jsonEncode(json)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
    });
  }

  test('refuses a time that is not one', () {
    expect(
      () => Credential.parse(jsonEncode(valid()..['expires_at'] = 'soon')),
      throwsA(isA<FormatException>()),
    );
  });

  test('refuses another kind', () {
    expect(
      () => Credential.parse('{"kind":"claude-code-setup-token"}'),
      throwsA(isA<FormatException>()),
    );
  });

  group('a token reply', () {
    test('once both tokens are in, nothing else can fail it', () {
      final reply = TokenReply.parse(
        200,
        '{"access_token":"a","refresh_token":"r","expires_in":"soon",'
        '"scope":7,"earliest_refresh_at":"2026-11-19T12:30:00Z"}',
      );
      final t = reply as Tokens;
      expect(t.expiresIn, isNull);
      expect(t.scopes, isNull);
      expect(t.earliestRefreshAt, DateTime.utc(2026, 11, 19, 12, 30));
    });

    test('a dead refresh token asks for a new sign-in', () {
      final reply = TokenReply.parse(
        400,
        '{"error":"refresh_token_reused","error_description":"reused"}',
      );
      expect((reply as TokenRefused).signInAgain, isTrue);
    });

    test('anything else does not', () {
      expect(
        (TokenReply.parse(503, 'down') as TokenRefused).signInAgain,
        isFalse,
      );
    });
  });

  test('no refresh is due within a minute of the reply', () {
    final now = DateTime.utc(2026, 11, 19, 12);
    final s = ChatGptSignIn.fromTokens(
      clientId: 'oaiapp_abc',
      hostId: 'h',
      accessToken: 'a',
      refreshToken: 'r',
      idToken: null,
      expiresIn: 0,
      earliestRefreshAt: null,
      scopes: const [],
      now: now,
    );
    expect(s.refreshAt, now.add(const Duration(minutes: 1)));
  });
}
