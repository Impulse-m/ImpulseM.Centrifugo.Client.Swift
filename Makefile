.PHONY: all proto proto-check-tools test release run-console-example

# The generator and Protocol pins (protoc version, swift-protobuf tag and commit,
# the Protocol commit client.proto is copied from) live in tools.env, which the
# proto-check workflow reads too.
include tools.env

all: proto

# protoc 34.0 and protoc-gen-swift built from the pinned swift-protobuf tag. The
# plugin has no version flag, so only protoc is checked here; the proto-check
# workflow builds the plugin from that tag and fails on any diff.
proto-check-tools:
	@protoc --version | grep -qx "libprotoc $(PROTOC_VERSION)" || { echo "error: protoc $(PROTOC_VERSION) is required, found: $$(protoc --version)" >&2; exit 1; }

proto: proto-check-tools
	protoc --swift_out=Sources/SwiftCentrifuge client.proto

# Runs the suite with or without Xcode installed - swift-testing ships with the
# Command Line Tools, the script just wires up its search paths. See CLAUDE.md.
test:
	./scripts/test.sh

release:
	pod trunk push SwiftCentrifuge.podspec

run-console-example:
	cd Examples/ConsoleExample && swift run
