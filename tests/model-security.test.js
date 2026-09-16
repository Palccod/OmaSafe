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
