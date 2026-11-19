import 'dart:convert';
import 'dart:io';

import 'package:is_chat_gpt_driver/is_chat_gpt_driver.dart';
import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

final cam = ModelSignInName.parse('cam-chatgpt')!;
final gpt = ModelName.parse('gpt-6.1-sol')!;

/// What the fake Responses API saw of one request.
typedef Seen = ({Map<String, String> headers, List<int> body});

void main() {
  late HttpServer server;
  late Directory dir;
  late ChatGptDriver driver;
  final seen = <Seen>[];
  // What the fake answers: a status and a body.
  late (int, String) answer;

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
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
    driver = ChatGptDriver({
      cam: SignInFile(
        File('${dir.path}/cam-chatgpt'),
        signIn,
        refresh: (_) => fail('refreshed'),
      ),
    }, endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1/responses'));
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

  Future<(Outcome<ModelReply>, List<String>)> ask(String request) async {
    final pieces = <String>[];
    final out = await driver.askTheModel(
      cam,
      gpt,
      'You are Cam.',
      request,
      report: (p) => pieces.add((p as ReplyArriving).text),
    );
    return (out, pieces);
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
    final out = await driver.askTheModel(
      ModelSignInName.parse('someone-else')!,
      gpt,
      '',
      '[{"role":"user","content":"Hi"}]',
      report: (_) {},
    );
    expect((out as Refused).why, 'no model sign-in someone-else');
  });
}
