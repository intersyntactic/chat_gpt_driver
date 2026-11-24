# Changelog

## 0.3.0

- **Breaking:** is_effects ^0.15.0. `Refused` is gone, and every failure says whether anything reached OpenAI: `NothingRan` before the POST (a bad call, an unknown sign-in, a bad request, a sign-in that can't give a token), `StoppedPartway` (with `done` null) from the POST on (any HTTP error status, a failed or truncated stream, a timeout, a lost connection). A caller must move to is_effects 0.15.0 before this driver is deployed: an older one can't read `nothingRan` or `stoppedPartway`. The `{}` probe now answers `{"kind":"nothingRan",…}`.
- `request` may be a `{tools, turns}` `ModelRequest` (is_model_vocabulary ^0.2.0). The driver builds `input` and `tools` from it with the same bytes every time, offers tools with `strict: false`, and asks for `reasoning.encrypted_content`. A JSON array is still taken as the `input` itself, as before.
- A reply that calls tools is a `ProposedToolCalls`: each `function_call`'s `call_id`, its name as sent, and its arguments text unchanged, with the reply's reasoning items kept as a `ProviderContinuation`. The driver runs nothing. A `ToolAnswered` turn goes back as a `function_call_output` whose first line, `[tool ran]`, `[tool failed]` or `[refused by the airlock: nothing ran]`, only the driver writes.

## 0.2.5

- A successful token refresh logs one line once the new sign-in is written: `<sign-in file>: refreshed, good until <expires_at>`. It holds no token. Before, only a failed refresh logged anything, so the journal couldn't show that one had happened. If the write fails, the existing `refreshed but not written` line is logged instead, never both.

## 0.2.4

- is_unix_socket_user_check ^0.2.1. The driver asks `decide` for a verdict and, when it refuses a caller, logs one line saying why (`refused a caller: not allowed: …` or `refused a caller: unread: …`) before closing the socket. 0.2.1 keeps that line to one line even when the OS error text holds a line break. Who it admits is unchanged: only `Allowed` gets in.

## 0.2.3

- is_effects ^0.14.3, which moves `SignIn` into `is_sign_in_vocabulary` and re-exports it, and whose `decodeAddressPrefix` refuses keys other than `origin` and `pathPrefix`. The driver uses neither; no behaviour change.

## 0.2.2

- is_effects ^0.14.2, which moves the web-address types into `is_web_address_vocabulary` and re-exports them. The driver uses none of them; no behaviour change.

## 0.2.1

- is_effects ^0.14.1. Its breaking changes since 0.9.0 (file reads, web requests, program names) touch nothing the driver uses; the model call, `ModelReply` and `ProgramMessage` codecs are unchanged.

## 0.2.0

- **Breaking:** one class, `ChatGptDriver`, is the driver and owns its socket: `ChatGptDriver.start(signIns, caller:, socket:, …)` binds and serves, and `close()` stops it. `ChatGptDriverService` is gone, and `ChatGptDriver` no longer implements `AsksTheModel`: the only way to ask it is over the socket.
- **Breaking:** `package:is_chat_gpt_driver/service.dart` is gone, with `ChatGptDriverSocket`. A caller now writes its own client: connect to the socket, write one call as JSON and close the write side, then read one JSON line per message until `{"kind":"finished",…}` (the README shows each line).
- The socket protocol is unchanged.

## 0.1.0

- `ChatGptDriver`: `AsksTheModel` through a ChatGPT plan's Responses API, with `request` as the `input` array sent as its own bytes and the rest of the body written by the driver.
- `SignInFile`: a sign-in kept in its own writable file, refreshed one at a time and written before its new token is used.
- `ChatGptDriverService` and `ChatGptDriverSocket`: the driver as its own service, answering only the airlock's user.
- `bin/sign_in.dart`: signs a host in from a computer with a browser.
