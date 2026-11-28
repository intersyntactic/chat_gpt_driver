/// Signs a host in with ChatGPT, run on a computer with a browser, and
/// writes the sign-in for that host, named for its model sign-in:
///
///     dart run is_chat_gpt_driver:sign_in <name>          # a new host
///     dart run is_chat_gpt_driver:sign_in <name> --again  # sign it in again
///
/// The file is always `~/.config/intersyntactic/chat-gpt-driver/<name>`, in
/// a directory closed to others and outside any checkout, so a commit can
/// never pick a sign-in up.
///
/// The redirect reaches `127.0.0.1` on this computer, not the host, so the
/// browser part runs here and the file is then copied to the host over SSH;
/// the host refreshes it from then on, and this copy goes stale at its
/// first refresh. A new host is registered as its own client with its own
/// `ext_agent_host_id`, never a copy of another's sign-in: each would
/// rotate the other's refresh token away. `--again` keeps the file's client
/// and host, for a host whose sign-in has died.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:is_chat_gpt_driver/is_chat_gpt_driver.dart';
import 'package:is_model_vocabulary/is_model_vocabulary.dart';

final _authorize = Uri.parse('https://auth.openai.com/api/accounts/authorize');
const _scopes =
    'openid profile email offline_access resource.invoke '
    '${ChatGptSignIn.planScope}';
const _agentName = 'intersyntactic chat_gpt_driver';
const _unissued = 'dynamic_agent_client';

Future<void> main(List<String> args) async {
  final (name, again) = switch (args) {
    [final name] => (name, false),
    [final name, '--again'] => (name, true),
    _ => _fail('usage: sign_in <model sign-in name> [--again]'),
  };
  final signInName =
      ModelSignInName.parse(name) ??
      _fail('$name is not a model sign-in name: a-z, 0-9, - and _');
  final home = Platform.environment['HOME'] ?? _fail('HOME is not set');
  final directory = Directory('$home/.config/intersyntactic/chat-gpt-driver');
  await directory.create(recursive: true);
  _chmod('700', directory.path);
  final path = '${directory.path}/$signInName';
  final file = File(path);
  final ChatGptSignIn? previous;
  if (again) {
    if (!file.existsSync()) _fail('no sign-in at $path to sign in again');
    previous = switch (Credential.parse(await file.readAsString())) {
      final ChatGptSignIn s => s,
    };
  } else if (file.existsSync()) {
    _fail('$path exists: --again signs its host in again');
  } else {
    previous = null;
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final redirect = 'http://127.0.0.1:${server.port}/auth/callback';
    final state = _random();
    final verifier = _random();
    final hostId = previous?.hostId ?? _newHostId();
    final url = _authorize.replace(
      queryParameters: {
        'client_id': previous?.clientId ?? _unissued,
        if (previous == null) 'agent_name_hint': _agentName,
        'ext_agent_host_id': hostId,
        'id_token_hint': ?previous?.idToken,
        'response_type': 'code',
        'redirect_uri': redirect,
        'scope': _scopes,
        'resource': openAiResource,
        'state': state,
        'nonce': _random(),
        'code_challenge_method': 'S256',
        'code_challenge': _b64(sha256.convert(ascii.encode(verifier)).bytes),
      },
    );
    stdout.writeln('Opening the browser to sign in. If it does not open:\n');
    stdout.writeln(
      '  ${url.replace(queryParameters: {...url.queryParameters}..remove('id_token_hint'))}\n',
    );
    await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', ['$url']);

    final q = (await _callback(server)).queryParameters;
    if (q['state'] != state) _fail('the reply did not belong to this sign-in');
    if (q['error'] case final error?) {
      _fail('declined in the browser: ${q['error_description'] ?? error}');
    }
    final code = q['code'] ?? _fail('the reply carried no code');
    final issued = q['client_id'];
    final String clientId;
    if (previous == null) {
      if (issued == null || issued == _unissued) {
        _fail('OpenAI did not issue a client id');
      }
      clientId = issued;
    } else {
      if (issued != null && issued != previous.clientId) {
        _fail('the reply was for a different registration');
      }
      clientId = previous.clientId;
    }

    final reply = await requestTokens({
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'code_verifier': verifier,
      'redirect_uri': redirect,
      'resource': openAiResource,
    });
    final tokens = switch (reply) {
      final Tokens t => t,
      TokenRefused() => _fail('OpenAI refused the code: $reply'),
    };
    final signIn = ChatGptSignIn.fromTokens(
      clientId: clientId,
      hostId: hostId,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      idToken: tokens.idToken ?? previous?.idToken,
      expiresIn: tokens.expiresIn,
      earliestRefreshAt: tokens.earliestRefreshAt,
      scopes: tokens.scopes ?? const [],
      now: DateTime.now(),
    );
    if (!signIn.canUsePlan) {
      _fail(
        'signed in, but ${ChatGptSignIn.planScope} was not granted: '
        'the plan cannot be used. Sign in again and allow it.',
      );
    }
    // Closed to others before a token is in it.
    await file.writeAsString('');
    _chmod('600', path);
    await file.writeAsString(signIn.encode(), flush: true);
    stdout.writeln(
      'Signed in, client $clientId, host $hostId, written to\n  $path\n'
      'Copy it to the host now, into the driver\'s StateDirectory under the\n'
      'same name, then delete this copy: the host\'s first refresh makes it '
      'stale.',
    );
  } finally {
    await server.close(force: true);
  }
}

Future<Uri> _callback(HttpServer server) async {
  await for (final request in server.timeout(
    const Duration(minutes: 5),
    onTimeout: (s) => s.close(),
  )) {
    // wire-ok: the redirect path OpenAI calls back on.
    if (request.uri.path != '/auth/callback') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }
    request.response
      ..headers.contentType = ContentType.text
      ..write('Done. You can close this tab and go back to the terminal.');
    await request.response.close();
    return request.uri;
  }
  _fail('no reply from the browser in 5 minutes');
}

/// A fresh UUIDv4 as a URN, the host's opaque id.
String _newHostId() {
  final b = _bytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return 'urn:uuid:${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String _random() => _b64(_bytes(32));

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

final _rng = Random.secure();
Uint8List _bytes(int n) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) _rng.nextInt(256)]);

void _chmod(String mode, String path) {
  final r = Process.runSync('chmod', [mode, path]);
  if (r.exitCode != 0) _fail('chmod $mode $path: ${r.stderr}');
}

Never _fail(String why) {
  stderr.writeln('sign_in: $why');
  exit(1);
}
