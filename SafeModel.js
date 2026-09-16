// Pure helpers for OmaSafe: drop parsing, name hygiene, vault paths, display
// formatting. No Qt/Quickshell imports — everything here must stay testable
// and side effect free, because every path that reaches the filesystem goes
// through the service's fixed-argv jobs.

// --- vault paths -------------------------------------------------------------
//
// The safe is browsed like a small file system: every entry carries a
// vault-absolute path ("/photos", "/photos/cat.jpg"); the root is "/".

// Parent folder of a vault path ("/a/b" → "/a", "/a" → "/").
function parentOf(path) {
    const p = String(path || "")
    if (p === "/" || p === "")
        return "/"
    const i = p.lastIndexOf("/")
    return i <= 0 ? "/" : p.substring(0, i)
}

// Final segment of a vault path ("/a/b" → "b", "/" → "").
function baseNameOf(path) {
    const p = String(path || "")
    if (p === "/" || p === "")
        return ""
    return p.substring(p.lastIndexOf("/") + 1)
}

// A child path inside `folder`. `name` must already be one sanitized segment.
function childPath(folder, name) {
    const f = String(folder || "/")
    return (f === "/" ? "" : f) + "/" + String(name || "")
}

// True when `path` is a strict descendant of `folder` — a child, a grandchild,
// any depth, but not the folder itself.
function isUnder(path, folder) {
    const p = String(path || "")
    const f = String(folder || "/")
    if (f === "/")
        return p !== "/" && p.indexOf("/") === 0
    return p.indexOf(f + "/") === 0
}

