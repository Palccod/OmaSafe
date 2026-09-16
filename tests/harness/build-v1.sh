#!/bin/bash
# Builds the fixture for the file-explorer harness: a drop folder tree and a
# hand-crafted pre-0.4.0 (v1) vault — one tar folder blob plus one root file,
# no recovery.enc — so the unlock-time migration is genuinely exercised.
# Run inside the harness directory (see run.sh).
set -e
V=data/.omasafe/vault
mkdir -p "$V" home/dropbox

# Drop material: a folder with a file, a nested subfolder, and an empty dir;
# plus the legacy-tree source and a loose file for the drop-into test.
mkdir -p home/dropbox/tree/sub home/dropbox/tree/empty home/dropbox/legacy/deeper
printf 'alpha payload\n' > home/dropbox/tree/a.txt
printf 'bravo payload\n' > home/dropbox/tree/sub/b.txt
printf 'extra payload\n' > home/dropbox/extra.txt
printf 'one\n' > home/dropbox/legacy/one.txt
printf 'two\n' > home/dropbox/legacy/deeper/two.txt

# The v1 vault: vault key wrapped under the password, the legacy folder as one
# tar blob, the root file as a second blob, and a version-1 index.
K=$(openssl rand -hex 32)
TARID=$(openssl rand -hex 16)
FID=$(openssl rand -hex 16)
printf '%s' "$K" | OS_PW=testpassword1 openssl enc -aes-256-cbc -pbkdf2 -iter 250000 -salt -out "$V/wrap.enc" -pass env:OS_PW
tar -C home/dropbox -cf legacy.tar legacy
OS_KEY=$K openssl enc -aes-256-cbc -pbkdf2 -iter 250000 -salt -in legacy.tar -out "$V/$TARID" -pass env:OS_KEY
OS_KEY=$K openssl enc -aes-256-cbc -pbkdf2 -iter 250000 -salt -in home/dropbox/extra.txt -out "$V/$FID" -pass env:OS_KEY
printf '{"version":1,"items":[{"id":"%s","name":"legacy","isDir":true,"size":0,"addedAt":1700000000000},{"id":"%s","name":"root.txt","isDir":false,"size":14,"addedAt":1700000000001}]}' "$TARID" "$FID" > idx.json
OS_KEY=$K openssl enc -aes-256-cbc -pbkdf2 -iter 250000 -salt -in idx.json -out "$V/index.enc" -pass env:OS_KEY
echo "$TARID" > tarid.txt
echo "v1 vault built (tar blob $TARID)"
