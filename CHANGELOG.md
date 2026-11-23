# Changelog

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
