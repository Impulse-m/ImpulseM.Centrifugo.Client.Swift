.PHONY: all proto proto-check-tools test run-console-example

PROTOC_VERSION := 34.0

all: proto

# The generator pin: protoc 34.0 and protoc-gen-swift built from swift-protobuf
# tag 1.35.0 (commit 9bbb079b). The plugin has no version flag, so only protoc is
# checked here; the proto-check workflow builds the plugin from that tag and fails
# on any diff.
proto-check-tools:
	@protoc --version | grep -qx "libprotoc $(PROTOC_VERSION)" || { echo "error: protoc $(PROTOC_VERSION) is required, found: $$(protoc --version)" >&2; exit 1; }

proto: proto-check-tools
	protoc --swift_out=Sources/SwiftCentrifuge client.proto

# Runs the suite with or without Xcode installed - swift-testing ships with the
# Command Line Tools, the script just wires up its search paths. See CLAUDE.md.
test:
	./scripts/test.sh

run-console-example:
	cd Examples/ConsoleExample && swift run
