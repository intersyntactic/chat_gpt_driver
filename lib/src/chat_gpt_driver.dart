import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

import 'responses_event.dart';
import 'responses_request.dart';
import 'sign_in_file.dart';

/// The ChatGPT driver: a service on a Unix socket that asks the model
/// through a ChatGPT plan, one streamed POST to the Responses API per call,
/// signed in as the sign-in the call names, for the airlock's user alone.
///
/// A caller connects, writes one call as JSON and closes its side:
///
///     {"signIn":"…","model":"…","systemPrompt":"…","request":"…"}
///
/// The driver answers one JSON line per message and closes: any number of
/// `{"kind":"reported","progress":…}` while the reply streams, then one
/// `{"kind":"finished","outcome":…}`, the `Outcome<ModelReply>`. Who is
/// calling is read from the socket as the kernel reports it, never from the
/// call. It runs as its own user, so a sign-in's tokens are readable and
/// writable by this process and no other.
///
/// `request` is a `{tools, turns}` request, from which the driver builds
/// the Responses API `input` and `tools`, or a JSON array that is the
/// `input` itself, sent as its exact bytes ([responsesBody]). The driver
/// writes the rest of the body, so the model called is only ever the one
/// decided. A reply that calls tools is a [ProposedToolCalls]: the driver
/// runs nothing.
final class ChatGptDriver {
  ChatGptDriver._(
    this._signIns,
    this._endpoint,
    this._limit,
    this._reasoningEffort,
    this._log,
    this._socketUserCheck,
    this._socket,
    this._server,
  );

  /// Listens on [socket] for the user [caller] alone, asking the model as
  /// the sign-ins in [signIns] at [endpoint], the Responses API by default.
  /// [limit] is how long one call may run; [reasoningEffort], when given,
  /// is asked of every `{tools, turns}` call; [socketUserReader] reads each
  /// caller's user from the kernel, the running kernel's by default. A
  /// socket file nothing listens on is replaced.
  static Future<ChatGptDriver> start(
    Map<ModelSignInName, SignInFile> signIns, {
    required UserId caller,
    required File socket,
    Uri? endpoint,
    Duration limit = const Duration(minutes: 10),
    ReasoningEffort? reasoningEffort,
    void Function(String line)? log,
    SocketUserReader? socketUserReader,
  }) async {
    final driver = ChatGptDriver._(
      Map.unmodifiable(signIns),
      endpoint ?? Uri.parse('https://api.openai.com/v1/responses'),
      limit,
      reasoningEffort,
      log ?? _silent,
      SocketUserCheck.only(caller, reader: socketUserReader),
      socket,
      await _bind(socket),
    );
    driver._server.listen(driver._serve);
    return driver;
  }

  final Map<ModelSignInName, SignInFile> _signIns;
  final Uri _endpoint;

  /// How long one call may run before it is abandoned.
  final Duration _limit;

  /// How hard the model reasons on a `{tools, turns}` call; null sends none.
  final ReasoningEffort? _reasoningEffort;

  /// Where a failed call's status, unreadable events and each whole call's
  /// reasoning tokens go: for whoever runs the driver, not the record.
  /// Never a token.
  final void Function(String line) _log;

  final SocketUserCheck _socketUserCheck;
  final File _socket;
  final ServerSocket _server;

  static void _silent(String _) {}

  /// A whole trajectory as an input array fits well inside this.
  static const maxCall = 16 << 20;

  static Future<ServerSocket> _bind(File socket) async {
    final address = InternetAddress(
      socket.path,
      type: InternetAddressType.unix,
    );
    if (socket.existsSync()) {
      try {
        (await Socket.connect(address, 0)).destroy();
        throw StateError('a service is already listening on ${socket.path}');
      } on SocketException {
        socket.deleteSync();
      }
    }
    return ServerSocket.bind(address, 0);
  }

  Future<void> close() async {
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
  }

