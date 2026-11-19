/// Runs the ChatGPT driver as a service (see
/// `package:is_chat_gpt_driver/service.dart`):
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
/// Exits 78 when it cannot start as configured, and closes cleanly on
/// SIGTERM or SIGINT.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_chat_gpt_driver/is_chat_gpt_driver.dart';
import 'package:is_chat_gpt_driver/service.dart';
import 'package:is_effects/is_effects.dart';

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
  final uid = _uidOf(caller) ?? _fail('no user $caller');
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
  if (signIns.isEmpty) _fail('no model sign-ins in $state');
  for (final MapEntry(key: name, value: file) in signIns.entries) {
    if (!file.signIn.canUsePlan) {
      _fail('$name was signed in without ${ChatGptSignIn.planScope}');
    }
  }
  final ChatGptDriverService service;
  try {
    service = await ChatGptDriverService.start(
      ChatGptDriver(signIns, log: stdout.writeln),
      uid,
      File(socket),
    );
  } on Object catch (e) {
    _fail('$e');
  }
  stdout.writeln(
    'listening on $socket for $caller, '
    'model sign-ins: ${signIns.keys.join(' ')}',
  );
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await service.close();
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
