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

    // Nerd Font glyphs (md block), verified in the live shell.
    readonly property string glyphShield: "\u{F0499}"        // nf-md-shield
    readonly property string glyphLock: "\u{F0347}"          // nf-md-lock
    readonly property string glyphLockOpen: "\u{F0FCB}"      // nf-md-lock-open-variant
    readonly property string glyphDrop: "\u{F0120}"          // nf-md-tray-arrow-down
    readonly property string glyphKey: "\u{F0306}"           // nf-md-key-variant
    readonly property string glyphDownload: "\u{F0192}"      // nf-md-download
    readonly property string glyphTrash: "\u{F01B4}"         // nf-md-delete
    readonly property string glyphClose: "\u{F0156}"         // nf-md-close
    readonly property string glyphCheck: "\u{F00EC}"         // nf-md-check

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
    property int deleteIndex: -1
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
    readonly property bool pointerOnCard: panel.hovered || button.hovered
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

    function copyBackupKey() {
        if (!root.svc || root.svc.pendingBackupKey === "")
            return
        root.svc.copyBackupKey()
        root.showToast("Back-up key copied")
    }

    function requestDelete(index) {
        root.deleteIndex = index
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
            anchors.centerIn: parent
            text: root.barDropActive || root.cardDropActive ? root.glyphDrop
                : root.unlocked ? root.glyphLockOpen
                : root.glyphShield
            color: root.barDropActive || root.cardDropActive || root.unlocked
                   ? Color.accent : button.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
        }

        // Dropping straight on the icon is the whole point: you are already
        // holding the file when you decide it needs to disappear.
        DropArea {
            anchors.fill: parent

            onEntered: drag => {
                if (!drag.hasUrls && !drag.hasText)
                    return
                drag.accept(Qt.CopyAction)
                root.barDropActive = true
                springTimer.restart()
            }

            onExited: {
                root.barDropActive = false
                springTimer.stop()
            }

            onDropped: drop => {
                root.barDropActive = false
                springTimer.stop()
                if (!root.svc)
                    return
                const entries = drop.hasUrls ? drop.urls : String(drop.text).split("\n")
                if (root.svc.phase !== "unlocked")
                    root.open()
                root.svc.stash(entries)
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
                            text: root.glyphShield + "  OmaSafe"
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
                                text: root.svc
                                    ? (root.svc.itemCount === 1 ? "1 item" : root.svc.itemCount + " items")
                                    : ""
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
                            placeholderText: "Password (4+ characters)"
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
                                if (root.setupPass.length < 4) {
                                    root.setupError = "Use at least 4 characters."
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
                                text: root.glyphKey
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
                            placeholderText: "New password (4+ characters)"
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
                                    if (root.changeNew.length < 4) {
                                        root.changeError = "Use at least 4 characters."
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

                        // Items
                        Repeater {
                            model: root.svc ? root.svc.items : []

                            delegate: Rectangle {
                                id: rowDelegate

                                required property int index
                                required property var modelData

                                readonly property string name: SafeModel.safeName(modelData.name)
                                readonly property string glyph: SafeModel.itemGlyph(modelData.name, modelData.isDir)
                                readonly property string ext: SafeModel.extOf(modelData.name)
                                readonly property string kindLabel: modelData.isDir
                                    ? "FOLDER" : (rowDelegate.ext !== "" ? rowDelegate.ext.toUpperCase() : "FILE")
                                // Plaintext staged for a drag-out (and for the
                                // thumbnail): decrypted on hover or press.
                                readonly property string stagePath: !!root.svc && root.svc.staged && root.svc.staged[modelData.id]
                                    ? String(root.svc.staged[modelData.id].path) : ""
                                readonly property url thumbUrl: rowDelegate.stagePath !== "" && SafeModel.isImage(modelData.name)
                                    ? SafeModel.urlFromPath(rowDelegate.stagePath) : ""

                                width: parent.width
                                implicitHeight: Style.space(56)
                                radius: Math.min(Style.cornerRadius, Style.space(8))
                                color: rowHover.hovered ? Qt.alpha(root.foreground, 0.07) : Qt.alpha(root.foreground, 0.035)
                                border.width: 1
                                border.color: rowHover.hovered ? Qt.alpha(Color.accent, 0.55) : "transparent"

                                Behavior on color {
                                    ColorAnimation { duration: 90 }
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

                                HoverHandler {
                                    id: rowHover
                                    cursorShape: Qt.OpenHandCursor
                                    onHoveredChanged: if (hovered) {
                                        rowDelegate.refreshDragImage()
                                        // Stage on hover, ledge-style: by the
                                        // time the press turns into a drag the
                                        // plaintext is usually already on disk,
                                        // and image chips get their thumbnail.
                                        if (root.svc)
                                            root.svc.stageItem(rowDelegate.index)
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
                                        console.log("omasafe: row press, staging", rowDelegate.name)
                                        if (root.svc)
                                            root.svc.stageItem(rowDelegate.index)
                                    }

                                    onPositionChanged: mouse => {
                                        if (!pressed || dragging)
                                            return
                                        const dx = mouse.x - pressPoint.x
                                        const dy = mouse.y - pressPoint.y
                                        if (Math.sqrt(dx * dx + dy * dy) < 10)
                                            return
                                        dragging = true
                                        rowDelegate.beginDrag()
                                    }

                                    onClicked: mouse => {
                                        // A plain click is intentionally inert —
                                        // extract and destroy live on the buttons.
                                    }
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
                                        text: rowDelegate.glyph
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
                                                    : "decrypting…"
                                            const size = modelData.isDir ? "" : " · " + SafeModel.humanSize(modelData.size)
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
                                        onClicked: root.svc.extractAt(rowDelegate.index)
                                    }

                                    PanelActionButton {
                                        anchors.verticalCenter: parent.verticalCenter
                                        iconText: root.glyphTrash
                                        tooltipText: "Destroy (encrypted copy is gone for good)"
                                        foreground: root.foreground
                                        hoverColor: Color.urgent
                                        fontFamily: root.fontFamily
                                        enabled: !root.svc || !root.svc.busy
                                        onClicked: root.requestDelete(rowDelegate.index)
                                    }
                                }
                            }
                        }

                        // Empty state
                        Column {
                            visible: !!root.svc && root.svc.itemCount === 0
                            width: parent.width
                            spacing: Style.space(6)

                            Item {
                                width: 1
                                height: Style.space(6)
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.glyphDrop
                                color: Qt.alpha(root.foreground, 0.5)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.display
                            }

                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: "The safe is empty"
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                            }

                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: "Drop files or folders here — or on the bar icon. Press a row and drag it anywhere to take it out."
                                textFormat: Text.PlainText
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
                            text: "Press an item and drag it into any window to take a copy out."
                            textFormat: Text.PlainText
                            color: Qt.alpha(root.foreground, 0.4)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            visible: !!root.svc && !root.svc.busy && root.showUnlock
                            width: parent.width
                            text: "Drops while locked are refused — unlock first."
                            textFormat: Text.PlainText
                            color: Qt.alpha(root.foreground, 0.4)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                    }
                }
            }

            // The whole card is a drop target while the safe is open. A
            // highlighted border is the only feedback a hovering drag gets.
            DropArea {
                anchors.fill: parent

                onEntered: drag => {
                    if (!drag.hasUrls && !drag.hasText)
                        return
                    drag.accept(Qt.CopyAction)
                    root.cardDropActive = true
                }

                onExited: root.cardDropActive = false

                onDropped: drop => {
                    root.cardDropActive = false
                    if (!root.svc)
                        return
                    const entries = drop.hasUrls ? drop.urls : String(drop.text).split("\n")
                    if (root.svc.phase !== "unlocked")
                        root.showToast("Unlock the safe before adding files")
                    else
                        root.svc.stash(entries)
                    if (drop.hasUrls)
                        drop.accept(Qt.CopyAction)
                }
            }

            // Destroy confirmation. Anchored over the whole card, like the
            // clipboard history's.
            ConfirmDialog {
                anchors.fill: parent
                z: 10
                opened: root.deleteConfirmOpen
                message: root.deleteIndex >= 0 && root.svc && root.deleteIndex < root.svc.itemCount
                    ? "Destroy " + SafeModel.safeName(root.svc.items[root.deleteIndex].name)
                      + "? The encrypted copy is erased for good."
                    : ""
                confirmText: "Destroy"
                background: Color.background
                foreground: root.foreground
                fontFamily: root.fontFamily
                onCanceled: root.deleteConfirmOpen = false
                onConfirmed: {
                    if (root.svc && root.deleteIndex >= 0)
                        root.svc.deleteAt(root.deleteIndex)
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
