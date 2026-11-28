import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_model_vocabulary/is_model_vocabulary.dart';

/// The whole Responses API body for one call. The driver writes everything
/// but the turns itself, so the model called is only ever the one decided.
///
/// [request] takes one of two shapes:
/// - a `{tools, turns}` [ModelRequest], from which `input` and `tools` are
///   built, the same bytes for the same request every time, since a replay
///   is matched byte for byte;
/// - a JSON array, the Responses `input` itself, spliced in as its own
///   bytes, as every request was before tools.
///
/// A request that is neither is a [FormatException] saying why. [effort],
/// when given, goes in a `{tools, turns}` body only: an input array's body
/// stays as the bytes the airlock approved.
String responsesBody(
  ModelName model,
  String systemPrompt,
  String request, {
  ReasoningEffort? effort,
}) {
  final Object? json;
  try {
    json = decodeJsonRefusingDuplicateKeysAndUnsafeIntegers(request);
  } on FormatException catch (e) {
    throw FormatException('request is not JSON the driver reads: ${e.message}');
  }
  return switch (json) {
    List<Object?>(isEmpty: true) => throw const FormatException(
      'request is an empty input',
    ),
    final List<Object?> items when items.every((i) => i is Map) =>
      '{"model":${jsonEncode(model.value)},'
          '"instructions":${jsonEncode(systemPrompt)},'
          '"store":false,"stream":true,'
          '"input":$request}',
    List<Object?>() => throw const FormatException(
      'request holds an input item that is not an object',
    ),
    _ when JsonObject.parse(json) != null => _fromTurns(
      model,
      systemPrompt,
      ModelRequest.decode(request),
      effort,
    ),
    _ => throw const FormatException(
      'request is neither {tools, turns} nor an input array',
    ),
  };
}

/// How hard the model reasons before it answers, sent as
/// `reasoning.effort`. With none sent, the model may not reason at all.
enum ReasoningEffort {
  low,
  medium,
  high;

  /// The effort named [name], or null when none is.
  static ReasoningEffort? parse(String name) => values.asNameMap()[name];
}

String _fromTurns(
  ModelName model,
  String systemPrompt,
  ModelRequest request,
  ReasoningEffort? effort,
) {
  if (request.turns.isEmpty) {
    throw const FormatException('request has no turns');
  }
  // Dropping a named tool would hide it from the model without a word, so
  // a request carrying one is refused until the driver can send them.
  if (request.namedTools.isNotEmpty) {
    throw const FormatException('this driver does not send named tools yet');
  }
  return jsonEncode({
    'model': model.value,
    'instructions': systemPrompt,
    'store': false,
    'stream': true,
    // Without this, store:false gives reasoning items with nothing in
    // them to send back, and the model loses its reasoning at every call.
    'include': ['reasoning.encrypted_content'],
    if (effort != null) 'reasoning': {'effort': effort.name},
    if (request.tools.isNotEmpty)
      'tools': [
        for (final tool in request.tools)
          {
            'type': 'function',
            'name': tool.name.value,
            'description': tool.description,
            'parameters': tool.inputSchema.asUncheckedMap(),
            'strict': false,
          },
      ],
    'input': [
      for (final turn in request.turns)
        ...switch (turn) {
          UserSaid(:final text) => [_message('user', text)],
          AgentSaid(:final text) => [_message('assistant', text)],
          AgentCalledTools(:final text, :final calls, :final continuation) => [
            ...?_continued(continuation?.text),
            if (text.isNotEmpty) _message('assistant', text),
            for (final call in calls)
              {
                'type': 'function_call',
                'call_id': call.id.value,
                'name': call.name.asSent,
                'arguments': call.input.text,
              },
          ],
          ToolAnswered(:final callId, :final result) => [
            {
              'type': 'function_call_output',
              'call_id': callId.value,
              'output': toolOutput(result),
            },
          ],
          // Unreachable: a request defining named tools has some, and those
          // are refused above.
          NamedToolsDefined() => throw const FormatException(
            'this driver does not send named tools yet',
          ),
        },
    ],
  });
}

Map<String, Object?> _message(String role, String text) => {
  'role': role,
  'content': text,
};

/// The items a continuation holds, sent back unchanged ahead of the calls
/// they led to.
List<Object?>? _continued(String? text) => switch (text) {
  null => null,
  _ => switch (decodeJsonRefusingDuplicateKeysAndUnsafeIntegers(text)) {
    final List<Object?> items when items.every((i) => i is Map) => items,
    _ => throw const FormatException(
      'a continuation that is not a list of items',
    ),
  },
};

/// How a tool's result reads to the model. A `function_call_output` has no
/// error flag, so every output starts with one of these lines, written by
/// the driver alone. The first line is always the driver's, never the
/// tool's text, so a fetched page that says "refused" can't pass as the
/// airlock refusing.
const ranLine = '[tool ran]';
const failedLine = '[tool failed]';
const refusedLine = '[refused by the airlock: nothing ran]';

/// [result] as `function_call_output` text.
String toolOutput(ToolResult result) => switch (result) {
  ToolRan(:final text) => '$ranLine\n$text',
  ToolFailed(:final text) => '$failedLine\n$text',
  ToolRefused(:final why) => '$refusedLine\n$why',
};
