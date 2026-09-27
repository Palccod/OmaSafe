#!/bin/bash
# OmaSafe — Dolphin service menu helper: send the selection into the safe.
#
# Dolphin hands over the selection as file:// URLs (%F); the vault IPC takes
# them as a JSON {"paths": [...]} body and does the URL decoding itself.
# A locked safe or a missing CLI become desktop notifications, since the
# card may not be open to show its toasts.
set -u

SHELL_BIN="$(command -v omarchy-shell || true)"
if [[ -z $SHELL_BIN ]]; then
  for candidate in /usr/bin/omarchy-shell /usr/sbin/omarchy-shell /usr/local/bin/omarchy-shell; do
    [[ -x $candidate ]] && SHELL_BIN=$candidate && break
  done
fi
if [[ -z ${SHELL_BIN:-} || ! -x $SHELL_BIN ]]; then
  notify-send "OmaSafe" "The omarchy-shell CLI was not found." 2>/dev/null
  exit 1
fi

if [[ $# -eq 0 ]]; then
  exit 0
fi

payload='{"paths":['
first=1
for url in "$@"; do
  [[ $first == 1 ]] || payload+=','
  first=0
  esc=${url//\\/\\\\}
  esc=${esc//\"/\\\"}
  payload+="\"$esc\""
done
payload+=']}'

status="$("$SHELL_BIN" palccod.omasafe.vault status 2>/dev/null)"
if [[ $status != *'"phase":"unlocked"'* ]]; then
  notify-send "OmaSafe" "The safe is locked — unlock it, then send the files again." 2>/dev/null
  exit 1
fi

if "$SHELL_BIN" palccod.omasafe.vault stash "$payload" >/dev/null 2>&1; then
  plural=$([[ $# == 1 ]] || echo s)
  notify-send "OmaSafe" "Sending $# item$plural into the safe…" 2>/dev/null
  exit 0
fi

notify-send "OmaSafe" "Could not reach the safe's IPC." 2>/dev/null
exit 1
