import 'dart:convert';

/// The `data:` payloads of a server-sent event stream, decoded. A chunk
/// boundary can fall anywhere, mid-line included; `event:` lines are
/// skipped, since each payload names its own type.
Stream<Object?> sseData(Stream<String> chunks) async* {
  var buffer = '';
  await for (final chunk in chunks) {
    buffer += chunk;
    while (true) {
      final nl = buffer.indexOf('\n');
      if (nl < 0) break;
      final line = buffer.substring(0, nl).trimRight();
      buffer = buffer.substring(nl + 1);
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        yield jsonDecode(payload);
      } on FormatException {
        yield const _NotJson();
      }
    }
  }
}

final class _NotJson {
  const _NotJson();
}

/// One event of the Responses API's stream, read once here so nothing else
/// reads its keys.
sealed class ResponsesEvent {
  const ResponsesEvent();

  static ResponsesEvent parse(Object? json) => switch (json) {
    {'type': 'response.output_text.delta', 'delta': final String delta} =>
      TextArriving(delta),
    {
      'type': 'response.output_item.done',
      'output_index': final int index,
      'item': final Object? item,
    } =>
      ItemDone(index, _text(item)),
    {'type': 'response.completed', 'response': final Object? response} =>
      Completed(_output(response), _spent(response)),
    {'type': 'response.incomplete', 'response': final Object? response} =>
      CutOff(_output(response), _spent(response), switch (response) {
        {'incomplete_details': {'reason': final String reason}} => reason,
        _ => 'no reason given',
      }),
    {'type': 'response.incomplete'} => const CutOff(
      null,
      null,
      'no reason given',
    ),
    {'type': 'response.failed', 'response': {'error': final Object? error}} =>
      Stopped('failed: ${_error(error)}'),
    {'type': 'response.failed'} => const Stopped('failed'),
    {'type': 'error', 'error': final Object? error} => Stopped(_error(error)),
    {'type': 'error'} => Stopped(_error(json)),
    Map<String, Object?>() => const Other(),
    _ => const Unreadable(),
  };

  /// The text of a response's output, or null when it lists none.
  static String? _output(Object? response) => switch (response) {
    {'output': final List<Object?> output} when output.isNotEmpty =>
      output.map(_text).join(),
    _ => null,
  };

  /// A response's `usage`, or null when it has none. OpenAI counts cached
  /// and cache-written tokens inside `input_tokens`; [Spent.input] is what
  /// is left once they are taken out.
  static Spent? _spent(Object? response) {
    if (response case {
      'usage':
          {
            'input_tokens': final int input,
            'output_tokens': final int output,
          } &&
          final usage,
    }) {
      final details = switch (usage) {
        {'input_tokens_details': final Object? d} => d,
        _ => null,
      };
      final cached = switch (details) {
        {'cached_tokens': final int n} => n,
        _ => 0,
      };
      final written = switch (details) {
        {'cache_write_tokens': final int n} => n,
        _ => null,
      };
      return (
        input: input - cached - (written ?? 0),
        cached: cached,
        output: output,
        cacheWritten: written,
      );
    }
    return null;
  }

  /// The text of one output item: a message's text and refusal parts in
  /// order; any other item, such as reasoning, has none.
  static String _text(Object? item) => switch (item) {
    {'type': 'message', 'content': final List<Object?> content} => [
      for (final part in content)
        switch (part) {
          {'type': 'output_text', 'text': final String text} => text,
          {'type': 'refusal', 'refusal': final String text} => text,
          _ => '',
        },
    ].join(),
    _ => '',
  };

  static String _error(Object? error) => _words(switch (error) {
    {'code': final String code, 'message': final String message} =>
      '$code: $message',
    {'message': final String message} => message,
    {'code': final String code} => code,
    _ => 'an error of no kind',
  });

  /// A refusal is kept for good, so a few words, not a body.
  static String _words(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

/// A piece of the reply's text as it streams.
final class TextArriving extends ResponsesEvent {
  const TextArriving(this.text);
  final String text;
}

/// Output item [index] is whole, and holds [text]. With `store: false` the
/// completed response can list no output, and these are the reply.
final class ItemDone extends ResponsesEvent {
  const ItemDone(this.index, this.text);
  final int index;
  final String text;
}

/// What one call spent, each count separate: [input] holds neither
/// [cached] nor [cacheWritten]. [cacheWritten] is null when OpenAI did not
/// say.
typedef Spent = ({int input, int cached, int output, int? cacheWritten});

/// The reply is whole. [text] is its output's text, or null when the
/// response listed no output.
final class Completed extends ResponsesEvent {
  const Completed(this.text, this.spent);
  final String? text;
  final Spent? spent;
}

/// The reply stopped before the model was done, because [reason] (such as
/// `max_output_tokens`), but tokens were spent and [text] came back.
final class CutOff extends ResponsesEvent {
  const CutOff(this.text, this.spent, this.reason);
  final String? text;
  final Spent? spent;
  final String reason;
}

/// The call failed, and no reply came back, because [why].
final class Stopped extends ResponsesEvent {
  const Stopped(this.why);
  final String why;
}

/// A payload that is not a JSON object.
final class Unreadable extends ResponsesEvent {
  const Unreadable();
}

/// Any other event, such as `response.created`.
final class Other extends ResponsesEvent {
  const Other();
}
