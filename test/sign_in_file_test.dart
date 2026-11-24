import 'dart:async';
import 'dart:io';

import 'package:is_chat_gpt_driver/is_chat_gpt_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

final t0 = DateTime.utc(2026, 11, 19, 12);

ChatGptSignIn signedIn({
  String access = 'access-1',
  String refresh = 'refresh-1',
  List<String> scopes = const [ChatGptSignIn.planScope],
  DateTime? at,
}) => ChatGptSignIn.fromTokens(
  clientId: 'oaiapp_test',
  hostId: 'urn:uuid:00000000-0000-4000-8000-000000000000',
  accessToken: access,
  refreshToken: refresh,
  idToken: null,
  expiresIn: 3600,
  earliestRefreshAt: null,
  scopes: scopes,
  now: at ?? t0,
);

Tokens tokens(String n) => Tokens(
  accessToken: 'access-$n',
  refreshToken: 'refresh-$n',
  idToken: null,
  expiresIn: 3600,
  scope: null,
  earliestRefreshAt: null,
);

String tokenOf(Outcome<AccessToken> out) =>
    (out as Ran<AccessToken>).output.value;

void main() {
  late Directory dir;
  late File file;
  late DateTime now;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sign-in-file');
    file = File('${dir.path}/cam-chatgpt');
    await file.writeAsString(signedIn().encode());
    now = t0;
  });
  tearDown(() => dir.delete(recursive: true));

  test('uses the token in hand until five minutes before expiry', () async {
    var refreshes = 0;
    final f = SignInFile(
      file,
      signedIn(),
      refresh: (_) async {
        refreshes++;
        return tokens('2');
      },
      now: () => now,
    );
    now = t0.add(const Duration(minutes: 54));
    expect(tokenOf(await f.accessToken()), 'access-1');
    expect(refreshes, 0);
    now = t0.add(const Duration(minutes: 55));
    expect(tokenOf(await f.accessToken()), 'access-2');
    expect(refreshes, 1);
  });

  test('runs one refresh at a time: concurrent callers share it', () async {
    final gate = Completer<TokenReply>();
    final spent = <String>[];
    final f = SignInFile(
      file,
      signedIn(),
      refresh: (s) {
        spent.add(s.refreshToken);
        return gate.future;
      },
      now: () => now,
    );
    now = t0.add(const Duration(hours: 1));
    final calls = [for (var i = 0; i < 5; i++) f.accessToken()];
    await pumpEventQueue();
    expect(spent, ['refresh-1'], reason: 'the refresh token is spent once');
    gate.complete(tokens('2'));
    expect([for (final c in calls) tokenOf(await c)], everyElement('access-2'));
  });

  test('the next refresh spends the rotated token, not the dead one', () async {
    final spent = <String>[];
    var n = 1;
    final f = SignInFile(
      file,
      signedIn(),
      refresh: (s) async {
        spent.add(s.refreshToken);
        return tokens('${++n}');
      },
      now: () => now,
    );
    now = t0.add(const Duration(hours: 1));
    await f.accessToken();
    now = now.add(const Duration(hours: 1));
    expect(tokenOf(await f.accessToken()), 'access-3');
    expect(spent, ['refresh-1', 'refresh-2']);
  });

  test(
    'logs a refresh once it is written, with its expiry and no token',
    () async {
      final logged = <String>[];
      final f = SignInFile(
        file,
        signedIn(),
        refresh: (_) async => tokens('2'),
        now: () => now,
        log: logged.add,
      );
      now = t0.add(const Duration(hours: 1));
      await f.accessToken();
      expect(logged, [
        '${file.path}: refreshed, good until '
            '${now.add(const Duration(hours: 1)).toIso8601String()}',
      ]);
      expect(
        logged.single,
        isNot(anyOf(contains('access-'), contains('refresh-'))),
      );
    },
  );

  test('a refresh it cannot write still serves, and says so instead', () async {
    final logged = <String>[];
    final f = SignInFile(
      file,
      signedIn(),
      refresh: (_) async => tokens('2'),
      now: () => now,
      log: logged.add,
    );
    await Process.run('chmod', ['500', dir.path]);
    addTearDown(() => Process.run('chmod', ['700', dir.path]));
    now = t0.add(const Duration(hours: 1));
    expect(tokenOf(await f.accessToken()), 'access-2');
    expect(logged, [
      allOf(
        startsWith('${file.path}: refreshed but not written ('),
        endsWith('a restart now loses this sign-in'),
      ),
    ]);
  });

  test('writes the rotated sign-in before its token is used', () async {
    final f = SignInFile(
      file,
      signedIn(),
      refresh: (_) async => tokens('2'),
      now: () => now,
    );
    now = t0.add(const Duration(hours: 1));
    final out = await f.accessToken();
    final onDisk = Credential.parse(await file.readAsString()) as ChatGptSignIn;
    expect(onDisk.refreshToken, 'refresh-2');
    expect(onDisk.accessToken, tokenOf(out));
    expect(dir.listSync().map((e) => e.uri.pathSegments.last), [
      'cam-chatgpt',
    ], reason: 'no temporary file is left beside it');
  });

  test('a dead sign-in refuses, and is never refreshed again', () async {
    var refreshes = 0;
    final f = SignInFile(
      file,
      signedIn(),
      refresh: (_) async {
        refreshes++;
        return const TokenRefused(
          'refresh_token_reused',
          'reused',
          signInAgain: true,
        );
      },
      now: () => now,
    );
    now = t0.add(const Duration(hours: 1));
    expect(
      (await f.accessToken() as NothingRan).why,
      startsWith('sign in again'),
    );
    expect(
      (await f.accessToken() as NothingRan).why,
      startsWith('sign in again'),
    );
    expect(refreshes, 1);
  });

  test('a failed refresh keeps the token in hand until it expires', () async {
    final f = SignInFile(
      file,
      signedIn(),
      refresh: (_) async =>
          const TokenRefused('network', 'down', signInAgain: false),
      now: () => now,
    );
    now = t0.add(const Duration(minutes: 58));
    expect(tokenOf(await f.accessToken()), 'access-1');
    now = t0.add(const Duration(hours: 1));
    expect(await f.accessToken(), isA<NothingRan>());
  });

  test('refuses a sign-in without the plan scope, never calling', () async {
    final f = SignInFile(
      file,
      signedIn(scopes: const ['openid']),
      refresh: (_) => fail('refreshed'),
      now: () => now,
    );
    expect(
      (await f.accessToken() as NothingRan).why,
      contains(ChatGptSignIn.planScope),
    );
  });

  test('loads each file, skipping an unfinished write', () async {
    await File('${dir.path}/.cam-chatgpt.tmp').writeAsString('{');
    final loaded = await SignInFile.load(dir);
    expect(loaded.keys.map((k) => '$k'), ['cam-chatgpt']);
    expect(loaded.values.single.signIn.refreshToken, 'refresh-1');
  });
}
