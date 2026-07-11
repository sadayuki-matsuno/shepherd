#!/bin/bash
# Build and run the test suite (./test.sh). No Xcode / XCTest required.
#
# The test binary links every app source EXCEPT:
#   - Sources/main.swift        (top-level app bootstrap — Tests/main.swift is the runner)
#   - Sources/AppDelegate+*.swift (extensions of the AppDelegate class declared there)
# so all pure logic (Models / Transcript / StatusStore / GitHubFacts / Commands / …)
# is exercised against the real implementations.
set -eu
cd "$(dirname "$0")"

SRCS=$(ls Sources/*.swift | grep -v -e '^Sources/main\.swift$' -e '^Sources/AppDelegate+')
mkdir -p build
# shellcheck disable=SC2086
swiftc -swift-version 5 -framework AppKit -framework IOKit -framework ApplicationServices \
  $SRCS Tests/*.swift -o build/shepherd-tests
exec ./build/shepherd-tests
