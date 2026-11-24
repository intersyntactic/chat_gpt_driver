# is_chat_gpt_driver

intersyntactic's ChatGPT driver: a service on a Unix socket that asks the
model through a ChatGPT plan, by "Sign in with ChatGPT". Agent loops hold no model credential and
have no network; they propose a call, the airlock decides it, and this
driver is the only piece that reaches OpenAI.

It exists because a driver that runs an agent CLI cannot say exactly what
the model sees: `claude -p` adds its own environment block (working folder,
OS, shell, date) to every request, and a model can repeat anything in its
input. This driver writes every byte of the request body itself.

## One call

One streamed `POST https://api.openai.com/v1/responses` per call, with
`Authorization: Bearer <access token>` and `accept: text/event-stream`. The
body is exactly:

```
{"model":<model>,"instructions":<systemPrompt>,"store":false,"stream":true,"input":<request>}
```

- **`request` is the `input` array**, the turns of the conversation as
  Responses API items, and goes into the body as its own bytes: not
  decoded and re-encoded, so a hash of what the airlock approved is a hash
  of what was sent. A request that is not a JSON array of objects, such as
  a whole body, is refused without calling, so the model is only ever the
  one decided. Plain text is one turn:
  `[{"role":"user","content":"…"}]`.
- **The system prompt is `instructions`.** The plan rejects a system-role
  input item.
- **Nothing else is sent.** Not `max_output_tokens` (the plan refuses it),
  not a cache key, not tools. Measured in enspyrco/intersyntactic, "Reply
  with OK." and "Hi" are 15 input tokens: nothing is added above the
  system prompt.
- **Streaming.** Each `response.output_text.delta` is reported as
  `ReplyArriving`. On `response.completed` the reply is a `FinishedReply`:
  the text of its output or, when that lists none (it may with
  `store: false`), of the `response.output_item.done` items in order.
  `response.incomplete` (such as `max_output_tokens`) ran and spent
  tokens, so it is `Ran` too, as a `CutOffReply` holding what came back.
  `response.failed` and `error` are `Refused` with their reason, as is a
  stream that ends before either: a dropped connection is never a short
  reply.
- **Usage.** Each reply carries a `ModelUsage` from the response's
  `usage`. OpenAI counts cached and cache-written tokens inside
  `input_tokens`; `ModelUsage.input` has them taken out, so `cacheRead`
  is `cached_tokens`, `cacheCreation` is `cache_write_tokens` (null when
  absent) and `context` adds back up to `input_tokens`. `contextWindow` is
  the model's `context_window` from the plan's `GET /v1/models`, read
  beside the first call on each sign-in, kept, and read again for a model
  the list did not name. It is null when the list cannot be read or does
  not name the model, never a guess. The plan also lists a larger
  `max_context_window` behind an experimental setting; the smaller one is
  used.
- **HTTP errors** are refused with their code, such as
  `chatgpt: HTTP 429: subscription_sharing_usage_limit_exceeded: …`.
- **Ten minutes** at most per call.

Over HTTP a growing conversation barely hits the prompt cache;
enspyrco/intersyntactic fixed that with one WebSocket per conversation. Not
here yet: port it if a plan's allowance starts to run out.

## Sign-ins

A sign-in is OAuth with PKCE, and its refresh token **rotates on every
refresh and the old one dies**. So a sign-in is state, not a fixed secret:

- **Each in its own file**, in a directory the driver's user owns and
  writes: systemd's `StateDirectory=`, never `LoadCredential=` (read-only).
  The file is named for the model sign-in. The service refuses to start
  when the directory is open to group or others.
- **Written before use.** A refresh writes the new sign-in to a temporary
  file beside the old and renames it over, then uses the new access token.
- **One refresh at a time.** Calls that find a refresh due all wait on the
  same one; two at once would spend the same refresh token and the second
  would kill the sign-in. `test/sign_in_file_test.dart` pins this.
- **When**: five minutes before the access token expires, never before the
  reply's `earliest_refresh_at`, never within a minute of the last.
- **A dead sign-in** (`refresh_token_reused`, `invalid_grant` and the like)
  refuses every call until it is signed in again. A refresh that fails
  otherwise keeps using the token in hand until it expires.
