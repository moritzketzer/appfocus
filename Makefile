# overlays/appfocus/Makefile
SWIFTC ?= swiftc
SWIFTFLAGS = -O -whole-module-optimization
FRAMEWORKS = -framework AppKit -framework ApplicationServices

COMMON := $(wildcard Sources/Common/*.swift)
DAEMON := $(wildcard Sources/Daemon/*.swift)
CLI    := $(wildcard Sources/CLI/*.swift)

# Test sources: all daemon sources except main.swift, plus test files
DAEMON_LIB := $(filter-out Sources/Daemon/main.swift,$(DAEMON))
TESTS      := $(wildcard Tests/Unit/*.swift)

# Swift Testing framework paths
PLATFORM   := /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
TOOLCHAIN  := /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain
TESTFLAGS  := -parse-as-library \
              -F $(PLATFORM)/Library/Frameworks \
              -plugin-path $(TOOLCHAIN)/usr/lib/swift/host/plugins/testing \
              -Xlinker -rpath -Xlinker $(PLATFORM)/Library/Frameworks

PREFIX ?= /usr/local

.PHONY: all clean install test

all: .build/appfocusd .build/appfocus

.build:
	mkdir -p .build

.build/appfocusd: $(COMMON) $(DAEMON) | .build
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $(COMMON) $(DAEMON) $(FRAMEWORKS)

.build/appfocus: $(COMMON) $(CLI) | .build
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $(COMMON) $(CLI)

.build/tests: $(COMMON) $(DAEMON_LIB) $(TESTS) | .build
	$(SWIFTC) $(TESTFLAGS) -o $@ $(COMMON) $(DAEMON_LIB) $(TESTS) $(FRAMEWORKS)

test: .build/tests
	.build/tests

clean:
	rm -rf .build

install: all
	install -d $(PREFIX)/bin
	install -m 755 .build/appfocusd $(PREFIX)/bin/appfocusd
	install -m 755 .build/appfocus $(PREFIX)/bin/appfocus
