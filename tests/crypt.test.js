// Tests for omasafe-crypt.py — the authenticated file-crypto helper behind
// every OmaSafe operation. Runs the real script with the real openssl, so
// the format the service writes on disk is what these exercise.

import { test } from "node:test"
import assert from "node:assert"
import { execFileSync, spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const helper = path.join(import.meta.dirname, "..", "omasafe-crypt.py")
const SECRET = "a".repeat(64)
const OTHER = "b".repeat(64)

function tmp() {
    return fs.mkdtempSync(path.join(os.tmpdir(), "omasafe-crypt-test-"))
}

function run(args, env, mode = "pipe") {
    return spawnSync("python3", [helper].concat(args), {
        env: Object.assign({}, process.env, env),
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024
    })
}

function encrypt(src, dst, secret) {
    return run(["encrypt", src, dst], { OS_SECRET: secret })
}

function decrypt(src, dst, secret) {
    return run(["decrypt", src, dst], { OS_SECRET: secret })
}

function check(path) {
    return run(["check", path], {})
}

function legacyEncrypt(src, dst, secret) {
    // Exactly what the pre-0.6.0 service ran: bare openssl, no tag.
    return spawnSync("openssl", ["enc", "-aes-256-cbc", "-pbkdf2", "-iter",
                                 "250000", "-salt", "-in", src, "-out", dst,
                                 "-pass", "env:OS_SECRET"], {
        env: Object.assign({}, process.env, { OS_SECRET: secret }),
        encoding: "utf8"
    })
}

test("encrypt/decrypt roundtrip through a file", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    const dec = path.join(d, "dec")
    fs.writeFileSync(src, "the quick brown fox")
    const e = encrypt(src, enc, SECRET)
    assert.equal(e.status, 0, e.stderr)
    assert.notEqual(fs.readFileSync(enc, "utf8"), "the quick brown fox")
    assert.equal(check(enc).stdout.trim(), "v3")
    const r = decrypt(enc, dec, SECRET)
    assert.equal(r.status, 0, r.stderr)
    assert.equal(fs.readFileSync(dec, "utf8"), "the quick brown fox")
    fs.rmSync(d, { recursive: true, force: true })
})

test("decrypt to stdout never writes a plaintext file", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    fs.writeFileSync(src, "0123456789abcdef")
    encrypt(src, enc, SECRET)
    const r = decrypt(enc, "-", SECRET)
    assert.equal(r.status, 0, r.stderr)
    assert.equal(r.stdout, "0123456789abcdef")
    assert.deepStrictEqual(fs.readdirSync(d).sort(), ["enc", "plain"])
    fs.rmSync(d, { recursive: true, force: true })
})

test("a flipped ciphertext byte is refused with the auth exit code", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    fs.writeFileSync(src, "attack at dawn")
    encrypt(src, enc, SECRET)
    const buf = fs.readFileSync(enc)
    // Flip a byte in the middle of the ciphertext, well inside the body.
    buf[buf.length >> 1] ^= 0x01
    fs.writeFileSync(enc, buf)
    const r = decrypt(enc, "-", SECRET)
    assert.equal(r.status, 3)
    assert.equal(r.stdout, "")
    fs.rmSync(d, { recursive: true, force: true })
})

test("a flipped tag byte is refused with the auth exit code", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    fs.writeFileSync(src, "attack at dawn")
    encrypt(src, enc, SECRET)
    const buf = fs.readFileSync(enc)
    buf[buf.length - 1] ^= 0x01
    fs.writeFileSync(enc, buf)
    const r = decrypt(enc, "-", SECRET)
    assert.equal(r.status, 3)
    fs.rmSync(d, { recursive: true, force: true })
})

test("a wrong secret is refused as an authentication failure", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    fs.writeFileSync(src, "attack at dawn")
    encrypt(src, enc, SECRET)
    const r = decrypt(enc, "-", OTHER)
    assert.equal(r.status, 3)
    fs.rmSync(d, { recursive: true, force: true })
})

test("truncated ciphertext is refused, never partially decrypted", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    fs.writeFileSync(src, "attack at dawn".repeat(20))
    encrypt(src, enc, SECRET)
    const buf = fs.readFileSync(enc)
    fs.writeFileSync(enc, buf.subarray(0, buf.length - 5))
    const r = decrypt(enc, "-", SECRET)
    assert.equal(r.status, 3)
    assert.equal(r.stdout, "")
    fs.rmSync(d, { recursive: true, force: true })
})

