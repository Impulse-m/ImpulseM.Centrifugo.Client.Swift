# SwiftCentrifuge

## About this fork

This is a fork of [centrifuge-swift](https://github.com/centrifugal/centrifuge-swift), maintained alongside the [Centrifugo server fork](https://github.com/Impulse-m/ImpulseM.Centrifugo) of the same organization. The public API matches upstream, so the upstream [client SDK documentation](https://centrifugal.dev/docs/transports/client_api) applies here as well.

Sibling SDKs from the same organization:

- JavaScript: [JS client repository](https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.JS)
- Android (Java): [Java client repository](https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Java)

Websocket client for [Centrifugo](https://github.com/centrifugal/centrifugo) server and [Centrifuge](https://github.com/centrifugal/centrifuge) library.

There is no v1 release of this library yet – API still evolves. At the moment patch version updates only contain backwards compatible changes, minor version updates can have backwards incompatible API changes.

Check out [client SDK API specification](https://centrifugal.dev/docs/transports/client_api) to learn how this SDK behaves. It's recommended to read that before starting to work with this SDK as the spec covers common SDK behavior - describes client and subscription state transitions, main options and methods. Also check out examples folder.

The features implemented by this SDK can be found in [SDK feature matrix](https://centrifugal.dev/docs/transports/client_sdk#sdk-feature-matrix).

> **This SDK is compatible with [the Centrifugo server fork](https://github.com/Impulse-m/ImpulseM.Centrifugo) and upstream [Centrifugo](https://github.com/centrifugal/centrifugo) v6.**

## Installation

This library is distributed through Swift Package Manager only. CocoaPods and Carthage are not supported.

`SwiftCentrifuge.podspec` is kept from upstream only so the upstream file history stays mergeable. It is not used for any distribution, and its `version` follows upstream's numbering (0.11.0), not this fork's release line (1.x).

### Swift Package Manager

In Xcode, use `File` -> `Add Package Dependencies...` and enter:

```
https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift.git
```

Or add it to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift.git", from: "1.0.0")
```

The module and product name is `SwiftCentrifuge`, so import it as:

```swift
import SwiftCentrifuge
```

Versions follow semantic versioning and are published as git tags `vX.Y.Z`. See the [releases page](https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift/releases) for the list of available versions and their changes.

If you get a warning complaining about missing pc file, you may need to install `pkg-config`. On macOS, this can be achieved with `brew install pkg-config`.

## Dependencies

This library depends on [SwiftProtobuf](https://github.com/apple/swift-protobuf)

## Requirements

- iOS 12.0
- Xcode 16.0 or newer. The package manifest declares `swift-tools-version:6.0`, which needs a Swift 6.0 toolchain.

## Getting Started

An [example app](Example) is included demonstrating basic client functionality.

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

Codes 15 to 17 are client-local errors of the fork SDKs; a server never sends them. The Swift forms are:

| Code | Swift form | Meaning |
|---|---|---|
| 10 | `transportWriteError(error:)` | Reserved. It is reached only when a request fails to encode, which no protobuf request of the client can do, and the transport gives no write error signal, so no call receives it today. |
| 11 | `connectionClosed` | The connection was lost while the call was on it, and the call cannot be resent on the next one. |
| 12 | `configurationError(message:)` | The configuration cannot work, for example an invalid instance or a `maxPendingRpc` below 1. |
| 15 | `replyError(code: 15, ...)` | The call was not sent: the connection cannot carry what it asks for (headers). |
| 16 | `replyError(code: 16, ...)` | The call was not sent: `maxPendingRpc` is reached, or 32 `refresh()` calls are in progress. |
| 17 | `replyError(code: 17, ...)` | The call was cancelled with `cancel()`. |

`clientRejected(code:message:)` carries the refusals the client makes itself, such as a closed rpc pool. It is never a server reply.

## Connection token refresh

- `refresh(token:completion:)` refreshes the connection token now. With a token it sends that token; without one it fetches it from `tokenGetter`. The completion gets a `CentrifugeRefreshResult` (`expires`, `ttl`, `user`, `authClass`) or the server's error, unchanged. A refused token is not kept: the previous one stays. A call made while disconnected waits for the next connection. Calls run one at a time; at most 32 are in progress, and a call beyond that fails with code 16. Without a token and without a `tokenGetter`, the call fails with `configurationError`.
- A timer refresh that fails is retried with a fresh token when the server answers with a client error (code below 100), a temporary error, or code 109. The retry delay is 10 to 20 seconds at first and doubles with each consecutive failure, up to `CentrifugeClientConfig.tokenRetryCap` (default 300 seconds). The delay is drawn from 10 s plus a random part, as the Java SDK does. This changes the earlier fixed 5 to 10 second retry: the first retry now starts at 10 seconds.
- A timer refresh refused with code 103 keeps the connection and its identity, and is not retried. Any other server error ends the connection with that code, without a reconnect.
- With `CentrifugeClientConfig.stopOnRefusedToken` (default true), a retry that would send again the token the server refused as expired (109) is not sent. The connection is left to expire, and the next connect asks the token getter for a token. Set it to false to resend the same token.
- A subscription token refresh follows the same rules, with its own failure count and its own retry delay: a failed refresh is reported through `onError` as `subscriptionRefreshError`. Code 103 keeps the subscription and is not retried, and any other error that is not retried unsubscribes with that code. This differs from earlier versions, which unsubscribed on code 109 and on any non-temporary error.

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

SwiftCentrifuge is available under the MIT license. See LICENSE for details.

## Release (for maintainers)

Consumers pick up a release through its git tag, so no separate publish step is needed for Swift Package Manager. Releases are created by the [`release`](.github/workflows/release.yml) GitHub Actions workflow, which validates the version, runs the tests, tags the version and publishes a GitHub Release.

There are two ways to run it:

1. Push a version tag, for example `v1.0.1`.
2. Run the workflow manually from the Actions tab, or from the command line with a version without the leading `v`:

```
gh workflow run release.yml -f version=1.0.1
```
