pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "SafeModel.js" as SafeModel

// OmaSafe's vault: every secret, every crypto operation, and every bit of
// filesystem state lives here, instantiated once by the shell. Bar widgets
// are thin views that call into this service.
//
// Storage model
// -------------
//   ~/.local/share/.omasafe/vault/wrap.enc     the vault key, encrypted under
//                                              the user's password
//   ~/.local/share/.omasafe/vault/recovery.enc the vault key, encrypted under
//                                              the back-up key
//   ~/.local/share/.omasafe/vault/index.enc  the manifest (names, sizes),
//                                            encrypted under the vault key
//   ~/.local/share/.omasafe/vault/<id>       one blob per item, openssl
//                                            AES-256-CBC + PBKDF2, filename
//                                            is a random 32-hex id
//
// Nothing on disk is plaintext and nothing is named after its content: a
// file manager shows a directory of opaque blobs. The vault key exists in
// memory only while the safe is unlocked; the password and the back-up key
// are never stored anywhere at all. Unlocking means: decrypt wrap.enc with
// the typed password (openssl refuses to decrypt garbage, so the exit code
// is the password check), or decrypt recovery.enc with the 64-hex back-up
// key. Changing the password re-wraps both files and issues a fresh
// back-up key, so the old one stops working the moment the new one is
// issued. Safes created before recovery.enc existed are upgraded on their
// first unlock: a separate back-up key is issued then, and the old key
// (which was the raw vault key) is no longer accepted.
//
// Every process runs through one serialized queue with fixed argv arrays —
// file names travel as arguments, never inside a shell string, and keys
// travel through the environment, never the command line.
Item {
    id: root

    property var shell: null
    property var manifest: null
    property bool initialized: false

    // "empty" (no safe yet) | "locked" | "unlocked"
    property string phase: "empty"
    // The vault key, hex. Cleared the moment the safe locks. Never written
    // to disk, never logged, never sent anywhere.
    property string sessionKey: ""
    // Shown once, right after initialization or a password change, until
    // the user acknowledges it.
    property string pendingBackupKey: ""
    // Why pendingBackupKey is on screen: "initial" (the safe was just
    // created) or "rotated" (the old back-up key was just invalidated).
    property string pendingKeyReason: "initial"
    // True while this session was opened with the back-up key rather than
    // the password — the card then offers a password change up front.
    property bool unlockedViaRecovery: false
    // Manifest entries while unlocked: [{id, name, isDir, size, addedAt}]
    property var items: []
    readonly property int itemCount: items ? items.length : 0
    // Decrypted copies staged for drag-out: id → {path, at}. The path is what
    // the native drag offers as text/uri-list.
    property var staged: ({})
    property string busyLabel: ""
    property string lastError: ""
    readonly property bool busy: busyLabel !== ""

    // Preferences (non-secret), persisted under XDG_STATE_HOME.
    property bool deleteOriginals: true
    // Seconds to stay unlocked after the popout closes; 0 keeps the session
    // until the shell restarts or the user locks manually.
    property int autoLockSeconds: 15

    signal toast(string message)

    // --- paths ---------------------------------------------------------------

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string vaultDir: dataHome + "/.omasafe/vault"
    // Plaintext exists here only for the milliseconds an operation takes;
    // the directory is tmpfs on a normal Omarchy install and wiped on logout.
    readonly property string scratchDir: runtimeDir + "/omasafe"
    // Plaintext staged here only while an item is being dragged out of the
    // card; wiped when the safe locks, or after ten minutes, whichever
    // comes first.
    readonly property string stageDir: scratchDir + "/stage"
    readonly property string wrapPath: vaultDir + "/wrap.enc"
    readonly property string recoveryPath: vaultDir + "/recovery.enc"
    readonly property string indexPath: vaultDir + "/index.enc"
    readonly property string prefsPath: stateHome + "/omarchy/plugins/palccod.omasafe.json"
    readonly property string exportDir: home + "/Downloads/OmaSafe"
    readonly property int maxIndexBytes: 4 * 1024 * 1024
    readonly property int maxIpcPayloadBytes: 256 * 1024
    readonly property int maxVaultItems: 4096

    // --- the job queue --------------------------------------------------------
    //
    // One worker process, jobs run strictly in order. Each job is a fixed
    // argv array plus an optional environment map; `done(code, stdout)` runs
    // between jobs, where it is safe to enqueue more.

    property var _queue: []
    property var _job: null
    // Item ids with a stage job in flight, so a press cannot double-queue.
    property var _staging: ({})

    function _enqueue(argv, env, done) {
        _queue.push({ argv: argv, env: env || ({}), done: done || null })
        _pump()
    }

    function _pump() {
        if (_job || _queue.length === 0)
            return
        _job = _queue.shift()
        worker.environment = _job.env
        worker.command = _job.argv
        worker.running = true
        watchdog.restart()
    }

    // Every job runs under a hard wall-clock deadline: a child that hangs
    // (a swapped FIFO behind a stat, an I/O stall) is killed and fails the
    // job instead of leaving the safe busy forever.
    Timer {
        id: watchdog
        interval: 120000
        onTriggered: {
            if (!root._job)
                return
            worker.running = false
            const job = root._job
            root._job = null
            if (job.done)
                job.done(124, "")
            root._emitToast("A safe operation timed out")
            root._pump()
        }
    }

    Process {
        id: worker
        stdout: StdioCollector {
            id: workerOut
            waitForEnd: true
        }
        onExited: (code, status) => {
            watchdog.stop()
            const job = root._job
            root._job = null
            if (job && job.done)
                job.done(code, String(workerOut.text || ""))
            root._pump()
        }
    }

    // openssl arguments for one encrypt/decrypt of a file. The key always
    // arrives through an environment variable named by `passVar`. An empty
    // `dst` means stdout: the plaintext comes back through the pipe and
    // never touches the disk.
    function _cipherArgv(src, dst, passVar, decrypt) {
        const argv = ["openssl", "enc"]
        if (decrypt)
            argv.push("-d")
        argv.push("-aes-256-cbc", "-pbkdf2", "-iter", "250000")
        if (!decrypt)
            argv.push("-salt")
        argv.push("-in", src)
        if (dst !== "")
            argv.push("-out", dst)
        argv.push("-pass", "env:" + passVar)
        return argv
    }

    function _hexJob(bytes, done) {
        _enqueue(["openssl", "rand", "-hex", String(bytes)], {}, (code, out) => {
            done(code === 0 ? out.trim() : "")
        })
    }

    function _exists(path, done) {
        _enqueue(["sh", "-c", 'if [ -f "$1" ]; then echo yes; else echo no; fi',
                  "omasafe-has", path], {}, (code, out) => {
            done(out.trim() === "yes")
        })
    }

    // Writes small plaintext to scratch through the environment (it never
    // touches argv, so it never shows in `ps`).
    function _writeScratch(fileName, content, done) {
        _enqueue(["sh", "-c", 'umask 077; printf %s "$OS_DATA" > "$1"',
                  "omasafe-scratch", root.scratchDir + "/" + fileName],
                 { OS_DATA: content }, done)
    }

    function _rmScratch(fileName) {
        _enqueue(["rm", "-f", "--", root.scratchDir + "/" + fileName], {}, null)
    }

    // A deletion that is only ever allowed inside the user's home — the
    // safe never removes anything it was not just handed from there.
    function _deletable(path) {
        return root.deleteOriginals && root.home !== ""
            && path.indexOf(root.home + "/") === 0
    }

    // --- boot -----------------------------------------------------------------

    function _mkdirs(done) {
        _enqueue(["sh", "-c", 'umask 077; mkdir -p "$1" "$2" "$3"',
                  "omasafe-mkdir", root.vaultDir, root.scratchDir,
                  root.stateHome + "/omarchy/plugins"], {}, done)
    }

    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", root.stateHome + "/omarchy/plugins"])
        _mkdirs((code, out) => {
            _enqueue(["sh", "-c", 'if [ -f "$1" ] && [ -f "$2" ]; then echo yes; else echo no; fi',
                      "omasafe-check", root.wrapPath, root.indexPath], {}, (c, out2) => {
                root.initialized = out2.trim() === "yes"
                root.phase = root.initialized ? "locked" : "empty"
            })
        })
    }

    // --- preferences ----------------------------------------------------------

    FileView {
        id: prefsFile
        path: root.prefsPath
        preload: true
        printErrors: false
        onLoaded: {
            try {
                const prefs = JSON.parse(prefsFile.text())
                if (typeof prefs.deleteOriginals === "boolean")
                    root.deleteOriginals = prefs.deleteOriginals
                root.autoLockSeconds = SafeModel.clampInt(prefs.autoLockSeconds, 15, 0, 3600)
            } catch (e) {
                // First run or a damaged file: defaults are already in place.
            }
        }
        onLoadFailed: error => {}
    }

    function _savePrefs() {
        prefsFile.setText(JSON.stringify({
            deleteOriginals: root.deleteOriginals,
            autoLockSeconds: root.autoLockSeconds
        }))
    }

    // --- initialization -------------------------------------------------------

    function initialize(password, onReady) {
        if (root.phase !== "empty" || typeof password !== "string" || password.length < 12)
            return false
        root.lastError = ""
        root.busyLabel = "Creating safe…"
        _mkdirs((code, out) => {
            // The vault key is 32 bytes → 64 hex digits; item ids are
            // 16 bytes → 32 digits.
            _hexJob(32, key => {
                if (!SafeModel.isHex64(key)) {
                    root.busyLabel = ""
                    root.lastError = "Key generation failed"
                    return
                }
                // The vault key spends a few milliseconds in scratch while
                // it is wrapped twice — once under the password, once under
                // a freshly minted back-up key — then is gone.
                _writeScratch("key", key, () => {
                    _enqueue(_cipherArgv(root.scratchDir + "/key", root.wrapPath, "OS_PW", false),
                             { OS_PW: password }, (c2, out2) => {
                        if (c2 !== 0) {
                            _rmScratch("key")
                            root.busyLabel = ""
                            root.lastError = "Could not create the safe"
                            return
                        }
                        _hexJob(32, rk => {
                            if (!SafeModel.isHex64(rk)) {
                                _rmScratch("key")
                                root.busyLabel = ""
                                root.lastError = "Key generation failed"
                                return
                            }
                            _enqueue(_cipherArgv(root.scratchDir + "/key", root.recoveryPath, "OS_RK", false),
                                     { OS_RK: rk }, (c3, out3) => {
                                _rmScratch("key")
                                if (c3 !== 0) {
                                    root.busyLabel = ""
                                    root.lastError = "Could not create the safe"
                                    return
                                }
                                root.pendingBackupKey = rk
                                root.pendingKeyReason = "initial"
                                // The initial index is encrypted under the vault
                                // key, so the key has to be live for this one write;
                                // the safe locks again immediately after.
                                root.sessionKey = key
                                root.items = []
                                _writeIndex(() => {
                                    root.initialized = true
                                    root.lock()
                                    if (onReady)
                                        onReady()
                                })
                            })
                        })
                    })
                })
            })
        })
        return true
    }

    function acknowledgeBackupKey() {
        root.pendingBackupKey = ""
    }

    // Copies the pending back-up key to the clipboard. The key travels
    // through the environment like every other secret — never argv — and
    // wl-copy is backgrounded so the job queue keeps moving while it serves
    // paste requests.
    function copyBackupKey() {
        if (root.pendingBackupKey === "")
            return
        _enqueue(["sh", "-c", 'printf "%s" "$OS_KEY" | wl-copy >/dev/null 2>&1 & exit 0',
                  "omasafe-copy"], { OS_KEY: root.pendingBackupKey }, null)
    }

    // --- locking --------------------------------------------------------------

    function lock() {
        root.sessionKey = ""
        root.items = []
        root.busyLabel = ""
        root.lastError = ""
        root.unlockedViaRecovery = false
        root.clearStaged()
        autoLockTimer.stop()
        root.phase = root.initialized ? "locked" : "empty"
    }

    // --- drag-out staging -------------------------------------------------------
    //
    // A native drag has to offer a real file, so before the widget can start
    // one, the item is decrypted into the tmpfs stage directory. The widget
    // stages on mouse press and begins the drag on a later move event, once
    // the plaintext is on disk — Drag.startDrag() blocks until the drop lands,
    // so it must be the plain path by then.

    function _stageDone(id, path, ok, name) {
        delete root._staging[id]
        root.busyLabel = ""
        if (!ok) {
            root._emitToast("Could not prepare " + name + " for dragging")
            return
        }
        // A fresh object every time: reassigning the same reference would not
        // fire the change signal, and the chips' stage-path bindings would
        // never see the new entry.
        const map = Object.assign({}, root.staged)
        map[id] = { path: path, at: Date.now() }
        root.staged = map
    }

    // Decrypts an item into the stage directory (idempotent per id). Returns
    // immediately; the widget polls `staged` for the resulting path.
    function stageItem(index) {
        if (root.phase !== "unlocked" || index < 0 || index >= root.items.length)
            return false
        const item = root.items[index]
        if (root.staged[item.id] || root._staging[item.id])
            return true
        root._staging[item.id] = true
        root.busyLabel = "Preparing " + item.name + "…"
        _enqueue(["sh", "-c", 'umask 077; mkdir -p -- "$1"', "omasafe-stage", root.stageDir], {}, (mc, mo) => {
            if (mc !== 0) {
                _stageDone(item.id, "", false, item.name)
                return
            }
            // A stage name that is not already taken, so two items that share
            // a name stage side by side.
            _enqueue(["sh", "-c",
                      'n="$2"; base="$2"; ext=""; case "$2" in *.*) base="${2%.*}"; ext=".${2##*.}";; esac; '
                    + 'i=1; while [ -e "$1/$n" ] && [ "$i" -lt 50 ]; do i=$((i+1)); n="$base ($i)$ext"; done; printf "%s" "$n"',
                      "omasafe-stage-name", root.stageDir, SafeModel.safeName(item.name)], {}, (cc, co) => {
                const finalName = co.trim() || SafeModel.safeName(item.name)
                const target = root.stageDir + "/" + finalName
                const blobPath = root.vaultDir + "/" + item.id
                if (item.isDir) {
                    _enqueue(_cipherArgv(blobPath, root.scratchDir + "/item.tar", "OS_KEY", true),
                             { OS_KEY: root.sessionKey }, (dc, dOut) => {
                        if (dc !== 0) {
                            _rmScratch("item.tar")
                            _stageDone(item.id, "", false, item.name)
                            return
                        }
                        _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {
                            _enqueue(["mkdir", "-p", "--", root.scratchDir + "/extract"], {}, () => {
                                _enqueue(["tar", "-C", root.scratchDir + "/extract", "-xf",
                                          root.scratchDir + "/item.tar"], {}, (xc, xo) => {
                                    _rmScratch("item.tar")
                                    if (xc !== 0) {
                                        _stageDone(item.id, "", false, item.name)
                                        return
                                    }
                                    _enqueue(["mv", "--", root.scratchDir + "/extract/" + SafeModel.safeName(item.name),
                                              target], {}, (vc, vo) => {
                                        _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {})
                                        _stageDone(item.id, target, vc === 0, item.name)
                                    })
                                })
                            })
                        })
                    })
                } else {
                    _enqueue(_cipherArgv(blobPath, target, "OS_KEY", true),
                             { OS_KEY: root.sessionKey }, (dc, do2) => {
                        _stageDone(item.id, target, dc === 0, item.name)
                    })
                }
            })
        })
        return true
    }

    // Removes every staged plaintext copy. Called when the safe locks; the
    // ten-minute sweeper below is the backstop for a session that never locks.
    function clearStaged() {
        const map = Object.assign({}, root.staged)
        let dirty = false
        for (const id in map) {
            _enqueue(["rm", "-rf", "--", map[id].path], {}, null)
            delete map[id]
            dirty = true
        }
        if (dirty)
            root.staged = map
        _enqueue(["rm", "-rf", "--", root.stageDir], {}, null)
    }

    Timer {
        interval: 60000
        repeat: true
        running: root.initialized
        onTriggered: {
            const now = Date.now()
            const map = Object.assign({}, root.staged)
            let dirty = false
            for (const id in map) {
                if (now - map[id].at > 600000) {
                    _enqueue(["rm", "-rf", "--", map[id].path], {}, null)
                    delete map[id]
                    dirty = true
                }
            }
            if (dirty)
                root.staged = map
        }
    }

    // The widget calls this when its popout opens/closes; the auto-lock grace
    // period runs only while the safe is closed.
    function panelOpened() {
        autoLockTimer.stop()
    }

    function panelClosed() {
        if (root.phase === "unlocked" && root.autoLockSeconds > 0)
            autoLockTimer.restart()
    }

    Timer {
        id: autoLockTimer
        interval: Math.max(1, root.autoLockSeconds) * 1000
        onTriggered: root.lock()
    }

    // One field takes both secrets: try the password first; a string that is
    // pure hex and exactly 64 digits also gets a shot as the back-up key.
    function unlock(secret) {
        if (root.phase !== "locked")
            return false
        const attempt = String(secret || "")
        if (attempt.length === 0)
            return false
        root.lastError = ""
        root.busyLabel = "Unlocking…"
        _enqueue(_cipherArgv(root.wrapPath, "", "OS_PW", true), { OS_PW: attempt }, (code, out) => {
            // Decrypt to stdout: no -out argument, so the plaintext key comes
            // back through the pipe and never touches the disk.
            const key = out.trim()
            if (code !== 0 || !SafeModel.isHex64(key)) {
                const backup = SafeModel.normalizeKey(attempt)
                if (SafeModel.isHex64(backup)) {
                    _unlockWithKey(backup)
                } else {
                    root.busyLabel = ""
                    root.lastError = "Wrong password"
                }
                return
            }
            root.unlockedViaRecovery = false
            root.sessionKey = key
            _loadIndex()
        })
        return true
    }

    // A 64-hex secret: on current safes it unwraps recovery.enc; on safes
    // from before that file existed, the key *was* the vault key, so the
    // index is opened with it directly and the safe is upgraded right after.
    function _unlockWithKey(key) {
        _exists(root.recoveryPath, has => {
            if (has) {
                _enqueue(_cipherArgv(root.recoveryPath, "", "OS_RK", true), { OS_RK: key }, (code, out) => {
                    const vk = out.trim()
                    if (code !== 0 || !SafeModel.isHex64(vk)) {
                        root.busyLabel = ""
                        root.lastError = "Back-up key does not fit this safe"
                        return
                    }
                    root.unlockedViaRecovery = true
                    root.sessionKey = vk
                    _loadIndex()
                })
                return
            }
            _enqueue(_cipherArgv(root.indexPath, "", "OS_KEY", true), { OS_KEY: key }, (code, out) => {
                if (code !== 0) {
                    root.busyLabel = ""
                    root.lastError = "Back-up key does not fit this safe"
                    return
                }
                root.unlockedViaRecovery = true
                root.sessionKey = key
                _loadIndex()
            })
        })
    }

    function _loadIndex() {
        _enqueue(_cipherArgv(root.indexPath, "", "OS_KEY", true), { OS_KEY: root.sessionKey }, (code, out) => {
            root.busyLabel = ""
            if (code !== 0) {
                root.sessionKey = ""
                root.lastError = "The safe could not be opened"
                root.phase = root.initialized ? "locked" : "empty"
                return
            }
            if (out.length > root.maxIndexBytes) {
                root.sessionKey = ""
                root.lastError = "The safe index is too large to open safely"
                root.phase = root.initialized ? "locked" : "empty"
                return
            }
            let parsed = null
            try {
                parsed = JSON.parse(out)
            } catch (e) {}
            const list = parsed && Array.isArray(parsed.items) ? parsed.items : []
            const clean = []
            for (const item of list) {
                if (!item || typeof item.id !== "string" || !/^[0-9a-f]{32}$/.test(item.id))
                    continue
                if (typeof item.name !== "string" || item.name === "")
                    continue
                if (clean.length >= root.maxVaultItems)
                    break
                clean.push({
                    id: item.id,
                    name: String(item.name),
                    isDir: item.isDir === true,
                    size: SafeModel.clampInt(item.size, 0, 0, Number.MAX_SAFE_INTEGER),
                    addedAt: SafeModel.clampInt(item.addedAt, 0, 0, Number.MAX_SAFE_INTEGER)
                })
            }
            root.items = clean
            root.lastError = ""
            root.phase = "unlocked"
            root._ensureRecovery()
        })
    }

    // Safes created before recovery.enc existed used the vault key itself as
    // the back-up key. On the first unlock of such a safe, issue a separate
    // back-up key wrapping the same vault key, show it once, and from then on
    // refuse the raw vault key — the old key is dead as far as the safe is
    // concerned. No blob is touched: the vault key does not change.
    function _ensureRecovery() {
        _exists(root.recoveryPath, has => {
            if (has)
                return
            root.busyLabel = "Upgrading the safe…"
            _hexJob(32, rk => {
                if (!SafeModel.isHex64(rk)) {
                    root.busyLabel = ""
                    root._emitToast("Could not issue a back-up key — try locking and unlocking again")
                    return
                }
                _writeScratch("vkey", root.sessionKey, () => {
                    _enqueue(_cipherArgv(root.scratchDir + "/vkey", root.recoveryPath, "OS_RK", false),
                             { OS_RK: rk }, (code, out) => {
                        _rmScratch("vkey")
                        root.busyLabel = ""
                        if (code !== 0) {
                            root._emitToast("Could not issue a back-up key — try locking and unlocking again")
                            return
                        }
                        root.pendingBackupKey = rk
                        root.pendingKeyReason = "rotated"
                    })
                })
            })
        })
    }

    // Re-encrypts the manifest from the in-memory list. The queue makes this
    // race-free: only one job touches index.enc at a time.
    function _writeIndex(done) {
        const json = JSON.stringify({ version: 1, items: root.items })
        _writeScratch("index.json", json, () => {
            _enqueue(_cipherArgv(root.scratchDir + "/index.json", root.indexPath, "OS_KEY", false),
                     { OS_KEY: root.sessionKey }, (code, out) => {
                _rmScratch("index.json")
                if (code !== 0)
                    root._emitToast("Could not update the safe's index")
                if (done)
                    done(code === 0)
            })
        })
    }

    function _emitToast(message) {
        root.toast(message)
    }

    // --- stashing (drag & drop / IPC) ------------------------------------------

    function stash(entries) {
        if (root.phase !== "unlocked") {
            root._emitToast("Unlock the safe before adding files")
            return 0
        }
        const paths = SafeModel.pathsFromEntries(entries)
        const remaining = Math.max(0, root.maxVaultItems - root.itemCount)
        if (remaining === 0) {
            root._emitToast("The safe has reached its item limit")
            return 0
        }
        // A cap keeps one IPC call — from a drag or a local caller — from
        // queueing an unbounded pile of jobs against the running shell.
        if (paths.length > 50) {
            paths.length = 50
            root._emitToast("Locking the first 50 items — the rest were refused")
        }
        if (paths.length > remaining) {
            paths.length = remaining
            root._emitToast("Only " + remaining + " more items fit in this safe")
        }
        let queued = 0
        for (const path of paths) {
            if (root._stashOne(path))
                queued++
        }
        return queued
    }

    function _stashOne(path) {
        const rawName = SafeModel.basename(path)
        const name = SafeModel.safeName(rawName)
        // The archive root and manifest name must remain identical. Refuse a
        // deceptive/control-bearing basename rather than silently renaming it
        // and producing a directory archive that cannot later be extracted.
        if (name === "" || name === "." || name === ".." || name !== rawName) {
            root._emitToast("Skipped an item whose name contains unsupported characters")
            return false
        }
        root.busyLabel = "Locking " + name + "…"
        // What kind of file is this? The script is a constant; only the path
        // travels as an argument.
        _enqueue(["sh", "-c",
                  'if [ -L "$1" ]; then echo link; elif [ -d "$1" ]; then echo dir; '
                + 'elif [ -f "$1" ]; then echo "file $(stat -c %s -- "$1")"; '
                + 'else echo missing; fi',
                  "omasafe-stat", path], {}, (code, out) => {
            const answer = out.trim().split(" ")
            const kind = answer[0]
            const size = answer.length > 1 ? SafeModel.clampInt(answer[1], 0, 0, Number.MAX_SAFE_INTEGER) : 0
            if (kind === "missing" || kind === "link") {
                root.busyLabel = ""
                root._emitToast("Skipped " + name + (kind === "link" ? " (symlinks are not safe material)" : ""))
                return
            }
            _hexJob(16, id => {
                if (id === "" || !/^[0-9a-f]{32}$/.test(id)) {
                    root.busyLabel = ""
                    root._emitToast("Could not lock " + name)
                    return
                }
                const blobPath = root.vaultDir + "/" + id
                if (kind === "dir") {
                    // Folders travel as a tar stream: one blob per item keeps
                    // the vault flat and anonymous.
                    _enqueue(["tar", "-C", SafeModel.dirname(path), "-cf",
                              root.scratchDir + "/item.tar", "--", name], {}, (tc, to) => {
                        if (tc !== 0) {
                            root.busyLabel = ""
                            root._emitToast("Could not read " + name)
                            return
                        }
                        _enqueue(_cipherArgv(root.scratchDir + "/item.tar", blobPath, "OS_KEY", false),
                                 { OS_KEY: root.sessionKey }, (ec, eo) => {
                            _rmScratch("item.tar")
                            if (ec !== 0) {
                                root.busyLabel = ""
                                root._emitToast("Could not lock " + name)
                                return
                            }
                            _stashCommit(id, name, true, size, path)
                        })
                    })
                } else {
                    _enqueue(_cipherArgv(path, blobPath, "OS_KEY", false),
                             { OS_KEY: root.sessionKey }, (ec, eo) => {
                        if (ec !== 0) {
                            root.busyLabel = ""
                            root._emitToast("Could not lock " + name)
                            return
                        }
                        _stashCommit(id, name, false, size, path)
                    })
                }
            })
        })
        return true
    }

    // Blob written and verified by openssl's exit code: record it in the
    // index, then — and only then — remove the original.
    function _stashCommit(id, name, isDir, size, originalPath) {
        const entry = { id: id, name: name, isDir: isDir, size: size, addedAt: Date.now() }
        const list = root.items.slice()
        list.push(entry)
        root.items = list
        _writeIndex(ok => {
            root.busyLabel = ""
            if (!ok) {
                root._emitToast(name + " is encrypted but not indexed — do not delete the original")
                return
            }
            if (_deletable(originalPath)) {
                _enqueue(["rm", "-rf", "--", originalPath], {}, (rc, ro) => {
                    if (rc !== 0)
                        root._emitToast("Locked " + name + " — the original could not be removed")
                    else
                        root._emitToast("Locked " + name)
                })
            } else {
                root._emitToast("Locked a copy of " + name)
            }
        })
    }

    // --- extraction -----------------------------------------------------------

    function extractAt(index) {
        if (root.phase !== "unlocked" || index < 0 || index >= root.items.length)
            return
        const item = root.items[index]
        root.busyLabel = "Unlocking " + item.name + "…"
        _enqueue(["sh", "-c", 'mkdir -p -- "$1"', "omasafe-export", root.exportDir], {}, (mc, mo) => {
            if (mc !== 0) {
                root.busyLabel = ""
                root._emitToast("Could not create " + root.exportDir)
                return
            }
            // Pick an export name that is not already taken; the loop is a
            // constant script, the starting name an argument.
            _enqueue(["sh", "-c",
                      'n="$2"; base="$2"; ext=""; case "$2" in *.*) base="${2%.*}"; ext=".${2##*.}";; esac; '
                    + 'i=1; while [ -e "$1/$n" ] && [ "$i" -lt 50 ]; do i=$((i+1)); n="$base ($i)$ext"; done; printf "%s" "$n"',
                      "omasafe-collision", root.exportDir, SafeModel.safeName(item.name)], {}, (cc, co) => {
                const finalName = co.trim() || SafeModel.safeName(item.name)
                const blobPath = root.vaultDir + "/" + item.id
                if (item.isDir) {
                    // Decrypt the tarball into scratch, unpack into a fresh
                    // scratch folder, then move the result into place — that
                    // way a name collision renames the folder, not merges it.
                    _enqueue(_cipherArgv(blobPath, root.scratchDir + "/item.tar", "OS_KEY", true),
                             { OS_KEY: root.sessionKey }, (dc, dOut) => {
                        if (dc !== 0) {
                            _rmScratch("item.tar")
                            root.busyLabel = ""
                            root._emitToast("Could not unlock " + item.name)
                            return
                        }
                        _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {
                            _enqueue(["mkdir", "-p", "--", root.scratchDir + "/extract"], {}, () => {
                                _enqueue(["tar", "-C", root.scratchDir + "/extract", "-xf",
                                          root.scratchDir + "/item.tar"], {}, (xc, xo) => {
                                    _rmScratch("item.tar")
                                    if (xc !== 0) {
                                        root.busyLabel = ""
                                        root._emitToast("Could not unpack " + item.name)
                                        return
                                    }
                                    _enqueue(["mv", "--", root.scratchDir + "/extract/" + SafeModel.safeName(item.name),
                                              root.exportDir + "/" + finalName], {}, (vc, vo) => {
                                        _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {})
                                        root.busyLabel = ""
                                        if (vc !== 0)
                                            root._emitToast("Could not move " + item.name + " out of the safe")
                                        else
                                            root._emitToast("Saved " + finalName + " to Downloads/OmaSafe")
                                    })
                                })
                            })
                        })
                    })
                } else {
                    // Files decrypt into the scratch dir and are renamed into
                    // place: a rename replaces whatever sits at the target
                    // (including a hostile symlink) instead of following it,
                    // and the write lands atomically.
                    _enqueue(_cipherArgv(blobPath, root.scratchDir + "/export.bin", "OS_KEY", true),
                             { OS_KEY: root.sessionKey }, (dc, do2) => {
                        if (dc !== 0) {
                            _rmScratch("export.bin")
                            root.busyLabel = ""
                            root._emitToast("Could not unlock " + item.name)
                            return
                        }
                        _enqueue(["mv", "--", root.scratchDir + "/export.bin",
                                  root.exportDir + "/" + finalName], {}, (vc, vo) => {
                            if (vc !== 0)
                                _rmScratch("export.bin")
                            root.busyLabel = ""
                            if (vc !== 0)
                                root._emitToast("Could not move " + item.name + " out of the safe")
                            else
                                root._emitToast("Saved " + finalName + " to Downloads/OmaSafe")
                        })
                    })
                }
            })
        })
    }

    // --- deletion / password ---------------------------------------------------

    function deleteAt(index) {
        if (root.phase !== "unlocked" || index < 0 || index >= root.items.length)
            return
        const item = root.items[index]
        root.busyLabel = "Destroying " + item.name + "…"
        _enqueue(["rm", "-f", "--", root.vaultDir + "/" + item.id], {}, (code, out) => {
            const list = root.items.slice()
            const i = root.items.indexOf(item)
            if (i !== -1)
                list.splice(i, 1)
            root.items = list
            _writeIndex(ok => {
                root.busyLabel = ""
                root._emitToast(ok ? "Destroyed " + item.name : "Could not update the index")
            })
        })
    }

    // Changing the password proves the caller knows a current secret first —
    // the password or the back-up key. On success both wraps are rewritten:
    // wrap.enc under the new password, recovery.enc under a brand-new
    // back-up key. The old back-up key is overwritten out of existence; the
    // vault key itself never changes, so no blob is touched.
    function changePassword(oldSecret, newPassword) {
        if (root.phase !== "unlocked" || typeof newPassword !== "string" || newPassword.length < 12)
            return false
        const old = String(oldSecret || "")
        if (old.length === 0)
            return false
        root.lastError = ""
        root.busyLabel = "Changing password…"
        const fail = () => {
            root.busyLabel = ""
            root.lastError = "The current password or back-up key is wrong"
        }
        _enqueue(_cipherArgv(root.wrapPath, "", "OS_OLD", true), { OS_OLD: old }, (code, out) => {
            if (code === 0 && out.trim() === root.sessionKey) {
                root._rotateSecrets(newPassword)
                return
            }
            const rk = SafeModel.normalizeKey(old)
            if (!SafeModel.isHex64(rk)) {
                fail()
                return
            }
            _enqueue(_cipherArgv(root.recoveryPath, "", "OS_RK", true), { OS_RK: rk }, (code2, out2) => {
                if (code2 !== 0 || out2.trim() !== root.sessionKey) {
                    fail()
                    return
                }
                root._rotateSecrets(newPassword)
            })
        })
        return true
    }

    function _rotateSecrets(newPassword) {
        const done = () => {
            root.busyLabel = ""
        }
        _hexJob(32, rk => {
            if (!SafeModel.isHex64(rk)) {
                done()
                root._emitToast("Could not issue a new back-up key — nothing was changed")
                return
            }
            _writeScratch("vkey", root.sessionKey, () => {
                _enqueue(_cipherArgv(root.scratchDir + "/vkey", root.wrapPath, "OS_PW", false),
                         { OS_PW: newPassword }, (code1, out1) => {
                    if (code1 !== 0) {
                        _rmScratch("vkey")
                        done()
                        root._emitToast("Could not change the password — nothing was changed")
                        return
                    }
                    _enqueue(_cipherArgv(root.scratchDir + "/vkey", root.recoveryPath, "OS_RK", false),
                             { OS_RK: rk }, (code2, out2) => {
                        _rmScratch("vkey")
                        done()
                        if (code2 !== 0) {
                            root._emitToast("The password changed, but no new back-up key could be issued")
                            return
                        }
                        // The new password works from here on, so the card
                        // stops nudging toward a change.
                        root.unlockedViaRecovery = false
                        root.pendingBackupKey = rk
                        root.pendingKeyReason = "rotated"
                        root._emitToast("Password changed — the old back-up key no longer works")
                    })
                })
            })
        })
    }

    // --- IPC -------------------------------------------------------------------
    //
    // The vault ops live on their own target; the bar widget's Panel base
    // auto-registers open/close/toggle on "palccod.omasafe", and two handlers
    // cannot share one target (the second registration is dropped).

    IpcHandler {
        target: "palccod.omasafe.vault"

        function lock(): void {
            root.lock()
        }

        function status(): string {
            return JSON.stringify({
                phase: root.phase,
                items: root.itemCount,
                busy: root.busy
            })
        }

        // Takes the same {"paths": [...]} wrapper the ledge uses: a bare JSON
        // array is splatted by the IPC layer, an object survives intact.
        function stash(paths: string): string {
            let entries = null
            const payload = String(paths)
            if (payload.length > root.maxIpcPayloadBytes) {
                root._emitToast("The stash request is too large")
                return "0"
            }
            try {
                const parsed = JSON.parse(payload)
                if (Array.isArray(parsed))
                    entries = parsed
                else if (parsed && Array.isArray(parsed.paths))
                    entries = parsed.paths
            } catch (e) {}
            if (!entries)
                entries = payload.split("\n")
            return String(root.stash(entries))
        }
    }
}
