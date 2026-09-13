import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const service = readFileSync(new URL("../Service.qml", import.meta.url), "utf8");
const widget = readFileSync(new URL("../BarWidget.qml", import.meta.url), "utf8");
const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"));

test("manifest entry-point kinds agree", () => {
  assert.deepEqual(Object.keys(manifest.entryPoints).sort(), ["barWidget", "service"]);
  assert.deepEqual(manifest.kinds.slice().sort(), ["bar-widget", "service"]);
});

test("stock graphical session does not require an interpreter", () => {
  assert.doesNotMatch(service + widget, /\[\s*["'](?:node|python[0-9.]*|ruby|deno|bun)["']/);
});

test("crypto secrets are passed by environment name, not literal argv", () => {
  assert.match(service, /-pass", "env:" \+ passVar/);
  assert.doesNotMatch(service, /-pass",\s*(?:root\.)?(?:sessionKey|pendingBackupKey)/);
});

test("destructive source deletion is disabled until descriptor identity is proven", () => {
  assert.equal(
    /_enqueue\(\["rm",\s*"-rf",\s*"--",\s*originalPath\]/.test(service),
    false,
    "pathname-based rm -rf can delete a different object after a same-UID replacement",
  );
});

test("locking cancels or invalidates queued callbacks", () => {
  assert.equal(
    /property\s+int\s+_(?:generation|epoch)|function\s+_cancel/.test(service),
    true,
    "lock needs a transaction generation/cancellation guard",
  );
});

test("index and credential writes use an atomic replacement helper", () => {
  assert.equal(
    /function\s+_atomicWrite\s*\(/.test(service),
    true,
    "critical metadata needs an explicit atomic-write implementation",
  );
  assert.equal(
    /_cipherArgv\([^\n]+root\.indexPath/.test(service),
    false,
    "openssl must not write directly to live index.enc",
  );
});

test("decrypted index and IPC payloads have byte limits before parsing", () => {
  assert.equal(/max(?:Index|Input|Payload)Bytes/i.test(service), true);
});

test("stored names pass a bounded display sanitizer", () => {
  assert.equal(/sanitize/i.test(service), true);
  assert.equal(/maxName/i.test(service), true);
});

test("security UI never relies on Qt AutoText", () => {
  const textBlocks = [...widget.matchAll(/\bText\s*\{[\s\S]*?\n\s*\}/g)].map((match) => match[0]);
  assert.ok(textBlocks.length > 0);
  for (const block of textBlocks) {
    if (/\btext\s*:/.test(block)) {
      assert.equal(
        /textFormat\s*:\s*Text\.PlainText/.test(block),
        true,
        "every dynamic Text node must declare Text.PlainText",
      );
    }
  }
});
