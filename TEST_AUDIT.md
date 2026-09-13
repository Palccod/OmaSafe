# OmaSafe testing and submission audit

Audit date: 2026-09-12. Audited commit: `2fc424d544581b7715fbe86de4daca3c70d3ffa0`.
Scope: read-only source review, canonical contributing-Clanker `omarchy-submit`
lane, Buzz static validation, Buzz real-shell render, and a deliberate red
proof. This document does not claim the plugin is safe or release-ready.

## Verdict

**INCONCLUSIVE WITH FINDINGS. Do not submit or recommend destructive use.**

The canonical gate denominator was established: 46 gates, of which 20 applied
to this tree-only submission check. All 20 applicable gates ran after the Buzz
round trip. Five blocked. Twenty-six PR/dossier/Go predicates were not
applicable. The repository has no offline tests, vendored lane, CI, marketplace
contract, harness seal, or committed rig/render receipts. Mutable filesystem
state remains unproven independently of the gate result.

## Evidence

| Layer | Result |
|---|---|
| Canonical Clanker lane | 12 PASS, 5 BLOCK, 1 INFO, 28 initial SKIP |
| Applicable denominator after classification | 20/20 ran; 26 not applicable |
| Buzz `omarchy-plugin-validate` | exit 0 |
| Buzz `qmllint` | 0 errors |
| Buzz real-shell render | failed: plugin warning at `BarWidget.qml:120`; visible coverage 0.205501 below 0.35 |
| Offline tests | 0/0 discovered; no test command |
| Red proof | deliberately invalid QML produced `qmllint=1` and rig verification exit 1 |

The red proof ran only in `/tmp/omasafe-redproof-FqnY7T`; the repository source
was not changed. The ordinary rig run used `/tmp/omasafe-audit-lS5yjj` and did
not create a shipment receipt in this repository.

## Gate findings

- C28: em/en dashes in shipped copy and string literals.
- C31: six flagged `Text` nodes omit `Text.PlainText`.
- C36: flagged text nodes lack explicit wrap/elide constraints.
- C37: no committed fingerprint-bound rig receipt.
- C43: marketplace descriptions are 88/500 and 45/500 characters and differ;
  the banner, marketplace contract, render proof, and claim tests are absent.
- Real shell: `BarWidget.qml:120` assigns an undefined hover value to `bool`.

## Security-critical findings

1. **Possible wrong-object deletion.** `Service.qml:664-668` checks a pathname,
   later `687-688` or `706` opens it, and `734-735` reopens it for recursive
   deletion. A same-UID replacement can make the encrypted object differ from
   the deleted object. The lexical home-prefix check at `204-207` does not pin
   the object or its ancestors.
2. **Predictable, pathname-bound state.** Vault, scratch, stage, export, wrap,
   recovery, and index paths (`Service.qml:87-95`) are reopened across steps.
   Scratch writes (`192-195`) and direct index replacement (`617-627`) do not
   establish a no-follow, descriptor-bound, fsynced transaction.
3. **Lock does not cancel work.** The queue/worker at `114-156` can outlive the
   state reset at `337-345`; delayed stash callbacks at `723-745` can attempt a
   commit after the key/items are cleared.
4. **Critical metadata is non-atomic.** Index writes (`617-627`) and password /
   recovery rotation (`900-923`) overwrite live files across separate failure
   windows. Initialization can announce success despite an index write failure.
5. **Unbounded trusted-in-memory input.** Decrypted index output is parsed
   before a byte cap (`547-575`); repeated stash calls grow the store beyond the
   per-call cap; IPC JSON is parsed without an input bound (`950-963`).
6. **Names are not display-sanitized.** `SafeModel.js:58-63` only replaces `/`;
   controls, bidi overrides, Unicode tags, angle brackets, and long names can
   enter stored/displayed state.
7. **Credential claim needs correction.** Four-character passwords are allowed
   at `Service.qml:257-259` and `857-859` for a product presented as a safe.
