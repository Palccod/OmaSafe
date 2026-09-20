// Boot harness for the /tmp scratch fallback (the path the marketplace
// review flagged for a symlink TOCTOU). Run with OMASAFE_FORCE_TMP_FALLBACK=1
// so the Service takes the mktemp -d fallback even though quickshell itself
// needs XDG_RUNTIME_DIR for Wayland. Proves, after boot settles:
//   - the scratch base was created and is exactly /tmp/omasafe-<random>
//   - it is a real directory (not a link), owned by the invoking user,
//     mode 0700
//   - the gate created omasafe/ under it, 0700
//   - the boot stage-wipe ran (stage/ absent — it is created on first use)
import QtQuick
import Quickshell

Item {
    id: root

    Service { id: svc }

    property int ticks: 0
    property bool finished: false

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            if (root.finished)
                return
            root.ticks++
            if (root.ticks > 240) {
                console.info("FALLBACK FAIL: timeout phase=" + svc.phase
                             + " base=" + svc.scratchBase
                             + " error=" + svc.lastError)
                root.finished = true
                Qt.quit()
                return
            }
            if (root.ticks < 40)
                return // let the boot queue settle before judging it
            if (svc.phase !== "locked" && svc.phase !== "empty")
                return // boot not finished — the gate work happens before this
            root.finished = true
            const base = svc.scratchBase
            svc._enqueue(["sh", "-c",
                          'case "$1" in /tmp/omasafe-[A-Za-z0-9]*) ;; *) echo badname; exit 1 ;; esac; '
                        + '[ -d "$1" ] && [ ! -L "$1" ] || { echo notdir; exit 1; }; '
                        + '[ "$(stat -c %u -- "$1")" = "$(id -u)" ] || { echo foreign; exit 1; }; '
                        + '[ "$(stat -c %a -- "$1")" = "700" ] || { echo loose; exit 1; }; '
                        + '[ -d "$1/omasafe" ] && [ "$(stat -c %a -- "$1/omasafe")" = "700" ] || { echo scratch; exit 1; }; '
                        + '[ ! -e "$1/omasafe/stage" ] || { echo stage-left; exit 1; }; '
                        + 'echo ok', "omasafe-fallback-check", base], {}, (c, out) => {
                if (c === 0 && out.trim() === "ok") {
                    console.info("FALLBACK ALL PASS base=" + base)
                } else {
                    console.info("FALLBACK FAIL: check c=" + c + " out=" + out)
                }
                Qt.quit()
            })
        }
    }
}
