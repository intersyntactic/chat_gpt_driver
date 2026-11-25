import 'dart:convert';
import 'dart:io';

import 'package:is_chat_gpt_driver/is_chat_gpt_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';
import 'package:test/test.dart';

final me = UserId.parse(
  int.parse((Process.runSync('id', ['-u']).stdout as String).trim()),
)!;

/// A Unix socket in a folder of its own, removed when the test ends. A
/// Unix socket's path is short on macOS, so not under the test's own temp
/// directory.
Future<File> freshSocket() async {
  final dir = await Directory('/tmp').createTemp('cgd');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}/s');
}

/// The caller's side of the socket, as the airlock holds its own: one call
/// in, then one JSON line per message until the finished one. A caller the
/// driver hangs up on, which may happen before the call is even written,
/// gets null.
Future<(Outcome<ModelReply>?, List<Progress>)> callOverSocket(
  File socket,
  ModelSignInName signIn,
  ModelName model,
  String systemPrompt,
  String request,
) async {
  final reported = <Progress>[];
  try {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(
      utf8.encode(
        jsonEncode(encodeModelCall(signIn, model, systemPrompt, request)),
      ),
    );
    await s.close();
    await for (final line
        in utf8.decoder.bind(s).transform(const LineSplitter())) {
      switch (decodeProgramMessage(jsonDecode(line), decodeModelReply)) {
        case Reported(:final progress):
          reported.add(progress);
        case Finished(:final outcome):
          return (outcome, reported);
      }
    }
  } on SocketException {
    // A broken pipe: hung up on.
  }
  return (null, reported);
}

/// Writes [call] as it is and returns the whole answer, trimmed.
Future<String> rawCall(File socket, String call) async {
  final s = await Socket.connect(
    InternetAddress(socket.path, type: InternetAddressType.unix),
    0,
  );
  s.add(utf8.encode(call));
  await s.close();
  return (await utf8.decoder.bind(s).join()).trim();
}

/// Starts a [ChatGptDriver] on a fresh socket, for this process's user
/// unless [caller] says otherwise, closed when the test ends. Returns the
/// socket, so every call and answer crosses the wire.
Future<File> startDriver(
  Map<ModelSignInName, SignInFile> signIns, {
  required Uri endpoint,
  UserId? caller,
  SocketUserReader? socketUserReader,
  void Function(String line)? log,
  ReasoningEffort? reasoningEffort,
}) async {
  final socket = await freshSocket();
  final driver = await ChatGptDriver.start(
    signIns,
    caller: caller ?? me,
    socket: socket,
    endpoint: endpoint,
    reasoningEffort: reasoningEffort,
    log: log,
    socketUserReader: socketUserReader,
  );
  addTearDown(driver.close);
  return socket;
}
