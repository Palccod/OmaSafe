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
