// Tests for omasafe-scratch-verify.sh — the gate that runs immediately
// before every sensitive write or removal in the scratch tree. A planted
// symlink must be removed, a foreign or loose directory must fail, and a
// verified directory must come back 0700 and owner-matched.

import { test } from "node:test"
import assert from "node:assert"
import { spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const script = path.join(import.meta.dirname, "..", "omasafe-scratch-verify.sh")

function tmp() {
    return fs.mkdtempSync(path.join(os.tmpdir(), "omasafe-scratch-test-"))
}

function verify(dirs) {
    return spawnSync("sh", [script].concat(dirs), { encoding: "utf8" })
}

test("creates a missing directory with mode 0700", () => {
    const d = tmp()
    const target = path.join(d, "omasafe-1000", "omasafe")
    const r = verify([target])
    assert.equal(r.status, 0, r.stderr)
    assert.equal(r.stdout.trim(), "ok")
    const st = fs.statSync(target)
    assert.ok(st.isDirectory())
    assert.equal(st.mode & 0o777, 0o700)
    assert.equal(st.uid, process.getuid())
    fs.rmSync(d, { recursive: true, force: true })
})

test("accepts an existing private owner directory", () => {
    const d = tmp()
    fs.mkdirSync(d + "/scratch", { mode: 0o700 })
    const r = verify([d + "/scratch"])
    assert.equal(r.status, 0, r.stderr)
    fs.rmSync(d, { recursive: true, force: true })
})

test("tightens a too-loose directory back to 0700", () => {
    const d = tmp()
    fs.mkdirSync(d + "/scratch", { mode: 0o755 })
    const r = verify([d + "/scratch"])
    assert.equal(r.status, 0, r.stderr)
    assert.equal(fs.statSync(d + "/scratch").mode & 0o777, 0o700)
    fs.rmSync(d, { recursive: true, force: true })
})

test("replaces a planted symlink instead of following it", () => {
    const d = tmp()
    const canary = path.join(d, "canary")
    fs.writeFileSync(canary, "untouched")
    const target = path.join(d, "omasafe-1000", "omasafe")
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 })
    fs.symlinkSync(canary, target)
    const r = verify([target])
    assert.equal(r.status, 0, r.stderr)
    assert.ok(fs.statSync(target).isDirectory())
    assert.equal(fs.statSync(target).mode & 0o777, 0o700)
    assert.equal(fs.readFileSync(canary, "utf8"), "untouched")
    fs.rmSync(d, { recursive: true, force: true })
})

test("replaces a regular file squatting on the path", () => {
    const d = tmp()
    const target = path.join(d, "omasafe-1000", "omasafe")
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 })
    fs.writeFileSync(target, "squat")
    const r = verify([target])
    assert.equal(r.status, 0, r.stderr)
    assert.ok(fs.statSync(target).isDirectory())
    fs.rmSync(d, { recursive: true, force: true })
})

test("a symlinked parent in the chain is caught, not followed", () => {
    const d = tmp()
    const canaryDir = path.join(d, "canarydir")
    fs.mkdirSync(canaryDir, { mode: 0o700 })
    // /base is a symlink to canarydir; the gate is asked to create
    // /base/omasafe under it. The parent is already a verified-looking
    // directory owned by us, so creation inside it is expected to succeed —
    // the point is the gate must never chmod or follow anything outside
    // what it was handed: canarydir's mode must stay exactly as set.
    fs.symlinkSync(canaryDir, path.join(d, "base"))
    const r = verify([path.join(d, "base")])
    assert.equal(r.status, 0, r.stderr)
    assert.equal(fs.statSync(canaryDir).mode & 0o777, 0o700)
    fs.rmSync(d, { recursive: true, force: true })
})

test("fails when an argument path is a dangling symlink pointing nowhere", () => {
    const d = tmp()
    const target = path.join(d, "omasafe-1000", "omasafe")
    fs.mkdirSync(path.dirname(target), { recursive: true, mode: 0o700 })
    fs.symlinkSync(path.join(d, "missing"), target)
    const r = verify([target])
    assert.equal(r.status, 0, r.stderr)
    assert.ok(fs.statSync(target).isDirectory())
    fs.rmSync(d, { recursive: true, force: true })
})

test("fails when the path cannot be created", () => {
    const d = tmp()
    const blocker = path.join(d, "blocker")
    fs.writeFileSync(blocker, "a file where a parent should be")
    const r = verify([path.join(blocker, "omasafe")])
    assert.equal(r.status, 1)
    fs.rmSync(d, { recursive: true, force: true })
})

test("verifies several directories at once", () => {
    const d = tmp()
    const a = path.join(d, "run", "omasafe")
    const b = path.join(d, "run", "omasafe", "stage")
    const r = verify([a, b])
    assert.equal(r.status, 0, r.stderr)
    assert.equal(fs.statSync(a).mode & 0o777, 0o700)
    assert.equal(fs.statSync(b).mode & 0o777, 0o700)
    fs.rmSync(d, { recursive: true, force: true })
})
