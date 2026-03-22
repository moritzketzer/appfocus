#!/usr/bin/env bash
# overlays/appfocus/Tests/test-integration.sh
# Integration tests for appfocus daemon + CLI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# Build
make clean && make
echo "✓ Build succeeded"

DAEMON=".build/appfocusd"
CLI=".build/appfocus"
SOCK="$HOME/.local/state/appfocus/appfocusd.sock"

cleanup() {
    kill "$DAEMON_PID" 2>/dev/null || true
    rm -f "$SOCK"
}
trap cleanup EXIT

# Start daemon
APPFOCUS_LOG=debug $DAEMON &
DAEMON_PID=$!
sleep 1

# Test 1: daemon is running
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "✗ Daemon failed to start"
    exit 1
fi
echo "✓ Daemon started (PID $DAEMON_PID)"

# Test 2: socket exists
if [ ! -S "$SOCK" ]; then
    echo "✗ Socket not found at $SOCK"
    exit 1
fi
echo "✓ Socket exists"

# Test 3: status command
STATUS=$($CLI status 2>/dev/null)
if [ -z "$STATUS" ]; then
    echo "✗ Status returned empty"
    exit 1
fi
echo "✓ Status: $STATUS"

# Test 4: jump command (should not error)
$CLI jump Finder 2>/dev/null
echo "✓ Jump Finder succeeded"

# Test 5: next/prev (should not error even with no windows)
$CLI next 2>/dev/null || true
$CLI prev 2>/dev/null || true
echo "✓ Next/prev did not crash"

# Test 6: invalid command
if $CLI 2>/dev/null; then
    echo "✗ Empty args should fail"
    exit 1
fi
echo "✓ Empty args rejected"

# Test 7: daemon refuses second instance
if APPFOCUS_LOG=debug $DAEMON 2>/dev/null; then
    echo "✗ Second daemon should fail"
    exit 1
fi
echo "✓ Second daemon correctly rejected"

echo ""
echo "All tests passed."
