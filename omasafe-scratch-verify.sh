#!/bin/sh
# Verifies — and creates — OmaSafe's private scratch directories.
#
# For every path argument: a symlink is never followed (a planted one is
# removed), a non-directory is replaced, a missing directory is created, and
# an existing one must be owned by the invoking user with mode exactly 0700
# (chmod'ed back into shape when the user owns it). Prints "ok" and exits 0
# only when every path ends up a private, owner-matched directory; anything
# else exits 1 without touching anything further, and callers must refuse
# to write. This is the gate run immediately before every sensitive write
# or removal in the scratch tree — including the per-UID /tmp fallback used
# when XDG_RUNTIME_DIR is not set, where another local user can pre-create
# the path.

umask 077
u="$(id -u)"
ok=1
for d in "$@"; do
    if [ -L "$d" ]; then
        rm -f -- "$d" || ok=0
    elif [ -e "$d" ] && [ ! -d "$d" ]; then
        rm -f -- "$d" || ok=0
    fi
    if [ "$ok" != 1 ]; then
        break
    fi
    if [ ! -e "$d" ]; then
        mkdir -p -- "$d" || ok=0
    fi
    if [ "$ok" = 1 ] && [ -d "$d" ]; then
        chmod 700 -- "$d" 2>/dev/null || ok=0
        [ "$(stat -c %u -- "$d" 2>/dev/null)" = "$u" ] || ok=0
        [ "$(stat -c %a -- "$d" 2>/dev/null)" = "700" ] || ok=0
    else
        ok=0
    fi
    if [ "$ok" != 1 ]; then
        break
    fi
done
if [ "$ok" = 1 ]; then
    echo ok
    exit 0
fi
exit 1
