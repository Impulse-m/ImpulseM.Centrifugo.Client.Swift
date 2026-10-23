# Migrating to 2.0.0

Version 2.0.0 of this fork adds the client features of the JS and Java SDKs of the same organization. Most of them are additive and off by default. This page lists what can break an existing app.

## New `CentrifugeError` cases

A `switch` over `CentrifugeError` with no `default` stops compiling. The new cases:

- `connectionClosed`: the connection was lost while a call was in flight (code 11).
- `transportWriteError(error:)`: a command could not be written.
- `clientRejected(code:message:)`: the rpc pool refused the call (closed pool, refused token, changed identity).
- `replyErrorDetails(CentrifugeReplyError)`: a server error reply to an rpc call that carries `appCode`, `appType` or `metadata`.

Add the cases you handle, or a `default` branch.

## Lost rpc calls fail with `connectionClosed`

A plain `rpc` call that was written before the connection was lost now fails with `connectionClosed` (11). Before 2.0.0 it failed with `clientDisconnected`. This applies to every client, with or without an instance. An app that retries on `clientDisconnected` must retry on `connectionClosed` too.

## Server error details of rpc calls

A server error reply to an rpc call that carries `appCode`, `appType` or `metadata` arrives as `replyErrorDetails` instead of `replyError`. Other server replies, such as connect, subscribe and refresh errors, stay `replyError`. An app that matches only `.replyError` for rpc calls misses those errors.

## New fields with defaults

`CentrifugeRpcResult` and `CentrifugeClientConfig` gain fields with default values. Initializers that use labels still compile. Code that builds these types positionally, or that relies on their memberwise initializer, must add the new arguments.

## Defect fixes on by default

These change behaviour without any setting:

- **Timer token refresh** follows the shared retry formula: 10 to 20 seconds after the first failure, growing with each failure up to `tokenRetryCap`. A token the server refused as expired is not sent again (`stopOnRefusedToken`, default true).
- **The ping watchdog** restarts on every decoded reply, not only on pings.
- **Command ids** wrap without a trap.
- **A pool connection whose session ended** is closed (`closeEndedSession`, default true).

## New, off by default

- Instance, server time and identity.
- Tracked rpc calls (`CentrifugeRpcOptions`, the `CentrifugeRpcCall` handle, msg_id, ack, cancel and deadlines).
- `refresh(token:)`.
- Publish debounce.
- Token exchange.
- `CentrifugeRpcPool`.

The README has a section for each one.
