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
      Completed(switch (response) {
        {'output': final List<Object?> output} when output.isNotEmpty =>
          output.map(_text).join(),
        _ => null,
      }),
    {
      'type': 'response.incomplete',
      'response': {'incomplete_details': {'reason': final String reason}},
    } =>
      Stopped('incomplete: $reason'),
    {'type': 'response.incomplete'} => const Stopped('incomplete'),
    {'type': 'response.failed', 'response': {'error': final Object? error}} =>
      Stopped('failed: ${_error(error)}'),
    {'type': 'response.failed'} => const Stopped('failed'),
    {'type': 'error', 'error': final Object? error} => Stopped(_error(error)),
    {'type': 'error'} => Stopped(_error(json)),
    Map<String, Object?>() => const Other(),
    _ => const Unreadable(),
  };

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

/// The reply is whole. [text] is its output's text, or null when the
/// response listed no output.
final class Completed extends ResponsesEvent {
  const Completed(this.text);
  final String? text;
}

/// The call is over without a whole reply, because [why].
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
