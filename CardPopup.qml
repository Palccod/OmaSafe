pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// OmaSafe — the card that hangs off the bar icon.
//
// A layer-shell surface the size of the card itself, placed under the bar
// widget that owns it. Deliberately NOT built on qs.Ui.KeyboardPanel, which
// the first-party popups use: that one spreads a screen-wide dismissal layer
// over every monitor, and while the card is open that overlay sits above all
// windows and has no drop target — a file dragged from the card to another
// window is refused everywhere. Copied from the ledge: here the surface is
// only as big as the card, so drops land in whatever window is under the
// pointer and nothing outside the card is ever blocked.
PanelWindow {
    id: popup

    // The bar item the card is aligned to, and the bar it lives on.
    property Item anchorItem: null
    property QtObject bar: null

    property bool open: false
    property int cardWidth: Style.space(360)
    property int cardHeight: Style.space(420)
    // Distance from the bar, and the smallest gap kept to the screen edges.
    property int gap: Style.gapsOut
    property int screenMargin: Style.gapsOut
    property int padding: Style.spacing.popupPadding
    property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    // Item that holds keyboard focus inside the card, so the key handlers
    // fire once the compositor hands this surface the keyboard.
    property Item focusTarget: null

    signal closeRequested()

    // Whether the pointer is on the card; the auto-close arms off this.
    readonly property bool hovered: cardHover.hovered

    default property alias content: holder.children

    readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
    readonly property string barPos: bar && bar.position ? bar.position : "top"
    readonly property real barW: anchorWindow ? anchorWindow.width : 0
    readonly property real barH: anchorWindow ? anchorWindow.height : 0
    readonly property real screenW: screen ? screen.width : 0
    readonly property real screenH: screen ? screen.height : 0
    readonly property real contentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

    function fittedHeight(contentHeight, cap) {
        var desired = Math.max(contentInset, (Number(contentHeight) || 0) + contentInset)
        var maxHeight = screenH > 0
            ? Math.max(Style.space(120), screenH - ((barPos === "top" || barPos === "bottom") ? barH + gap + screenMargin : screenMargin * 2))
            : desired
        if (cap !== undefined && Number(cap) > 0)
            maxHeight = Math.min(maxHeight, Number(cap))
        return Math.round(Math.min(desired, maxHeight))
    }

    // --- placement (copied from the ledge) ------------------------------------

    // mapToItem is a one-shot; the watcher re-evaluates it whenever anything
    // between the bar surface and the icon moves or resizes.
    TransformWatcher {
        id: anchorWatcher
        a: popup.anchorWindow ? popup.anchorWindow.contentItem : null
        b: popup.anchorItem
    }

    readonly property point anchorPos: {
        anchorWatcher.transform // reactive dependency
        if (!anchorItem || !anchorWindow)
            return Qt.point(0, 0)
        return anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
    }

    // Along the bar we follow the icon; away from the bar we measure from the
    // bar surface itself, because the icon's mapped position carries the bar's
    // internal centering with it.
    readonly property point cardOrigin: {
        if (!anchorItem || !anchorWindow)
            return Qt.point(screenMargin, screenMargin)
        var x = 0
        var y = 0
        if (barPos === "bottom") {
            x = anchorPos.x + anchorItem.width / 2 - cardWidth / 2
            y = screenH - barH - cardHeight - gap
        } else if (barPos === "left") {
            x = barW + gap
            y = anchorPos.y + anchorItem.height / 2 - cardHeight / 2
        } else if (barPos === "right") {
            x = screenW - barW - cardWidth - gap
            y = anchorPos.y + anchorItem.height / 2 - cardHeight / 2
        } else {
            x = anchorPos.x + anchorItem.width / 2 - cardWidth / 2
            y = barH + gap
        }
        x = Math.max(screenMargin, Math.min(x, screenW - cardWidth - screenMargin))
        y = Math.max(screenMargin, Math.min(y, screenH - cardHeight - screenMargin))
        return Qt.point(Math.round(x), Math.round(y))
    }

    // --- surface ---------------------------------------------------------------

    screen: anchorWindow ? anchorWindow.screen : null
    // Stays mapped through the fade-out so there is something to animate.
    visible: open || card.opacity > 0
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omasafe-card"
    WlrLayershell.layer: WlrLayer.Top
    // OnDemand: the compositor hands this surface the keyboard when it is
    // clicked, and never before. An Exclusive grab would route every pointer
    // event to the card for as long as it lasts — and this surface exists to
    // sit still while the user drags a file around other windows.
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    implicitWidth: cardWidth
    implicitHeight: cardHeight

    // Anchoring two adjacent edges keeps the implicit size and turns the
    // margins into an absolute position on the output.
    anchors {
        top: true
        left: true
    }

    margins {
        top: popup.cardOrigin.y
        left: popup.cardOrigin.x
    }

    onOpenChanged: {
        if (!open || !focusTarget)
            return
        // After the surface has mapped and the children have laid out. Qt
        // needs an item holding focus inside the window for the key handlers.
        Qt.callLater(function () {
            if (popup.open && popup.focusTarget)
                popup.focusTarget.forceActiveFocus()
        })
    }

    BorderSurface {
        id: card
        anchors.fill: parent
        color: Color.popups.background
        borderSpec: popup.borderSpec
        padding: popup.padding
        radius: Style.cornerRadius
        opacity: popup.open ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        // Only tracks the pointer; it takes no events away from the content.
        HoverHandler {
            id: cardHover
        }

        Item {
            id: holder
            anchors.fill: parent
            anchors.topMargin: card.contentTopInset
            anchors.rightMargin: card.contentRightInset
            anchors.bottomMargin: card.contentBottomInset
            anchors.leftMargin: card.contentLeftInset
        }
    }
}
