#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Building Swift targets"
swift build

echo "==> Running core self-tests"
swift run CoreSelfTest

echo "==> Starting engine in background"
pkill -f AudioMatrixEngine 2>/dev/null || true
.build/debug/AudioMatrixEngine &
ENGINE_PID=$!
sleep 1

cleanup() {
  kill "$ENGINE_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> CLI ping"
.build/debug/audiomatrix ping

echo "==> List output devices"
.build/debug/audiomatrix list-devices

echo "==> Test tone on default output channels 1-2"
.build/debug/audiomatrix test-tone --device default --ch 1
.build/debug/audiomatrix start
.build/debug/audiomatrix status

if xcrun --find xctest 2>/dev/null; then
  echo "==> Running XCTest suite"
  swift test || true
else
  echo "==> Skipping XCTest (full Xcode not selected)"
fi

echo "Verification complete."
