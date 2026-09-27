pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// OmaSafe — the floating vault window.
//
// A regular toplevel (Quickshell FloatingWindow) instead of the anchored
// layer card: wider, draggable and resizable like any floating window, and
// it stays open while other popups come and go. Hyprland tiles toplevels by
// default, so a windowrule matched on the exact title installs at shell
// start and re-arms on every open — hyprctl keyword rules are session-
// scoped, so a compositor reload would otherwise lose them mid-session.
FloatingWindow {
    id: win

    property bool open: false
    property Item focusTarget: null
    // Accent flash while a dragged payload hovers the window (the old
    // surface-border behavior, kept for the drop-target feedback).
    property bool accentBorder: false

    signal closeRequested()

    // Kept for parity with the old CardPopup contract; the floating window
    // deliberately has no auto-close-on-pointer-leave behavior.
    readonly property bool hovered: winHover.hovered

    default property alias content: holder.children

    title: "OmaSafe"
    visible: open
    implicitWidth: Style.space(760)
    implicitHeight: Style.space(580)
    minimumSize: Qt.size(Style.space(480), Style.space(360))
    color: Color.popups.background

    function installFloatRule() {
        // New-parser Hyprland rejects `hyprctl keyword` rules entirely and
        // wants Lua window_rule objects (omacom's hyprctl eval); the guard
        // variable keeps the rule a singleton and re-enables it after a
        // compositor reload. The shell process inherits HYPRLAND_INSTANCE
        // _SIGNATURE from the session, so hyprctl reaches the right instance.
        Quickshell.execDetached(["hyprctl", "eval",
            'omasafe_rules = omasafe_rules or {}; '
            + 'if omasafe_rules.float == nil then '
            + 'omasafe_rules.float = hl.window_rule({ name = "omasafe-float", '
            + 'match = { initial_title = "^OmaSafe$" }, float = true }) '
            + 'else omasafe_rules.float:set_enabled(true) end'])
    }

    Component.onCompleted: {
        win.installFloatRule()
        // Legacy-parser fallback for compositors without hyprctl eval;
        // a harmless no-op where the Lua path is supported.
        Quickshell.execDetached(["hyprctl", "keyword", "windowrulev2",
                                 "float, title:^(OmaSafe)$"])
    }

    onOpenChanged: if (open) win.installFloatRule()

    onVisibleChanged: {
        if (visible && focusTarget)
            Qt.callLater(function () {
                if (win.open && win.focusTarget)
                    win.focusTarget.forceActiveFocus()
            })
        else if (!visible && open)
            // The WM closed the window (Super+Q, a script) — flow it back so
            // the bar button and the panel controller land on "closed".
            win.closeRequested()
    }

    HoverHandler { id: winHover }

    Item {
        id: holder
        anchors.fill: parent
        anchors.margins: Style.spacing.popupPadding
    }

    Rectangle {
        anchors.fill: parent
        z: 999
        color: "transparent"
        border.width: Math.max(1, Style.space(2))
        border.color: win.accentBorder ? Color.accent : "transparent"
    }
}
