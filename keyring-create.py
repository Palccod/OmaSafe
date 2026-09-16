#!/usr/bin/env python3
"""OmaSafe — one-time creation of the dedicated "OmaSafe" keyring.

Creating a Secret Service collection needs CreateCollection plus the
caller-bound Prompt performed on one D-Bus connection; no single-shot CLI
(busctl, secret-tool) can do both, so the plugin shells out to this helper
exactly once per opt-in. The native GNOME keyring dialog asks the user to
choose the new keyring's password — no secret ever passes through this
process, and the keyring itself is never auto-unlocked at login.

Output protocol (stdout, line-oriented):
  created / <object path>   the keyring exists and is ready
  canceled                  the user dismissed the password dialog
  timeout                   the dialog was not answered in time
  error                     the Secret Service is missing or refused

Exit status is zero only on "created".
"""
import sys

import gi
from gi.repository import Gio, GLib

LABEL = "OmaSafe"
DIALOG_TIMEOUT_SECONDS = 300


def main():
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        props = {"org.freedesktop.Secret.Collection.Label": GLib.Variant("s", LABEL)}
        result = bus.call_sync(
            "org.freedesktop.secrets", "/org/freedesktop/secrets",
            "org.freedesktop.Secret.Service", "CreateCollection",
            GLib.Variant("(a{sv}s)", (props, "")),
            GLib.VariantType("(oo)"), Gio.DBusCallFlags.NONE, -1, None)
        _, prompt_path = (str(v) for v in result.unpack())
        if prompt_path == "/":
            print("created")
            print("/")
            return 0
        loop = GLib.MainLoop()
        state = {"outcome": "timeout", "path": None}

        def on_completed(conn, sender, path, iface, signal, params):
            if path != prompt_path:
                return
            dismissed, variant = params
            if dismissed:
                state["outcome"] = "canceled"
            else:
                state["outcome"] = "created"
                if variant:
                    state["path"] = str(variant.unpack())
            loop.quit()

        def expire():
            loop.quit()

        bus.signal_subscribe(
            "org.freedesktop.secrets", "org.freedesktop.Secret.Prompt",
            "Completed", None, None, Gio.DBusSignalFlags.NONE, on_completed)
        GLib.timeout_add_seconds(DIALOG_TIMEOUT_SECONDS, expire)
        bus.call_sync(
            "org.freedesktop.secrets", prompt_path,
            "org.freedesktop.Secret.Prompt", "Prompt",
            GLib.Variant("(s)", ("",)), None, Gio.DBusCallFlags.NONE, -1, None)
        loop.run()
        print(state["outcome"])
        if state["outcome"] == "created":
            print(state["path"] or "/")
            return 0
        return 1
    except Exception:
        print("error")
        return 1


if __name__ == "__main__":
    sys.exit(main())
