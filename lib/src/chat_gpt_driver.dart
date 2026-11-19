import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

import 'responses_event.dart';
import 'sign_in_file.dart';

/// [AsksTheModel] through a ChatGPT plan: one streamed POST to the
/// Responses API per call, signed in as the sign-in the call names.
///
/// `request` is the Responses API `input`: a JSON array of the turns, sent
/// as its exact bytes. The driver writes the rest of the body itself, and
/// nothing else: `model`, `systemPrompt` as `instructions`, `store: false`
/// and `stream: true` ([body]). A request that is not an array, such as a
/// whole body, is refused, so the model called is only ever the one
/// decided.
final class ChatGptDriver implements AsksTheModel {
  ChatGptDriver(
    Map<ModelSignInName, SignInFile> signIns, {
    Uri? endpoint,
    this._limit = const Duration(minutes: 10),
    void Function(String line)? log,
  }) : _signIns = Map.unmodifiable(signIns),
       _endpoint = endpoint ?? Uri.parse('https://api.openai.com/v1/responses'),
       _log = log ?? _silent;

  final Map<ModelSignInName, SignInFile> _signIns;
  final Uri _endpoint;

  /// How long one call may run before it is abandoned.
  final Duration _limit;

  /// Where a failed call's status and unreadable events go: for whoever
  /// runs the driver, not the record. Never a token.
  final void Function(String line) _log;

  static void _silent(String _) {}

  /// The whole body for one call, [input] spliced in as its own bytes.
  /// [input] must already be a JSON array ([whyNotInput]).
  static String body(ModelName model, String systemPrompt, String input) =>
      '{"model":${jsonEncode(model.value)},'
      '"instructions":${jsonEncode(systemPrompt)},'
      '"store":false,"stream":true,'
      '"input":$input}';

  /// Why [request] cannot be the `input`, or null when it can: a JSON
  /// array of objects, at least one.
  static String? whyNotInput(String request) {
    final Object? json;
    try {
      json = jsonDecode(request);
    } on FormatException {
      return 'request is not JSON';
    }
    return switch (json) {
      List<Object?>(isEmpty: true) => 'request is an empty input',
      final List<Object?> items when items.every((i) => i is Map) => null,
      List<Object?>() => 'request holds an input item that is not an object',
      Map<String, Object?>() =>
        'request is a body; it must be only the input array',
      _ => 'request is not an input array',
    };
  }

  @override
  Future<Outcome<ModelReply>> askTheModel(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request, {
    required Report report,
  }) async {
    final file = _signIns[signIn];
    if (file == null) return Refused('no model sign-in $signIn');
    if (whyNotInput(request) case final why?) return Refused(why);
    final AccessToken token;
    switch (await file.accessToken()) {
      case Ran(:final output):
        token = output;
      case Refused(:final why):
        return Refused('$signIn: $why');
    }
    final http = HttpClient();
    try {
      return await _call(
        http,
        token,
        body(model, systemPrompt, request),
        report,
        '$signIn $model',
      ).timeout(_limit);
    } on TimeoutException {
      return Refused('timed out after ${_limit.inSeconds}s');
    } on IOException catch (e) {
      _log('$signIn $model: $e');
      return Refused('could not reach ChatGPT: ${e.runtimeType}');
    } finally {
      http.close(force: true);
    }
  }

  Future<Outcome<ModelReply>> _call(
    HttpClient http,
    AccessToken token,
    String body,
    Report report,
    String call,
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
      return Refused('chatgpt: HTTP ${response.statusCode}${_errorOf(text)}');
    }
    final done = <int, String>{};
    await for (final data in sseData(utf8.decoder.bind(response))) {
      switch (ResponsesEvent.parse(data)) {
        case TextArriving(:final text):
          report(ReplyArriving(text));
        case ItemDone(:final index, :final text):
          done[index] = text;
        case Completed(:final text):
          final keys = done.keys.toList()..sort();
          return Ran(
            ModelReply(text ?? [for (final k in keys) done[k]].join()),
          );
        case Stopped(:final why):
          return Refused('chatgpt: $why');
        case Unreadable():
          _log('$call: unreadable event: ${_clip('$data')}');
        case Other():
          break;
      }
    }
    return const Refused(
      'chatgpt: the stream ended before the reply was whole',
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
