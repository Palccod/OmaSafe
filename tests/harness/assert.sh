#!/bin/bash
# On-disk assertions after the file-explorer harness has run: what the QML
# steps could not see from inside the process. Run inside the harness
# directory (see run.sh).
cd /tmp/omasafe-xtest
V=data/.omasafe/vault
fails=0
check() {  # check <label> <condition-exit>
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi
}

# 1. index.enc authenticates, decrypts under the password-wrapped key and
#    is version 2. The vault fixture is built in the pre-0.6.0
#    unauthenticated format; after the run every file must have been
#    migrated to the tagged format, so everything here goes through the
#    helper.
OS_SECRET=testpassword1 python3 ./omasafe-crypt.py decrypt "$V/wrap.enc" /tmp/xtest-wrapkey
check "wrap.enc authenticates and decrypts" $?
K=$(cat /tmp/xtest-wrapkey)
OS_SECRET=$K python3 ./omasafe-crypt.py decrypt "$V/index.enc" /tmp/xtest-index.json
check "index decrypts under password-wrapped key" $?
grep -q '"version":2' /tmp/xtest-index.json
check "index on disk is version 2" $?

# 1b. every file left in the vault carries the authentication tag
nonv3=0
for f in "$V"/*; do
  [ "$(python3 ./omasafe-crypt.py check "$f")" = "v3" ] || { echo "  not v3: $f"; nonv3=1; }
done
check "every vault file was migrated to the authenticated format" "$nonv3"

# 1c. tampering is refused: flip a byte in a copy of the index — the helper
#     must fail with its auth exit code and write no plaintext
cp "$V/index.enc" /tmp/xtest-tampered
python3 - <<'EOF'
with open('/tmp/xtest-tampered', 'r+b') as f:
    f.seek(20)
    b = f.read(1)
    f.seek(20)
    f.write(bytes([b[0] ^ 0x01]))
EOF
rm -f /tmp/xtest-tampered-out
OS_SECRET=$K python3 ./omasafe-crypt.py decrypt /tmp/xtest-tampered /tmp/xtest-tampered-out 2>/dev/null
[ $? -eq 3 ]; check "tampered index refused with auth failure" $?
[ ! -e /tmp/xtest-tampered-out ]; check "tampered index produced no plaintext" $?

# 2. expected paths present; the /legacy tree was deleted in the final step
for p in '/root.txt' '/tree/a.txt' '/tree/sub/b.txt' '/tree/sub/extra.txt' '/tree/empty'; do
  grep -q "\"path\":\"$p\"" /tmp/xtest-index.json
  check "index has $p" $?
done
for p in '/legacy' '/legacy/one.txt' '/legacy/deeper/two.txt'; do
  grep -q "\"path\":\"$p\"" /tmp/xtest-index.json
  [ $? -ne 0 ]; check "index no longer has $p" $?
done
grep -q '"path":"/partial/y.txt"' /tmp/xtest-index.json
check "index has /partial/y.txt" $?
grep -q '"path":"/partial/x.txt"' /tmp/xtest-index.json
[ $? -ne 0 ]; check "unreadable file was skipped" $?
[ -f home/dropbox/partial/y.txt ] && [ -f home/dropbox/partial/x.txt ]
check "partial-failure original tree kept on disk" $?
# 3. the tar blob was deleted after the migration
TARID=$(cat tarid.txt)
[ ! -f "$V/$TARID" ]; check "legacy tar blob deleted" $?

# 4. every indexed file has a blob on disk
python3 - <<'EOF'
import json, os, sys
idx = json.load(open('/tmp/xtest-index.json'))
missing = [it['path'] for it in idx['items'] if not it['isDir'] and not os.path.isfile('data/.omasafe/vault/' + it['id'])]
if missing:
    print("FAIL: blobs missing for", missing); sys.exit(1)
print("PASS: every indexed file has a blob")
EOF
check "blob files exist for all indexed files" $?

# 5. the extracted subtree matches the originals byte for byte
E=home/Downloads/OmaSafe/tree
[ -f "$E/a.txt" ] && [ -f "$E/sub/b.txt" ] && [ -f "$E/sub/extra.txt" ] && [ -d "$E/empty" ]
check "exported folder has a.txt, sub/b.txt, sub/extra.txt, empty/" $?
printf 'alpha payload\n' | cmp -s - "$E/a.txt"; check "exported a.txt byte-identical" $?
printf 'bravo payload\n' | cmp -s - "$E/sub/b.txt"; check "exported b.txt byte-identical" $?
printf 'extra payload\n' | cmp -s - "$E/sub/extra.txt"; check "exported extra.txt byte-identical" $?

# 6. the stage dir was wiped when the safe locked
STAGE=$(ls /run/user/$(id -u)/omasafe/stage 2>/dev/null | wc -l)
[ "$STAGE" -eq 0 ]; check "stage dir empty after lock" $?

# 7. wrap.enc + recovery.enc both present (recovery issued during upgrade)
[ -f "$V/wrap.enc" ] && [ -f "$V/recovery.enc" ]; check "wrap.enc and recovery.enc present" $?

# 8. the blobs of the deleted folder are really gone from disk
python3 - <<'EOF'
import json, os, sys
ids = json.load(open('/tmp/omasafe-xtest/predelete.json'))
left = [i for i in ids if os.path.isfile('data/.omasafe/vault/' + i)]
if left:
    print("FAIL: deleted blobs still on disk:", left); sys.exit(1)
print("PASS: deleted folder's blobs removed from disk")
EOF
check "deleted folder's blobs removed" $?

# 9. no orphan blobs: every blob in the vault belongs to an index entry
python3 - <<'EOF'
import json, os, sys
idx = json.load(open('/tmp/xtest-index.json'))
known = {it['id'] for it in idx['items'] if not it['isDir']}
vdir = 'data/.omasafe/vault'
orphans = []
for f in os.listdir(vdir):
    if f.endswith('.enc') or f.startswith('.tmp-'):
        continue
    if f not in known:
        orphans.append(f)
if orphans:
    print("FAIL: orphan blobs:", orphans); sys.exit(1)
print("PASS: no orphan blobs in the vault")
EOF
check "no orphan blobs" $?

# 10. the index refuses to open under an empty key: the tag check fails
#     before openssl ever runs
OS_SECRET="" python3 ./omasafe-crypt.py decrypt "$V/index.enc" /tmp/xtest-empty-out 2>/dev/null
[ $? -eq 3 ]; check "index not readable under an empty key" $?
[ ! -e /tmp/xtest-empty-out ]; check "empty-key attempt produced no plaintext" $?

echo "----"
echo "$fails failures"
exit $fails
