#!/bin/bash
# Recreates the ephemeral harness workspace (it lives in /tmp, which does not
# survive reboots), builds the fixture, runs the headless Quickshell harness
# against the working-tree Service.qml/SafeModel.js, then checks the disk
# state. Requires a real Wayland session (Quickshell needs a compositor);
# only HOME/XDG_DATA_HOME/XDG_STATE_HOME are redirected, so the test never
# touches the real vault.
set -e
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=/tmp/omasafe-xtest

rm -rf "$T"
mkdir -p "$T/home" "$T/data" "$T/state"
cp "$REPO/Service.qml" "$REPO/SafeModel.js" \
   "$REPO/tests/harness/shell.qml" \
   "$REPO/tests/harness/build-v1.sh" \
   "$REPO/tests/harness/assert.sh" "$T/"

cd "$T"
bash build-v1.sh

echo "--- running headless harness ---"
env HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state" \
    qs -p "$T" > out.log 2> err.log || true
cat out.log
if grep -q "HARNESS FAIL" out.log; then
  echo "HARNESS FAILED"
  exit 1
fi
if ! grep -q "HARNESS ALL PASS" out.log; then
  echo "HARNESS DID NOT COMPLETE"
  exit 1
fi
if grep -qiE "TypeError|ReferenceError|is not a function|Cannot read" err.log; then
  echo "QML ERRORS PRESENT:"
  grep -iE "TypeError|ReferenceError|is not a function|Cannot read" err.log
  exit 1
fi

echo "--- on-disk assertions ---"
bash assert.sh
