# Protocol sync

`client.proto` is a copy of `definitions/client.proto` from the Protocol repository of the fork.
Never edit it here. The copy is LF-normalised; the source is CRLF, and the two match once
carriage returns are ignored.

The pins live in `tools.env`:

- `PROTOC_VERSION`, `PROTOC_SHA256`: protoc 34.0 and the SHA-256 of its release asset.
- `SWIFT_PROTOBUF_TAG`, `SWIFT_PROTOBUF_COMMIT`: protoc-gen-swift is built from swift-protobuf
  tag 1.35.0, which must resolve to commit 9bbb079b.
- `PROTOCOL_COMMIT`: the Protocol repo commit `client.proto` is copied from (70f37c2 at the
  last change).

The Makefile includes `tools.env`, and the proto-check workflow reads it into `GITHUB_ENV`.
Bump the pins in one place.

## Upstream merge

1. Run `git diff upstream/master -- client.proto` first. Each upstream-only change must be
   re-applied to the fork file before regeneration, because the merge conflicts with the
   fork's protocol fields in both `client.proto` and `client.pb.swift`.
2. Take `definitions/client.proto` whole from the new Protocol commit, and set
   `PROTOCOL_COMMIT` in `tools.env` to that commit.
3. Run `make proto` (protoc 34.0 and the plugin from the pinned tag), then commit the
   regenerated `Sources/SwiftCentrifuge/client.pb.swift`.

## What the proto-check workflow verifies

- `client.pb.swift` matches a regeneration from `client.proto` with the pinned generators.
- `client.proto` matches `definitions/client.proto` at `PROTOCOL_COMMIT` once carriage
  returns are ignored. The Protocol repo is public, so the check needs no token.

The workflow runs on pushes and pull requests that touch `client.proto`, `tools.env`,
`Makefile`, `client.pb.swift` or the workflow itself.
