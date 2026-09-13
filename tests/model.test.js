import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const sourceUrl = new URL("../SafeModel.js", import.meta.url);
const source = readFileSync(sourceUrl, "utf8");
const model = { decodeURIComponent, encodeURIComponent, isFinite, Math, Number, parseInt };
vm.createContext(model);
vm.runInContext(source, model, { filename: sourceUrl.pathname });

test("path helpers preserve absolute path structure", () => {
  assert.equal(model.basename("/home/user/report.pdf"), "report.pdf");
  assert.equal(model.basename("/home/user/folder/"), "folder");
  assert.equal(model.basename("report.pdf"), "report.pdf");
  assert.equal(model.dirname("/home/user/report.pdf"), "/home/user");
  assert.equal(model.dirname("/one"), "/");
  assert.equal(model.dirname(null), "/");
});

test("drop parser accepts local absolute paths only and deduplicates", () => {
  assert.deepEqual(Array.from(model.pathsFromEntries(null)), []);
  assert.deepEqual(
    Array.from(model.pathsFromEntries([
      "file:///home/user/a%20b.txt?ignored=yes",
      "/home/user/a b.txt",
      "https://example.com/file",
      "relative.txt",
      "/",
      "",
    ])),
    ["/home/user/a b.txt"],
  );
});

test("malformed URL escapes remain bounded input instead of throwing", () => {
  assert.deepEqual(Array.from(model.pathsFromEntries(["file:///tmp/%ZZ"])), ["/tmp/%ZZ"]);
});

test("name and collision helpers do not create a path", () => {
  assert.equal(model.safeName("../report.txt"), ".._report.txt");
  assert.equal(model.safeName(".."), "untitled");
  assert.equal(model.safeName(""), "untitled");
  assert.equal(model.withAttempt("archive.tar.gz", 2), "archive.tar (2).gz");
  assert.equal(model.withAttempt("README", 3), "README (3)");
  assert.equal(model.withAttempt("README", 1), "README");
});

test("backup keys normalize, validate, and format", () => {
  const key = "ab".repeat(32);
  assert.equal(model.normalizeKey(key.toUpperCase().replace(/(.{8})/g, "$1-")), key);
  assert.equal(model.isHex64(key), true);
  assert.equal(model.isHex64(key.slice(1)), false);
  assert.equal(model.normalizeKey(null), "");
  assert.equal(model.isHex64(null), false);
  assert.equal(model.formatKey(key).split(" ").length, 8);
});

test("URI list encoding preserves separators and encodes data", () => {
  assert.equal(model.urlFromPath("/tmp/a b.txt"), "file:///tmp/a%20b.txt");
  assert.equal(model.uriList(["/tmp/a b.txt"]), "file:///tmp/a%20b.txt\r\n");
});

test("numeric bounds and human-readable sizes are deterministic", () => {
  assert.equal(model.clampInt("12", 3, 0, 10), 10);
  assert.equal(model.clampInt("bad", 3, 0, 10), 3);
  assert.equal(model.humanSize(-1), "");
  assert.equal(model.humanSize("not-a-number"), "");
  assert.equal(model.humanSize(0), "0 B");
  assert.equal(model.humanSize(1024), "1 KB");
  assert.equal(model.humanSize(1536), "1.5 KB");
  assert.equal(model.humanSize(153600), "150 KB");
});

test("file-kind helpers are case-insensitive", () => {
  assert.equal(model.extOf("PHOTO.JPEG"), "jpeg");
  assert.equal(model.extOf("README"), "");
  assert.equal(model.isImage("PHOTO.JPEG"), true);
  assert.equal(model.isImage("notes.txt"), false);
  assert.equal(typeof model.itemGlyph("folder", true), "string");
  assert.equal(typeof model.itemGlyph("photo.png", false), "string");
  assert.equal(typeof model.itemGlyph("clip.mp4", false), "string");
  assert.equal(typeof model.itemGlyph("track.flac", false), "string");
  assert.equal(typeof model.itemGlyph("notes.txt", false), "string");
  assert.equal(typeof model.itemGlyph("data.bin", false), "string");
});
