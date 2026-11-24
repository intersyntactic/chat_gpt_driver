import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_chat_gpt_driver/is_chat_gpt_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';
import 'package:test/test.dart';

import 'start_driver.dart';

final cam = ModelSignInName.parse('cam-chatgpt')!;
final gpt = ModelName.parse('gpt-6.1-sol')!;

/// What the fake Responses API saw of one request.
typedef Seen = ({Map<String, String> headers, List<int> body});

void main() {
  late HttpServer server;
  late Directory dir;
  late Map<ModelSignInName, SignInFile> signIns;
  late Uri endpoint;
  late File socket;
  final seen = <Seen>[];
  // What the fake answers: a status and a body.
  late (int, String) answer;
  // What it answers `GET /v1/models` with, and how often it was asked.
  late (int, String) models;
  var modelLookups = 0;

  setUp(() async {
    seen.clear();
    modelLookups = 0;
    models = (
      200,
      jsonEncode({
        'models': [
          {'slug': 'gpt-6.1-sol', 'context_window': 500000},
          {'slug': 'gpt-6.2-astra', 'context_window': 272000},
        ],
      }),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      // wire-ok: the fake routes by the path the driver asks for.
      if (request.uri.path == '/v1/models') {
        modelLookups++;
        final (status, text) = models;
        request.response
          ..statusCode = status
          ..write(text);
        await request.response.close();
        return;
      }
      final body = <int>[];
      await request.forEach(body.addAll);
      final headers = <String, String>{};
      request.headers.forEach((k, v) => headers[k] = v.join(','));
      seen.add((headers: headers, body: body));
      final (status, text) = answer;
      request.response
        ..statusCode = status
        ..write(text);
      await request.response.close();
    });
    dir = await Directory.systemTemp.createTemp('driver');
    final signIn = ChatGptSignIn.fromTokens(
      clientId: 'oaiapp_test',
      hostId: 'h',
      accessToken: 'the-access-token',
      refreshToken: 'r',
      idToken: null,
      expiresIn: 3600,
      earliestRefreshAt: null,
      scopes: const [ChatGptSignIn.planScope],
      now: DateTime.now(),
    );
    signIns = {
      cam: SignInFile(
        File('${dir.path}/cam-chatgpt'),
        signIn,
        refresh: (_) => fail('refreshed'),
      ),
    };
    endpoint = Uri.parse('http://127.0.0.1:${server.port}/v1/responses');
    socket = await startDriver(signIns, endpoint: endpoint);
  });
  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  String sse(List<Object> events) =>
      [for (final e in events) 'data: ${jsonEncode(e)}\n\n'].join();

  Map<String, Object> message(String text) => {
    'type': 'message',
    'content': [
      {'type': 'output_text', 'text': text},
    ],
  };

  /// Asks over the socket as [signIn] for [model], cam for gpt by default.
  Future<(Outcome<ModelReply>, List<String>)> ask(
    String request, {
    ModelSignInName? signIn,
    ModelName? model,
    String systemPrompt = 'You are Cam.',
  }) async {
    final (out, reported) = await callOverSocket(
      socket,
      signIn ?? cam,
      model ?? gpt,
      systemPrompt,
      request,
    );
    return (
      out ?? fail('hung up on'),
      [for (final p in reported) (p as ReplyArriving).text],
    );
  }

  test('sends the approved input as its own bytes, and nothing else', () async {
    answer = (
      200,
      sse([
        {
          'type': 'response.completed',
          'response': {
            'output': [message('OK')],
          },
        },
      ]),
    );
    // Whitespace, an escape and non-ASCII: a re-encode would change these.
    const input = ' [ {"role":"user", "content":"Hi \\u00e9 ü"}\r\n] ';
    final (out, _) = await ask(input);
    expect((out as Ran<ModelReply>).output.text, 'OK');
    expect(
      seen.single.body,
      utf8.encode(
        '{"model":"gpt-6.1-sol","instructions":"You are Cam.",'
        '"store":false,"stream":true,"input":$input}',
      ),
    );
    expect(seen.single.headers['authorization'], 'Bearer the-access-token');
    expect(seen.single.headers['accept'], 'text/event-stream');
  });

  test('streams each delta, and the completed text is the reply', () async {
    answer = (
      200,
      '${sse([
            {'type': 'response.created'},
            {'type': 'response.output_text.delta', 'delta': 'Hel'},
          ])}data: {"type":"response.output_text.del'
          'ta","delta":"lo"}\n\n'
          '${sse([
            {
              'type': 'response.completed',
              'response': {
                'output': [message('Hello')],
              },
            },
          ])}',
    );
    final (out, pieces) = await ask('[{"role":"user","content":"Hi"}]');
    expect((out as Ran<ModelReply>).output.text, 'Hello');
    expect(pieces, ['Hel', 'lo']);
  });

  test(
    'with store false and no output listed, the done items are the reply',
    () async {
      answer = (
        200,
        sse([
          {
            'type': 'response.output_item.done',
            'output_index': 1,
            'item': message('second'),
          },
          {
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': {'type': 'reasoning'},
          },
          {
            'type': 'response.completed',
            'response': {'output': <Object>[]},
          },
        ]),
      );
      final (out, _) = await ask('[{"role":"user","content":"Hi"}]');
      expect((out as Ran<ModelReply>).output.text, 'second');
    },
  );

  Map<String, Object> completed(String text, Map<String, Object> usage) => {
    'type': 'response.completed',
    'response': {
      'output': [message(text)],
      'usage': usage,
    },
  };

  const usage = {
    'input_tokens': 1200,
    'input_tokens_details': {'cached_tokens': 1000},
    'output_tokens': 7,
  };

  test('reports usage with the cached tokens taken out of input, and the '
      'plan\'s context window', () async {
    answer = (200, sse([completed('OK', usage)]));
    final (out, _) = await ask('[{"role":"user","content":"Hi"}]');
    final reply = (out as Ran<ModelReply>).output;
    expect(reply, isA<FinishedReply>());
    expect(
      reply.usage,
      const ModelUsage(
        input: 200,
        cacheRead: 1000,
        output: 7,
        contextWindow: 500000,
      ),
    );
    expect(reply.usage!.context, 1200);
  });

  test(
    'a cache write, when OpenAI counts one, is taken out of input too',
    () async {
      answer = (
        200,
        sse([
          completed('OK', {
            'input_tokens': 1200,
            'input_tokens_details': {
              'cached_tokens': 1000,
              'cache_write_tokens': 150,
            },
            'output_tokens': 7,
          }),
        ]),
      );
      final (out, _) = await ask('[{"role":"user","content":"Hi"}]');
      final spent = (out as Ran<ModelReply>).output.usage!;
      expect(
        (spent.input, spent.cacheCreation, spent.context),
        (50, 150, 1200),
      );
    },
  );

  test(
    'reads the models once per sign-in, and again for a model not listed',
    () async {
      answer = (200, sse([completed('OK', usage)]));
      await ask('[{"role":"user","content":"Hi"}]');
      await ask('[{"role":"user","content":"Hi"}]');
      expect(modelLookups, 1);
      final (out, _) = await ask(
        '[{"role":"user","content":"Hi"}]',
        model: ModelName.parse('gpt-6.2-astra'),
      );
      expect(modelLookups, 1, reason: 'the first read listed it already');
      expect((out as Ran<ModelReply>).output.usage!.contextWindow, 272000);
      final (unseen, _) = await ask(
        '[{"role":"user","content":"Hi"}]',
        model: ModelName.parse('gpt-6.3-sol'),
      );
      expect(modelLookups, 2);
      expect((unseen as Ran<ModelReply>).output.usage!.contextWindow, isNull);
    },
  );

  test(
    'with the models out of reach, the window is unknown, never a guess',
    () async {
      models = (503, 'down');
      answer = (200, sse([completed('OK', usage)]));
      final (out, _) = await ask('[{"role":"user","content":"Hi"}]');
      final reply = (out as Ran<ModelReply>).output;
      expect(reply.text, 'OK');
      expect(reply.usage!.contextWindow, isNull);
    },
  );

  test('a cut-off reply ran: what came back, and what it spent', () async {
    answer = (
      200,
      sse([
        {'type': 'response.output_text.delta', 'delta': 'Half a'},
        {
          'type': 'response.incomplete',
          'response': {
            'incomplete_details': {'reason': 'max_output_tokens'},
            'output': <Object>[],
            'usage': usage,
          },
        },
      ]),
    );
    final (out, _) = await ask('[{"role":"user","content":"Hi"}]');
    final reply = (out as Ran<ModelReply>).output;
    expect(reply, isA<CutOffReply>());
    expect(reply.text, 'Half a');
    expect(reply.usage!.output, 7);
  });

  test('a failed response is refused with its error', () async {
    answer = (
      200,
      sse([
        {
          'type': 'response.failed',
          'response': {
            'error': {'code': 'server_error', 'message': 'boom'},
          },
        },
      ]),
    );
    final (out, _) = await ask('[{"role":"user","content":"Hi"}]');
    expect((out as Refused).why, 'chatgpt: failed: server_error: boom');
  });

  test('a stream that ends early is refused, never a short reply', () async {
    answer = (
      200,
      sse([
        {'type': 'response.output_text.delta', 'delta': 'Hal'},
      ]),
    );
    final (out, _) = await ask('[{"role":"user","content":"Hi"}]');
    expect((out as Refused).why, contains('ended before'));
  });

  test('an HTTP error is refused with its code', () async {
    answer = (
      429,
      '{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}',
    );
    final (out, _) = await ask('[{"role":"user","content":"Hi"}]');
    expect(
      (out as Refused).why,
      'chatgpt: HTTP 429: subscription_sharing_usage_limit_exceeded: limit',
    );
  });

  for (final (request, why) in [
    ('Hi', 'not JSON'),
    ('[]', 'empty input'),
    ('["Hi"]', 'not an object'),
    ('{"model":"gpt-4","input":[]}', 'a body'),
    ('"Hi"', 'not an input array'),
  ]) {
    test('refuses $request without calling', () async {
      final (out, _) = await ask(request);
      expect((out as Refused).why, contains(why));
      expect(seen, isEmpty);
    });
  }

  test('refuses a sign-in it does not hold', () async {
    final (out, _) = await ask(
      '[{"role":"user","content":"Hi"}]',
      signIn: ModelSignInName.parse('someone-else'),
    );
    expect((out as Refused).why, 'no model sign-in someone-else');
  });

  group('the socket', () {
    const hi = '[{"role":"user","content":"Hi"}]';

    test('answers the probe {} without asking the model', () async {
      expect(
        await rawCall(socket, '{}'),
        '{"kind":"finished","outcome":{"kind":"refused",'
        '"why":"not a call: modelCall.signIn: not a string"}}',
      );
      expect(seen, isEmpty);
    });

    test('refuses a sign-in that is not a name', () async {
      expect(
        await rawCall(
          socket,
          '{"signIn":"Nick!","model":"m","systemPrompt":"","request":"x"}',
        ),
        contains('not a call: modelCall.signIn: not a model sign-in'),
      );
      expect(seen, isEmpty);
    });

    test('refuses a call too large to carry', () async {
      expect(
        await rawCall(socket, ' ' * (ChatGptDriver.maxCall + 1)),
        contains('call too large'),
      );
      expect(seen, isEmpty);
    });

    // A refused caller is hung up on, sometimes before its call is written:
    // a broken pipe and an empty answer both count as no answer.
    test('closes on any other user, unanswered, and logs who', () async {
      final logged = <String>[];
      final other = await startDriver(
        signIns,
        endpoint: endpoint,
        caller: UserId.parse(me.number + 1),
        log: logged.add,
      );
      final (out, reported) = await callOverSocket(other, cam, gpt, '', hi);
      expect(out, isNull);
      expect(reported, isEmpty);
      expect(seen, isEmpty);
      expect(logged, [
        'refused a caller: not allowed: user $me is not one of '
            '{${me.number + 1}}',
      ]);
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
      test('closes on $what, unanswered, and logs why', () async {
        final logged = <String>[];
        final faked = await startDriver(
          signIns,
          endpoint: endpoint,
          socketUserReader: reader,
          log: logged.add,
        );
        final (out, _) = await callOverSocket(faked, cam, gpt, '', hi);
        expect(out, isNull);
        expect(seen, isEmpty);
        expect(logged, [startsWith('refused a caller: unread: ')]);
      });
    }

    test('asks for its caller as a faked kernel reports it', () async {
      answer = (200, sse([completed('OK', usage)]));
      final faked = await startDriver(
        signIns,
        endpoint: endpoint,
        socketUserReader: SocketUserReader(
          kernel: Kernel.linux,
          readOption: (_, _) =>
              Uint8List(12)
                ..buffer.asByteData().setUint32(4, me.number, Endian.host),
          overflowUid: () => 65534,
        ),
      );
      final (out, _) = await callOverSocket(faked, cam, gpt, '', hi);
      expect((out! as Ran<ModelReply>).output.text, 'OK');
    });

    test('will not start over a socket something listens on', () async {
      expect(
        () => ChatGptDriver.start(signIns, caller: me, socket: socket),
        throwsStateError,
      );
    });
  });
}
