#!/bin/sh
set -eu

swift build \
  --build-path .build/strict-concurrency \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
