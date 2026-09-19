#!/usr/bin/env python3
"""Authenticated file encryption for OmaSafe.

Every blob, wrap and index file is AES-256-CBC (PBKDF2, 250k iterations,
via the openssl CLI) wrapped in encrypt-then-MAC: an HMAC-SHA256 tag over
the header and ciphertext. The tag is verified in full before any
decryption runs, so tampered ciphertext is refused before plaintext can
exist.

Format v3:  b"OMASAFE3\\n" || ciphertext || tag(32)
            tag = HMAC-SHA256(macKey, header || ciphertext)
            macKey = HMAC-SHA256(secret, "omasafe mac key v3")

The wrapping secret travels through the environment (OS_SECRET), never
argv. Files from before 0.6.0 have no header; they still decrypt (there is
no tag to verify on them) and the caller learns so through exit code 10 to
migrate them. Writes land through a same-directory temp file created
O_NOFOLLOW and renamed into place, so neither the temp nor the destination
ever writes through a symlink.

usage:
  omasafe-crypt.py encrypt <src> <dst>
  omasafe-crypt.py decrypt <src> <dst|"-" for stdout>
  omasafe-crypt.py check <path>          prints "v3" or "legacy"

exit codes: 0 ok, 10 ok but legacy input, 3 authentication failure,
2 usage/config error, otherwise the openssl exit code.
"""

import hashlib
import hmac
import os
import subprocess
import sys
import threading

HEADER = b"OMASAFE3\n"
TAG_SIZE = 32
MAC_INFO = b"omasafe mac key v3"
CHUNK = 1 << 16
ENV_SECRET = "OS_SECRET"

EXIT_OK = 0
EXIT_LEGACY = 10
EXIT_AUTH = 3
EXIT_USAGE = 2


def _die(code, message):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def _secret():
    s = os.environ.get(ENV_SECRET)
    if s is None:
        _die(EXIT_USAGE, "missing " + ENV_SECRET)
    return s.encode("utf-8", "surrogateescape")


def _mac_key(secret):
    return hmac.new(secret, MAC_INFO, hashlib.sha256).digest()


def _openssl(argv, secret):
    env = dict(os.environ)
    env[ENV_SECRET] = secret.decode("utf-8", "surrogateescape")
    return subprocess.Popen(argv, env=env,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)


# Encrypt reads the plaintext straight from `src` — only stdout is a pipe.
def _enc_argv(src):
    return ["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-iter", "250000",
            "-salt", "-in", src, "-pass", "env:" + ENV_SECRET]


# v3 decrypt feeds the tag-stripped body through stdin — the file's head
# and tail are not ciphertext — so no -in argument at all.
def _dec_stdin_argv():
    return ["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter",
            "250000", "-pass", "env:" + ENV_SECRET]


# Legacy decrypt consumes the whole file, so it reads it directly.
def _dec_file_argv(src):
    return ["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter",
            "250000", "-in", src, "-pass", "env:" + ENV_SECRET]


def _tmp_path(dst):
    return dst + ".omasafe-tmp"


def _clear_tmp(tmp):
    try:
        if os.path.lexists(tmp):
            os.unlink(tmp)
    except OSError:
        pass


def _open_tmp(tmp):
    # Refuse a symlink planted at the temp path outright — nothing
    # legitimate ever puts one there, and refusing keeps the posture
    # explicit instead of quietly cleaning up after an attacker. A stale
    # regular file from a crashed run is fine: O_TRUNC reclaims it.
    if os.path.islink(tmp):
        _die(EXIT_USAGE, "refusing to write through a symlink at " + tmp)
    # O_NOFOLLOW backs the check up against a swap between it and the open;
    # the mode is 0600 so the file is private from the first instant.
    return os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC
                   | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)


def _append_tag(tmp, tag):
    # Same O_NOFOLLOW discipline when reopening to append the tag.
    fd = os.open(tmp, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW
                 | os.O_CLOEXEC)
    with os.fdopen(fd, "ab") as f:
        f.write(tag)


def _read_head(src):
    with open(src, "rb") as f:
        return f.read(len(HEADER))


