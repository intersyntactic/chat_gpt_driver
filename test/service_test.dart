import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_chat_gpt_driver/service.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';
import 'package:test/test.dart';

/// Streams the request back a word at a time, and refuses `refuse`.
final class Echo implements AsksTheModel {
  final calls = <(ModelSignInName, ModelName, String, String)>[];

  @override
  Future<Outcome<ModelReply>> askTheModel(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request, {
    required Report report,
  }) async {
    calls.add((signIn, model, systemPrompt, request));
    if (request == 'refuse') return const Refused('chatgpt: no');
    for (final word in request.split(' ')) {
      report(ReplyArriving(word));
    }
    return Ran(FinishedReply(text: request));
  }
}

final me = UserId.parse(
  int.parse((Process.runSync('id', ['-u']).stdout as String).trim()),
)!;
final seat = ModelSignInName.parse('cam-chatgpt')!;
final gpt = ModelName.parse('gpt-6.1-sol')!;

void main() {
  late Directory dir;
  late File socket;
  late Echo driver;

  setUp(() async {
    // A Unix socket's path is short on macOS, so not under the test's own
    // temp directory.
    dir = await Directory('/tmp').createTemp('cgd');
    socket = File('${dir.path}/s');
    driver = Echo();
  });
  tearDown(() => dir.delete(recursive: true));

  Future<String> raw(String call) async {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(utf8.encode(call));
    await s.close();
    return (await utf8.decoder.bind(s).join()).trim();
  }

  test('asks for its caller, streaming the reply back', () async {
    final service = await ChatGptDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final pieces = <String>[];
    final out = await ChatGptDriverSocket(socket).askTheModel(
      seat,
      gpt,
      'You are Cam.',
      'hello there you',
      report: (p) => pieces.add((p as ReplyArriving).text),
    );
    expect((out as Ran<ModelReply>).output.text, 'hello there you');
    expect(pieces, ['hello', 'there', 'you']);
    expect(driver.calls.single, (seat, gpt, 'You are Cam.', 'hello there you'));
  });

  test('carries a refusal back across the socket', () async {
    final service = await ChatGptDriverService.start(driver, me, socket);
    addTearDown(service.close);
    final out = await ChatGptDriverSocket(socket)
        .askTheModel(seat, gpt, '', 'refuse', report: (_) {});
    expect((out as Refused).why, 'chatgpt: no');
  });

  test('answers the probe {} without asking the model', () async {
    final service = await ChatGptDriverService.start(driver, me, socket);
    addTearDown(service.close);
    expect(
      await raw('{}'),
      '{"kind":"finished","outcome":{"kind":"refused",'
      '"why":"not a call: modelCall.signIn: not a string"}}',
    );
    expect(driver.calls, isEmpty);
  });

  test('refuses a sign-in that is not a name', () async {
    final service = await ChatGptDriverService.start(driver, me, socket);
    addTearDown(service.close);
    expect(
      await raw(
        '{"signIn":"Nick!","model":"m","systemPrompt":"","request":"x"}',
      ),
      contains('not a call: modelCall.signIn: not a model sign-in'),
    );
    expect(driver.calls, isEmpty);
  });

  test('closes on any other user, unanswered', () async {
    final service = await ChatGptDriverService.start(
      driver,
      UserId.parse(me.number + 1)!,
      socket,
    );
    addTearDown(service.close);
    final out = await ChatGptDriverSocket(socket)
        .askTheModel(seat, gpt, '', 'hello', report: (_) {});
    // The service may hang up before the call is even written, so the
    // client's words vary; that it is refused and never asked does not.
    expect((out as Refused).why, startsWith('chat gpt driver: '));
    expect(driver.calls, isEmpty);
  });

  // The kernel's answer is faked, so each case runs on any platform.
  final unreadable = {
    'a Linux answer too short to hold a uid': SocketUserReader(
      kernel: Kernel.linux,
      readOption: (_, _) => Uint8List(4),
    ),
    'the overflow uid on Linux': SocketUserReader(
      kernel: Kernel.linux,
      readOption: (_, _) =>
          Uint8List(12)..buffer.asByteData().setUint32(4, 65534, Endian.host),
      overflowUid: () => 65534,
    ),
    'a kernel it cannot read': SocketUserReader(kernel: Kernel.other),
  };
  for (final MapEntry(key: what, value: reader) in unreadable.entries) {
    test('closes on $what, unanswered', () async {
      final service = await ChatGptDriverService.start(
        driver,
        me,
        socket,
        socketUserReader: reader,
      );
      addTearDown(service.close);
      final out = await ChatGptDriverSocket(socket)
          .askTheModel(seat, gpt, '', 'hello', report: (_) {});
      expect((out as Refused).why, startsWith('chat gpt driver: '));
      expect(driver.calls, isEmpty);
    });
  }

  test('asks for its caller as a faked kernel reports it', () async {
    final service = await ChatGptDriverService.start(
      driver,
      me,
      socket,
      socketUserReader: SocketUserReader(
        kernel: Kernel.linux,
        readOption: (_, _) =>
            Uint8List(12)
              ..buffer.asByteData().setUint32(4, me.number, Endian.host),
        overflowUid: () => 65534,
      ),
    );
    addTearDown(service.close);
    final out = await ChatGptDriverSocket(socket)
        .askTheModel(seat, gpt, '', 'hello', report: (_) {});
    expect((out as Ran<ModelReply>).output.text, 'hello');
  });

  test('will not start over a socket something listens on', () async {
    final service = await ChatGptDriverService.start(driver, me, socket);
    addTearDown(service.close);
    expect(
      () => ChatGptDriverService.start(driver, me, socket),
      throwsStateError,
    );
  });
}
