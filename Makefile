.PHONY: all proto test run-console-example

all: proto

proto:
	protoc --swift_out=Sources/SwiftCentrifuge client.proto

# Runs the suite with or without Xcode installed - swift-testing ships with the
# Command Line Tools, the script just wires up its search paths. See CLAUDE.md.
test:
	./scripts/test.sh

run-console-example:
	cd Examples/ConsoleExample && swift run