def _feed_stdin(proc, path, offset, size):
    # Feeds `size` bytes from `path[offset:]` into openssl's stdin. Runs on
    # its own thread so a big body cannot deadlock against the stdout pipe
    # being read in the main thread.
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            remaining = size
            while remaining > 0:
                chunk = f.read(min(CHUNK, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                proc.stdin.write(chunk)
    except BrokenPipeError:
        pass
    except OSError:
        pass
    finally:
        try:
            proc.stdin.close()
        except BrokenPipeError:
            pass


def _drain(proc, out):
    while True:
        chunk = proc.stdout.read(CHUNK)
        if not chunk:
            break
        out.write(chunk)


def _encrypt(src, dst):
    mac = hmac.new(_mac_key(_secret()), digestmod=hashlib.sha256)
    mac.update(HEADER)
    tmp = _tmp_path(dst)
    proc = _openssl(_enc_argv(src), _secret())
    try:
        fd = _open_tmp(tmp)
        with os.fdopen(fd, "wb") as out:
            out.write(HEADER)
            while True:
                chunk = proc.stdout.read(CHUNK)
                if not chunk:
                    break
                mac.update(chunk)
                out.write(chunk)
        rc = proc.wait()
        if rc != 0:
            _clear_tmp(tmp)
            sys.exit(rc)
        _append_tag(tmp, mac.digest())
    except SystemExit:
        raise
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
        _clear_tmp(tmp)
        raise
    os.replace(tmp, dst)
    sys.exit(EXIT_OK)


def _verify_tag(src):
    """Streams the file once; True when the v3 tag checks out."""
    size = os.path.getsize(src)
    if size < len(HEADER) + TAG_SIZE:
        return False
    body_end = size - TAG_SIZE
    mac = hmac.new(_mac_key(_secret()), digestmod=hashlib.sha256)
    with open(src, "rb") as f:
        head = f.read(len(HEADER))
        if head != HEADER:
            return False
        mac.update(head)
        remaining = body_end - len(HEADER)
        while remaining > 0:
            chunk = f.read(min(CHUNK, remaining))
            if not chunk:
                return False
            mac.update(chunk)
            remaining -= len(chunk)
        stored = f.read(TAG_SIZE)
    return hmac.compare_digest(mac.digest(), stored)


def _decrypt(src, dst):
    if not _verify_tag(src):
        _die(EXIT_AUTH, "authentication failed")
    body_end = os.path.getsize(src) - TAG_SIZE
    body_size = body_end - len(HEADER)
    # stdin=PIPE: the tag-stripped body is fed to openssl while its
    # plaintext streams back through stdout.
    proc = subprocess.Popen(
        _dec_stdin_argv(),
        env=_env_with_secret(_secret()),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL)
    to_stdout = dst == "-"
    tmp = None
    out_fd = None
    try:
        if to_stdout:
            out = sys.stdout.buffer
        else:
            tmp = _tmp_path(dst)
            out_fd = _open_tmp(tmp)
            out = os.fdopen(out_fd, "wb")
            out_fd = None
        feeder = threading.Thread(target=_feed_stdin,
                                  args=(proc, src, len(HEADER), body_size))
        feeder.start()
        _drain(proc, out)
        feeder.join()
        rc = proc.wait()
        if rc != 0:
            if tmp:
                _clear_tmp(tmp)
            sys.exit(rc)
        out.flush()
        if not to_stdout:
            os.fsync(out.fileno())
    except SystemExit:
        raise
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
        if tmp:
            _clear_tmp(tmp)
        raise
    finally:
        if out_fd is not None:
            os.close(out_fd)
    if not to_stdout:
        os.replace(tmp, dst)
    sys.exit(EXIT_OK)


def _decrypt_legacy(src, dst):
    # No header: a pre-0.6.0 blob. There is no tag to check, so this
    # decrypts exactly as the old openssl-only path did and reports the
    # legacy format through its exit code so the caller can migrate it.
    proc = _openssl(_dec_file_argv(src), _secret())
    to_stdout = dst == "-"
    tmp = None
    out_fd = None
    try:
        if to_stdout:
            out = sys.stdout.buffer
        else:
            tmp = _tmp_path(dst)
            out_fd = _open_tmp(tmp)
            out = os.fdopen(out_fd, "wb")
            out_fd = None
        _drain(proc, out)
        rc = proc.wait()
        if rc != 0:
            if tmp:
                _clear_tmp(tmp)
            sys.exit(rc)
        out.flush()
        if not to_stdout:
            os.fsync(out.fileno())
    except SystemExit:
        raise
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
        if tmp:
            _clear_tmp(tmp)
        raise
    finally:
        if out_fd is not None:
            os.close(out_fd)
    if not to_stdout:
        os.replace(tmp, dst)
    sys.exit(EXIT_LEGACY)


def _env_with_secret(secret):
    env = dict(os.environ)
    env[ENV_SECRET] = secret.decode("utf-8", "surrogateescape")
    return env


def main():
    argv = sys.argv[1:]
    if len(argv) < 2:
        _die(EXIT_USAGE, "usage: omasafe-crypt.py encrypt|decrypt <src> <dst>"
                         " | check <path>")
    mode = argv[0]
    if mode == "check":
        if len(argv) != 2:
            _die(EXIT_USAGE, "usage: omasafe-crypt.py check <path>")
        try:
            head = _read_head(argv[1])
        except OSError:
            _die(EXIT_USAGE, "cannot read " + argv[1])
        print("v3" if head == HEADER else "legacy")
        sys.exit(EXIT_OK)
    if len(argv) != 3:
        _die(EXIT_USAGE, "usage: omasafe-crypt.py encrypt|decrypt <src> <dst>")
    src, dst = argv[1], argv[2]
    if mode == "encrypt":
        if dst == "-":
            _die(EXIT_USAGE, "encrypt needs a real destination")
        _encrypt(src, dst)
    if mode == "decrypt":
        try:
            head = _read_head(src)
        except OSError:
            _die(EXIT_USAGE, "cannot read " + src)
        if head == HEADER:
            _decrypt(src, dst)
        _decrypt_legacy(src, dst)
    _die(EXIT_USAGE, "unknown mode " + mode)


if __name__ == "__main__":
    main()
