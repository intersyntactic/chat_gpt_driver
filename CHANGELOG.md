# Changelog

## 0.1.0

- `ChatGptDriver`: `AsksTheModel` through a ChatGPT plan's Responses API, with `request` as the `input` array sent as its own bytes and the rest of the body written by the driver.
- `SignInFile`: a sign-in kept in its own writable file, refreshed one at a time and written before its new token is used.
- `ChatGptDriverService` and `ChatGptDriverSocket`: the driver as its own service, answering only the airlock's user.
- `bin/sign_in.dart`: signs a host in from a computer with a browser.
