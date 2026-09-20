import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
import test from "node:test"

const source = readFileSync(new URL("../SafeModel.js", import.meta.url), "utf8")
const model = {}
vm.createContext(model)
vm.runInContext(source, model)

test("safeName neutralizes display controls and path separators", () => {
    assert.equal(model.safeName("report/../../secret.txt"), "report_.._.._secret.txt")
    assert.equal(model.safeName("invoice\u202Etxt.exe"), "invoice_txt.exe")
    assert.equal(model.safeName("hello\nworld"), "hello_world")
    assert.equal(model.safeName("<b>name</b>"), "_b_name__b_")
})

test("safeName provides a bounded non-special fallback", () => {
    assert.equal(model.safeName(""), "untitled")
    assert.equal(model.safeName(".."), "untitled")
    assert.equal(model.safeName("x".repeat(300)).length, 240)
})

test("vault paths reject traversal, escapes, and display controls", () => {
    assert.equal(model.validVaultPath("/photos/cat.jpg"), true)
    assert.equal(model.validVaultPath("/photos"), true)
    assert.equal(model.validVaultPath("/"), true)
    assert.equal(model.validVaultPath("/photos/../secret"), false)
    assert.equal(model.validVaultPath("/photos/./x"), false)
    assert.equal(model.validVaultPath("photos/cat.jpg"), false)
    assert.equal(model.validVaultPath("/photos//cat.jpg"), false)
    assert.equal(model.validVaultPath("/photos/cat.jpg/"), false)
    assert.equal(model.validVaultPath("/pho\tto"), false)
    assert.equal(model.validVaultPath("/invoice\u202Eevil"), false)
    assert.equal(model.validVaultPath("/" + "x".repeat(241)), false)
    assert.equal(model.validVaultPath(null), false)
})

test("runtime source declares bounded inputs and stronger new passwords", () => {
    const service = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
    const widget = readFileSync(new URL("../BarWidget.qml", import.meta.url), "utf8")
    assert.match(service, /maxIndexBytes/)
    assert.match(service, /maxIpcPayloadBytes/)
    assert.match(service, /maxVaultItems/)
    assert.match(service, /name !== rawName/)
    assert.match(service, /password\.length < 12/)
    assert.match(service, /newPassword\.length < 12/)
    assert.match(widget, /Password \(12\+ characters\)/)
})

test("the /tmp scratch fallback is a race-safe randomized mktemp base", () => {
    const service = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
    // The fallback base comes from mktemp -d — a fresh, unguessable name
    // created atomically, not a predictable path an attacker can pre-create
    // or race a symlink into (marketplace review, round 2).
    assert.match(service, /mktemp -d \/tmp\/omasafe-/)
    // The mktemp result is validated against its exact expected shape
    // before it becomes the base.
    assert.match(service, /\/\^\\\/tmp\\\/omasafe-\[A-Za-z0-9\]\+\$\/\.test\(base\)/)
    // The old predictable forms must be gone.
    assert.doesNotMatch(service, /"\/tmp\/omasafe-" \+/)
    assert.doesNotMatch(service, /root\._uid/)
    // No base, no gate: with the fallback unset everything refuses.
    assert.match(service, /scratchBase === ""/)
})

test("keyring copies travel through the environment, never argv", () => {
    const service = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
    // The store script pipes the key from an env var into secret-tool stdin.
    assert.match(service, /printf \\'%s\\' "\$OS_RK" \| secret-tool store/)
    // A rotation that landed mid-flow must not leave the old key current.
    assert.match(service, /root\.pendingBackupKey !== key/)
    // Keyring answers are re-validated before they reach the unlock path.
    assert.match(service, /SafeModel\.parseKeyringSecret/)
    assert.match(service, /SafeModel\.validKeyringPath/)
    // The recovery search uses fixed attributes; no secret in argv.
    assert.match(service, /"secret-tool", "search", "--unlock",[\s\S]*?"application", "omasafe", "item", "backup"/)
})

test("the dedicated keyring is re-locked after every use", () => {
    const service = readFileSync(new URL("../Service.qml", import.meta.url), "utf8")
    // The save flow locks the keyring again whether or not the store worked.
    assert.match(service, /_keyringStoreIn\(path, key, ok => _keyringLock\(path, \(\) => finish\(ok\)\)\)/)
    assert.match(service, /_keyringStoreIn\(p2, key, ok => _keyringLock\(p2, \(\) => finish\(ok\)\)\)/)
    // Recovery locks first thing after the search, prompt or no prompt.
    assert.match(service, /_keyringLock\(root\.keyringPath, null\)/)
    assert.match(service, /"Lock", "ao", "1"/)
})