  Future<void> _serve(Socket socket) async {
    try {
      final verdict = _socketUserCheck.decide(socket);
      if (verdict is! Allowed) {
        _log('refused a caller: $verdict');
        socket.destroy();
        return;
      }
      final bytes = BytesBuilder(copy: false);
      var tooLarge = false;
      await for (final chunk in socket) {
        if (bytes.length + chunk.length > maxCall) {
          tooLarge = true;
          break;
        }
        bytes.add(chunk);
      }
      if (tooLarge) {
        _write(socket, const Finished(NothingRan('call too large')));
        await socket.close();
        return;
      }
      final ModelSignInName signIn;
      final ModelName model;
      final String systemPrompt;
      final String request;
      try {
        (signIn, model, systemPrompt, request) = decodeModelCall(
          jsonDecode(utf8.decode(bytes.takeBytes(), allowMalformed: true)),
        );
      } on FormatException catch (e) {
        _write(socket, Finished(NothingRan('not a call: ${e.message}')));
        await socket.close();
        return;
      }
      final outcome = await _ask(
        signIn,
        model,
        systemPrompt,
        request,
        (progress) => _write(socket, Reported(progress)),
      );
      _write(socket, Finished(outcome));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  static void _write(Socket socket, ProgramMessage<ModelReply> message) =>
      socket.add(
        utf8.encode(
          '${jsonEncode(encodeProgramMessage(message, encodeModelReply))}\n',
        ),
      );

  /// Everything up to the POST is [NothingRan]: no request has left. From
  /// the POST on, a failure is [StoppedPartway], whatever the status: the
  /// conversation has reached OpenAI, and the plan's allowance may be spent.
  Future<Outcome<ModelReply>> _ask(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request,
    Report report,
  ) async {
    final file = _signIns[signIn];
    if (file == null) return NothingRan('no model sign-in $signIn');
    final String body;
    try {
      body = responsesBody(
        model,
        systemPrompt,
        request,
        effort: _reasoningEffort,
      );
    } on FormatException catch (e) {
      return NothingRan(e.message);
    }
    final AccessToken token;
    switch (await file.accessToken()) {
      case Ran(:final output):
        token = output;
      case NothingRan(:final why) || StoppedPartway(:final why):
        return NothingRan('$signIn: $why');
    }
    final http = HttpClient();
    try {
      return await _call(
        http,
        token,
        body,
        report,
        '$signIn $model',
        // Looked up beside the call, not after it; it never throws.
        _contextWindow(http, signIn, model, token),
      ).timeout(_limit);
    } on TimeoutException {
      return StoppedPartway(
        why: 'timed out after ${_limit.inSeconds}s',
        done: null,
      );
    } on IOException catch (e) {
      _log('$signIn $model: $e');
      return StoppedPartway(
        why: 'lost ChatGPT mid-call: ${e.runtimeType}',
        done: null,
      );
    } finally {
      http.close(force: true);
    }
  }

  static ModelUsage? _usage(Spent? spent, int? contextWindow) =>
      switch (spent) {
        null => null,
        (
          :final input,
          :final cached,
          :final output,
          :final cacheWritten,
          reasoning: _,
        ) =>
          ModelUsage(
            input: input,
            cacheRead: cached,
            output: output,
            cacheCreation: cacheWritten,
            contextWindow: contextWindow,
          ),
      };

  /// The plan's `context_window` for [model], from `GET /models` beside the
  /// endpoint: read once per sign-in and kept, and read again for a model
  /// not yet seen. Null when the plan does not list it or cannot be
  /// reached, never a guess.
  Future<int?> _contextWindow(
    HttpClient http,
    ModelSignInName signIn,
    ModelName model,
    AccessToken token,
  ) async {
    if (_windows[signIn]?[model.value] case final known?) return known;
    try {
      final request = await http
          .getUrl(_endpoint.resolve('models'))
          .timeout(_modelsLimit);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${token.value}',
      );
      final response = await request.close().timeout(_modelsLimit);
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(_modelsLimit);
      if (response.statusCode != 200) {
        _log('$signIn: models: HTTP ${response.statusCode}');
        return null;
      }
      final windows = switch (jsonDecode(text)) {
        {'models': final List<Object?> models} => {
          for (final m in models)
            if (m case {
              'slug': final String slug,
              'context_window': final int window,
            })
              slug: window,
        },
        _ => <String, int>{},
      };
      _windows[signIn] = windows;
      return windows[model.value];
    } on IOException catch (e) {
      _log('$signIn: models: ${e.runtimeType}');
    } on TimeoutException {
      _log('$signIn: models: no answer in ${_modelsLimit.inSeconds}s');
    } on FormatException {
      _log('$signIn: models: not JSON');
    }
    return null;
  }

  /// Each sign-in's models' context windows, by slug.
  final _windows = <ModelSignInName, Map<String, int>>{};

  static const _modelsLimit = Duration(seconds: 15);

  Future<Outcome<ModelReply>> _call(
    HttpClient http,
    AccessToken token,
    String body,
    Report report,
    String call,
    Future<int?> contextWindow,
  ) async {
    final request = await http.postUrl(_endpoint);
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${token.value}')
      ..set(HttpHeaders.acceptHeader, 'text/event-stream');
    request.add(utf8.encode(body));
    final response = await request.close();
    if (response.statusCode != 200) {
      final text = await utf8.decoder.bind(response).join();
      _log('$call: HTTP ${response.statusCode}: ${_clip(text)}');
      final why = 'chatgpt: HTTP ${response.statusCode}${_errorOf(text)}';
      return StoppedPartway(why: why, done: null);
    }
    final done = <int, OutputItem>{};
    final arrived = StringBuffer();
    // With `store: false` a response can list no output: then the done
    // items are the reply, and failing those, what streamed.
    List<OutputItem> itemsOf(List<OutputItem>? output) {
      if (output != null) return output;
      if (done.isEmpty) return [SaidItem('$arrived')];
      final keys = done.keys.toList()..sort();
      return [for (final k in keys) done[k]!];
    }

    await for (final data in sseData(utf8.decoder.bind(response))) {
      switch (ResponsesEvent.parse(data)) {
        case TextArriving(:final text):
          arrived.write(text);
          report(ReplyArriving(text));
        case ItemDone(:final index, :final item):
          done[index] = item;
        case Completed(:final output, :final spent):
          _logReasoning(call, spent);
          return _reply(
            itemsOf(output),
            _usage(spent, await contextWindow),
            call,
          );
        case CutOff(:final output, :final spent, :final reason):
          _log('$call: cut off: $reason');
          _logReasoning(call, spent);
          // Calls in a cut-off reply may be partial, so only its text counts.
          return Ran(
            CutOffReply(
              text: _textOf(itemsOf(output)),
              usage: _usage(spent, await contextWindow),
            ),
          );
        case Stopped(:final why):
          return StoppedPartway(why: 'chatgpt: $why', done: null);
        case Unreadable():
          _log('$call: unreadable event: ${_clip('$data')}');
        case Other():
          break;
      }
    }
    return const StoppedPartway(
      why: 'chatgpt: the stream ended before the reply was whole',
      done: null,
    );
  }

  /// How much of a whole call's output was reasoning, which [ModelUsage]
  /// has no place for, so whether the model reasoned can be read later.
  void _logReasoning(String call, Spent? spent) => _log(switch (spent) {
    null => '$call: no usage reported',
    (:final output, reasoning: null, input: _, cached: _, cacheWritten: _) =>
      '$call: $output output tokens, reasoning not reported',
    (:final output, :final reasoning?, input: _, cached: _, cacheWritten: _) =>
      '$call: reasoned $reasoning of $output output tokens',
  });

  static String _textOf(List<OutputItem> items) => [
    for (final item in items)
      if (item case SaidItem(:final text)) text,
  ].join();

  /// A whole reply: [ProposedToolCalls] when the model called any tool,
  /// carrying its reasoning items as they came, else [FinishedReply].
  Outcome<ModelReply> _reply(
    List<OutputItem> items,
    ModelUsage? usage,
    String call,
  ) {
    final text = _textOf(items);
    final calls = <ToolCall>[];
    for (final item in items) {
      if (item case CallItem(:final callId, :final name, :final arguments)) {
        final id = ToolCallId.parse(callId);
        final input = ToolInput.parse(arguments);
        if (id == null || input == null) {
          _log('$call: unusable function_call: ${_clip('$callId $arguments')}');
          return StoppedPartway(
            why: id == null
                ? 'chatgpt: a call id that is empty, too long or has '
                      'control characters'
                : 'chatgpt: call $callId sent arguments that are not a '
                      'JSON object',
            done: null,
          );
        }
        calls.add(
          ToolCall(id: id, name: CalledToolName.fromSent(name), input: input),
        );
      }
    }
    if (calls.isEmpty) return Ran(FinishedReply(text: text, usage: usage));
    final reasoning = [
      for (final item in items)
        if (item case ReasoningItem(:final json)) json,
    ];
    return Ran(
      ProposedToolCalls(
        text: text,
        calls: calls,
        continuation: reasoning.isEmpty
            ? null
            : ProviderContinuation.parse(jsonEncode(reasoning)),
        usage: usage,
      ),
    );
  }

  /// `: <code>: <message>` from an error body, such as
  /// `subscription_sharing_usage_limit_exceeded`, or nothing.
  static String _errorOf(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return '';
    }
    final said = switch (json) {
      {'error': {'code': final String code, 'message': final String m}} =>
        '$code: $m',
      {'error': {'message': final String m}} => m,
      {'detail': final String detail} => detail,
      _ => null,
    };
    if (said == null) return '';
    return ': ${said.length <= 200 ? said : '${said.substring(0, 200)}…'}';
  }

  static String _clip(String s) =>
      s.length <= 2000 ? s : '${s.substring(0, 2000)}…';
}
