/// Runs the ChatGPT driver, a service on a Unix socket that carries out
/// model calls for one user:
///
///     CHAT_GPT_DRIVER_SOCKET=/run/intersyntactic-chat-gpt-driver/chat-gpt-driver.sock \
///       CHAT_GPT_DRIVER_CALLER=airlock \
///       STATE_DIRECTORY=/var/lib/intersyntactic-chat-gpt-driver \
///       dart run is_chat_gpt_driver:service
///
/// `CHAT_GPT_DRIVER_CALLER` is the one user, by name or id, whose calls it
/// carries out. systemd sets `STATE_DIRECTORY` from `StateDirectory=`: it
/// holds one sign-in per file, which the driver rewrites on every refresh,
/// so it must be the driver's own and closed to everyone else.
///
/// With no sign-ins it will not start, unless `CHAT_GPT_DRIVER_ALLOW_NO_SIGN_INS=1`:
/// then it listens and refuses every call, so a rehearsal can prove the
/// binary, sandbox and socket without ever holding a live sign-in.
///
/// `CHAT_GPT_DRIVER_REASONING_EFFORT` is how hard the model reasons on a
/// `{tools, turns}` call: `low`, `medium` (when unset), `high`, or `off` to
/// send none.
///
/// Exits 78 when it cannot start as configured, and closes cleanly on
/// SIGTERM or SIGINT.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_chat_gpt_driver/is_chat_gpt_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

Future<void> main() async {
  final env = Platform.environment;
  final [socket, caller, state] = [
    for (final name in [
      'CHAT_GPT_DRIVER_SOCKET',
      'CHAT_GPT_DRIVER_CALLER',
      'STATE_DIRECTORY',
    ])
      env[name] ?? _fail('$name is not set'),
  ];
  final number = _uidOf(caller) ?? _fail('no user $caller');
  final uid =
      UserId.parse(number) ??
      _fail('$caller is uid $number, which names no one user');
  final directory = Directory(state);
  final stat = directory.statSync();
  if (stat.type != FileSystemEntityType.directory) {
    _fail('$state is not a directory');
  }
  // Group or other may not read, write or enter it: it holds live tokens.
  if (stat.mode & 0x3f != 0) {
    _fail('$state is open to others (mode ${stat.modeString()}); make it 0700');
  }
  final Map<ModelSignInName, SignInFile> signIns;
  try {
    signIns = await SignInFile.load(directory, log: stdout.writeln);
  } on Exception catch (e) {
    _fail('$e');
  }
  // wire-ok: an environment variable, read once here.
  final allowNoSignIns = switch (env['CHAT_GPT_DRIVER_ALLOW_NO_SIGN_INS']) {
    null => false,
    '1' => true,
    final other => _fail('CHAT_GPT_DRIVER_ALLOW_NO_SIGN_INS is $other, not 1'),
  };
  // wire-ok: an environment variable, read once here.
  final reasoningEffort = switch (env['CHAT_GPT_DRIVER_REASONING_EFFORT']) {
    null => ReasoningEffort.medium,
    'off' => null,
    final name =>
      ReasoningEffort.parse(name) ??
          _fail(
            'CHAT_GPT_DRIVER_REASONING_EFFORT is $name, not '
            '${[for (final e in ReasoningEffort.values) e.name].join(', ')} '
            'or off',
          ),
  };
  if (signIns.isEmpty && !allowNoSignIns) {
    _fail('no model sign-ins in $state');
  }
  for (final MapEntry(key: name, value: file) in signIns.entries) {
    if (!file.signIn.canUsePlan) {
      _fail('$name was signed in without ${ChatGptSignIn.planScope}');
    }
  }
  final ChatGptDriver driver;
  try {
    driver = await ChatGptDriver.start(
      signIns,
      caller: uid,
      socket: File(socket),
      reasoningEffort: reasoningEffort,
      log: stdout.writeln,
    );
  } on Object catch (e) {
    _fail('$e');
  }
  stdout.writeln(
    'listening on $socket for $caller, '
    'model sign-ins: ${signIns.keys.join(' ')}, '
    'reasoning effort: ${reasoningEffort?.name ?? 'off'}',
  );
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await driver.close();
  exit(0);
}

int? _uidOf(String user) {
  if (int.tryParse(user) case final uid?) return uid;
  final r = Process.runSync('id', ['-u', user]);
  return r.exitCode == 0 ? int.tryParse(r.stdout.toString().trim()) : null;
}

Never _fail(String why) {
  stderr.writeln('is_chat_gpt_driver service: $why');
  exit(78);
}