- **In the log**, each refresh leaves exactly one line, never a token:
  `<file>: refreshed, good until <expires_at>`, or `<file>: refreshed but
  not written (…); a restart now loses this sign-in`, or `<file>: refresh
  refused: …; sign in again`, or `<file>: refresh failed: …`.
- **No token is ever printed**: `toString()` is `a chatgpt-sign-in` or `an
  access token`, and logs carry status codes, never bodies with tokens.

A file is:

```json
{
  "kind": "chatgpt-sign-in",
  "client_id": "oaiapp_…",
  "host_id": "urn:uuid:…",
  "access_token": "…",
  "refresh_token": "…",
  "id_token": "…",
  "expires_at": "2026-11-19T13:00:00.000Z",
  "earliest_refresh_at": "2026-11-19T12:01:00.000Z",
  "scopes": ["openid", "…", "chatgpt.tokens.use.direct"]
}
```

A sign-in without `chatgpt.tokens.use.direct` is identity only and cannot
spend the plan; the service will not start with one.

### Signing a host in

The OAuth redirect reaches `127.0.0.1` on the computer with the browser,
not the host, so sign in on a laptop and copy the file over
([OpenAI's self-hosted VM guide](https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms)):

```
dart run is_chat_gpt_driver:sign_in cam-chatgpt
scp ~/.config/intersyntactic/chat-gpt-driver/cam-chatgpt \
  host:/var/lib/intersyntactic-chat-gpt-driver/cam-chatgpt
rm ~/.config/intersyntactic/chat-gpt-driver/cam-chatgpt
```

`sign_in` takes the model sign-in's name, never a path, and always writes
to `~/.config/intersyntactic/chat-gpt-driver/` (mode 0700), outside any
checkout, so a sign-in can't be committed by accident.

Each host gets **its own sign-in**: a new client registration and a fresh
`ext_agent_host_id`, never a copy of another app's. Two holders of one
sign-in rotate each other's refresh token away. The host refreshes it from
then on, so the laptop's copy is stale at the host's first refresh. A host
whose sign-in has died is signed in again with `--again <file>`, which
keeps its client and host id.

## Running as its own service

```
CHAT_GPT_DRIVER_SOCKET=/run/intersyntactic-chat-gpt-driver/chat-gpt-driver.sock \
  CHAT_GPT_DRIVER_CALLER=airlock \
  dart run is_chat_gpt_driver:service   # STATE_DIRECTORY from StateDirectory=
```

The unit needs `StateDirectory=intersyntactic-chat-gpt-driver` with
`StateDirectoryMode=0700`, which keeps the sign-ins from everyone else
whatever their files' modes. The airlock reaches the socket through
`Group=`, a callers group it joins, with
`RuntimeDirectoryMode=0750` and `UMask=0007`, so the socket is
group-writable. (`UMask=0077` would leave the airlock unable to connect.)
Run one instance per state directory: refreshes are one at a time within a
process, not across processes.

At start it loads the sign-ins and prints one line:

```
listening on <socket> for <caller>, model sign-ins: <names>
```

Any configuration it cannot start with exits 78, including a state
directory with no sign-ins. `CHAT_GPT_DRIVER_ALLOW_NO_SIGN_INS=1` lets it
start with none, listening and refusing every call: for a rehearsal that
proves the binary, sandbox and socket without a live sign-in, never for the
live unit. SIGTERM and SIGINT close it cleanly.

The service reads who is calling from the socket as the kernel reports it
(`SO_PEERCRED`) and closes any other user's connection unanswered. A caller
writes one call as JSON and closes its side; the service answers one JSON
line per message and closes:

```
→ {"signIn":"cam-chatgpt","model":"gpt-6.1-sol","systemPrompt":"…","request":"[{\"role\":\"user\",\"content\":\"Hi\"}]"}
← {"kind":"reported","progress":{"kind":"replyArriving","text":"…"}}   (any number)
← {"kind":"finished","outcome":{"kind":"ran","output":"<the reply>"}}
← {"kind":"finished","outcome":{"kind":"refused","why":"…"}}
```

`{}` is a probe that never reaches the model:

```
← {"kind":"finished","outcome":{"kind":"refused","why":"not a call: modelCall.signIn: not a string"}}
```

The package holds no client for this wire: each caller, the airlock
included, writes its own, and holds no secret.
