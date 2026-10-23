# SwiftCentrifuge

Websocket client for [Centrifugo](https://github.com/centrifugal/centrifugo) server and [Centrifuge](https://github.com/centrifugal/centrifuge) library.

## About this fork

This is a fork of [centrifuge-swift](https://github.com/centrifugal/centrifuge-swift), the upstream Swift client SDK. The fork is built for the [Centrifugo server fork](https://github.com/Impulse-m/ImpulseM.Centrifugo) and is released from its own repository. The upstream [client SDK documentation](https://centrifugal.dev/docs/transports/client_api) applies here as well.

- **Current version:** 2.0.0. Install it with Swift Package Manager from `https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift.git` (see [Installation](#installation)). The breaking changes of 2.0.0 are listed in [MIGRATION.md](MIGRATION.md).
- **What the fork adds:**
  - [Instance, server time and identity](#instance-server-time-and-identity)
  - [Tracked rpc calls](#tracked-rpc-calls) and their [client error codes](#client-error-codes)
  - [RPC pool](#rpc-pool)
  - [Connection token refresh](#connection-token-refresh), including the token exchange
  - [Ping watchdog](#ping-watchdog)
  - [Publish debounce](#publish-debounce)
- **Sibling repositories:**
  - Server: [ImpulseM.Centrifugo](https://github.com/Impulse-m/ImpulseM.Centrifugo)
  - Core (Go library used by the server): [ImpulseM.Centrifugo.Core](https://github.com/Impulse-m/ImpulseM.Centrifugo.Core)
  - Protocol (source of `client.proto`): [ImpulseM.Centrifugo.Protocol](https://github.com/Impulse-m/ImpulseM.Centrifugo.Protocol)
  - JavaScript SDK: [ImpulseM.Centrifugo.Client.JS](https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.JS)
  - Java SDK: [ImpulseM.Centrifugo.Client.Java](https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Java)

> This SDK is built for the Centrifugo server fork. The one test suite that needs a real server, `GetStateTests`, runs against Centrifugo v6 from [docker-compose.yml](docker-compose.yml).

Check out [client SDK API specification](https://centrifugal.dev/docs/transports/client_api) to learn how this SDK behaves. It's recommended to read that before starting to work with this SDK as the spec covers common SDK behavior - describes client and subscription state transitions, main options and methods. Also check out examples folder.

The features implemented by this SDK can be found in [SDK feature matrix](https://centrifugal.dev/docs/transports/client_sdk#sdk-feature-matrix).

## Installation

This library is distributed through Swift Package Manager. The repository keeps `SwiftCentrifuge.podspec` from upstream so the file history stays mergeable. It is not published, and its `version` follows upstream's numbering (0.11.0), not this fork's release line.

### Swift Package Manager

In Xcode, use `File` -> `Add Package Dependencies...` and enter:

```
https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift.git
```

Or add it to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift.git", from: "2.0.0")
```

The module and product name is `SwiftCentrifuge`, so import it as:

```swift
import SwiftCentrifuge
```

Versions follow semantic versioning and are published as git tags `vX.Y.Z`. See the [releases page](https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift/releases) for the list of available versions and their changes.

If you get a warning complaining about missing pc file, you may need to install `pkg-config`. On macOS, this can be achieved with `brew install pkg-config`.

## Dependencies

This library depends on [SwiftProtobuf](https://github.com/apple/swift-protobuf).

## Requirements

- iOS 12.0
- Xcode 16.0 or newer. The package manifest declares `swift-tools-version:6.0`, which needs a Swift 6.0 toolchain.

## Getting Started

An [example app](Example) is included demonstrating basic client functionality. The [console example](Examples/ConsoleExample) runs against a local Centrifugo: `make run-console-example`.

## Instance, server time and identity

- `CentrifugeClientConfig.instance` is an optional id of the client: 22 to 64 characters of `A-Z`, `a-z`, `0-9`, `_` or `-`. It is sent in the connect request and is never written to the debug log, which shows `connect instance=<redacted>`. `CentrifugeClient.create(endpoint:config:delegate:)` throws `CentrifugeError.configurationError` for an invalid instance; `CentrifugeClient(endpoint:config:delegate:)` still returns a client, which reports the error through `onError` at `connect()`.
- `serverTimeMillis()` returns the server time: the local clock plus the offset of the last command reply that carried a time. It needs `client.reply_include_server_time` on the server. Before such a reply it returns the local time.
- `CentrifugeClientDelegate.onAuth(_:_:)` reports the `user` and `authClass` of the connection on every connect, and on a refresh that changes them.

## Tracked rpc calls

A call made with `rpc(method:data:options:completion:)` is tracked when the client has an `instance` and the server confirmed the RPC options on the connection. A tracked call carries a msg_id, so the server runs it at most once. Its reply is acknowledged with the next command, and a call that was written when the connection was lost is sent again on the next connection, with the same msg_id and `retransmit` set. The rpc method returns a `CentrifugeRpcCall`; `cancel()` on it fails a call that is not sent yet, and sends a cancel to the server for a sent one.

- `CentrifugeRpcOptions` carries the headers of the call and its `timeout`, the deadline across all its attempts. The explicit timeout must be above 0 and no more than `CentrifugeClientConfig.timeout`.
- `CentrifugeClientConfig.maxPendingRpc` (default 32, at least 1) bounds the calls of a client with an instance that are not settled yet. A call beyond it fails at once with code 16. A client without an instance has no bound.
- A server error that the server answers with `x-centrifugo-retry` metadata was not executed. `new_msg_id` makes the client resend the call with a new msg_id, at most twice; `later` resends it with the same msg_id after a delay, at most three times. The error of the last attempt reaches the completion unchanged.
- `CentrifugeRpcResult.cached` is true when the server answered from its record of an earlier call with the same msg_id.
- A call on a connection without the RPC options is sent as a plain request. Its headers cannot be carried, so such a call fails with code 15.

**Breaking change (Swift fork v2.0.0):** a server error reply to an rpc call that carries an application code, type or metadata arrives as `CentrifugeError.replyErrorDetails(CentrifugeReplyError)`, not as `.replyError`. An app that matches only `.replyError` misses those errors. Errors without them stay `.replyError`, and server replies to connect, subscribe and refresh always stay `.replyError`. `CentrifugeError` gains the cases `connectionClosed`, `transportWriteError`, `clientRejected` and `replyErrorDetails`, so a `switch` over `CentrifugeError` needs a `default` case. `CentrifugeRpcResult` gains `cached`, and `CentrifugeClientConfig` gains `maxPendingRpc`, both with defaults.

**Breaking change (Swift fork v2.0.0):** a plain rpc call (a client without an `instance`, or a connection without the RPC options) that was written when the connection was lost now fails with `CentrifugeError.connectionClosed`, not `clientDisconnected`. An app that retries an rpc on `clientDisconnected` after a network drop must retry on `connectionClosed` as well. This applies to every client, with or without an `instance`.

### Client error codes

Codes 15 to 18 are client-local errors of the fork SDKs; a server never sends them. The Swift forms are:

| Code | Swift form | Meaning |
|---|---|---|
| 10 | `transportWriteError(error:)` | Reserved. It is reached only when a request fails to encode, which no protobuf request of the client can do, and the transport gives no write error signal, so no call receives it today. |
| 11 | `connectionClosed` | The connection was lost while the call was on it, and the call cannot be resent on the next one. |
| 12 | `configurationError(message:)` | The configuration cannot work, for example an invalid instance or a `maxPendingRpc` below 1. |
| 15 | `replyError(code: 15, ...)` | The call was not sent: the connection cannot carry what it asks for (headers). |
| 16 | `replyError(code: 16, ...)` | The call was not sent: `maxPendingRpc` is reached, or 32 `refresh()` calls are in progress. |
| 17 | `replyError(code: 17, ...)` | The call was cancelled with `cancel()`. |
| 18 | `replyError(code: 18, ...)` | A redirect of a pool call did not complete: its URL was refused, or its fetch failed, or its status, its redirect or its body was refused. |

`clientRejected(code:message:)` carries the refusals the client makes itself, such as a closed rpc pool. It is never a server reply.

## RPC pool

`CentrifugeRpcPool(main:options:)` (or `CentrifugeRpcPool.create`, which throws for options that cannot work) runs plain calls for large payloads on several connections per endpoint URL. `endpoints` maps an endpoint key to URLs; each connection carries up to `maxInflightPerConnection` calls (default 1), and at most `maxConnectionsPerEndpoint` connections open per URL (default 2). A call that finds no free slot waits in the line of its key, up to `maxQueued` (default 64); a call beyond that fails with `replyError(code: 16)` unless it can open a connection. A connection without calls for `idleTimeout` (default 60 seconds) closes. `close(completion:)` closes every connection: waiting calls fail with `replyError(code: 17)`, calls in flight with `connectionClosed`, and later calls with `clientRejected(code: 4)`. The pool's calls use the main client's queue and clock, so a delegate callback may call `stats()` and `close(completion:)`.

### Failures and resends

- A call made while the main client is disconnected fails with `clientDisconnected`, or with `unauthorized` when the session ended. A call whose options cannot work (for example an `affinity` without `affinityHeader`, or a `timeout` above the pool's) fails with `configurationError`.
- A call lost with its connection is sent again on a connection of its key, at the back of the line.
- A call that the server refuses with `x-centrifugo-retry: later` is sent again after a random delay of up to 250 ms, doubled for each later resend of that call, and never longer than the time left before its deadline.
- The `reroute` option maps a server error reply to an endpoint key, and the call then moves to the front of that key's line.
- `retries` (default 3) bounds all resends of one call together, and no resend goes past the call's deadline.
- A connection that the server closes for message size (close code 1009) or that ends as unauthorized settles its calls in flight with `connectionClosed`, and none of them is sent again. The pool reports no error event for these closes.
- A server error reply to a pool call that carries an application code, type or metadata arrives as `replyErrorDetails`.
- The pool has two resend patterns for a server error, and both use the same budget of `retries`. `reroute` moves the call to another endpoint key, at the front of its line. `redirect` does not resend the call at all: it fetches the bytes at a URL and settles the call with them. A call that the server refuses with `later` takes the delayed resend, not the move, unless `reroute` maps the error first.

### Redirect

The `redirect` option moves the bytes of a call to a URL. It receives the outcome of each call that reached a connection (a reply, a server error, or a connection that lost the call), and returns a `CentrifugeRedirect` (`url`, `headers`, and an optional `maxBytes`), or nil for no redirect. A timeout, a cancel and a close never reach it.

- The pool then fetches that URL with a GET that carries only the redirect's headers: no cookies and no credentials. The fetch follows no redirect, so a 3xx answer fails it, and so does a response whose URL differs from the requested one.
- The URL must be `https:`; `http:` is allowed only from an endpoint that is not secure, since `wss:` and `https:` endpoints are secure. A URL of another scheme fails the call before any request.
- A body over `maxBytes` (default `maxRedirectBytes`, 16 MiB) is refused before it is read in full, and a non-2xx status or a failed fetch fails the call. All of these settle the call with `replyError(code: 18)`.
- At most `maxRedirectsInflight` fetches run at once (default 4, from 1 to 16). A fetch that waits for a slot counts in `queued`, under `maxQueued`, and `close` settles it with `connectionClosed`. The deadline of the call covers the fetch.
- The fetch uses the transport settings of `urlSession` when one is given (proxy, TLS, timeouts, URL protocol classes), and none of its headers, cookies, credentials or cache. A runtime that follows a redirect anyway and reports no response URL cannot be detected by the pool, so it is outside this check; an application that needs a strict check on such a runtime uses its own session.

### Tokens and identity

- With `tokenFrom: true` the pool takes its token from its main client, the one way to share the client's token and session. Each connection is lent the main client's confirmed token: the token the server accepted at the client's last connect or accepted refresh, never one the application set and the client has not confirmed. A connection waits for the client while the client connects.
- A connection refused its token asks the client again, and the client renews its token once for each refused token; a renewal in progress is shared. When that renewal gives back the refused token, or the client has no `tokenGetter` and no `tokenExchange` to renew with, the token is spent: the calls that no connection can take fail with `clientRejected(code: 3, message: "token refused")` until the client's next confirmation.
- A call is bound to the identity generation of the client when it is made. When the identity changes, a call still waiting fails with `clientRejected(code: 3, message: "identity changed")`; when the session ends, it fails with `unauthorized`. A call is never written under another identity. Calls in flight complete on their connection.
- A connection of an identity the client has left retires at its next event: its next connect, a waiting call of its endpoint that finds it idle, or its idle timeout. A connection that the server confirms with another identity than its generation's is retired, and its token is spent.
- The pool does not walk its connections when the identity changes, so after an account switch call `close(completion:)` on the pool to close them at once, and build a new pool. An application that logs a user out must do the same: the connections keep their identity until the main client confirms another one, and a plain `disconnect()` of the main client does not end it.
- `closeEndedSession` (default true) closes the idle connections of a session the main client ended, as the client ends it, rather than at the idle timeout. Set it to `false` to keep them until their idle timeout or their next call.
- Without `tokenFrom`, `token` gives every connection the same token and `tokenGetter` asks for one per connection. `tokenFrom` is exclusive with both, and `CentrifugeRpcPool.create` throws `configurationError` for the combination.

## Connection token refresh

- `refresh(token:completion:)` refreshes the connection token now. With a token it sends that token; without one it fetches it from `tokenGetter`. The completion gets a `CentrifugeRefreshResult` (`expires`, `ttl`, `user`, `authClass`) or the server's error, unchanged. A refused token is not kept: the previous one stays. A call made while disconnected waits for the next connection. Calls run one at a time; at most 32 are in progress, and a call beyond that fails with code 16. Without a token and without a `tokenGetter`, the call fails with `configurationError`.
- A timer refresh that fails is retried with a fresh token when the server answers with a client error (code below 100), a temporary error, or code 109. The retry delay is 10 to 20 seconds at first and doubles with each consecutive failure, up to `CentrifugeClientConfig.tokenRetryCap` (default 300 seconds). The delay is drawn from 10 s plus a random part, as the Java SDK does. This changes the earlier fixed 5 to 10 second retry: the first retry now starts at 10 seconds.
- A timer refresh refused with code 103 keeps the connection and its identity, and is not retried. Any other server error ends the connection with that code, without a reconnect.
- With `CentrifugeClientConfig.stopOnRefusedToken` (default true), a retry that would send again the token the server refused as expired (109) is not sent. The connection is left to expire, and the next connect asks the token getter for a token. Set it to false to resend the same token.
- A subscription token refresh follows the same rules, with its own failure count and its own retry delay: a failed refresh is reported through `onError` as `subscriptionRefreshError`. Code 103 keeps the subscription and is not retried, and any other error that is not retried unsubscribes with that code. This differs from earlier versions, which unsubscribed on code 109 and on any non-temporary error.
- The token exchange (`CentrifugeClientConfig.tokenExchange`, a `CentrifugeTokenExchange`) gets the connection token from a refresh token the application stores, instead of from `tokenGetter`; the two are exclusive, and `CentrifugeClient.create` throws `configurationError` for both.
  - The application implements `load` (the stored refresh token, or nil), `store` (a rotated refresh token) and `exchange`, which calls the server over the connection with `event.rpc`.
  - An anonymous connect is completed by the exchange over the same connection, and the timer refresh renews the access token in the window of 0.7 to 0.9 of its ttl (0.6 to 0.9 with `earlyRenewal`).
  - A refused refresh token (an `unauthorized` from `exchange`, or an rpc error whose `appType` is in `refusalTypes`) is presented again once, inside the `grace` (default 30 seconds, at most 300); a second refusal of the same token ends the session with code 1.
  - Failed exchanges are retried with backoff, starting at 5 seconds.

## Ping watchdog

- The connection closes with code 2 (`no ping`) and reconnects when the server has been silent for one window: the server's ping interval plus `CentrifugeClientConfig.maxServerPingDelay`. Any reply counts as activity: a command reply, a push or a server ping. The detection is one window after the last reply.
- A server ping still gets its pong when the server asks for one.

## Publish debounce

- The server sets the publish window of a channel in its subscribe result (`publishDebounce`, milliseconds). A window of 0, the default, sends every publish. Otherwise the first publish is sent at once and opens the window; the publishes that follow inside the window replace one pending value, whose completion succeeds at once. The pending value is sent when the window ends, and a new window starts. A window longer than 2^31 - 1 ms is treated as 2^31 - 1 ms.
- The pending value is dropped when the subscription is unsubscribed or the connection is lost, so it is never sent after either.

## Usage in background

When a mobile application goes to the background there are OS-specific limitations for established persistent connections - which can be silently closed shortly. Thus in most cases you need to disconnect from a server when app moves to the background and connect again when app goes to the foreground.

## Using URLSessionWebSocketTask

See `useNativeWebSocket` option of Client which allows using `URLSessionWebSocketTask` instead of our fork of Starscream v3. Please report if you have successful setup of SwiftCentrifuge with `URLSessionWebSocketTask` – so we could eventually make it default.

### URLSessionWebSocketTask: configuring Proxy Settings

If you need to manually configure proxy settings for `URLSessionWebSocketTask`, follow these steps:
1.    Set up a proxy tool:
Configure your preferred proxy tool (e.g., Charles Proxy, Proxyman, or mitmproxy) according to its documentation. Ensure that it is properly set up to intercept traffic from your device.
2.    Verify proxy functionality:
Enable system-wide proxy settings on your device and check that traffic from system calls is captured in your proxy tool.
3.    Disable system proxy:
After verifying that the proxy tool works as expected, disable the system-wide proxy settings on your device.
4.    Configure CentrifugeClient for proxying:
Use the `urlSessionConfigurationProvider` option in `CentrifugeClientConfig` to explicitly provide proxy settings for `URLSessionWebSocketTask`.
5.    Test the connection:
Run your application and ensure that WebSocket traffic from SwiftCentrifuge is properly routed through your proxy tool.

## Running tests

```bash
make test
```

The suite uses [swift-testing](https://github.com/swiftlang/swift-testing), which ships with the Swift toolchain, so a full Xcode install is not required — `make test` wires up the framework search paths when only the Command Line Tools are present, and defers to `swift test` when Xcode is there.

Most suites talk to an in-process fake Centrifugo server and need no external dependencies. The suite which covers recovery and state loading (`GetStateTests`) needs a real Centrifugo (>= 6.8.0) configured as in [docker-compose.yml](docker-compose.yml):

```bash
docker compose up -d
make test
```

To run a single suite use a filter, for example:

```bash
./scripts/test.sh --filter GetStateTests
```

## License

SwiftCentrifuge is available under the MIT license. See [LICENSE](LICENSE) for details.

Some files are derived from Starscream (Apache-2.0), and the protocol definitions are MIT-licensed by their authors. Their notices and license texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Release (for maintainers)

Consumers pick up a release through its git tag, so no separate publish step is needed for Swift Package Manager. Releases are created by the [`release`](.github/workflows/release.yml) GitHub Actions workflow, which validates the version, runs the tests, tags the version and publishes a GitHub Release.

There are two ways to run it:

1. Push a version tag, for example `v1.0.1`.
2. Run the workflow manually from the Actions tab, or from the command line with a version without the leading `v`:

```
gh workflow run release.yml -f version=1.0.1
```
