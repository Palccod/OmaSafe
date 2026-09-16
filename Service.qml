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
//   ~/.local/share/.omasafe/vault/index.enc  the manifest (vault paths, sizes),
//                                            encrypted under the vault key
//   ~/.local/share/.omasafe/vault/<id>       one blob per FILE, openssl
//                                            AES-256-CBC + PBKDF2, filename
//                                            is a random 32-hex id
//
// The index is a tiny file system: every entry carries a vault-absolute path
// ("/photos", "/photos/cat.jpg"); folder entries are structural markers and
// only files have blobs. That is what makes the safe browsable and lets a
// drop land inside a folder — and it means adding one file to a big folder
// re-encrypts one file, not the folder. Safes from before 0.4.0 stored a
// dropped folder as one tar blob; those are exploded into per-file blobs on
// the first unlock after the upgrade (see _migrateLegacy).
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
    // The dedicated "OmaSafe" keyring: an optional copy of the back-up key
    // behind the keyring's own password (the session never unlocks it).
    // keyringPath is the Secret Service collection path, "" while no such
    // keyring exists; keyringLastSaveKey records which back-up key the
    // keyring copy holds, so the banner can tell "saved" from "stale".
    property string keyringPath: ""
    property bool keyringAvailable: false
    property string keyringLastSaveKey: ""
    // Manifest entries while unlocked: [{id, path, isDir, size, addedAt}]
    // where `path` is vault-absolute ("/photos/cat.jpg"); only files carry
    // an `id` (their blob). Folder entries are structural markers.
    property var items: []
    readonly property int itemCount: items ? items.length : 0
    // The folder the card is currently browsing ("/" = safe root). Pure view
    // state, but it lives here so the drop target and IPC share one truth.
    property string currentFolder: "/"
    // The listing for the card: direct children of currentFolder, folders
    // first, each alphabetical.
    readonly property var visibleItems: _listFolder(currentFolder)
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
    // One recursive folder drop may queue at most this many file encryptions;
    // larger trees are refused whole rather than half-stashed.
    readonly property int maxStashFiles: 500

    // --- the job queue --------------------------------------------------------
    //
    // One worker process, jobs run strictly in order. Each job is a fixed
    // argv array plus an optional environment map; `done(code, stdout)` runs
    // between jobs, where it is safe to enqueue more.

    property var _queue: []
    property var _job: null
    // Item ids with a stage job in flight, so a press cannot double-queue.
    property var _staging: ({})
    // Bumped by every lock(). Async pipelines capture the value when they
    // start and abandon ship the moment it changes: without this, a lock
    // landing mid-pipeline lets a late callback re-wrap metadata under a
    // just-cleared (empty) key — openssl accepts an empty password, so the
    // index would silently become readable by anyone.
    property int _generation: 0

    function _enqueue(argv, env, done, timeoutMs) {
        _queue.push({ argv: argv, env: env || ({}), done: done || null,
                       timeoutMs: timeoutMs || 0 })
        _pump()
    }

    // True when `gen` was captured before the most recent lock — every
    // callback that carries one must stop the moment it flips.
    function _stale(gen) {
        return gen !== root._generation
    }

    function _pump() {
        if (_job || _queue.length === 0)
            return
        _job = _queue.shift()
        worker.environment = _job.env
        worker.command = _job.argv
        watchdog.interval = _job.timeoutMs > 0 ? _job.timeoutMs : 120000
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

    // Critical metadata (wrap.enc, recovery.enc, index.enc) is never written
    // in place: openssl encrypts into a hidden temp file in the same
    // directory and a rename flips it over the live name. A crash can cost
    // the new version, but a truncated or half-encrypted file can never be
    // what survives under the live name. The temp must share the vault
    // directory — a rename across filesystems (tmpfs scratch → disk) is a
    // copy, not an atomic flip.
    function _cipherAtomic(src, dstPath, passVar, env, done) {
        const tmp = root.vaultDir + "/.tmp-" + SafeModel.basename(dstPath)
        _enqueue(_cipherArgv(src, tmp, passVar, false), env, (code, out) => {
            if (code !== 0) {
                _enqueue(["rm", "-f", "--", tmp], {}, null)
                if (done) done(false)
                return
            }
            _enqueue(["mv", "-f", "--", tmp, dstPath], {}, (mc, mo) => {
                if (mc !== 0)
                    _enqueue(["rm", "-f", "--", tmp], {}, null)
                if (done) done(mc === 0)
            })
        })
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
            // A killed shell can leave staged plaintext behind with no sweeper
            // running. Nothing legitimate can be in the stage dir at boot —
            // the safe starts locked — so it is wiped before anything else.
            _enqueue(["rm", "-rf", "--", root.stageDir], {}, null)
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
                    _cipherAtomic(root.scratchDir + "/key", root.wrapPath, "OS_PW",
                                  { OS_PW: password }, ok2 => {
                        if (!ok2) {
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
                            _cipherAtomic(root.scratchDir + "/key", root.recoveryPath, "OS_RK",
                                          { OS_RK: rk }, ok3 => {
                                _rmScratch("key")
                                if (!ok3) {
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
                                _writeIndex(ok => {
                                    if (!ok) {
                                        root.busyLabel = ""
                                        root.lastError = "Could not create the safe"
                                        root.lock()
                                        return
                                    }
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
        // Everything queued against the old session dies with it; late
        // callbacks check their captured generation and stop.
        root._generation++
        root.sessionKey = ""
        root.items = []
        // Stagings aborted by the lock never reach _stageDone — the in-flight
        // map must not keep their paths marked busy, or the next session
        // would silently refuse to stage them again.
        root._staging = ({})
        root.busyLabel = ""
        root.lastError = ""
        root.unlockedViaRecovery = false
        root.clearStaged()
        autoLockTimer.stop()
        root.phase = root.initialized ? "locked" : "empty"
        root.currentFolder = "/"
    }

    // --- browsing ---------------------------------------------------------------
    //
    // The card browses the index like a tiny file system. A folder row is one
    // click away from its contents; a drop can land in whatever folder is
    // open instead of the root.

    function _listFolder(folder) {
        return SafeModel.childrenOf(root.items, folder)
    }

    // Open a folder (or "/" for the root). Anything else is ignored — the
    // path came from the index, but paths are checked again on the way in.
    function navigate(path) {
        const p = String(path || "/")
        if (!SafeModel.validVaultPath(p))
            return false
        if (p !== "/" && !(root.items || []).some(it => it.path === p && it.isDir))
            return false
        root.currentFolder = p
        return true
    }

    // True when `path` names a folder in the index (or the root, always a
    // folder). Drop targets call this before accepting a payload.
    function isFolder(path) {
        const p = String(path || "/")
        if (p === "/")
            return true
        return (root.items || []).some(it => it.path === p && it.isDir)
    }

    // A vault path that is not taken yet: "cat.jpg" → "cat.jpg", then
    // "cat (2).jpg", … inside `folder`. `taken` is the list of paths already
    // claimed by the index or by earlier entries of the same drop.
    function _uniqueVaultPath(folder, name, taken) {
        const base = SafeModel.safeName(name)
        let candidate = SafeModel.childPath(folder, base)
        if (taken.indexOf(candidate) === -1)
            return candidate
        const dot = base.lastIndexOf(".")
        const stem = dot > 0 ? base.substring(0, dot) : base
        const ext = dot > 0 ? base.substring(dot) : ""
        for (let i = 2; i < 1000; i++) {
            candidate = SafeModel.childPath(folder, stem + " (" + i + ")" + ext)
            if (taken.indexOf(candidate) === -1)
                return candidate
        }
        return SafeModel.childPath(folder, SafeModel.basename(candidate) + " (copy)")
    }

    // Every folder path from "/" down to the parent of `path` — used to
    // synthesize structural entries the index may lack after a load.
    function _ancestorPaths(path) {
        const out = []
        let p = SafeModel.parentOf(String(path || "/"))
        while (p !== "/") {
            out.push(p)
            p = SafeModel.parentOf(p)
        }
        return out
    }

    // --- drag-out staging -------------------------------------------------------
    //
    // A native drag has to offer a real file, so before the widget can start
    // one, the item is decrypted into the tmpfs stage directory. The widget
    // stages on mouse press and begins the drag on a later move event, once
    // the plaintext is on disk — Drag.startDrag() blocks until the drop lands,
    // so it must be the plain path by then.

    function _stageDone(key, path, ok, name, gen) {
        delete root._staging[key]
        root.busyLabel = ""
        // Locked mid-staging: the stage wipe is already queued behind this
        // job, so recording the path would leave the chips pointing at a
        // file that is about to be deleted.
        if (gen !== undefined && root._stale(gen))
            return
        if (!ok) {
            root._emitToast("Could not prepare " + name + " for dragging")
            return
        }
        // A fresh object every time: reassigning the same reference would not
        // fire the change signal, and the chips' stage-path bindings would
        // never see the new entry.
        const map = Object.assign({}, root.staged)
        map[key] = { path: path, at: Date.now() }
        root.staged = map
    }

    // Decrypts an item into the stage directory (idempotent per path).
    // Returns immediately; the widget polls `staged` for the resulting path.
    // Folders stage as real folders — every file under them is decrypted
    // into place — so a drag-out carries the whole tree.
    function stageItem(path) {
        if (root.phase !== "unlocked")
            return false
        const item = (root.items || []).find(it => it.path === path)
        if (!item)
            return false
        if (root.staged[item.path] || root._staging[item.path])
            return true
        root._staging[item.path] = true
        const name = SafeModel.baseNameOf(item.path)
        root.busyLabel = "Preparing " + name + "…"
        const gen = root._generation
        _enqueue(["sh", "-c", 'umask 077; mkdir -p -- "$1"', "omasafe-stage", root.stageDir], {}, (mc, mo) => {
            if (mc !== 0) {
                _stageDone(item.path, "", false, name, gen)
                return
            }
            // A stage name that is not already taken, so two items that share
            // a name stage side by side.
            _enqueue(["sh", "-c",
                      'n="$2"; base="$2"; ext=""; case "$2" in *.*) base="${2%.*}"; ext=".${2##*.}";; esac; '
                    + 'i=1; while [ -e "$1/$n" ] && [ "$i" -lt 50 ]; do i=$((i+1)); n="$base ($i)$ext"; done; printf "%s" "$n"',
                      "omasafe-stage-name", root.stageDir, SafeModel.safeName(name)], {}, (cc, co) => {
                if (root._stale(gen)) {
                    _stageDone(item.path, "", false, name, gen)
                    return
                }
                const finalName = co.trim() || SafeModel.safeName(name)
                const target = root.stageDir + "/" + finalName
                if (!item.isDir) {
                    const blobPath = root.vaultDir + "/" + item.id
                    _enqueue(_cipherArgv(blobPath, target, "OS_KEY", true),
                             { OS_KEY: root.sessionKey }, (dc, do2) => {
                        _stageDone(item.path, target, dc === 0, name, gen)
                    })
                    return
                }
                if (item.legacy) {
                    root._stageLegacyTar(item, target, name, gen)
                    return
                }
                // Modern folder: stage every file under it, preserving the
                // subtree layout.
                const files = []
                const dirs = []
                for (const it of root.items) {
                    if (!SafeModel.isUnder(it.path, item.path))
                        continue
                    if (it.isDir) {
                        if (dirs.indexOf(it.path) === -1)
                            dirs.push(it.path)
                    } else {
                        files.push(it)
                    }
                }
                if (files.length === 0) {
                    _enqueue(["mkdir", "-p", "--", target], {}, () => {
                        _stageDone(item.path, target, true, name, gen)
                    })
                    return
                }
                const mkdirArgs = ["mkdir", "-p", "--", target]
                for (const d of dirs) {
                    const rel = d.substring(item.path.length)
                    mkdirArgs.push(target + rel)
                }
                _enqueue(mkdirArgs, {}, (pc, po) => {
                    if (root._stale(gen)) {
                        _stageDone(item.path, "", false, name, gen)
                        return
                    }
                    if (pc !== 0) {
                        _stageDone(item.path, "", false, name, gen)
                        return
                    }
                    const jobs = []
                    for (const f of files) {
                        const rel = f.path.substring(item.path.length)
                        jobs.push({ id: f.id, target: target + rel, name: SafeModel.baseNameOf(f.path) })
                    }
                    root._decryptList(jobs, "Preparing " + name + "…", ok => {
                        _stageDone(item.path, target, ok, name, gen)
                    }, gen)
                })
            })
        })
        return true
    }

    // Decrypts blobs one by one through scratch into their final paths.
    // jobs: [{id, target, name}]; done(ok). Used by folder staging and
    // folder export — the queue makes the sequence strictly ordered.
    function _decryptList(jobs, label, done, gen) {
        let idx = 0
        const step = () => {
            if (root._stale(gen)) {
                done(false)
                return
            }
            if (idx >= jobs.length) {
                done(true)
                return
            }
            const j = jobs[idx]
            idx++
            root.busyLabel = label + " " + idx + "/" + jobs.length
            _enqueue(_cipherArgv(root.vaultDir + "/" + j.id, root.scratchDir + "/export.bin", "OS_KEY", true),
                     { OS_KEY: root.sessionKey }, (dc, dOut) => {
                if (root._stale(gen)) {
                    _rmScratch("export.bin")
                    done(false)
                    return
                }
                if (dc !== 0) {
                    _rmScratch("export.bin")
                    root.busyLabel = ""
                    done(false)
                    return
                }
                _enqueue(["mv", "--", root.scratchDir + "/export.bin", j.target], {}, (vc, vo) => {
                    if (vc !== 0)
                        _rmScratch("export.bin")
                    if (vc !== 0) {
                        root.busyLabel = ""
                        done(false)
                        return
                    }
                    step()
                })
            })
        }
        step()
    }

    // A pre-0.4.0 folder is one tar blob; stage it the old way until the
    // upgrade has exploded it.
    function _stageLegacyTar(item, target, name, gen) {
        _enqueue(_cipherArgv(root.vaultDir + "/" + item.id, root.scratchDir + "/item.tar", "OS_KEY", true),
                 { OS_KEY: root.sessionKey }, (dc, dOut) => {
            if (dc !== 0) {
                _rmScratch("item.tar")
                _stageDone(item.path, "", false, name, gen)
                return
            }
            _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {
                _enqueue(["mkdir", "-p", "--", root.scratchDir + "/extract"], {}, () => {
                    _enqueue(["tar", "-C", root.scratchDir + "/extract", "-xf",
                              root.scratchDir + "/item.tar"], {}, (xc, xo) => {
                        _rmScratch("item.tar")
                        if (xc !== 0) {
                            _stageDone(item.path, "", false, name, gen)
                            return
                        }
                        _enqueue(["mv", "--", root.scratchDir + "/extract/" + SafeModel.safeName(name),
                                  target], {}, (vc, vo) => {
                            _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {})
                            _stageDone(item.path, target, vc === 0, name, gen)
                        })
                    })
                })
            })
        })
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
        // Never yank the key out from under a running job: wait it out and
        // lock the moment the queue goes quiet.
        onTriggered: root.busy ? autoLockTimer.restart() : root.lock()
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
        const gen = root._generation
        _enqueue(_cipherArgv(root.wrapPath, "", "OS_PW", true), { OS_PW: attempt }, (code, out) => {
            if (root._stale(gen))
                return
            // Decrypt to stdout: no -out argument, so the plaintext key comes
            // back through the pipe and never touches the disk.
            const key = out.trim()
            if (code !== 0 || !SafeModel.isHex64(key)) {
                const backup = SafeModel.normalizeKey(attempt)
                if (SafeModel.isHex64(backup)) {
                    _unlockWithKey(backup, gen)
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
    function _unlockWithKey(key, gen) {
        _exists(root.recoveryPath, has => {
            if (root._stale(gen))
                return
            if (has) {
                _enqueue(_cipherArgv(root.recoveryPath, "", "OS_RK", true), { OS_RK: key }, (code, out) => {
                    if (root._stale(gen))
                        return
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
                if (root._stale(gen))
                    return
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
        const gen = root._generation
        _enqueue(_cipherArgv(root.indexPath, "", "OS_KEY", true), { OS_KEY: root.sessionKey }, (code, out) => {
            if (root._stale(gen))
                return
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
            const legacy = parsed && parsed.version === 1
            const clean = []
            const seen = []
            for (const item of list) {
                if (clean.length >= root.maxVaultItems)
                    break
                if (!item)
                    continue
                // v1 entries carry `name` and live at the root; v2 entries
                // carry a full vault path. Both are re-validated: the index
                // was ciphertext and may have been tampered with.
                const path = legacy
                    ? SafeModel.childPath("/", SafeModel.safeName(item.name))
                    : String(item.path || "")
                if (path === "/" || !SafeModel.validVaultPath(path) || seen.indexOf(path) !== -1)
                    continue
                const isDir = item.isDir === true
                let id = ""
                if (!isDir || legacy) {
                    // v1 folders are tar blobs; v2 folders are pure structure.
                    id = typeof item.id === "string" ? item.id : ""
                    if (!/^[0-9a-f]{32}$/.test(id))
                        continue
                }
                seen.push(path)
                clean.push({
                    id: id,
                    path: path,
                    isDir: isDir,
                    legacy: legacy && isDir,
                    size: SafeModel.clampInt(item.size, 0, 0, Number.MAX_SAFE_INTEGER),
                    addedAt: SafeModel.clampInt(item.addedAt, 0, 0, Number.MAX_SAFE_INTEGER)
                })
            }
            // A hand-edited index may reference files whose folders were
            // never declared; synthesize the missing structure so every
            // file's parent chain exists.
            for (let i = 0; i < clean.length; i++) {
                if (clean[i].isDir)
                    continue
                for (const anc of root._ancestorPaths(clean[i].path)) {
                    if (seen.indexOf(anc) === -1) {
                        seen.push(anc)
                        clean.push({ id: "", path: anc, isDir: true, legacy: false, size: 0, addedAt: 0 })
                    }
                }
            }
            root.items = clean
            root.lastError = ""
            root.phase = "unlocked"
            root.currentFolder = "/"
            if (legacy)
                root._migrateLegacy(gen)
            root._ensureRecovery()
        })
    }

    // Safes created before recovery.enc existed used the vault key itself as
    // the back-up key. On the first unlock of such a safe, issue a separate
    // back-up key wrapping the same vault key, show it once, and from then on
    // refuse the raw vault key — the old key is dead as far as the safe is
    // concerned. No blob is touched: the vault key does not change.
    function _ensureRecovery() {
        const gen = root._generation
        _exists(root.recoveryPath, has => {
            // A present recovery.enc means the safe is already upgraded; the
            // upgrade may only run when it is missing. Running it anyway would
            // re-mint the back-up key on every unlock, silently killing the
            // copy the user saved.
            if (root._stale(gen) || has)
                return
            root.busyLabel = "Upgrading the safe…"
            _hexJob(32, rk => {
                if (!SafeModel.isHex64(rk)) {
                    root.busyLabel = ""
                    root._emitToast("Could not issue a back-up key — try locking and unlocking again")
                    return
                }
                // Locked mid-upgrade: wrapping the now-empty session key
                // would replace recovery.enc with garbage the user can never
                // decrypt. The next unlock retries the upgrade instead.
                if (root._stale(gen) || !SafeModel.isHex64(root.sessionKey)) {
                    root.busyLabel = ""
                    return
                }
                _writeScratch("vkey", root.sessionKey, () => {
                    // Env for the wrap below is captured here — re-check.
                    if (root._stale(gen) || !SafeModel.isHex64(root.sessionKey)) {
                        _rmScratch("vkey")
                        root.busyLabel = ""
                        return
                    }
                    _cipherAtomic(root.scratchDir + "/vkey", root.recoveryPath, "OS_RK",
                                  { OS_RK: rk }, ok => {
                        _rmScratch("vkey")
                        root.busyLabel = ""
                        if (!ok) {
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

    // --- the v1 → v2 upgrade ------------------------------------------------------
    //
    // Safes from before 0.4.0 stored a dropped folder as one tar blob. The
    // first unlock after the upgrade explodes each of those into per-file
    // blobs and rewrites the index as v2. A failure anywhere leaves the v1
    // index on disk untouched — the upgrade simply retries next unlock, and
    // the session keeps working with the tar blobs marked legacy.

    function _migrateLegacy(gen) {
        const dirs = []
        for (const it of root.items)
            if (it.legacy)
                dirs.push(it)
        if (dirs.length === 0) {
            // Nothing to explode; persist the v2 layout (v1 files became
            // path-keyed entries) so this upgrade stops running.
            _writeIndex(null)
            return
        }
        root.busyLabel = "Upgrading the safe…"
        _migrateNext(dirs, 0, [], gen)
    }

    function _migrateNext(dirs, i, acc, gen) {
        if (root._stale(gen)) {
            root.busyLabel = ""
            return
        }
        if (i >= dirs.length) {
            const keep = []
            for (const it of root.items)
                if (!it.legacy)
                    keep.push(it)
            for (const e of acc)
                keep.push(e)
            root.items = keep
            root.busyLabel = ""
            _writeIndex(ok => {
                if (ok)
                    root._emitToast("Safe upgraded — folders are now browsable")
            })
            return
        }
        const entry = dirs[i]
        _migrateOne(entry, newEntries => {
            if (root._stale(gen))
                return
            if (newEntries === null) {
                root.busyLabel = ""
                root._emitToast("Could not upgrade a folder — the safe keeps the old layout and retries next unlock")
                return
            }
            for (const e of newEntries)
                acc.push(e)
            _enqueue(["rm", "-f", "--", root.vaultDir + "/" + entry.id], {}, null)
            _migrateNext(dirs, i + 1, acc, gen)
        }, gen)
    }

    // Decrypts one legacy tar blob, unpacks it in scratch, and turns its
    // contents into a plan of per-file blobs. done(newEntries|null).
    function _migrateOne(entry, done, gen) {
        _enqueue(_cipherArgv(root.vaultDir + "/" + entry.id, root.scratchDir + "/item.tar", "OS_KEY", true),
                 { OS_KEY: root.sessionKey }, (dc, dOut) => {
            if (root._stale(gen)) { done(null); return }
            if (dc !== 0) { _rmScratch("item.tar"); done(null); return }
            _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {
                _enqueue(["mkdir", "-p", "--", root.scratchDir + "/extract"], {}, () => {
                    _enqueue(["tar", "-C", root.scratchDir + "/extract", "-xf",
                              root.scratchDir + "/item.tar"], {}, (xc, xo) => {
                        _rmScratch("item.tar")
                        if (root._stale(gen)) { done(null); return }
                        if (xc !== 0) { done(null); return }
                        // Constant script; only the tree root travels as an
                        // argument. %P gives paths relative to it.
                        _enqueue(["sh", "-c",
                                  'find "$1" -mindepth 1 ! -type l \\( -type f -o -type d \\) -printf \'%y\\t%s\\t%P\\n\' | sort',
                                  "omasafe-find", root.scratchDir + "/extract"], {}, (fc, fo) => {
                            if (root._stale(gen)) { done(null); return }
                            if (fc !== 0) { done(null); return }
                            root._migratePlan(entry, String(fo || ""), done, gen)
                        })
                    })
                })
            })
        })
    }

    // Turns find output into a file plan (name collisions after
    // sanitization get unique vault paths) and encrypts it blob by blob.
    function _migratePlan(entry, findOut, done, gen) {
        const srcDir = root.scratchDir + "/extract"
        const taken = root._takenPaths()
        const files = []
        const dirs = []
        let tooBig = false
        for (const line of findOut.split("\n")) {
            if (line === "")
                continue
            const parts = line.split("\t")
            if (parts.length < 3)
                continue
            const kind = parts[0]
            const rel = parts.slice(2).join("\t")
            // The first segment is the archive's own root folder — the
            // entry's vault path already carries it.
            const segs = rel.split("/")
            segs.shift()
            let vp = entry.path
            for (const s of segs)
                vp = SafeModel.childPath(vp, SafeModel.safeName(s))
            if (!SafeModel.validVaultPath(vp))
                continue
            if (kind === "d") {
                if (dirs.indexOf(vp) === -1)
                    dirs.push(vp)
            } else {
                if (files.length >= root.maxStashFiles) {
                    tooBig = true
                    break
                }
                const dest = root._uniqueVaultPath(SafeModel.parentOf(vp), SafeModel.baseNameOf(vp), taken)
                taken.push(dest)
                files.push({
                    disk: srcDir + "/" + rel,
                    vaultPath: dest,
                    size: SafeModel.clampInt(parts[1], 0, 0, Number.MAX_SAFE_INTEGER)
                })
            }
        }
        if (tooBig) {
            _enqueue(["rm", "-rf", "--", srcDir], {}, null)
            done(null)
            return
        }
        const out = []
        for (const d of dirs)
            out.push({ id: "", path: d, isDir: true, legacy: false, size: 0, addedAt: entry.addedAt })
        root._encryptList(files, "Upgrading the safe…", true, (newFiles, failed) => {
            _enqueue(["rm", "-rf", "--", srcDir], {}, () => {
                // Strict mode: null means a failure (or a lock) — the upgrade
                // aborts whole and retries next unlock, with the old tar
                // blob still intact.
                if (newFiles === null || failed > 0) {
                    done(null)
                    return
                }
                for (const f of newFiles)
                    out.push(f)
                done(out)
            })
        }, gen)
    }

    // Encrypts files one by one into fresh blobs. `files` is
    // [{disk, vaultPath, size}].
    //
    // In strict mode (the legacy upgrade) any failure aborts the run — a
    // partial migration would lose the failed files with the old tar blob,
    // so it must be all or nothing, retried next unlock.
    //
    // Outside strict mode a file that cannot be read is skipped and counted:
    // the rest of the folder still lands in the safe, and the summary names
    // the shortfall. done(entries, failed) receives the finished entries and
    // the failure count, or done(null, 0) when the safe locked mid-run —
    // earlier blobs survive as orphans, which are harmless.
    function _encryptList(files, label, strict, done, gen) {
        const out = []
        let idx = 0
        let failed = 0
        const step = () => {
            if (root._stale(gen)) {
                done(null, 0)
                return
            }
            if (idx >= files.length) {
                done(out, failed)
                return
            }
            const f = files[idx]
            idx++
            root.busyLabel = label + " " + idx + "/" + files.length
            const fail = () => {
                if (strict) {
                    root.busyLabel = ""
                    done(null, 0)
                    return
                }
                failed++
                step()
            }
            _hexJob(16, id => {
                if (!/^[0-9a-f]{32}$/.test(id)) {
                    fail()
                    return
                }
                if (root._stale(gen)) {
                    done(null, 0)
                    return
                }
                _enqueue(_cipherArgv(f.disk, root.vaultDir + "/" + id, "OS_KEY", false),
                         { OS_KEY: root.sessionKey }, (ec, eo) => {
                    if (root._stale(gen)) {
                        done(null, 0)
                        return
                    }
                    if (ec !== 0) {
                        // Clean the partial blob; counting continues below.
                        _enqueue(["rm", "-f", "--", root.vaultDir + "/" + id], {}, null)
                        fail()
                        return
                    }
                    out.push({ id: id, path: f.vaultPath, isDir: false, legacy: false,
                               size: f.size, addedAt: Date.now() })
                    step()
                })
            })
        }
        step()
    }

    // Re-encrypts the manifest from the in-memory list. The queue makes this
    // race-free: only one job touches index.enc at a time.
    function _writeIndex(done) {
        // Last-ditch invariant: a locked (or half-locked) safe must never
        // rewrite the manifest — openssl would happily encrypt it under an
        // empty password. Callers guard this with the generation; this is
        // the backstop that makes the invariant impossible to violate.
        if (!SafeModel.isHex64(root.sessionKey)) {
            if (done)
                done(false)
            return
        }
        const gen = root._generation
        const json = JSON.stringify({ version: 2, items: root.items })
        _writeScratch("index.json", json, () => {
            // The env below is captured at this exact moment, so the guard
            // has to sit here too — a lock that landed while the scratch
            // write ran left sessionKey empty, and the check above the
            // scratch write is already stale history.
            if (root._stale(gen) || !SafeModel.isHex64(root.sessionKey)) {
                _rmScratch("index.json")
                if (done)
                    done(false)
                return
            }
            _cipherAtomic(root.scratchDir + "/index.json", root.indexPath, "OS_KEY",
                          { OS_KEY: root.sessionKey }, (ok) => {
                _rmScratch("index.json")
                if (root._stale(gen)) {
                    if (done)
                        done(false)
                    return
                }
                if (!ok)
                    root._emitToast("Could not update the safe's index")
                if (done)
                    done(ok)
            })
        })
    }

    function _emitToast(message) {
        root.toast(message)
    }

    // --- stashing (drag & drop / IPC) ------------------------------------------

    // Every path already claimed in the index — the collision universe a new
    // entry must be unique against.
    function _takenPaths() {
        const out = []
        for (const it of root.items)
            out.push(it.path)
        return out
    }

    function stash(entries, folder) {
        if (root.phase !== "unlocked") {
            root._emitToast("Unlock the safe before adding files")
            return 0
        }
        // Drops land in the folder the card is browsing; anything else (bar
        // icon, IPC) goes to the root.
        const target = typeof folder === "string" && root.isFolder(folder) ? folder : "/"
        const paths = SafeModel.pathsFromEntries(entries)
        const remaining = Math.max(0, root.maxVaultItems - root.itemCount)
        if (remaining === 0) {
            root._emitToast("The safe has reached its item limit")
            return 0
        }
        // A cap keeps one IPC call — from a drag or a local caller — from
        // queueing an unbounded pile of jobs against the running shell. A
        // folder drop adds one entry per file, so the hard cap is checked
        // again inside the recursive stasher.
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
            if (root._stashOne(path, target))
                queued++
        }
        return queued
    }

    function _stashOne(path, folderPath) {
        const rawName = SafeModel.basename(path)
        const name = SafeModel.safeName(rawName)
        // The archive root and manifest name must remain identical. Refuse a
        // deceptive/control-bearing basename rather than silently renaming it.
        if (name === "" || name === "." || name === ".." || name !== rawName) {
            root._emitToast("Skipped an item whose name contains unsupported characters")
            return false
        }
        root.busyLabel = "Locking " + name + "…"
        const gen = root._generation
        // What kind of file is this? The script is a constant; only the path
        // travels as an argument.
        _enqueue(["sh", "-c",
                  'if [ -L "$1" ]; then echo link; elif [ -d "$1" ]; then echo dir; '
                + 'elif [ -f "$1" ]; then echo "file $(stat -c %s -- "$1")"; '
                + 'else echo missing; fi',
                  "omasafe-stat", path], {}, (code, out) => {
            if (root._stale(gen))
                return
            const answer = out.trim().split(" ")
            const kind = answer[0]
            const size = answer.length > 1 ? SafeModel.clampInt(answer[1], 0, 0, Number.MAX_SAFE_INTEGER) : 0
            if (kind === "missing" || kind === "link") {
                root.busyLabel = ""
                root._emitToast("Skipped " + name + (kind === "link" ? " (symlinks are not safe material)" : ""))
                return
            }
            if (kind === "dir") {
                root._stashFolder(path, folderPath, gen)
                return
            }
            _hexJob(16, id => {
                if (id === "" || !/^[0-9a-f]{32}$/.test(id)) {
                    root.busyLabel = ""
                    root._emitToast("Could not lock " + name)
                    return
                }
                if (root._stale(gen)) {
                    root.busyLabel = ""
                    return
                }
                const vaultPath = root._uniqueVaultPath(folderPath, name, root._takenPaths())
                _enqueue(_cipherArgv(path, root.vaultDir + "/" + id, "OS_KEY", false),
                         { OS_KEY: root.sessionKey }, (ec, eo) => {
                    if (ec !== 0) {
                        root.busyLabel = ""
                        root._emitToast("Could not lock " + name)
                        return
                    }
                    _stashCommit(id, vaultPath, size, path, gen)
                })
            })
        })
        return true
    }

    // Blob written and verified by openssl's exit code: record it in the
    // index, then — and only then — remove the original. A lock that landed
    // mid-pipeline stops here: the blob survives as an unindexed orphan
    // (harmless), the original stays on disk, and nothing is rewritten
    // under an empty key.
    function _stashCommit(id, vaultPath, size, originalPath, gen) {
        if (root._stale(gen)) {
            root.busyLabel = ""
            root._emitToast("The safe locked before " + SafeModel.baseNameOf(vaultPath)
                            + " was recorded — nothing was deleted")
            return
        }
        const entry = { id: id, path: vaultPath, isDir: false, legacy: false,
                        size: size, addedAt: Date.now() }
        const list = root.items.slice()
        for (const anc of root._ancestorPaths(vaultPath)) {
            if (!list.some(it => it.path === anc))
                list.push({ id: "", path: anc, isDir: true, legacy: false,
                            size: 0, addedAt: entry.addedAt })
        }
        list.push(entry)
        root.items = list
        _writeIndex(ok => {
            root.busyLabel = ""
            if (!ok) {
                root._emitToast(SafeModel.baseNameOf(vaultPath) + " is encrypted but not indexed — do not delete the original")
                return
            }
            if (_deletable(originalPath)) {
                _enqueue(["rm", "-rf", "--", originalPath], {}, (rc, ro) => {
                    if (rc !== 0)
                        root._emitToast("Locked " + SafeModel.baseNameOf(vaultPath) + " — the original could not be removed")
                    else
                        root._emitToast("Locked " + SafeModel.baseNameOf(vaultPath))
                })
            } else {
                root._emitToast("Locked a copy of " + SafeModel.baseNameOf(vaultPath))
            }
        })
    }

    // A dropped folder becomes a folder entry plus one blob per file, so it
    // can be browsed and grown later without ever re-encrypting the whole
    // tree. The index is written once, after the last file.
    function _stashFolder(origPath, folderPath, gen) {
        const rawName = SafeModel.basename(origPath)
        const name = SafeModel.safeName(rawName)
        if (name === "" || name === "." || name === ".." || name !== rawName) {
            root.busyLabel = ""
            root._emitToast("Skipped a folder whose name contains unsupported characters")
            return
        }
        const taken = root._takenPaths()
        const target = root._uniqueVaultPath(folderPath, name, taken)
        taken.push(target)
        root.busyLabel = "Reading " + name + "…"
        // Constant script; only the tree root travels as an argument. %P
        // gives paths relative to it, sorted for deterministic order.
        _enqueue(["sh", "-c",
                  'find "$1" -mindepth 1 ! -type l \\( -type f -o -type d \\) -printf \'%y\\t%s\\t%P\\n\' | sort',
                  "omasafe-find", origPath], {}, (fc, fo) => {
            if (root._stale(gen)) {
                root.busyLabel = ""
                return
            }
            root.busyLabel = ""
            if (fc !== 0) {
                root._emitToast("Could not read " + name)
                return
            }
            const files = []
            const dirs = []
            let tooBig = false
            for (const line of String(fo || "").split("\n")) {
                if (line === "")
                    continue
                const parts = line.split("\t")
                if (parts.length < 3)
                    continue
                const rel = parts.slice(2).join("\t")
                let vp = target
                for (const s of rel.split("/"))
                    vp = SafeModel.childPath(vp, SafeModel.safeName(s))
                if (!SafeModel.validVaultPath(vp))
                    continue
                if (parts[0] === "d") {
                    if (dirs.indexOf(vp) === -1)
                        dirs.push(vp)
                } else {
                    if (files.length >= root.maxStashFiles) {
                        tooBig = true
                        break
                    }
                    const dest = root._uniqueVaultPath(SafeModel.parentOf(vp), SafeModel.baseNameOf(vp), taken)
                    taken.push(dest)
                    files.push({
                        disk: origPath + "/" + rel,
                        vaultPath: dest,
                        size: SafeModel.clampInt(parts[1], 0, 0, Number.MAX_SAFE_INTEGER)
                    })
                }
            }
            if (tooBig) {
                root._emitToast(name + " holds more than " + root.maxStashFiles
                                + " files — it was refused whole. Split it up or add it in parts.")
                return
            }
            // Structure entries: the found dirs plus every ancestor a file
            // implies, all the way up to the folder being dropped.
            for (const f of files) {
                for (const anc of root._ancestorPaths(f.vaultPath))
                    if (dirs.indexOf(anc) === -1)
                        dirs.push(anc)
            }
            for (let i = 0; i < dirs.length; ) {
                const above = root._ancestorPaths(dirs[i])
                let grew = false
                for (const anc of above)
                    if (dirs.indexOf(anc) === -1) {
                        dirs.push(anc)
                        grew = true
                    }
                if (!grew)
                    i++
            }
            if (root.itemCount + dirs.length + files.length > root.maxVaultItems) {
                root._emitToast("Not enough room for " + name + " — nothing was changed")
                return
            }
            if (files.length === 0) {
                // An empty folder is still a folder: record the structure.
                const entries = [{ id: "", path: target, isDir: true, legacy: false,
                                   size: 0, addedAt: Date.now() }]
                for (const d of dirs)
                    if (d !== target)
                        entries.push({ id: "", path: d, isDir: true, legacy: false,
                                       size: 0, addedAt: Date.now() })
                _commitEntries(entries, origPath, gen, "Locked " + name, false)
                return
            }
            _encryptList(files, "Locking " + name + "…", false, (newFiles, failed) => {
                if (newFiles === null)
                    return
                const entries = [{ id: "", path: target, isDir: true, legacy: false,
                                   size: 0, addedAt: Date.now() }]
                for (const d of dirs)
                    if (d !== target)
                        entries.push({ id: "", path: d, isDir: true, legacy: false,
                                       size: 0, addedAt: Date.now() })
                for (const f of newFiles)
                    entries.push(f)
                let doneLabel
                let keepOriginal = false
                if (failed > 0) {
                    // The whole tree stays on disk: a blanket rm -rf would
                    // take the failed files' originals with it.
                    keepOriginal = true
                    doneLabel = "Locked " + newFiles.length + " of " + files.length
                                + " files from " + name + " — the original folder was kept"
                } else if (files.length > 1)
                    doneLabel = "Locked " + name + " (" + files.length + " files)"
                else
                    doneLabel = "Locked " + name
                _commitEntries(entries, origPath, gen, doneLabel, keepOriginal)
            }, gen)
        })
    }

    // Appends finished entries to the index in a single write, then removes
    // the original — unless `keepOriginal` is set (a partial run must not
    // delete the files that failed to stash). `doneLabel` is the summary for
    // the success toast. Callers have gen-guarded their way here; the write
    // re-checks on its own.
    function _commitEntries(entries, originalPath, gen, doneLabel, keepOriginal) {
        if (root._stale(gen)) {
            root.busyLabel = ""
            root._emitToast("The safe locked — nothing was recorded, the original was kept")
            return
        }
        const list = root.items.slice()
        for (const e of entries)
            list.push(e)
        root.items = list
        const name = SafeModel.baseNameOf(entries[0].path)
        _writeIndex(ok => {
            root.busyLabel = ""
            if (!ok) {
                root._emitToast("Encrypted, but the index could not be updated — do not delete the original")
                return
            }
            if (!keepOriginal && _deletable(originalPath)) {
                _enqueue(["rm", "-rf", "--", originalPath], {}, (rc, ro) => {
                    root._emitToast(rc === 0 ? doneLabel
                                             : doneLabel + " — the original could not be removed")
                })
            } else {
                root._emitToast(keepOriginal ? doneLabel : "Locked a copy of " + name)
            }
        })
    }

    // --- extraction -----------------------------------------------------------

    function extractAt(path) {
        if (root.phase !== "unlocked")
            return
        const item = (root.items || []).find(it => it.path === path)
        if (!item)
            return
        const name = SafeModel.baseNameOf(item.path)
        root.busyLabel = "Unlocking " + name + "…"
        const gen = root._generation
        _enqueue(["sh", "-c", 'mkdir -p -- "$1"', "omasafe-export", root.exportDir], {}, (mc, mo) => {
            if (mc !== 0) {
                root.busyLabel = ""
                root._emitToast("Could not create " + root.exportDir)
                return
            }
            if (item.isDir && !item.legacy) {
                root._extractFolder(item, name, gen)
                return
            }
            // Pick an export name that is not already taken; the loop is a
            // constant script, the starting name an argument.
            _enqueue(["sh", "-c",
                      'n="$2"; base="$2"; ext=""; case "$2" in *.*) base="${2%.*}"; ext=".${2##*.}";; esac; '
                    + 'i=1; while [ -e "$1/$n" ] && [ "$i" -lt 50 ]; do i=$((i+1)); n="$base ($i)$ext"; done; printf "%s" "$n"',
                      "omasafe-collision", root.exportDir, SafeModel.safeName(name)], {}, (cc, co) => {
                // Everything below decrypts with the session key; a safe that
                // locked meanwhile must not decrypt garbage into Downloads.
                if (root._stale(gen)) {
                    root.busyLabel = ""
                    return
                }
                const finalName = co.trim() || SafeModel.safeName(name)
                if (item.isDir) {
                    // Legacy tar folder: unpack straight into place.
                    root._extractLegacyTar(item, finalName, name, gen)
                    return
                }
                const blobPath = root.vaultDir + "/" + item.id
                // Files decrypt into the scratch dir and are renamed into
                // place: a rename replaces whatever sits at the target
                // (including a hostile symlink) instead of following it,
                // and the write lands atomically.
                _enqueue(_cipherArgv(blobPath, root.scratchDir + "/export.bin", "OS_KEY", true),
                         { OS_KEY: root.sessionKey }, (dc, do2) => {
                    if (dc !== 0) {
                        _rmScratch("export.bin")
                        root.busyLabel = ""
                        root._emitToast("Could not unlock " + name)
                        return
                    }
                    _enqueue(["mv", "--", root.scratchDir + "/export.bin",
                              root.exportDir + "/" + finalName], {}, (vc, vo) => {
                        if (vc !== 0)
                            _rmScratch("export.bin")
                        root.busyLabel = ""
                        if (vc !== 0)
                            root._emitToast("Could not move " + name + " out of the safe")
                        else
                            root._emitToast("Saved " + finalName + " to Downloads/OmaSafe")
                    })
                })
            })
        })
    }

    // Modern folder export: recreate the subtree under one fresh name in
    // Downloads/OmaSafe — a collision renames the folder instead of merging.
    function _extractFolder(item, name, gen) {
        _enqueue(["sh", "-c",
                  'n="$2"; base="$2"; ext=""; case "$2" in *.*) base="${2%.*}"; ext=".${2##*.}";; esac; '
                + 'i=1; while [ -e "$1/$n" ] && [ "$i" -lt 50 ]; do i=$((i+1)); n="$base ($i)$ext"; done; printf "%s" "$n"',
                  "omasafe-collision", root.exportDir, SafeModel.safeName(name)], {}, (cc, co) => {
            if (root._stale(gen)) {
                root.busyLabel = ""
                return
            }
            const finalName = co.trim() || SafeModel.safeName(name)
            const rootTarget = root.exportDir + "/" + finalName
            const files = []
            const dirs = []
            for (const it of root.items) {
                if (!SafeModel.isUnder(it.path, item.path))
                    continue
                if (it.isDir) {
                    if (dirs.indexOf(it.path) === -1)
                        dirs.push(it.path)
                } else {
                    files.push(it)
                }
            }
            if (files.length === 0) {
                // An empty folder exports as an empty folder.
                _enqueue(["mkdir", "-p", "--", rootTarget], {}, (pc, po) => {
                    root.busyLabel = ""
                    root._emitToast(pc === 0 ? "Saved " + finalName + " to Downloads/OmaSafe"
                                             : "Could not move " + name + " out of the safe")
                })
                return
            }
            // Every parent the extracted files need — the index's dir
            // entries already cover the chain, mirrored under rootTarget.
            const mkdirArgs = ["mkdir", "-p", "--", rootTarget]
            for (const d of dirs) {
                const rel = d.substring(item.path.length)
                mkdirArgs.push(rootTarget + rel)
            }
            _enqueue(mkdirArgs, {}, (pc, po) => {
                if (root._stale(gen)) {
                    root.busyLabel = ""
                    return
                }
                if (pc !== 0) {
                    root.busyLabel = ""
                    root._emitToast("Could not move " + name + " out of the safe")
                    return
                }
                const jobs = []
                for (const f of files) {
                    const rel = f.path.substring(item.path.length)
                    jobs.push({ id: f.id, target: rootTarget + rel,
                                name: SafeModel.baseNameOf(f.path) })
                }
                root._decryptList(jobs, "Unlocking " + name + "…", ok => {
                    root.busyLabel = ""
                    if (ok)
                        root._emitToast("Saved " + finalName + " to Downloads/OmaSafe")
                    else
                        root._emitToast("Could not move " + name + " out of the safe")
                }, gen)
            })
        })
    }

    // Pre-0.4.0 tar folder: decrypt, unpack in scratch, move into place.
    function _extractLegacyTar(item, finalName, name, gen) {
        const blobPath = root.vaultDir + "/" + item.id
        _enqueue(_cipherArgv(blobPath, root.scratchDir + "/item.tar", "OS_KEY", true),
                 { OS_KEY: root.sessionKey }, (dc, dOut) => {
            if (dc !== 0) {
                _rmScratch("item.tar")
                root.busyLabel = ""
                root._emitToast("Could not unlock " + name)
                return
            }
            _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {
                _enqueue(["mkdir", "-p", "--", root.scratchDir + "/extract"], {}, () => {
                    _enqueue(["tar", "-C", root.scratchDir + "/extract", "-xf",
                              root.scratchDir + "/item.tar"], {}, (xc, xo) => {
                        _rmScratch("item.tar")
                        if (xc !== 0) {
                            root.busyLabel = ""
                            root._emitToast("Could not unpack " + name)
                            return
                        }
                        _enqueue(["mv", "--", root.scratchDir + "/extract/" + SafeModel.safeName(name),
                                  root.exportDir + "/" + finalName], {}, (vc, vo) => {
                            _enqueue(["rm", "-rf", "--", root.scratchDir + "/extract"], {}, () => {})
                            root.busyLabel = ""
                            if (vc !== 0)
                                root._emitToast("Could not move " + name + " out of the safe")
                            else
                                root._emitToast("Saved " + finalName + " to Downloads/OmaSafe")
                        })
                    })
                })
            })
        })
    }

    // --- deletion / password ---------------------------------------------------

    function deleteAt(path) {
        if (root.phase !== "unlocked")
            return
        const item = (root.items || []).find(it => it.path === path)
        if (!item)
            return
        const name = SafeModel.baseNameOf(item.path)
        root.busyLabel = "Destroying " + name + "…"
        const gen = root._generation
        if (item.isDir && !item.legacy) {
            // Every file under the folder has its own blob; erase them all
            // in one job, then drop the entries.
            const ids = []
            for (const it of root.items)
                if (!it.isDir && SafeModel.isUnder(it.path, item.path))
                    ids.push(it.id)
            const argv = ["rm", "-f", "--"]
            for (const id of ids)
                argv.push(root.vaultDir + "/" + id)
            _enqueue(argv, {}, (code, out) => {
                if (root._stale(gen)) {
                    root.busyLabel = ""
                    root._emitToast("The safe locked before " + name + " was destroyed — it is still in the safe")
                    return
                }
                _deleteEntries(item, name, gen)
            })
            return
        }
        _enqueue(["rm", "-f", "--", root.vaultDir + "/" + item.id], {}, (code, out) => {
            if (root._stale(gen)) {
                root.busyLabel = ""
                root._emitToast("The safe locked before " + name + " was destroyed — it is still in the safe")
                return
            }
            _deleteEntries(item, name, gen)
        })
    }

    function _deleteEntries(item, name, gen) {
        const list = []
        for (const it of root.items)
            if (it !== item && !SafeModel.isUnder(it.path, item.path))
                list.push(it)
        root.items = list
        // If the card was inside the deleted folder, walk back up.
        if (root.currentFolder === item.path || SafeModel.isUnder(root.currentFolder, item.path))
            root.currentFolder = SafeModel.parentOf(item.path)
        _writeIndex(ok => {
            root.busyLabel = ""
            root._emitToast(ok ? "Destroyed " + name : "Could not update the index")
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
        const gen = root._generation
        const fail = () => {
            root.busyLabel = ""
            root.lastError = "The current password or back-up key is wrong"
        }
        _enqueue(_cipherArgv(root.wrapPath, "", "OS_OLD", true), { OS_OLD: old }, (code, out) => {
            if (root._stale(gen))
                return
            if (code === 0 && out.trim() === root.sessionKey) {
                root._rotateSecrets(newPassword, gen)
                return
            }
            const rk = SafeModel.normalizeKey(old)
            if (!SafeModel.isHex64(rk)) {
                fail()
                return
            }
            _enqueue(_cipherArgv(root.recoveryPath, "", "OS_RK", true), { OS_RK: rk }, (code2, out2) => {
                if (root._stale(gen))
                    return
                if (code2 !== 0 || out2.trim() !== root.sessionKey) {
                    fail()
                    return
                }
                root._rotateSecrets(newPassword, gen)
            })
        })
        return true
    }

    function _rotateSecrets(newPassword, gen) {
        const done = () => {
            root.busyLabel = ""
        }
        _hexJob(32, rk => {
            if (!SafeModel.isHex64(rk)) {
                done()
                root._emitToast("Could not issue a new back-up key — nothing was changed")
                return
            }
            // The guard that matters most in this file: re-wrapping the
            // session key after a lock would encrypt an empty string under
            // the new password and the new back-up key — both wraps dead,
            // the vault key gone. Never rotate without a live key.
            if (root._stale(gen) || !SafeModel.isHex64(root.sessionKey)) {
                done()
                root._emitToast("The safe locked — the password was not changed")
                return
            }
            _writeScratch("vkey", root.sessionKey, () => {
                // Env for both wraps below is captured here — re-check.
                if (root._stale(gen) || !SafeModel.isHex64(root.sessionKey)) {
                    _rmScratch("vkey")
                    done()
                    root._emitToast("The safe locked — the password was not changed")
                    return
                }
                _cipherAtomic(root.scratchDir + "/vkey", root.wrapPath, "OS_PW",
                              { OS_PW: newPassword }, ok1 => {
                    if (!ok1) {
                        _rmScratch("vkey")
                        done()
                        root._emitToast("Could not change the password — nothing was changed")
                        return
                    }
                    _cipherAtomic(root.scratchDir + "/vkey", root.recoveryPath, "OS_RK",
                                  { OS_RK: rk }, ok2 => {
                        _rmScratch("vkey")
                        done()
                        if (!ok2) {
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

    // --- keyring (optional copy of the back-up key) -----------------------------
    //
    // The back-up key can be copied into a dedicated keyring ("OmaSafe"),
    // apart from the session-unlocked default: the keyring keeps its own
    // password, nothing opens it at login, and reading it pops the native
    // keyring dialog. The copy is strictly a convenience for a lost
    // password — the vault's wraps never depend on it, and deleting the
    // keyring or its item from a keyring manager revokes nothing.

    // Finds the dedicated keyring by label. The script is a constant; the
    // daemon mangles collection names into safe path segments, and the
    // discovered path is validated before anything else ever sees it.
    function _keyringFind(done) {
        _enqueue(["sh", "-c",
                  'busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets '
                + 'org.freedesktop.Secret.Service Collections 2>/dev/null '
                + '| grep -o \'/org/freedesktop/secrets/collection/[^" ]*\' '
                + '| while IFS= read -r p; do '
                + 'busctl --user get-property org.freedesktop.secrets "$p" '
                + 'org.freedesktop.Secret.Collection Label 2>/dev/null '
                + '| grep -q \'"OmaSafe"\' && printf \'%s\\n\' "$p"; done | head -n 1',
                  "omasafe-keyring-find"], {}, (code, out) => {
            const p = String(out || "").trim()
            done(SafeModel.validKeyringPath(p) ? p : "")
        })
    }

    // Cheap existence probe for the card: is the dedicated keyring there?
    // Runs when the popout opens (and after any lock) so the unlock view
    // can offer keyring recovery.
    function probeKeyring() {
        _keyringFind(p => {
            root.keyringPath = p
            root.keyringAvailable = p !== ""
        })
    }

    function _keyringHelperPath() {
        const u = Qt.resolvedUrl("keyring-create.py").toString()
        return u.indexOf("file://") === 0 ? u.substring(7) : u
    }

    // One-time creation of the dedicated keyring. Creating a Secret
    // Service collection needs CreateCollection plus the caller-bound
    // Prompt on one D-Bus connection, which no single-shot CLI can do —
    // hence the shipped helper. The native dialog collects the new
    // keyring's password, which never passes through the safe at all.
    function _keyringCreate(done) {
        _enqueue(["python3", root._keyringHelperPath()], {}, (code, out) => {
            const status = String(out || "").split("\n")[0].trim()
            done(code === 0 && status === "created")
        }, 330000)
    }

    // Stores the key into the dedicated keyring. The key rides the
    // environment into secret-tool's stdin — never argv, never a file —
    // and the store is refused unless the key is still the one on screen:
    // a rotation that landed mid-flow must not leave the old back-up key
    // in the keyring looking current.
    function _keyringStoreIn(path, key, done) {
        if (!SafeModel.validKeyringPath(path) || !SafeModel.isHex64(key)
                || root.pendingBackupKey !== key) {
            done(false)
            return
        }
        _enqueue(["sh", "-c",
                  'printf \'%s\' "$OS_RK" | secret-tool store '
                + '--label=\'OmaSafe back-up key\' -c "$1" application omasafe item backup',
                  "omasafe-keyring-store", path],
                 { OS_RK: key }, (code, out) => done(code === 0), 180000)
    }

    // Locks the dedicated keyring again. Unlocking a collection leaves it
    // open for the rest of the session, so a recovery right after a save
    // would read the copy with no prompt at all — the keyring must sit
    // behind its password except during the exact operation using it.
    // Locking needs no password, so this always runs, no-op included.
    function _keyringLock(path, done) {
        if (!SafeModel.validKeyringPath(path)) {
            if (done)
                done(false)
            return
        }
        _enqueue(["busctl", "--user", "call", "org.freedesktop.secrets",
                  "/org/freedesktop/secrets", "org.freedesktop.Secret.Service",
                  "Lock", "ao", "1", path], {}, (code, out) => {
            if (done)
                done(code === 0)
        })
    }

    // The banner button: copy the pending back-up key into the dedicated
    // keyring, creating the keyring first when it does not exist yet. The
    // keyring is locked again afterwards whatever happened, so the next
    // use always asks for its password.
    function keyringSavePendingKey() {
        const key = root.pendingBackupKey
        if (!SafeModel.isHex64(key) || root.busy)
            return false
        const finish = ok => {
            root.busyLabel = ""
            if (!ok) {
                root._emitToast("Could not save the back-up key in the keyring")
                return
            }
            root.keyringLastSaveKey = key
            root._emitToast("Back-up key saved in the OmaSafe keyring")
        }
        root.busyLabel = "Saving in the keyring…"
        _keyringFind(path => {
            if (path !== "") {
                _keyringStoreIn(path, key, ok => _keyringLock(path, () => finish(ok)))
                return
            }
            root.busyLabel = "Creating the keyring — choose its password in the dialog…"
            _keyringCreate(ok => {
                if (!ok) {
                    finish(false)
                    return
                }
                _keyringFind(p2 => {
                    root.busyLabel = "Saving in the keyring…"
                    _keyringStoreIn(p2, key, ok => _keyringLock(p2, () => finish(ok)))
                })
            })
        })
        return true
    }

    // The unlock card's keyring path: ask the Secret Service for the saved
    // back-up key. A locked keyring pops the native unlock dialog, so the
    // job gets a long deadline; the value must come back as a full 64-hex
    // key before it is handed to the normal back-up-key unlock.
    function recoverFromKeyring() {
        if (root.phase !== "locked" || root.busy)
            return false
        root.lastError = ""
        root.busyLabel = "Opening the keyring…"
        const gen = root._generation
        _enqueue(["secret-tool", "search", "--unlock",
                  "application", "omasafe", "item", "backup"], {}, (code, out) => {
            // Re-lock first, whatever the search did: a prompted unlock
            // must not leave the keyring open for the rest of the session.
            _keyringLock(root.keyringPath, null)
            if (root._stale(gen))
                return
            root.busyLabel = ""
            const key = SafeModel.parseKeyringSecret(out)
            if (!SafeModel.isHex64(key)) {
                // Covers a canceled dialog, a wrong keyring password, and a
                // missing or stale item alike — none needs its own words.
                root.lastError = "The keyring did not give up the back-up key"
                return
            }
            root.busyLabel = "Unlocking…"
            _unlockWithKey(key, gen)
        }, 330000)
        return true
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
