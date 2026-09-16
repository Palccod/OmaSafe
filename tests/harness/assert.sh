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

# 1. index.enc decrypts under the password-wrapped key and is version 2
K=$(OS_PW=testpassword1 openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -in $V/wrap.enc -pass env:OS_PW | tr -d '\n')
OS_KEY=$K openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -in $V/index.enc -pass env:OS_KEY -out /tmp/xtest-index.json 2>/dev/null
check "index decrypts under password-wrapped key" $?
grep -q '"version":2' /tmp/xtest-index.json
check "index on disk is version 2" $?

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

# 10. the index refuses to decrypt under an empty key
OS_KEY="" openssl enc -d -aes-256-cbc -pbkdf2 -iter 250000 -in $V/index.enc -pass env:OS_KEY -out /dev/null 2>/dev/null
[ $? -ne 0 ]; check "index not readable under an empty key" $?

echo "----"
echo "$fails failures"
exit $fails
