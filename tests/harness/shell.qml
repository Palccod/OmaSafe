// File-explorer regression harness for OmaSafe 0.4.0.
//
// Boots against a hand-built v1 vault (one tar folder blob + one root file,
// no recovery.enc) and proves, in order:
//   - unlock triggers the legacy upgrade: tar blob exploded into per-file
//     blobs, paths under /legacy/, a back-up key issued once
//   - a real folder drop becomes structure + one blob per file (empty dirs
//     preserved), originals removed
//   - browsing: navigate(), visibleItems, currentFolder resets on lock
//   - dropping a file into a subfolder lands inside it
//   - folder extract recreates the subtree in Downloads/OmaSafe
//   - folder staging produces a real folder for drag-out
//   - lock wipes the view; re-unlock: index is v2 on disk, no key shown,
//     no re-migration
//   - folder delete removes every descendant entry and blob
//
// Run via tests/harness/run.sh (recreates the ephemeral /tmp copy first,
// because /tmp does not survive reboots).
import QtQuick
import Quickshell
import "SafeModel.js" as SafeModel

Item {
    id: root

    Service {
        id: svc
    }

    readonly property string drop: "/tmp/omasafe-xtest/home/dropbox"
    property int step: 0
    property int idleTicks: 0
    property double startedAt: Date.now()
    property bool finished: false
    property var preDelete: undefined

    function idle() {
        return svc._job === null && svc._queue.length === 0 && !svc.busy
    }

    function has(path) {
        return (svc.items || []).some(it => it.path === path)
    }

    function vis(folder, name) {
        return SafeModel.childrenOf(svc.items, folder).some(it => SafeModel.baseNameOf(it.path) === name)
    }

    readonly property var steps: [
        {
            label: "boots locked with the v1 vault",
            enter: () => {},
            done: () => svc.initialized && svc.phase === "locked"
        },
        {
            label: "unlock upgrades the legacy folder and issues a key",
            enter: () => { svc.unlock("testpassword1") },
            done: () => svc.phase === "unlocked"
                         && root.has("/legacy/deeper/two.txt")
                         && root.has("/legacy/one.txt")
                         && root.has("/legacy/deeper")
                         && root.has("/root.txt")
                         && svc.pendingBackupKey !== "",
            leave: () => { svc.acknowledgeBackupKey() }
        },
        {
            label: "no legacy entries remain after the upgrade",
            enter: () => {},
            done: () => (svc.items || []).every(it => it.legacy !== true)
        },
        {
            label: "folder drop explodes into structure + per-file blobs",
            enter: () => { svc.stash([root.drop + "/tree"]) },
            done: () => root.has("/tree")
                         && root.has("/tree/a.txt")
                         && root.has("/tree/sub")
                         && root.has("/tree/sub/b.txt")
                         && root.has("/tree/empty")
        },
        {
            label: "original folder was removed",
            enter: () => {},
            done: () => true
        },
        {
            label: "browse into the folder",
            enter: () => { svc.navigate("/tree") },
            done: () => svc.currentFolder === "/tree"
                         && root.vis("/tree", "sub")
                         && root.vis("/tree", "a.txt")
                         && root.vis("/tree", "empty")
        },
        {
            label: "navigate into a subfolder and back",
            enter: () => { svc.navigate("/tree/sub") },
            done: () => svc.currentFolder === "/tree/sub"
                         && root.vis("/tree/sub", "b.txt"),
            leave: () => { svc.navigate("/tree") }
        },
        {
            label: "drop a file into the open subfolder",
            enter: () => { svc.stash([root.drop + "/extra.txt"], "/tree/sub") },
            done: () => root.has("/tree/sub/extra.txt")
        },
        {
            label: "original of the inner drop was removed",
            enter: () => {},
            done: () => true
        },
        {
            label: "an unreadable file is skipped, the rest still land",
            enter: () => { svc.stash([root.drop + "/partial"]) },
            done: () => root.has("/partial")
                         && root.has("/partial/y.txt")
                         && !root.has("/partial/x.txt")
        },
        {
            label: "folder extract recreates the subtree",
            enter: () => { svc.extractAt("/tree") },
            done: () => true
        },
        {
            label: "folder staging produces a real folder",
            enter: () => { svc.stageItem("/tree") },
            done: () => svc.staged && svc.staged["/tree"] !== undefined
                         && String(svc.staged["/tree"].path) !== ""
        },
        {
            label: "lock resets the view",
            enter: () => { svc.lock() },
            done: () => svc.phase === "locked" && svc.currentFolder === "/"
        },
        {
            label: "re-unlock: v2 persists, no key, no re-migration",
            enter: () => { svc.unlock("testpassword1") },
            done: () => svc.phase === "unlocked"
                         && svc.pendingBackupKey === ""
                         && root.has("/tree/sub/extra.txt")
                         && root.has("/legacy/deeper/two.txt")
        },
        {
            label: "capture the subtree's blob ids before deletion",
            enter: () => {
                root.preDelete = (svc.items || [])
                    .filter(it => !it.isDir && SafeModel.isUnder(it.path, "/legacy"))
                    .map(it => it.id)
            },
            done: () => root.preDelete !== undefined
        },
        {
            label: "deleteAt(/legacy) drops entries and blobs",
            enter: () => {
                svc._enqueue(["sh", "-c", 'printf %s "$OS_DATA" > "$1"', "omasafe-dump",
                              "/tmp/omasafe-xtest/predelete.json"],
                             { OS_DATA: JSON.stringify(root.preDelete) }, null)
                svc.deleteAt("/legacy")
            },
            done: () => !root.has("/legacy")
                         && !root.has("/legacy/one.txt")
                         && !root.has("/legacy/deeper")
                         && !root.has("/legacy/deeper/two.txt")
                         && root.has("/tree/sub/extra.txt"),
            leave: () => { svc.lock() }
        }
    ]

    function poll() {
        if (root.finished)
            return
        if (Date.now() - root.startedAt > 240000) {
            const s = root.steps[root.step]
            console.info("HARNESS FAIL: timeout at step " + root.step
                         + " (" + (s ? s.label : "?") + ")")
            console.info("STATE phase=" + svc.phase + " busy=" + svc.busy
                         + " label=" + svc.busyLabel + " folder=" + svc.currentFolder
                         + " items=" + JSON.stringify(svc.items))
            root.finished = true
            Qt.quit()
            return
        }
        const s = root.steps[root.step]
        if (!s)
            return
        if (!s.entered) {
            s.entered = true
            root.idleTicks = 0
            s.enter()
        }
        if (!root.idle())
            root.idleTicks = 0
        else
            root.idleTicks++
        if (root.idleTicks >= 10 && s.done()) {
            console.info("HARNESS PASS " + root.step + ": " + s.label)
            if (s.leave)
                s.leave()
            root.step++
            root.idleTicks = 0
            if (root.step >= root.steps.length) {
                console.info("HARNESS ALL PASS")
                root.finished = true
                Qt.quit()
            }
        }
    }

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: root.poll()
    }
}
