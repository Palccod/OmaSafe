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
cp "$REPO/Service.qml" "$REPO/SafeModel.js" "$REPO/keyring-create.py" \
   "$REPO/omasafe-crypt.py" "$REPO/omasafe-scratch-verify.sh" \
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

echo "--- /tmp fallback harness (race-safe mktemp base) ---"
# Second boot with the fallback forced (the test seam inside Service.qml,
# because quickshell itself needs XDG_RUNTIME_DIR for Wayland): proves the
# randomized mktemp base is created, private, and that the scratch gate
# passes on it. Lives in its own directory so its shell.qml is separate.
FB="$T/fb"
mkdir -p "$FB"
for f in Service.qml SafeModel.js omasafe-crypt.py omasafe-scratch-verify.sh keyring-create.py; do
  cp "$REPO/$f" "$FB/$f"
done
cp "$REPO/tests/harness/fallback-sh.qml" "$FB/shell.qml"
env HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state" \
    OMASAFE_FORCE_TMP_FALLBACK=1 \
    qs -p "$FB" > fb-out.log 2> fb-err.log || true
cat fb-out.log
if grep -q "FALLBACK FAIL" fb-out.log; then
  echo "FALLBACK HARNESS FAILED"
  exit 1
fi
if ! grep -q "FALLBACK ALL PASS" fb-out.log; then
  echo "FALLBACK HARNESS DID NOT COMPLETE"
  exit 1
fi
if grep -qiE "TypeError|ReferenceError|is not a function|Cannot read" fb-err.log; then
  echo "QML ERRORS PRESENT:"
  grep -iE "TypeError|ReferenceError|is not a function|Cannot read" fb-err.log
  exit 1
fi
# Clean up the throwaway base the fallback boot created in the real /tmp.
FB_BASE=$(sed -n 's/^FALLBACK ALL PASS base=//p' fb-out.log | head -1)
[ -n "$FB_BASE" ] && rm -rf -- "$FB_BASE"
echo "--- all harnesses green ---"