// Paths are rebuilt from an encrypted index that may have been tampered with,
// so they are re-validated before anything is built from them: absolute, one
// sane segment at a time, no traversal, no control or bidi characters.
function validVaultPath(path) {
    const p = String(path || "")
    if (p === "/")
        return true
    if (p.indexOf("/") !== 0)
        return false
    const segs = p.substring(1).split("/")
    for (let i = 0; i < segs.length; i++) {
        const s = segs[i]
        if (s === "" || s === "." || s === ".." || s.length > 240)
            return false
        if (/[<>\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/.test(s))
            return false
    }
    return true
}

// The direct children of `folder`, folders first then files, each alphabetical
// — the listing a file explorer shows for that folder.
function childrenOf(items, folder) {
    const f = String(folder || "/")
    const out = []
    if (!items)
        return out
    for (let i = 0; i < items.length; i++) {
        const it = items[i]
        if (it && parentOf(it.path) === f)
            out.push(it)
    }
    out.sort(function (a, b) {
        if (a.isDir !== b.isDir)
            return a.isDir ? -1 : 1
        const an = String(a.name || baseNameOf(a.path)).toLowerCase()
        const bn = String(b.name || baseNameOf(b.path)).toLowerCase()
        return an < bn ? -1 : an > bn ? 1 : 0
    })
    return out
}

// File count and total bytes under `folder` (folders carry no bytes).
function subtreeStats(items, folder) {
    const out = { files: 0, bytes: 0 }
    if (!items)
        return out
    for (let i = 0; i < items.length; i++) {
        const it = items[i]
        if (it && !it.isDir && isUnder(it.path, folder)) {
            out.files++
            out.bytes += clampInt(it.size, 0, 0, Number.MAX_SAFE_INTEGER)
        }
    }
    return out
}

// Breadcrumb chain for a vault path, root first: "/photos/cat.jpg" →
// [{path: "/", name: ""}, {path: "/photos", name: "photos"}, …].
function pathSegments(path) {
    const p = String(path || "/")
    const out = [{ path: "/", name: "" }]
    if (p === "/" || p === "")
        return out
    const segs = p.substring(1).split("/")
    let acc = ""
    for (let i = 0; i < segs.length; i++) {
        if (segs[i] === "")
            continue
        acc += "/" + segs[i]
        out.push({ path: acc, name: segs[i] })
    }
    return out
}

// --- disk paths ----------------------------------------------------------------

// Last path segment, tolerating a trailing slash on directory drops.
function basename(path) {
    const p = String(path || "").replace(/\/+$/, "")
    const i = p.lastIndexOf("/")
    return i === -1 ? p : p.substring(i + 1)
}

// Parent directory of an absolute path, without the trailing slash.
function dirname(path) {
    const p = String(path || "").replace(/\/+$/, "")
    const i = p.lastIndexOf("/")
    if (i <= 0)
        return "/"
    return p.substring(0, i)
}

// Turns drag or IPC entries (file:// urls, or plain paths one per line)
// into a de-duplicated list of absolute paths. Anything that is not a
// local file is ignored — the safe only takes real files.
function pathsFromEntries(entries) {
    const out = []
    if (!entries)
        return out
    for (const raw of entries) {
        let entry = String(raw || "").trim()
        if (entry === "")
            continue
        if (entry.indexOf("file://") === 0) {
            let path = entry.substring(7)
            const q = path.indexOf("?")
            if (q !== -1)
                path = path.substring(0, q)
            try {
                path = decodeURIComponent(path)
            } catch (e) {
                // A malformed percent-escape keeps the raw path; the stat
                // step below will report it missing and skip it.
            }
            entry = path
        }
        if (entry.indexOf("/") !== 0)
            continue
        if (entry === "/" || entry.indexOf("\0") !== -1)
            continue
        if (out.indexOf(entry) === -1)
            out.push(entry)
    }
    return out
}

// A stored item name is only ever a basename this plugin wrote itself,
// but export paths are built from it, so it is re-validated on the way out.
function safeName(name) {
    // Control characters and bidi overrides can make a stored name render as
    // another file or inject terminal/UI controls. Keep ordinary Unicode but
    // neutralize those controls and cap the value used by the UI and exports.
    let n = String(name || "")
        .replace(/[\/<>\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, "_")
        .substring(0, 240)
    if (n === "" || n === "." || n === "..")
        n = "untitled"
    return n
}

// "photo.jpg" + attempt 2 → "photo (2).jpg", for exports that would
// otherwise clobber a file already sitting in the export folder.
function withAttempt(name, attempt) {
    if (attempt <= 1)
        return name
    const dot = name.lastIndexOf(".")
    const base = dot > 0 ? name.substring(0, dot) : name
    const ext = dot > 0 ? name.substring(dot) : ""
    return base + " (" + attempt + ")" + ext
}

// A backup key may be pasted with spaces, dashes or uppercase; only the
// hex digits matter.
function normalizeKey(text) {
    return String(text || "").toLowerCase().replace(/[^0-9a-f]/g, "")
}

function isHex64(text) {
    return /^[0-9a-f]{64}$/.test(String(text || ""))
}

// 64 hex digits are unreadable as one blob; groups of 8 scan like a
// recovery code. normalizeKey() eats the spaces back off on entry.
function formatKey(key) {
    const hex = normalizeKey(key)
    const groups = []
    for (let i = 0; i < hex.length; i += 8)
        groups.push(hex.substring(i, i + 8))
    return groups.join(" ")
}

// file:// url for a drag payload or clipboard, percent-encoding each path
// segment so spaces and unicode names survive the trip.
function urlFromPath(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}

// text/uri-list payload (CRLF per RFC 2483) for a native drag.
function uriList(paths) {
    return paths.map(urlFromPath).join("\r\n") + "\r\n"
}

function clampInt(value, fallback, min, max) {
    const n = parseInt(value, 10)
    if (!isFinite(n))
        return fallback
    return Math.min(max, Math.max(min, n))
}

function humanSize(bytes) {
    const b = Number(bytes)
    if (!isFinite(b) || b < 0)
        return ""
    if (b < 1024)
        return b + " B"
    const units = ["KB", "MB", "GB", "TB"]
    let v = b
    let i = -1
    while (v >= 1024 && i < units.length - 1) {
        v /= 1024
        i++
    }
    return (v >= 100 ? Math.round(v) : Math.round(v * 10) / 10) + " " + units[i]
}

const imageExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "heic", "avif", "tiff", "ico"]
const videoExts = ["mp4", "mkv", "webm", "mov", "avi", "m4v", "flv"]
const audioExts = ["mp3", "flac", "ogg", "wav", "m4a", "opus", "aac"]
const docExts = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "odt"]

function extOf(name) {
    const dot = String(name).lastIndexOf(".")
    return dot === -1 ? "" : String(name).substring(dot + 1).toLowerCase()
}

function itemGlyph(name, isDir) {
    if (isDir)
        return "\u{F024B}" // nf-md-folder
    const ext = extOf(name)
    if (imageExts.indexOf(ext) !== -1)
        return "\u{F028E}" // nf-md-file-image
    if (videoExts.indexOf(ext) !== -1)
        return "\u{F021C}" // nf-md-film
    if (audioExts.indexOf(ext) !== -1)
        return "\u{F0A0C}" // nf-md-music-note
    if (docExts.indexOf(ext) !== -1)
        return "\u{F0264}" // nf-md-file
    return "\u{F0264}"     // nf-md-file
}

// True for file types the thumbnail box can render once the item is
// staged (decrypted) in the scratch dir.
function isImage(name) {
    return imageExts.indexOf(extOf(name)) !== -1
}
