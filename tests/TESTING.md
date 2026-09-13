# Testing policy

## Classification

OmaSafe is an Omarchy plugin, a long-lived QML service, a frontend, and a
security-critical local file/cryptographic boundary. Node is development-only.

## Thresholds

- Pure helper coverage: 95% lines/functions/statements and 90% branches.
- Path, key, name, deletion, plaintext-cleanup, and credential-transition
  predicates require complete branch and mutation evidence before release.
- Any data-loss, overwrite, secret-disclosure, plaintext-residue, archive,
  same-UID race, or transaction-atomicity failure blocks merge.

## Waived layers

None. Cross-application drag/drop may be signed manual UAT only when the trusted
Buzz compositor cannot automate it; this is not a waiver for crypto or file
lifecycle behavior.

## Installed gates

- L0: `@intentsolutions/audit-harness@1.4.0` classification and depth audit;
  hash verification remains unbound until the maintainer initializes the manifest
- L3: Node test runner and c8 for `SafeModel.js`
- L3 source contracts: manifest, runtime, secrets, deletion, transaction bounds
- L6: Buzz validation/render remains to be vendored and bound to a candidate SHA

## Current audit

See `TEST_AUDIT.md`. The initial security contracts are intentionally red on
0.3.0 and therefore run explicitly with `npm run test:contracts` rather than in
required CI. Do not weaken them to make CI green; repair the runtime boundaries,
then promote the contract command into the required workflow.