8. **Ciphertext integrity is not authenticated.** AES-256-CBC protects
   confidentiality but does not authenticate blobs or metadata before release
   and tar extraction.

## Required test mechanism

### P0: portable merge gate

Vendor the current audit harness and contributing-Clanker lane using Foundry as
a structural reference, not as evidence. Add one offline command that runs
freshness, harness verification, conformance, source contracts, unit and
integration tests. CI and pre-push must call that same command. Pin actions and
use read-only default permissions.

### P0: deterministic unit and property tests

Run `SafeModel.js` under a dev-only Node test runner. Cover every helper and
malformed URLs, controls, Unicode, roots, dotfiles, duplicate paths, collision
names, large/invalid numbers, key normalization, and URI-list encoding. Use
fixed/reported fuzz seeds. Require 100% branch coverage and mutation kill for
path/key/name safety predicates; target at least 95% line/function and 90%
branch coverage for the helper module.

### P0: filesystem and crypto lifecycle

Drive the real service with isolated HOME and XDG directories and actual
`openssl`/`tar`. Prove byte-identical file and directory round trips, modes,
wrong secrets, recovery rotation/migration, corruption, missing binaries,
permissions, ENOSPC, timeout, signals, restart at every transaction boundary,
and no secret in argv/logs or plaintext after success, error, lock, timeout, or
shutdown.

Add deterministic synchronization hooks for same-UID replacement at every
check/open/write/move/delete boundary. Swap final and temporary entries, source,
destination, blob, state files, parents and ancestors with symlinks, hardlinks,
FIFO, socket, oversized object, directory, and disappearing entry. Any external
read/write/delete, hang, original deletion before durable indexed ciphertext,
or plaintext after lock blocks merge.

Validate every tar member before extraction: reject traversal, absolute paths,
links, device/FIFO entries, duplicate members, expansion bombs, and unexpected
archive roots. Add authenticated ciphertext or a verified encrypt-then-MAC
format before claiming tamper detection.

### P1: Buzz Rig end-to-end

Vendor fingerprint-bound `rig-verify` and `rig-render` scripts, plus an OmaSafe
lifecycle hook. The trusted rig must install the exact candidate commit, create
a safe, rotate/restore secrets, stash/extract/destroy fixtures, call real IPC,
lock/restart, remove/reinstall, and render setup, locked, unlocked, rotation,
error, and destructive-confirmation states with zero plugin warnings. Cross-app
drag/drop can remain explicit signed UAT only if compositor automation cannot
cover it.

The receipt must bind source SHA, clean-tree fingerprint, installed tree and rig
image digests, validator/linter exits, shell-log hash, lifecycle results,
screenshot hashes, and timestamp. Fork PRs must not receive rig credentials.

### P1: robustness and acceptance

Use Stryker for pure helpers and fault injection for every subprocess/callback
boundary. Run serial and concurrent lifecycle/race lanes, large-file/tree caps,
watchdog tests, and a soak for memory, children, descriptors, residue, and queue
liveness. Trace MUST requirements for no data loss, no overwrite, no plaintext
residue, recovery continuity, atomic credential rotation, safe destruction,
hostile-path refusal, shutdown lock, and exact-SHA Buzz load.

## Release gates

Block merge on any harness tamper, Clanker/static/test failure, uncovered MUST,
surviving critical mutation, nondeterminism, secret disclosure, plaintext
residue, unsafe archive behavior, overwrite/data loss, split-brain credentials,
hang, race escape, or missing exact-SHA evidence. AI review is advisory. A real
Buzz receipt is mandatory for release/main. Visual polish and documented
non-security manual UAT may be advisory; crypto integrity, filesystem identity,
atomicity, and cleanup may not.

## Recommended sequence

First add failing security lifecycle tests and a descriptor-bound filesystem
helper design. Then repair runtime behavior. Add marketplace copy/assets only
after the safety and real-shell lanes are green; presentation must not outrun
the product boundary it describes.
