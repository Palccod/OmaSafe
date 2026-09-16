pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "SafeModel.js" as SafeModel

// OmaSafe — the bar end of the plugin. The button is a drop target (drag a
// file onto it mid-drag, exactly like the ledge), the popout is everything
// else: setup, unlock, the back-up key, and the contents listing with
// extract / destroy actions.
//
// All vault logic lives in the service (palccod.omasafe); this file only
// renders state and forwards gestures. The popout does not grab the screen
// while open — dragging files in starts with a press in some other window,
// and a screen-wide dismissal overlay would eat it. It closes on Escape,
// the ✕, a second click on the bar icon, or the auto-lock timer.
Panel {
    id: root

    moduleName: "palccod.omasafe"
    ipcTarget: "palccod.omasafe"

    readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("palccod.omasafe") : null
    readonly property string phase: svc ? svc.phase : "empty"

    readonly property color foreground: bar ? bar.barForeground : Color.foreground
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    // Nerd Font glyphs (md block), codepoints from the official
    // glyphnames.json and confirmed against the installed font's cmap.
    readonly property string glyphShield: "\u{F0499}"        // nf-md-shield
    readonly property string glyphLock: "\u{F0347}"          // nf-md-lock
    readonly property string glyphLockOpen: "\u{F0FCB}"      // nf-md-lock-open-variant
    readonly property string glyphDrop: "\u{F0120}"          // nf-md-tray-arrow-down
    readonly property string glyphKey: "\u{F0306}"           // nf-md-key-variant
    readonly property string glyphDownload: "\u{F0192}"      // nf-md-download
    readonly property string glyphTrash: "\u{F01B4}"         // nf-md-delete
    readonly property string glyphClose: "\u{F0156}"         // nf-md-close
    readonly property string glyphCheck: "\u{F00EC}"         // nf-md-check
    readonly property string glyphFolderOpen: "\u{F0770}"    // nf-md-folder-open
    readonly property string glyphChevronLeft: "\u{F0141}"   // nf-md-chevron-left
    readonly property string glyphGrid: "\u{F0570}"          // nf-md-view-grid
    readonly property string glyphList: "\u{F0572}"          // nf-md-view-list

    // Which card to show is derived state — the service is the only source
    // of truth, so a lock from IPC or the timer lands the card back on the
    // password field by itself.
    readonly property bool showBackup: !!svc && svc.pendingBackupKey !== ""
    readonly property bool showSetup: !showBackup && phase === "empty"
    readonly property bool showUnlock: !showBackup && phase === "locked"
    readonly property bool showChangePw: !showBackup && changePwOpen && unlocked
    readonly property bool showContents: !showBackup && !changePwOpen && phase === "unlocked"
    readonly property bool unlocked: phase === "unlocked"

    // Per-card UI state.
    property bool cardDropActive: false
    property bool barDropActive: false
    property string toastText: ""
    property bool deleteConfirmOpen: false
    property string deletePath: ""
    property bool gridMode: false
    property string setupError: ""
    property string unlockText: ""
    property string setupPass: ""
    property string setupConfirm: ""
    property bool changePwOpen: false
    property string changeOld: ""
    property string changeNew: ""
    property string changeConfirm: ""
    property string changeError: ""

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function showToast(text) {
        root.toastText = text
        toastTimer.restart()
    }

    Connections {
        target: root.svc
        function onToast(message) {
            root.showToast(String(message))
        }
        function onPhaseChanged() {
            root.unlockText = ""
            root.setupPass = ""
            root.setupConfirm = ""
            root.setupError = ""
            root.deleteConfirmOpen = false
            root.changePwOpen = false
            root.changeOld = ""
            root.changeNew = ""
            root.changeConfirm = ""
            root.changeError = ""
        }
        // The moment a fresh back-up key is on screen (initial issue or a
        // rotation), the change-password card gives way to it.
        function onPendingBackupKeyChanged() {
            if (root.svc && root.svc.pendingBackupKey !== "")
                root.changePwOpen = false
        }
    }

    // One popout at a time, and the auto-lock grace period only runs while
    // the card is away.
    function syncPopout() {
        if (!bar || !bar.requestPopout)
            return
        if (opened)
            bar.requestPopout(root)
        else if (bar.activePopout === root)
            bar.releasePopout(root)
    }

    // Ledge-style auto-close: once the pointer has visited the card and then
    // left it, the card tidies itself away — which also starts the safe's
    // auto-lock countdown. Held off while a drag-out is in flight, a drop
    // onto the card is pending, the destroy dialog is open, or the service
    // is mid-job.
    property bool pointerHasVisited: false
    property bool dragOutActive: false
    readonly property bool pointerOnCard: !!panel.hovered || !!button.hovered
    readonly property bool autoCloseArmed: opened && pointerHasVisited
        && !pointerOnCard && !dragOutActive && !barDropActive
        && !deleteConfirmOpen && !(svc && svc.busy)

    onPointerOnCardChanged: if (pointerOnCard) root.pointerHasVisited = true
    onAutoCloseArmedChanged: autoCloseArmed ? autoCloseTimer.restart() : autoCloseTimer.stop()

    Timer {
        id: autoCloseTimer
        interval: 3000
        onTriggered: if (root.autoCloseArmed)
            root.close()
    }

    onOpenedChanged: {
        syncPopout()
        if (!root.svc)
            return
        if (opened) {
            root.svc.panelOpened()
        } else {
            root.pointerHasVisited = false
            root.svc.panelClosed()
        }
    }

    Timer {
        id: toastTimer
        interval: 2400
        onTriggered: root.toastText = ""
    }

    Timer {
        id: springTimer
        // Hold a drag on the bar icon and the card opens under it, so the
        // safe can be unlocked without letting go of the file first.
        interval: 700
        onTriggered: if (root.barDropActive) root.open()
    }

    // A Wayland drag that ends on another surface (or whose source dies) can
    // leave a DropArea without its exit event, and the icon would sit on the
    // drop glyph forever. Any real drag move re-enters well within a minute,
    // so a minute of silence means the highlights are orphans.
    Timer {
        id: dropFlagWatchdog
        interval: 60000
        onTriggered: {
            root.barDropActive = false
            root.cardDropActive = false
            springTimer.stop()
        }
    }

    onBarDropActiveChanged: {
        if (barDropActive || cardDropActive)
            dropFlagWatchdog.restart()
        else
            dropFlagWatchdog.stop()
    }

    onCardDropActiveChanged: {
        if (barDropActive || cardDropActive)
            dropFlagWatchdog.restart()
        else
            dropFlagWatchdog.stop()
    }

    function copyBackupKey() {
        if (!root.svc || root.svc.pendingBackupKey === "")
            return
        root.svc.copyBackupKey()
        root.showToast("Back-up key copied")
    }

    function requestDelete(path) {
        root.deletePath = String(path || "")
        root.deleteConfirmOpen = true
    }

    // --- bar button -----------------------------------------------------------

    WidgetButton {
        id: button
        bar: root.bar
        labelVisible: false
        hasVisualContent: true
        dimmed: !root.unlocked && !root.opened
        tooltipText: !root.svc ? "OmaSafe"
            : root.svc.busy ? "OmaSafe — " + root.svc.busyLabel
            : root.showSetup ? "OmaSafe — no safe yet"
            : root.unlocked ? "OmaSafe — unlocked, " + (root.svc.itemCount === 1 ? "1 item" : root.svc.itemCount + " items")
            : "OmaSafe — locked"
        fixedWidth: root.bar ? (root.bar.vertical ? Style.bar.iconSlot : -1) : -1
        fixedHeight: root.bar && root.bar.vertical ? Style.bar.iconSlot : -1

        onPressed: function (buttonCode) {
            if (buttonCode === Qt.LeftButton)
                root.toggle()
        }

        Text {
            id: iconGlyph
            anchors.centerIn: parent
            width: parent.width
            text: root.barDropActive || root.cardDropActive ? root.glyphDrop
                : root.unlocked ? root.glyphLockOpen
                : root.glyphShield
            textFormat: Text.PlainText
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            color: root.barDropActive || root.cardDropActive || root.unlocked
                   ? Color.accent : button.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge

            // The icon breathes while the safe is mid-job, so a long folder
            // drop is visibly alive with the card closed; the tooltip carries
            // the live "k/N" progress.
            SequentialAnimation {
                running: !!root.svc && root.svc.busy
                         && !root.barDropActive && !root.cardDropActive
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation {
                    target: iconGlyph
                    property: "opacity"
                    to: 0.35
                    duration: 550
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    target: iconGlyph
                    property: "opacity"
                    to: 1
                    duration: 550
                    easing.type: Easing.InOutQuad
                }
            }
        }

        // Dropping straight on the icon is the whole point: you are already
        // holding the file when you decide it needs to disappear.
        DropArea {
            anchors.fill: parent

            onEntered: drag => {
                console.log("omasafe: drag enter bar icon, urls=" + drag.hasUrls
                            + " text=" + drag.hasText)
                if (!drag.hasUrls && !drag.hasText)
                    return
                drag.accept(Qt.CopyAction)
                root.barDropActive = true
                springTimer.restart()
            }

            onExited: {
                root.barDropActive = false
                root.cardDropActive = false
                springTimer.stop()
            }

            onDropped: drop => {
                console.log("omasafe: drop on bar icon, urls=" + drop.hasUrls)
                // A drop that crosses surfaces can leave the other surface's
                // exit event undelivered; both highlights die with any drop.
                root.barDropActive = false
                root.cardDropActive = false
                springTimer.stop()
                if (!root.svc)
                    return
                const entries = drop.hasUrls ? drop.urls : String(drop.text).split("\n")
                if (root.svc.phase !== "unlocked")
                    root.open()
                else if (!root.opened)
                    // Show the run: a folder drop can take minutes, and the
                    // card is where the progress lives.
                    root.open()
                root.svc.stash(entries, root.svc.currentFolder)
                if (drop.hasUrls)
                    drop.accept(Qt.CopyAction)
            }
        }
    }

    // --- the card --------------------------------------------------------------

    CardPopup {
        id: panel

        anchorItem: button
        bar: root.bar
        open: root.opened
        cardWidth: Style.space(360)
        cardHeight: panel.fittedHeight(content.implicitHeight, Style.space(560))
        focusTarget: keyCatcher
        onCloseRequested: root.close()

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: {
                if (root.deleteConfirmOpen) {
                    root.deleteConfirmOpen = false
                    return
                }
                root.close()
            }

            // The whole card is a drop target while the safe is open. It sits
            // BELOW the flick content in stacking order, so folder rows and
            // tiles catch their own drops first; whatever misses them lands
            // in the folder the card is browsing. A highlighted border is
            // the only feedback a hovering drag gets.
            DropArea {
                anchors.fill: parent

                onEntered: drag => {
                    console.log("omasafe: drag enter card, urls=" + drag.hasUrls
                                + " text=" + drag.hasText)
                    if (!drag.hasUrls && !drag.hasText)
                        return
                    drag.accept(Qt.CopyAction)
                    root.cardDropActive = true
                }

                onExited: {
                    root.cardDropActive = false
                    root.barDropActive = false
                }

                onDropped: drop => {
                    console.log("omasafe: drop on card, urls=" + drop.hasUrls)
                    root.cardDropActive = false
                    root.barDropActive = false
                    springTimer.stop()
                    if (!root.svc)
                        return
                    const entries = drop.hasUrls ? drop.urls : String(drop.text).split("\n")
                    if (root.svc.phase !== "unlocked")
                        root.showToast("Unlock the safe before adding files")
                    else
                        root.svc.stash(entries, root.svc.currentFolder)
                    if (drop.hasUrls)
                        drop.accept(Qt.CopyAction)
                }
            }

            Flickable {
                id: scroll
                anchors.fill: parent
                contentWidth: width
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                Column {
                    id: content
                    width: scroll.width
                    spacing: Style.space(12)

                    // Header -------------------------------------------------
                    Item {
                        width: parent.width
                        height: Style.space(26)

                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * 0.55
                            text: root.glyphShield + "  OmaSafe"
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.subtitle
                            font.bold: true
                        }

                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Style.space(2)

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: root.showContents
                                width: Math.min(implicitWidth, Style.space(80))
                                text: root.svc
                                    ? (root.svc.itemCount === 1 ? "1 item" : root.svc.itemCount + " items")
                                    : ""
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: Color.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                rightPadding: Style.space(8)
                            }

                            PanelActionButton {
                                visible: root.showContents
                                iconText: root.glyphKey
                                tooltipText: "Change password"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: {
                                    root.changeOld = ""
                                    root.changeNew = ""
                                    root.changeConfirm = ""
                                    root.changeError = ""
                                    root.changePwOpen = true
                                }
                            }

                            PanelActionButton {
                                visible: root.showContents
                                iconText: root.glyphLock
                                tooltipText: "Lock now"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: {
                                    if (root.svc)
                                        root.svc.lock()
                                    root.close()
                                }
                            }

                            PanelActionButton {
                                iconText: root.glyphClose
                                tooltipText: "Close"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.close()
                            }
                        }
                    }

                    // Service missing — never expected, but the card must
                    // not render nonsense if it ever happens.
                    Text {
                        visible: !root.svc
                        width: parent.width
                        text: "The safe's service is not running. Restart the shell."
                        wrapMode: Text.WordWrap
                        textFormat: Text.PlainText
                        color: Color.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    // Setup ---------------------------------------------------
                    Column {
                        visible: root.showSetup
                        width: parent.width
                        spacing: Style.space(10)

                        Text {
                            width: parent.width
                            text: "Create the safe"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            text: "Files you drop in are encrypted and the originals are removed. Pick a password — a back-up key is generated once, shown to you a single time, and there is no way to recover it."
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: Qt.alpha(root.foreground, 0.75)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        TextField {
                            width: parent.width
                            password: true
                            placeholderText: "Password (12+ characters)"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            text: root.setupPass
                            onTextChanged: root.setupPass = text
                            enabled: !root.svc || !root.svc.busy
                            onAccepted: setupButton.activate()
                        }

                        TextField {
                            width: parent.width
                            password: true
                            placeholderText: "Repeat password"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            text: root.setupConfirm
                            onTextChanged: root.setupConfirm = text
                            enabled: !root.svc || !root.svc.busy
                            onAccepted: setupButton.activate()
                        }

                        Text {
                            visible: (root.setupError !== ""
                                      || (!!root.svc && root.svc.lastError !== ""))
                            width: parent.width
                            text: root.setupError !== ""
                                  ? root.setupError
                                  : (root.svc ? root.svc.lastError : "")
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        Button {
                            id: setupButton
                            width: parent.width
                            text: "Create safe"
                            foreground: root.foreground
                            accent: Color.accent
                            fontFamily: root.fontFamily
                            enabled: !root.svc || !root.svc.busy

                            function activate() {
                                if (!root.svc)
                                    return
                                if (root.setupPass.length < 12) {
                                    root.setupError = "Use at least 12 characters."
                                    return
                                }
                                if (root.setupPass !== root.setupConfirm) {
                                    root.setupError = "The passwords do not match."
                                    return
                                }
                                root.setupError = ""
                                root.svc.initialize(root.setupPass)
                            }

                            onClicked: activate()
                        }
                    }

                    // Back-up key ----------------------------------------------
                    Column {
                        visible: root.showBackup
                        width: parent.width
                        spacing: Style.space(10)

                        Row {
                            width: parent.width
                            spacing: Style.space(6)

                            Text {
                                width: implicitWidth
                                text: root.glyphKey
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: Color.accent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.heading
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Your back-up key"
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                                font.bold: true
                            }
                        }

                        Text {
                            width: parent.width
                            text: "This key opens the safe without the password. It is shown once and stored nowhere — save it in a password manager or on paper before continuing."
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: Qt.alpha(root.foreground, 0.75)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        Text {
                            visible: !!root.svc && root.svc.pendingKeyReason === "rotated"
                            width: parent.width
                            text: "The back-up key you used before is no longer valid."
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        Text {
                            width: parent.width
                            text: root.svc ? SafeModel.formatKey(root.svc.pendingBackupKey) : ""
                            textFormat: Text.PlainText
                            color: Color.accent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WrapAnywhere
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(8)

                            Button {
                                width: (parent.width - Style.space(8)) / 2
                                text: "Copy key"
                                foreground: root.foreground
                                accent: Color.accent
                                fontFamily: root.fontFamily
                                onClicked: root.copyBackupKey()
                            }

                            Button {
                                width: (parent.width - Style.space(8)) / 2
                                text: "I've saved it"
                                foreground: root.foreground
                                accent: Color.accent
                                fontFamily: root.fontFamily
                                onClicked: {
                                    if (root.svc)
                                        root.svc.acknowledgeBackupKey()
                                    root.showToast(root.svc && root.svc.pendingKeyReason === "rotated"
                                        ? "New back-up key saved — the old one no longer works"
                                        : "The safe is ready — drop files on me")
                                }
                            }
                        }
                    }

                    // Unlock -----------------------------------------------------
                    Column {
                        visible: root.showUnlock
                        width: parent.width
                        spacing: Style.space(10)

                        Text {
                            width: parent.width
                            text: "The safe is locked."
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: Qt.alpha(root.foreground, 0.75)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        TextField {
                            id: unlockField
                            width: parent.width
                            password: true
                            placeholderText: "Password or back-up key"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            text: root.unlockText
                            onTextChanged: root.unlockText = text
                            enabled: !root.svc || !root.svc.busy
                            onAccepted: unlockButton.activate()
                        }

                        Text {
                            visible: !!root.svc && root.svc.lastError !== ""
                            width: parent.width
                            text: root.svc ? root.svc.lastError : ""
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        Button {
                            id: unlockButton
                            width: parent.width
                            text: "Unlock"
                            foreground: root.foreground
                            accent: Color.accent
                            fontFamily: root.fontFamily
                            enabled: !root.svc || !root.svc.busy

                            function activate() {
                                if (!root.svc)
                                    return
                                if (!root.svc.unlock(root.unlockText))
                                    return
                                unlockField.clear()
                            }

                            onClicked: activate()
                        }
                    }

                    // Change password ---------------------------------------------
                    Column {
                        visible: root.showChangePw
                        width: parent.width
                        spacing: Style.space(10)

                        Text {
                            width: parent.width
                            text: "Change password"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }

                        Text {
                            width: parent.width
                            text: "Prove who you are with the current password or the back-up key. A brand-new back-up key is issued with the change — the old one stops working immediately."
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: Qt.alpha(root.foreground, 0.75)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        TextField {
                            width: parent.width
                            password: true
                            placeholderText: "Current password or back-up key"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            text: root.changeOld
                            onTextChanged: root.changeOld = text
                            enabled: !root.svc || !root.svc.busy
                            onAccepted: changeButton.activate()
                        }

                        TextField {
                            width: parent.width
                            password: true
                            placeholderText: "New password (12+ characters)"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            text: root.changeNew
                            onTextChanged: root.changeNew = text
                            enabled: !root.svc || !root.svc.busy
                            onAccepted: changeButton.activate()
                        }

                        TextField {
                            width: parent.width
                            password: true
                            placeholderText: "Repeat new password"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            text: root.changeConfirm
                            onTextChanged: root.changeConfirm = text
                            enabled: !root.svc || !root.svc.busy
                            onAccepted: changeButton.activate()
                        }

                        Text {
                            visible: root.changeError !== ""
                            width: parent.width
                            text: root.changeError
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            color: Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(8)

                            Button {
                                width: (parent.width - Style.space(8)) / 2
                                text: "Back"
                                foreground: root.foreground
                                accent: Color.accent
                                fontFamily: root.fontFamily
                                enabled: !root.svc || !root.svc.busy
                                onClicked: root.changePwOpen = false
                            }

                            Button {
                                id: changeButton
                                width: (parent.width - Style.space(8)) / 2
                                text: "Change password"
                                foreground: root.foreground
                                accent: Color.accent
                                fontFamily: root.fontFamily
                                enabled: !root.svc || !root.svc.busy

                                function activate() {
                                    if (!root.svc)
                                        return
                                    if (root.changeOld.length === 0) {
                                        root.changeError = "Enter the current password or the back-up key."
                                        return
                                    }
                                    if (root.changeNew.length < 12) {
                                        root.changeError = "Use at least 12 characters."
                                        return
                                    }
                                    if (root.changeNew !== root.changeConfirm) {
                                        root.changeError = "The new passwords do not match."
                                        return
                                    }
                                    root.changeError = ""
                                    if (root.svc.changePassword(root.changeOld, root.changeNew)) {
                                        // Authentication runs in the service's
                                        // queue: on success the back-up-key card
                                        // takes over via onPendingBackupKeyChanged,
                                        // on failure lastError shows below.
                                        root.changeOld = ""
                                        root.changeNew = ""
                                        root.changeConfirm = ""
                                    }
                                }

                                onClicked: activate()
                            }
                        }
                    }

                    // Contents ---------------------------------------------------
                    Column {
                        visible: root.showContents
                        width: parent.width
                        spacing: Style.space(8)

                        // Nudge after a back-up-key unlock: the password may
                        // be effectively lost, so the change is one click away.
                        Column {
                            visible: !!root.svc && root.svc.unlockedViaRecovery
                            width: parent.width
                            spacing: Style.space(6)

                            Rectangle {
                                width: parent.width
                                height: bannerText.implicitHeight + bannerButton.implicitHeight + Style.space(24)
                                radius: Style.space(8)
                                color: Qt.alpha(Color.urgent, 0.12)
                                border.width: 1
                                border.color: Qt.alpha(Color.urgent, 0.45)

                                Column {
                                    anchors.fill: parent
                                    anchors.margins: Style.space(10)
                                    spacing: Style.space(8)

                                    Text {
                                        id: bannerText
                                        width: parent.width
                                        text: "You opened the safe with the back-up key. If the password is lost, change it now — a new back-up key is issued with every change."
                                        wrapMode: Text.WordWrap
                                        textFormat: Text.PlainText
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.bodySmall
                                    }

                                    Button {
                                        id: bannerButton
                                        width: parent.width
                                        text: "Change password"
                                        foreground: root.foreground
                                        accent: Color.urgent
                                        fontFamily: root.fontFamily
                                        onClicked: {
                                            root.changeOld = ""
                                            root.changeNew = ""
                                            root.changeConfirm = ""
                                            root.changeError = ""
                                            root.changePwOpen = true
                                        }
                                    }
                                }
                            }
                        }

                        // Toolbar: breadcrumbs on the left, layout toggle on
                        // the right.
                        Item {
                            visible: root.showContents
                            width: parent.width
                            height: Style.space(26)

                            Row {
                                id: crumbs
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Style.space(2)

                                PanelActionButton {
                                    visible: !!root.svc && root.svc.currentFolder !== "/"
                                    iconText: root.glyphChevronLeft
                                    tooltipText: "Up one folder"
                                    foreground: root.foreground
                                    fontFamily: root.fontFamily
                                    onClicked: if (root.svc)
                                        root.svc.navigate(SafeModel.parentOf(root.svc.currentFolder))
                                }

                                Repeater {
                                    model: root.svc ? SafeModel.pathSegments(root.svc.currentFolder) : []

                                    delegate: Text {
                                        id: crumb
                                        required property int index
                                        required property var modelData

                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, Style.space(90))
                                        text: (index === 0 ? "" : " / ") + (modelData.name === "" ? "safe" : modelData.name)
                                        textFormat: Text.PlainText
                                        elide: Text.ElideMiddle
                                        color: !!root.svc && modelData.path === root.svc.currentFolder
                                               ? Color.accent : Qt.alpha(root.foreground, 0.6)
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.bodySmall
                                        font.bold: !!root.svc && modelData.path === root.svc.currentFolder

                                        TapHandler {
                                            onTapped: if (root.svc) root.svc.navigate(crumb.modelData.path)
                                        }
                                    }
                                }
                            }

                            PanelActionButton {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                iconText: root.gridMode ? root.glyphList : root.glyphGrid
                                tooltipText: root.gridMode ? "List view" : "Grid view"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: root.gridMode = !root.gridMode
                            }
                        }

                        // Items — list view
                        Column {
                            visible: root.showContents && !root.gridMode
                            width: parent.width
                            spacing: Style.space(8)

                        Repeater {
                            model: root.svc ? root.svc.visibleItems : []

                            delegate: Rectangle {
                                id: rowDelegate

                                required property int index
                                required property var modelData

                                readonly property string name: SafeModel.baseNameOf(modelData.path)
                                readonly property bool isFolder: modelData.isDir === true
                                // A pre-0.4.0 tar folder: extractable and
                                // draggable, but not browsable until the
                                // service's one-time upgrade explodes it.
                                readonly property bool browsable: rowDelegate.isFolder && modelData.legacy !== true
                                readonly property string glyph: SafeModel.itemGlyph(rowDelegate.name, modelData.isDir)
                                readonly property string ext: SafeModel.extOf(rowDelegate.name)
                                readonly property string kindLabel: modelData.isDir
                                    ? "FOLDER" : (rowDelegate.ext !== "" ? rowDelegate.ext.toUpperCase() : "FILE")
                                readonly property int childCount: rowDelegate.isFolder
                                    ? (root.svc ? SafeModel.childrenOf(root.svc.items, modelData.path).length : 0) : 0
                                // Plaintext staged for a drag-out (and for the
                                // thumbnail): decrypted on hover or press.
                                readonly property string stagePath: !!root.svc && root.svc.staged && root.svc.staged[modelData.path]
                                    ? String(root.svc.staged[modelData.path].path) : ""
                                readonly property url thumbUrl: rowDelegate.stagePath !== "" && SafeModel.isImage(rowDelegate.name)
                                    ? SafeModel.urlFromPath(rowDelegate.stagePath) : ""
                                // Highlight while a dragged payload hovers a
                                // folder: that drop lands inside it.
                                property bool folderHover: false

                                width: parent.width
                                implicitHeight: Style.space(56)
                                radius: Math.min(Style.cornerRadius, Style.space(8))
                                color: rowDelegate.folderHover || rowHover.hovered ? Qt.alpha(root.foreground, 0.07) : Qt.alpha(root.foreground, 0.035)
                                border.width: 1
                                border.color: rowDelegate.folderHover
                                    ? Color.accent
                                    : (rowHover.hovered ? Qt.alpha(Color.accent, 0.55) : "transparent")

                                Behavior on color {
                                    ColorAnimation { duration: 90 }
                                }

                                // Dropping onto a folder row files the payload
                                // into that folder instead of the open one.
                                DropArea {
                                    anchors.fill: parent
                                    enabled: rowDelegate.browsable

                                    onEntered: drag => {
                                        console.log("omasafe: drag enter row, urls=" + drag.hasUrls)
                                        if (!drag.hasUrls && !drag.hasText)
                                            return
                                        drag.accept(Qt.CopyAction)
                                        rowDelegate.folderHover = true
                                    }

                                    onExited: rowDelegate.folderHover = false

                                    onDropped: drop => {
                                        console.log("omasafe: drop on row")
                                        rowDelegate.folderHover = false
                                        if (!root.svc)
                                            return
                                        const entries = drop.hasUrls ? drop.urls : String(drop.text).split("\n")
                                        root.svc.stash(entries, rowDelegate.modelData.path)
                                        if (drop.hasUrls)
                                            drop.accept(Qt.CopyAction)
                                    }
                                }

                                // Native drag-out, copied from the ledge: the
                                // cursor carries a file:// url of the staged
                                // plaintext and any window can take a copy.
                                // The grabbed thumbnail is what the cursor
                                // shows — without an imageSource a Wayland
                                // drag is completely invisible.
                                Drag.dragType: Drag.Automatic
                                Drag.supportedActions: Qt.CopyAction
                                Drag.proposedAction: Qt.CopyAction
                                Drag.mimeData: rowDelegate.stagePath !== ""
                                    ? ({ "text/uri-list": SafeModel.uriList([rowDelegate.stagePath]),
                                         "text/plain": rowDelegate.stagePath })
                                    : ({})
                                Drag.imageSource: rowDelegate.dragImage

                                property url dragImage: ""

                                function refreshDragImage() {
                                    thumbBox.grabToImage(function (result) {
                                        rowDelegate.dragImage = result.url
                                    }, Qt.size(Style.space(44), Style.space(44)))
                                }

                                function beginDrag() {
                                    if (rowDelegate.stagePath === "")
                                        return
                                    console.log("omasafe: drag out", rowDelegate.name)
                                    root.dragOutActive = true
                                    rowDelegate.Drag.active = true
                                    rowDelegate.Drag.startDrag(Qt.CopyAction)
                                    if (rowDelegate.Drag.active)
                                        rowDelegate.Drag.active = false
                                    root.dragOutActive = false
                                }

                                // A staged folder is a whole-subtree decrypt,
                                // so it must never run on hover or on a
                                // plain click-to-navigate — only when the
                                // pointer actually turns into a drag. Files
                                // stay cheap and stage on hover, ledge-style.
                                HoverHandler {
                                    id: rowHover
                                    cursorShape: rowDelegate.browsable ? Qt.PointingHandCursor : Qt.OpenHandCursor
                                    onHoveredChanged: if (hovered) {
                                        rowDelegate.refreshDragImage()
                                        if (root.svc && !rowDelegate.isFolder)
                                            root.svc.stageItem(rowDelegate.modelData.path)
                                    }
                                }

                                // Copied from the ledge: the list must not
                                // steal the press — dragging a file out is the
                                // whole point, scrolling is done with the wheel.
                                MouseArea {
                                    id: rowDrag
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton
                                    preventStealing: true

                                    property point pressPoint: Qt.point(0, 0)
                                    property bool dragging: false

                                    onPressed: mouse => {
                                        pressPoint = Qt.point(mouse.x, mouse.y)
                                        dragging = false
                                        rowDelegate.refreshDragImage()
                                        if (root.svc && !rowDelegate.isFolder)
                                            root.svc.stageItem(rowDelegate.modelData.path)
                                    }

                                    onPositionChanged: mouse => {
                                        if (!pressed || dragging)
                                            return
                                        const dx = mouse.x - pressPoint.x
                                        const dy = mouse.y - pressPoint.y
                                        if (Math.sqrt(dx * dx + dy * dy) < 10)
                                            return
                                        dragging = true
                                        if (rowDelegate.isFolder) {
                                            // The subtree decrypt starts here,
                                            // at the first real drag motion;
                                            // beginDrag fires from
                                            // onStagePathChanged once the
                                            // plaintext tree is ready.
                                            if (root.svc)
                                                root.svc.stageItem(rowDelegate.modelData.path)
                                            return
                                        }
                                        rowDelegate.beginDrag()
                                    }

                                    onClicked: mouse => {
                                        // A click opens a folder; files stay
                                        // inert — extract and destroy live on
                                        // the buttons. A completed drag
                                        // attempt must not also navigate.
                                        if (!dragging && rowDelegate.browsable && root.svc)
                                            root.svc.navigate(rowDelegate.modelData.path)
                                    }
                                }

                                // The drag starts the moment a pressed folder
                                // finishes staging.
                                onStagePathChanged: {
                                    if (rowDrag.dragging && rowDelegate.stagePath !== "")
                                        rowDelegate.beginDrag()
                                }

                                Rectangle {
                                    id: thumbBox
                                    anchors.left: parent.left
                                    anchors.leftMargin: Style.space(6)
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Style.space(44)
                                    height: Style.space(44)
                                    radius: Math.min(rowDelegate.radius, Style.space(6))
                                    clip: true
                                    color: thumb.status === Image.Ready ? "transparent" : Qt.alpha(root.foreground, 0.06)

                                    Image {
                                        id: thumb
                                        anchors.fill: parent
                                        visible: status === Image.Ready
                                        source: rowDelegate.thumbUrl
                                        asynchronous: true
                                        cache: false
                                        fillMode: Image.PreserveAspectCrop
                                        sourceSize.width: Style.space(88)
                                        sourceSize.height: Style.space(88)
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: thumb.status !== Image.Ready
                                        width: parent.width
                                        text: rowDelegate.glyph
                                        textFormat: Text.PlainText
                                        elide: Text.ElideRight
                                        horizontalAlignment: Text.AlignHCenter
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.iconLarge
                                        color: Color.accent
                                    }
                                }

                                Column {
                                    anchors.left: thumbBox.right
                                    anchors.leftMargin: Style.space(10)
                                    anchors.right: actionsRow.left
                                    anchors.rightMargin: Style.space(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Style.space(2)

                                    Text {
                                        width: parent.width
                                        text: rowDelegate.name
                                        textFormat: Text.PlainText
                                        elide: Text.ElideMiddle
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                    }

                                    Text {
                                        width: parent.width
                                        elide: Text.ElideRight
                                        textFormat: Text.PlainText
                                        text: {
                                            if (rowHover.hovered)
                                                return rowDelegate.stagePath !== ""
                                                    ? "drag · release over a window to copy"
                                                    : (rowDelegate.browsable
                                                        ? "click to open · drop files to add inside"
                                                        : "decrypting…")
                                            if (modelData.isDir)
                                                return rowDelegate.childCount === 1
                                                    ? "1 item" : rowDelegate.childCount + " items"
                                            const size = " · " + SafeModel.humanSize(modelData.size)
                                            return rowDelegate.kindLabel + size
                                        }
                                        color: rowHover.hovered ? Color.accent : Qt.alpha(root.foreground, 0.5)
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                    }
                                }

                                Row {
                                    id: actionsRow
                                    anchors.right: parent.right
                                    anchors.rightMargin: Style.space(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Style.space(2)
                                    opacity: rowHover.hovered ? 1 : 0
                                    enabled: opacity > 0

                                    Behavior on opacity {
                                        NumberAnimation { duration: 90 }
                                    }

                                    PanelActionButton {
                                        anchors.verticalCenter: parent.verticalCenter
                                        iconText: root.glyphDownload
                                        tooltipText: "Unlock to Downloads/OmaSafe"
                                        foreground: root.foreground
                                        fontFamily: root.fontFamily
                                        enabled: !root.svc || !root.svc.busy
                                        onClicked: root.svc.extractAt(rowDelegate.modelData.path)
                                    }

                                    PanelActionButton {
                                        anchors.verticalCenter: parent.verticalCenter
                                        iconText: root.glyphTrash
                                        tooltipText: "Destroy (encrypted copy is gone for good)"
                                        foreground: root.foreground
                                        hoverColor: Color.urgent
                                        fontFamily: root.fontFamily
                                        enabled: !root.svc || !root.svc.busy
                                        onClicked: root.requestDelete(rowDelegate.modelData.path)
                                    }
                                }
                            }
                        }
                        }

                        // Items — grid view
                        Grid {
                            visible: root.showContents && root.gridMode
                            width: parent.width
                            columns: 3
                            columnSpacing: Style.space(8)
                            rowSpacing: Style.space(8)

                            Repeater {
                                model: root.svc ? root.svc.visibleItems : []

                                delegate: Rectangle {
                                    id: tileDelegate

                                    required property int index
                                    required property var modelData

                                    readonly property string name: SafeModel.baseNameOf(modelData.path)
                                    readonly property bool isFolder: modelData.isDir === true
                                    readonly property bool browsable: tileDelegate.isFolder && modelData.legacy !== true
                                    readonly property string glyph: SafeModel.itemGlyph(tileDelegate.name, modelData.isDir)
                                    readonly property int childCount: tileDelegate.isFolder
                                        ? (root.svc ? SafeModel.childrenOf(root.svc.items, modelData.path).length : 0) : 0
                                    readonly property string stagePath: !!root.svc && root.svc.staged && root.svc.staged[modelData.path]
                                        ? String(root.svc.staged[modelData.path].path) : ""
                                    readonly property url thumbUrl: tileDelegate.stagePath !== "" && SafeModel.isImage(tileDelegate.name)
                                        ? SafeModel.urlFromPath(tileDelegate.stagePath) : ""
                                    property bool folderHover: false

                                    width: (parent.width - Style.space(16)) / 3
                                    height: Style.space(84)
                                    radius: Math.min(Style.cornerRadius, Style.space(8))
                                    color: tileDelegate.folderHover || tileHover.hovered ? Qt.alpha(root.foreground, 0.07) : Qt.alpha(root.foreground, 0.035)
                                    border.width: 1
                                    border.color: tileDelegate.folderHover
                                        ? Color.accent
                                        : (tileHover.hovered ? Qt.alpha(Color.accent, 0.55) : "transparent")

                                    Behavior on color {
                                        ColorAnimation { duration: 90 }
                                    }

                                    DropArea {
                                        anchors.fill: parent
                                        enabled: tileDelegate.browsable

                                        onEntered: drag => {
                                            console.log("omasafe: drag enter tile, urls=" + drag.hasUrls)
                                            if (!drag.hasUrls && !drag.hasText)
                                                return
                                            drag.accept(Qt.CopyAction)
                                            tileDelegate.folderHover = true
                                        }

                                        onExited: tileDelegate.folderHover = false

                                        onDropped: drop => {
                                            console.log("omasafe: drop on tile")
                                            tileDelegate.folderHover = false
                                            if (!root.svc)
                                                return
                                            const entries = drop.hasUrls ? drop.urls : String(drop.text).split("\n")
                                            root.svc.stash(entries, tileDelegate.modelData.path)
                                            if (drop.hasUrls)
                                                drop.accept(Qt.CopyAction)
                                        }
                                    }

                                    Drag.dragType: Drag.Automatic
                                    Drag.supportedActions: Qt.CopyAction
                                    Drag.proposedAction: Qt.CopyAction
                                    Drag.mimeData: tileDelegate.stagePath !== ""
                                        ? ({ "text/uri-list": SafeModel.uriList([tileDelegate.stagePath]),
                                             "text/plain": tileDelegate.stagePath })
                                        : ({})
                                    Drag.imageSource: tileDelegate.dragImage

                                    property url dragImage: ""

                                    function refreshDragImage() {
                                        tileThumbBox.grabToImage(function (result) {
                                            tileDelegate.dragImage = result.url
                                        }, Qt.size(Style.space(44), Style.space(44)))
                                    }

                                    function beginDrag() {
                                        if (tileDelegate.stagePath === "")
                                            return
                                        root.dragOutActive = true
                                        tileDelegate.Drag.active = true
                                        tileDelegate.Drag.startDrag(Qt.CopyAction)
                                        if (tileDelegate.Drag.active)
                                            tileDelegate.Drag.active = false
                                        root.dragOutActive = false
                                    }

                                    // Same rule as list rows: a folder is only
                                    // staged when a press turns into a real
                                    // drag, never on hover or click.
                                    HoverHandler {
                                        id: tileHover
                                        cursorShape: tileDelegate.browsable ? Qt.PointingHandCursor : Qt.OpenHandCursor
                                        onHoveredChanged: if (hovered) {
                                            tileDelegate.refreshDragImage()
                                            if (root.svc && !tileDelegate.isFolder)
                                                root.svc.stageItem(tileDelegate.modelData.path)
                                        }
                                    }

                                    MouseArea {
                                        id: tileDrag
                                        anchors.fill: parent
                                        acceptedButtons: Qt.LeftButton
                                        preventStealing: true

                                        property point pressPoint: Qt.point(0, 0)
                                        property bool dragging: false

                                        onPressed: mouse => {
                                            pressPoint = Qt.point(mouse.x, mouse.y)
                                            dragging = false
                                            tileDelegate.refreshDragImage()
                                            if (root.svc && !tileDelegate.isFolder)
                                                root.svc.stageItem(tileDelegate.modelData.path)
                                        }

                                        onPositionChanged: mouse => {
                                            if (!pressed || dragging)
                                                return
                                            const dx = mouse.x - pressPoint.x
                                            const dy = mouse.y - pressPoint.y
                                            if (Math.sqrt(dx * dx + dy * dy) < 10)
                                                return
                                            dragging = true
                                            if (tileDelegate.isFolder) {
                                                if (root.svc)
                                                    root.svc.stageItem(tileDelegate.modelData.path)
                                                return
                                            }
                                            tileDelegate.beginDrag()
                                        }

                                        onClicked: mouse => {
                                            if (!dragging && tileDelegate.browsable && root.svc)
                                                root.svc.navigate(tileDelegate.modelData.path)
                                        }
                                    }

                                    onStagePathChanged: {
                                        if (tileDrag.dragging && tileDelegate.stagePath !== "")
                                            tileDelegate.beginDrag()
                                    }

                                    Column {
                                        anchors.fill: parent
                                        anchors.margins: Style.space(6)
                                        spacing: Style.space(2)

                                        Rectangle {
                                            id: tileThumbBox
                                            width: Style.space(40)
                                            height: Style.space(40)
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            radius: Math.min(Style.cornerRadius, Style.space(6))
                                            clip: true
                                            color: tileThumb.status === Image.Ready ? "transparent" : Qt.alpha(root.foreground, 0.06)

                                            Image {
                                                id: tileThumb
                                                anchors.fill: parent
                                                visible: status === Image.Ready
                                                source: tileDelegate.thumbUrl
                                                asynchronous: true
                                                cache: false
                                                fillMode: Image.PreserveAspectCrop
                                                sourceSize.width: Style.space(80)
                                                sourceSize.height: Style.space(80)
                                            }

                                            Text {
                                                id: tileIcon
                                                anchors.centerIn: parent
                                                visible: tileThumb.status !== Image.Ready
                                                text: tileDelegate.glyph
                                                textFormat: Text.PlainText
                                                elide: Text.ElideRight
                                                font.family: root.fontFamily
                                                font.pixelSize: Style.font.display
                                                color: Color.accent
                                            }
                                        }

                                        Text {
                                            width: parent.width
                                            text: tileDelegate.name
                                            textFormat: Text.PlainText
                                            elide: Text.ElideMiddle
                                            horizontalAlignment: Text.AlignHCenter
                                            color: root.foreground
                                            font.family: root.fontFamily
                                            font.pixelSize: Style.font.caption
                                        }

                                        Text {
                                            width: parent.width
                                            text: tileDelegate.isFolder
                                                ? (tileDelegate.childCount === 1 ? "1 item" : tileDelegate.childCount + " items")
                                                : SafeModel.humanSize(modelData.size)
                                            textFormat: Text.PlainText
                                            elide: Text.ElideRight
                                            horizontalAlignment: Text.AlignHCenter
                                            color: Qt.alpha(root.foreground, 0.5)
                                            font.family: root.fontFamily
                                            font.pixelSize: Style.font.caption
                                        }
                                    }

                                    // Hover actions, mirroring the list row.
                                    Row {
                                        anchors.top: parent.top
                                        anchors.right: parent.right
                                        anchors.margins: Style.space(4)
                                        spacing: Style.space(2)
                                        opacity: tileHover.hovered ? 1 : 0
                                        enabled: opacity > 0

                                        Behavior on opacity {
                                            NumberAnimation { duration: 90 }
                                        }

                                        PanelActionButton {
                                            iconText: root.glyphDownload
                                            tooltipText: "Unlock to Downloads/OmaSafe"
                                            foreground: root.foreground
                                            fontFamily: root.fontFamily
                                            enabled: !root.svc || !root.svc.busy
                                            onClicked: root.svc.extractAt(tileDelegate.modelData.path)
                                        }

                                        PanelActionButton {
                                            iconText: root.glyphTrash
                                            tooltipText: "Destroy (encrypted copy is gone for good)"
                                            foreground: root.foreground
                                            hoverColor: Color.urgent
                                            fontFamily: root.fontFamily
                                            enabled: !root.svc || !root.svc.busy
                                            onClicked: root.requestDelete(tileDelegate.modelData.path)
                                        }
                                    }
                                }
                            }
                        }

                        // Empty state — a folder can be empty while the safe
                        // is not; the wording follows the location.
                        Column {
                            visible: root.showContents
                                     && (!root.svc || root.svc.visibleItems.length === 0)
                            width: parent.width
                            spacing: Style.space(6)

                            Item {
                                width: 1
                                height: Style.space(6)
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width
                                text: !root.svc || (root.svc.currentFolder === "/" && root.svc.itemCount === 0)
                                      ? root.glyphDrop : root.glyphFolderOpen
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                                color: Qt.alpha(root.foreground, 0.5)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.display
                            }

                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: !root.svc || (root.svc.currentFolder === "/" && root.svc.itemCount === 0)
                                      ? "The safe is empty"
                                      : "This folder is empty"
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                            }

                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: !root.svc || (root.svc.currentFolder === "/" && root.svc.itemCount === 0)
                                      ? "Drop files or folders here — or on the bar icon. Press an item and drag it anywhere to take it out."
                                      : "Drop files here to add them inside this folder."
                                textFormat: Text.PlainText
                                wrapMode: Text.WordWrap
                                color: Qt.alpha(root.foreground, 0.55)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                        }
                    }

                    // Preferences (unlocked only) ---------------------------------
                    Column {
                        visible: root.showContents
                        width: parent.width
                        spacing: Style.space(10)

                        PanelSeparator {}

                        Toggle {
                            width: parent.width
                            label: "Remove originals"
                            description: "On, a dropped file is moved into the safe. Off, it is only copied, and the original stays where it was."
                            checked: !!root.svc && root.svc.deleteOriginals
                            foreground: root.foreground
                            accent: Color.accent
                            fontFamily: root.fontFamily
                            onClicked: {
                                if (!root.svc)
                                    return
                                root.svc.deleteOriginals = !root.svc.deleteOriginals
                                root.svc._savePrefs()
                            }
                        }

                        Toggle {
                            width: parent.width
                            label: "Auto-lock after closing"
                            description: "The safe locks itself " + (root.svc && root.svc.autoLockSeconds > 0
                                       ? root.svc.autoLockSeconds + " seconds after this card closes"
                                       : "only when you lock it or quit the shell") + "."
                            checked: !!root.svc && root.svc.autoLockSeconds > 0
                            foreground: root.foreground
                            accent: Color.accent
                            fontFamily: root.fontFamily
                            onClicked: {
                                if (!root.svc)
                                    return
                                root.svc.autoLockSeconds = root.svc.autoLockSeconds > 0 ? 0 : 15
                                root.svc._savePrefs()
                            }
                        }
                    }

                    // Footer -------------------------------------------------------
                    Column {
                        width: parent.width
                        spacing: Style.space(4)

                        Item {
                            width: 1
                            height: Style.space(2)
                        }

                        Text {
                            visible: !!root.svc && root.svc.busy
                            width: parent.width
                            text: root.svc ? root.svc.busyLabel : ""
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            color: Color.accent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            visible: !!root.svc && !root.svc.busy && root.showContents
                            width: parent.width
                            text: "Click folders to browse, drop onto one to add inside. Press an item and drag it into any window to take a copy out."
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            color: Qt.alpha(root.foreground, 0.4)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            visible: !!root.svc && !root.svc.busy && root.showUnlock
                            width: parent.width
                            text: "Drops while locked are refused — unlock first."
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            color: Qt.alpha(root.foreground, 0.4)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                    }
                }
            }

            // Destroy confirmation. Anchored over the whole card, like the
            // clipboard history's.
            ConfirmDialog {
                anchors.fill: parent
                z: 10
                opened: root.deleteConfirmOpen
                message: {
                    if (!root.svc || root.deletePath === "")
                        return ""
                    const it = (root.svc.items || []).find(e => e.path === root.deletePath)
                    if (!it)
                        return ""
                    const name = SafeModel.baseNameOf(it.path)
                    if (it.isDir && it.legacy !== true) {
                        const kids = (root.svc.items || []).filter(
                            e => SafeModel.isUnder(e.path, it.path) && !e.isDir).length
                        return kids > 0
                            ? "Destroy " + name + " and the " + kids + (kids === 1 ? " file" : " files")
                              + " inside it? The encrypted copies are erased for good."
                            : "Destroy " + name + "? The encrypted copy is erased for good."
                    }
                    return "Destroy " + name + "? The encrypted copy is erased for good."
                }
                confirmText: "Destroy"
                background: Color.background
                foreground: root.foreground
                fontFamily: root.fontFamily
                onCanceled: root.deleteConfirmOpen = false
                onConfirmed: {
                    if (root.svc && root.deletePath !== "")
                        root.svc.deleteAt(root.deletePath)
                    root.deleteConfirmOpen = false
                }
            }

            // Toast -------------------------------------------------------------
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                width: Math.min(parent.width, toastLabel.implicitWidth + Style.space(20))
                height: toastLabel.implicitHeight + Style.space(12)
                radius: height / 2
                color: Color.accent
                opacity: root.toastText ? 1 : 0
                visible: opacity > 0
                z: 20

                Behavior on opacity {
                    NumberAnimation { duration: 140 }
                }

                Text {
                    id: toastLabel
                    anchors.centerIn: parent
                    text: root.toastText
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width - Style.space(16))
                    color: Color.background
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                }
            }
        }
    }

    // Accent border while a drag hovers the card. Lives outside the CardPopup
    // on purpose — its default property routes children into the holder, and
    // the border belongs to the surface itself.
    Binding {
        target: panel
        property: "borderSpec"
        value: Border.flat(Color.accent, Math.max(1, Style.space(2)))
        when: root.cardDropActive
    }
}
