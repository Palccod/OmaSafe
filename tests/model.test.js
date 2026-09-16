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

test("vault path helpers split, join, and bound ancestry", () => {
  assert.equal(model.parentOf("/photos/cat.jpg"), "/photos");
  assert.equal(model.parentOf("/photos"), "/");
  assert.equal(model.parentOf("/"), "/");
  assert.equal(model.parentOf(""), "/");
  assert.equal(model.baseNameOf("/photos/cat.jpg"), "cat.jpg");
  assert.equal(model.baseNameOf("/photos"), "photos");
  assert.equal(model.baseNameOf("/"), "");
  assert.equal(model.childPath("/", "photos"), "/photos");
  assert.equal(model.childPath("/photos", "cat.jpg"), "/photos/cat.jpg");
  assert.equal(model.isUnder("/photos/cat.jpg", "/photos"), true);
  assert.equal(model.isUnder("/photos", "/photos"), false);
  assert.equal(model.isUnder("/photographs/x", "/photos"), false);
  assert.equal(model.isUnder("/anything", "/"), true);
  assert.equal(model.isUnder("/", "/"), false);
});

test("breadcrumb chains walk from the root down", () => {
  // Objects built inside the vm context have a foreign prototype, so compare
  // flattened strings instead of deepEqual on the objects themselves.
  const chain = (p) => Array.from(model.pathSegments(p), (s) => s.path + "|" + s.name);
  assert.deepEqual(chain("/"), ["/|"]);
  assert.deepEqual(chain("/photos/vacation"), ["/|", "/photos|photos", "/photos/vacation|vacation"]);
});

const sampleItems = [
  { path: "/zebra.txt", isDir: false, size: 10, name: "zebra.txt" },
  { path: "/photos", isDir: true, name: "photos" },
  { path: "/photos/cat.jpg", isDir: false, size: 100, name: "cat.jpg" },
  { path: "/photos/vacation", isDir: true, name: "vacation" },
  { path: "/photos/vacation/sea.jpg", isDir: false, size: 200, name: "sea.jpg" },
  { path: "/docs", isDir: true, name: "docs" },
];

test("vault path validation refuses traversal and control characters", () => {
  assert.equal(model.validVaultPath("/photos/cat.jpg"), true);
  assert.equal(model.validVaultPath("/"), true);
  assert.equal(model.validVaultPath("/photos/../secret"), false);
  assert.equal(model.validVaultPath("/photos/./secret"), false);
  assert.equal(model.validVaultPath("/photos//x"), false);
  assert.equal(model.validVaultPath("relative/path"), false);
  assert.equal(model.validVaultPath("/tab\tchar"), false);
  assert.equal(model.validVaultPath("/" + "x".repeat(241)), false);
  assert.equal(model.validVaultPath(null), false);
});

test("breadcrumbs skip doubled separators and empty input stays at root", () => {
  const chain = (p) => Array.from(model.pathSegments(p), (s) => s.path + "|" + s.name);
  assert.deepEqual(chain("/photos//vacation"), ["/|", "/photos|photos", "/photos/vacation|vacation"]);
  assert.deepEqual(chain(""), ["/|"]);
});

test("subtree stats tolerate a missing list and ties sort stably", () => {
  assert.equal(model.subtreeStats(null, "/").files, 0);
  const ties = [{ path: "/a.txt", isDir: false, name: "a.txt", size: 1 },
                { path: "/A.txt", isDir: false, name: "A.txt", size: 2 }];
  assert.equal(Array.from(model.childrenOf(ties, "/")).length, 2);
});

test("path helpers fall back safely on null arguments", () => {
  assert.equal(model.isUnder(null, "/"), false);
  assert.equal(model.isUnder("/x", null), true);
  assert.equal(model.isUnder("/", null), false);
  assert.equal(model.childPath("/", null), "/");
  assert.equal(model.childPath(null, "a"), "/a");
  const unnamed = [{ path: "/b.txt", isDir: false }, { path: "/a.txt", isDir: false }];
  const sorted = Array.from(model.childrenOf(unnamed, "/"), (it) => it.path);
  assert.deepEqual(sorted, ["/a.txt", "/b.txt"]);
});

test("folder listings show only direct children, folders first", () => {
  assert.deepEqual(
    Array.from(model.childrenOf(sampleItems, "/"), (it) => it.path),
    ["/docs", "/photos", "/zebra.txt"],
  );
  assert.deepEqual(
    Array.from(model.childrenOf(sampleItems, "/photos"), (it) => it.path),
    ["/photos/vacation", "/photos/cat.jpg"],
  );
  assert.deepEqual(Array.from(model.childrenOf(sampleItems, "/docs")), []);
  assert.deepEqual(Array.from(model.childrenOf(null, "/")), []);
});

test("subtree stats count files and bytes at any depth", () => {
  const stats = (folder) => {
    const s = model.subtreeStats(sampleItems, folder);
    return s.files + " files / " + s.bytes + " bytes";
  };
  assert.equal(stats("/photos"), "2 files / 300 bytes");
  assert.equal(stats("/photos/vacation"), "1 files / 200 bytes");
  assert.equal(stats("/"), "3 files / 310 bytes");
  assert.equal(stats("/docs"), "0 files / 0 bytes");
});

test("keyring collection paths accept only Secret Service paths", () => {
  assert.equal(model.validKeyringPath("/org/freedesktop/secrets/collection/omasafe"), true);
  assert.equal(model.validKeyringPath("/org/freedesktop/secrets/collection/Default_5fKeyring"), true);
  assert.equal(model.validKeyringPath(""), false);
  assert.equal(model.validKeyringPath(null), false);
  assert.equal(model.validKeyringPath("/org/freedesktop/secrets/collection/"), false);
  assert.equal(model.validKeyringPath("/org/freedesktop/secrets/collection/omasafe/1"), false);
  assert.equal(model.validKeyringPath("/org/freedesktop/secrets/collection/omsafe; rm -rf /"), false);
  assert.equal(model.validKeyringPath("file:///etc/passwd"), false);
});

test("parseKeyringSecret accepts only the last full 64-hex secret line", () => {
  const KEY = "0123456789abcdef".repeat(4);
  const out = [
    "[/6]",
    "label = OmaSafe back-up key",
    "secret = " + KEY,
    "schema = org.freedesktop.Secret.Generic",
  ].join("\n");
  assert.equal(model.parseKeyringSecret(out), KEY);
  assert.equal(model.parseKeyringSecret("secret = nothexpassword\n"), "");
  assert.equal(model.parseKeyringSecret("secret = " + KEY + "\nsecret = short\n"), "");
  assert.equal(model.parseKeyringSecret("label = fake\ncreated = 2020\n"), "");
  assert.equal(model.parseKeyringSecret(""), "");
  assert.equal(model.parseKeyringSecret(null), "");
});