test("legacy openssl files decrypt with the legacy exit code", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    const dec = path.join(d, "dec")
    fs.writeFileSync(src, "from a 0.5.1 safe")
    const e = legacyEncrypt(src, enc, SECRET)
    assert.equal(e.status, 0, e.stderr)
    assert.equal(check(enc).stdout.trim(), "legacy")
    const r = decrypt(enc, dec, SECRET)
    assert.equal(r.status, 10)
    assert.equal(fs.readFileSync(dec, "utf8"), "from a 0.5.1 safe")
    fs.rmSync(d, { recursive: true, force: true })
})

test("legacy file re-encrypted under the helper becomes v3", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    const dec = path.join(d, "dec")
    fs.writeFileSync(src, "migrate me")
    legacyEncrypt(src, enc, SECRET)
    // What the service's _reencryptBlob does: decrypt the legacy blob (the
    // plaintext is in hand), then re-encrypt that plaintext to the same
    // id in the tagged format.
    const r0 = decrypt(enc, dec, SECRET)
    assert.equal(r0.status, 10)
    const e = encrypt(dec, enc + ".new", SECRET)
    assert.equal(e.status, 0, e.stderr)
    fs.renameSync(enc + ".new", enc)
    assert.equal(check(enc).stdout.trim(), "v3")
    const r = decrypt(enc, dec + "2", SECRET)
    assert.equal(r.status, 0)
    assert.equal(fs.readFileSync(dec + "2", "utf8"), "migrate me")
    fs.rmSync(d, { recursive: true, force: true })
})

test("decrypt refuses to write through a symlink at the temp path", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const enc = path.join(d, "enc")
    const dst = path.join(d, "out")
    const canary = path.join(d, "canary")
    fs.writeFileSync(src, "do not follow")
    encrypt(src, enc, SECRET)
    fs.writeFileSync(canary, "untouched")
    // Pre-create the helper's temp path as a symlink to the canary.
    fs.symlinkSync(canary, dst + ".omasafe-tmp")
    const r = decrypt(enc, dst, SECRET)
    assert.notEqual(r.status, 0)
    assert.equal(fs.readFileSync(canary, "utf8"), "untouched")
    assert.ok(!fs.existsSync(dst), "destination must not be created")
    fs.rmSync(d, { recursive: true, force: true })
})

test("encrypt refuses to write through a symlink at the temp path", () => {
    const d = tmp()
    const src = path.join(d, "plain")
    const dst = path.join(d, "out")
    const canary = path.join(d, "canary")
    fs.writeFileSync(src, "do not follow")
    fs.writeFileSync(canary, "untouched")
    fs.symlinkSync(canary, dst + ".omasafe-tmp")
    const r = encrypt(src, dst, SECRET)
    assert.notEqual(r.status, 0)
    assert.equal(fs.readFileSync(canary, "utf8"), "untouched")
    fs.rmSync(d, { recursive: true, force: true })
})

test("multi-megabyte files roundtrip (chunked streaming)", () => {
    const d = tmp()
    const src = path.join(d, "big")
    const enc = path.join(d, "enc")
    const dec = path.join(d, "dec")
    const block = cryptoBlock()
    fs.writeFileSync(src, Buffer.concat(Array(400).fill(block))) // ~5.5 MB
    const e = encrypt(src, enc, SECRET)
    assert.equal(e.status, 0, e.stderr)
    const r = decrypt(enc, dec, SECRET)
    assert.equal(r.status, 0, r.stderr)
    assert.ok(fs.readFileSync(dec).equals(fs.readFileSync(src)))
    fs.rmSync(d, { recursive: true, force: true })
})

test("check on a missing file exits nonzero", () => {
    const r = check("/nonexistent/nowhere")
    assert.notEqual(r.status, 0)
})

function cryptoBlock() {
    // Deterministic ~14 KB block, bigger than one 64 KB read is not needed —
    // several chunks are exercised by repetition above.
    const block = Buffer.alloc(14 * 1024)
    for (let i = 0; i < block.length; i++)
        block[i] = (i * 7 + 13) & 0xff
    return block
}
