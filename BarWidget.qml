pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "SafeModel.js" as SafeModel
import "bridge" as OmaSafeBridge

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

    // Primary path: the bar host's scoped facade — the first-party bar scopes
    // it to this plugin, so serviceFor() reaches our own live service.
    // Fallback: the engine-wide bridge singleton. Replacement bars (e.g.
    // ruixen.bar) are handed a facade whose serviceFor() is a deliberate null
    // stub — Omarchy never exposes service resolution to them — so widgets
    // they host would otherwise never see the service. The binding
    // re-evaluates on its own when the service publishes (or is torn down).
    readonly property var svc: {
        var viaHost = bar && bar.shell && typeof bar.shell.serviceFor === "function"
            ? bar.shell.serviceFor("palccod.omasafe") : null
        return viaHost || OmaSafeBridge.Bridge.service
    }
    readonly property string phase: svc ? svc.phase : "empty"

    readonly property color foreground: bar ? bar.barForeground : Color.foreground
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    // Nerd Font glyphs (md block), codepoints from the official
    // glyphnames.json and confirmed against the installed font's cmap.
    readonly property string glyphShield: "\u{F0499}"        // nf-md-shield
    readonly property string glyphLock: "\u{F033E}"          // nf-md-lock
    readonly property string glyphLockOpen: "\u{F033F}"      // nf-md-lock-open
    readonly property string glyphDrop: "\u{F0120}"          // nf-md-tray-arrow-down
    readonly property string glyphKey: "\u{F0306}"           // nf-md-key-variant
    readonly property string glyphDownload: "\u{F0192}"      // nf-md-download
    readonly property string glyphTrash: "\u{F01B4}"         // nf-md-delete
    readonly property string glyphClose: "\u{F0156}"         // nf-md-close
    readonly property string glyphCheck: "\u{F05E0}"         // nf-md-check-circle
    readonly property string glyphFolderOpen: "\u{F0770}"    // nf-md-folder-open
    readonly property string glyphChevronLeft: "\u{F0141}"   // nf-md-chevron-left
    readonly property string glyphGrid: "\u{F0570}"          // nf-md-view-grid
    readonly property string glyphList: "\u{F0572}"          // nf-md-view-list
    readonly property string glyphSearch: "\u{F0349}"        // nf-md-magnify
    readonly property string glyphSort: "\u{F023F}"          // nf-md-sort
    readonly property string glyphImage: "\u{F0318}"         // nf-md-image-multiple
    readonly property string glyphDoc: "\u{F09EE}"           // nf-md-file-document
    readonly property string glyphMusic: "\u{F0386}"         // nf-md-music-note
    readonly property string glyphVideo: "\u{F0A1C}"         // nf-md-video-vintage
    readonly property string glyphChevronRight: "\u{F0142}"  // nf-md-chevron-right
    readonly property string glyphSettings: "\u{F0493}"      // nf-md-cog
    readonly property string glyphSelect: "\u{F0132}"        // nf-md-checkbox-multiple-marked

    // Which card to show is derived state — the service is the only source
    // of truth, so a lock from IPC or the timer lands the card back on the
    // password field by itself.
    readonly property bool showBackup: !!svc && svc.pendingBackupKey !== ""
    readonly property bool showSetup: !showBackup && phase === "empty"
    readonly property bool showUnlock: !showBackup && phase === "locked"
    readonly property bool showChangePw: !showBackup && changePwOpen && unlocked
    readonly property bool showContents: !showBackup && !changePwOpen && phase === "unlocked"
    readonly property bool unlocked: phase === "unlocked"
    // True while the keyring copy holds exactly the back-up key on screen;
    // a rotation flips it back so the banner offers to re-save.
    readonly property bool keyringSaveDone: !!svc && svc.keyringLastSaveKey !== ""
        && svc.keyringLastSaveKey === svc.pendingBackupKey

    // Per-card UI state.
    property bool cardDropActive: false
    property bool barDropActive: false
    property string toastText: ""
    // An optional action inside the toast pill (the delete Undo).
    property string toastActionText: ""
    property var toastActionFn: null
    // View state lives on the service so it persists in the prefs file; the
    // widget only reads it here and writes it through the toggles.
    readonly property bool gridMode: !!root.svc && root.svc.gridMode
    // Search: filters the whole vault by base name, independent of the open
    // folder. Cleared by Escape, any navigation, revealing a result, or the
    // card closing or locking.
    property string searchQuery: ""
    readonly property bool searchMode: root.searchQuery.trim().length > 0
    readonly property var searchResults: root.searchMode && root.svc
        ? SafeModel.searchItems(root.svc.items, root.searchQuery, 200)
        : { items: [], truncated: false }
    // What the list and grid Repeaters show: search results while a search
    // is live, otherwise the open folder's children — run through the view
    // sort in both cases.
    // What the list and grid Repeaters show. Precedence: a type-filtered
    // vault-wide flat list, then search results, then the open folder —
    // sorted in every case.
    readonly property var currentListing: SafeModel.sortEntries(
        root.typeFilter > 0 ? root.filterByType(root.svc ? root.svc.items : [])
        : root.searchMode ? root.searchResults.items
                        : (root.svc ? root.svc.visibleItems : []),
        root.sortMode)
    // Listing sort: 0 = name, 1 = newest first, 2 = largest. Persisted on
    // the service; the toolbar button cycles it.
    readonly property int sortMode: root.svc ? root.svc.sortMode : 0
    readonly property var sortLabels: ["name", "newest first", "largest first"]
    // Type filter (the sidebar): 0 = all files, then images, documents,
    // music, videos. Non-zero modes list that type vault-wide, flat.
    property int typeFilter: 0
    readonly property var typeFilterModel: [
        { label: "All Files", icon: root.glyphFolderOpen, empty: "files" },
        { label: "Images", icon: root.glyphImage, empty: "images" },
        { label: "Documents", icon: root.glyphDoc, empty: "documents" },
        { label: "Music", icon: root.glyphMusic, empty: "music" },
        { label: "Videos", icon: root.glyphVideo, empty: "videos" }
    ]

    function filterByType(items) {
        if (root.typeFilter === 0 || !items)
            return items
        const check = root.typeFilter === 1 ? SafeModel.isImage
            : root.typeFilter === 2 ? SafeModel.isDoc
            : root.typeFilter === 3 ? SafeModel.isAudio
            : SafeModel.isVideo
        return items.filter(it => !it.isDir && check(it.path))
    }
    // Grid image thumbnails, per the preferences toggle.
    readonly property bool showThumbnails: !root.svc || root.svc.showThumbnails

    function cycleSort() {
        if (!root.svc)
            return
        root.svc.sortMode = (root.svc.sortMode + 1) % 3
        root.svc._savePrefs()
        root.showToast("Sorted by " + root.sortLabels[root.svc.sortMode])
    }
    // A revealed file flashes its row for a moment after the jump.
    property string flashPath: ""
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
        root.toastActionText = ""
        root.toastActionFn = null
        toastTimer.interval = 2400
        toastTimer.restart()
    }

    // Widget-raised toast with an action — the delete Undo. Outlives the
    // service's passive messages, and its lifetime mirrors the trash grace
    // window on the service side.
    function showActionToast(text, actionText, fn) {
        root.toastText = text
        root.toastActionText = actionText
        root.toastActionFn = fn
        toastTimer.interval = 7000
        toastTimer.restart()
    }

    // The trash is undoable for a few seconds; the toast carries the Undo.
    function requestDelete(path) {
        const p = String(path || "")
        if (!root.svc || p === "")
            return
        const id = root.svc.trashMany([p])
        if (id === "")
            return
        root.showActionToast("Deleted " + SafeModel.baseNameOf(p), "Undo",
                             function () {
                                 if (!root.svc)
                                     return
                                 if (root.svc.undoTrash(id))
                                     root.showToast("Restored " + SafeModel.baseNameOf(p))
                                 else
                                     root.showToast("Too late — " + SafeModel.baseNameOf(p) + " is gone for good")
                             })
    }

    // Select mode: clicks toggle selection instead of opening; a bar offers
    // the bulk actions on everything chosen.
    property bool selectMode: false
    property var selectedPaths: []
    readonly property int selectedCount: root.selectedPaths.length

    function isSelected(path) {
        return root.selectedPaths.indexOf(String(path)) !== -1
    }

    function toggleSelectMode() {
        root.selectMode = !root.selectMode
        root.selectedPaths = []
    }

    function toggleSelected(path) {
        const p = String(path || "")
        root.selectedPaths = root.isSelected(p)
            ? root.selectedPaths.filter(x => x !== p)
            : root.selectedPaths.concat([p])
    }

    function deleteSelected() {
        if (!root.svc || !root.selectedPaths.length)
            return
        const paths = root.selectedPaths.slice()
        const names = paths.length === 1
            ? SafeModel.baseNameOf(paths[0])
            : paths.length + " items"
        const id = root.svc.trashMany(paths)
        root.selectedPaths = []
        if (id === "")
            return
        root.showActionToast("Deleted " + names, "Undo",
                             function () {
                                 if (!root.svc)
                                     return
                                 if (root.svc.undoTrash(id))
                                     root.showToast("Restored " + names)
                                 else
                                     root.showToast("Too late — already gone for good")
                             })
    }

    // Group drag: in select mode, dragging a picked item carries the whole
    // selection. The picked items stage one by one (each is a decrypt job,
    // folders the most work); the drag starts from the initiating row once
    // the last staged copy lands. Dragging an unpicked item stays single.
    property bool groupDragPending: false
    property var groupDragPaths: []
    property var groupDragItem: null
    property string groupDragPath: ""

    function dragMimeDataFor(path, stagePath) {
        if (stagePath === "")
            return {}
        return {
            "text/uri-list": SafeModel.uriList([stagePath]),
            "text/plain": stagePath
        }
    }

    // Returns true when the drag is now owned by the group machinery (either
    // started, or waiting for the remaining decrypts) — the caller skips its
    // single-item drag in that case.
    function beginGroupDrag(item, path) {
        if (!root.selectMode || !root.isSelected(path))
            return false
        root.groupDragPending = true
        root.groupDragItem = item
        root.groupDragPath = String(path)
        root.groupDragPaths = root.selectedPaths.slice()
        for (const p of root.groupDragPaths)
            root.svc.stageItem(p)
        const uris = []
        for (const p of root.groupDragPaths) {
            const st = root.svc.staged ? root.svc.staged[p] : null
            if (!st)
                return true
            uris.push(st.path)
        }
        root.startGroupDrag(uris)
        return true
    }

    function startGroupDrag(uris) {
        const item = root.groupDragItem
        root.groupDragPending = false
        root.groupDragItem = null
        if (!item || !uris.length)
            return
        root.dragOutActive = true
        item.Drag.mimeData = {
            "text/uri-list": SafeModel.uriList(uris),
            "text/plain": uris.join("\n")
        }
        item.Drag.active = true
        item.Drag.startDrag(Qt.CopyAction)
        if (item.Drag.active)
            item.Drag.active = false
        // Hand the row back its own single-item payload — the imperative
        // assignment above replaced its declarative one.
        item.Drag.mimeData = root.dragMimeDataFor(root.groupDragPath, item.stagePath)
        root.dragOutActive = false
    }

    function exitSearch() {
        searchField.text = ""
        root.flashPath = ""
    }

    // Jump from a search or filter result to where it lives: folders open
    // in place, files land in their folder with the row flashing briefly.
    function revealItem(path, isDir) {
        if (!root.svc)
            return
        root.typeFilter = 0
        root.svc.navigate(isDir ? path : SafeModel.parentOf(path))
        root.exitSearch()
        if (!isDir) {
            root.flashPath = String(path)
            flashTimer.restart()
        }
    }

    Connections {
        target: root.svc
        function onToast(message) {
            root.showToast(String(message))
        }
        // A group drag waits for the picked items to finish staging; the
        // last staged copy is what lets it start.
        function onStagedChanged() {
            if (!root.groupDragPending)
                return
            const uris = []
            for (const p of root.groupDragPaths) {
                const st = root.svc.staged ? root.svc.staged[p] : null
                if (!st)
                    return
                uris.push(st.path)
            }
            root.startGroupDrag(uris)
        }
        function onPhaseChanged() {
            root.unlockText = ""
            root.setupPass = ""
            root.setupConfirm = ""
            root.setupError = ""
            root.changePwOpen = false
            root.changeOld = ""
            root.changeNew = ""
            root.changeConfirm = ""
            root.changeError = ""
            root.exitSearch()
            root.settingsOpen = false
            root.selectMode = false
            root.selectedPaths = []
            // A locked safe can offer keyring recovery — check whether the
            // dedicated keyring exists before the unlock card shows.
            if (root.svc && root.svc.phase === "locked")
                root.svc.probeKeyring()
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

    // The old anchored card tidied itself away once the pointer had visited
    // and left; the floating window behaves like a window and stays open
    // until it is closed through ESC, its close button, IPC, or the WM.
    readonly property bool autoCloseArmed: false
    // True while a drag-out from the card is in flight.
    property bool dragOutActive: false

    onOpenedChanged: {
        syncPopout()
        if (!root.svc)
            return
        if (opened) {
            root.svc.panelOpened()
            root.svc.probeKeyring()
        } else {
            root.exitSearch()
            root.svc.panelClosed()
        }
    }

    Timer {
        id: toastTimer
        interval: 2400
        onTriggered: root.toastText = ""
    }

    Timer {
        id: flashTimer
        interval: 1400
        onTriggered: root.flashPath = ""
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

    function previewStep(delta) {
        const list = root.previewablePaths
        if (!list.length)
            return
        const idx = list.indexOf(root.previewPath)
        const next = Math.max(0, Math.min(list.length - 1, (idx < 0 ? 0 : idx + delta)))
        root.openPreview(list[next])
    }

    // Preview lightbox: the file currently viewed large. The path must stay
    // inside the visible listing; the overlay hides itself when it leaves.
    property bool previewOpen: false
    property string previewPath: ""
    property string previewText: ""
    // The settings page, opened from the header gear; swaps out the listing.
    property bool settingsOpen: false

    readonly property var previewablePaths: {
        const out = []
        for (const it of root.currentListing)
            if (!it.isDir)
                out.push(it.path)
        return out
    }

    // Files open in the preview lightbox; folders keep navigating. Staging
    // decrypts the blob to the scratch dir, which is both the image source
    // and the text reader's input.
    function openPreview(path) {
        const p = String(path || "")
        if (p === "" || !root.svc)
            return
        root.previewPath = p
        root.previewText = ""
        root.previewOpen = true
        root.svc.stageItem(p)
    }

    function closePreview() {
        root.previewOpen = false
        root.previewPath = ""
        root.previewText = ""
        keyCatcher.forceActiveFocus()
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

    FloatingCard {
        id: panel

        open: root.opened
        focusTarget: keyCatcher
        onCloseRequested: root.close()

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: {
                // ESC peels the layers back before it closes the window:
                // preview, then settings, then selection picks, then select
                // mode, then the card itself.
                if (root.previewOpen) {
                    root.closePreview()
                    return
                }
                if (root.settingsOpen) {
                    root.settingsOpen = false
                    return
                }
                if (root.selectMode) {
                    if (root.selectedCount > 0)
                        root.selectedPaths = []
                    else
                        root.selectMode = false
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

            // Fixed top: the header. Hides while settings are up.
            Column {
                id: fixedTop
                visible: !root.settingsOpen
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(6)

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
                            iconText: root.glyphSettings
                            tooltipText: root.settingsOpen ? "Back to the safe" : "Settings"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.settingsOpen = !root.settingsOpen
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

            }

            // Type filter sidebar — All Files, then media types. Filters
            // are vault-wide and flat; collapses while locked or in settings.
            Column {
                id: sidebar
                visible: root.showContents && !root.settingsOpen
                anchors.top: fixedTop.bottom
                anchors.bottom: fixedBottom.top
                anchors.left: parent.left
                anchors.topMargin: Style.space(6)
                anchors.bottomMargin: Style.space(6)
                width: root.showContents && !root.settingsOpen ? Style.space(148) : 0
                clip: true
                spacing: Style.space(2)

                Repeater {
                    model: root.typeFilterModel

                    delegate: Rectangle {
                        required property int index
                        required property var modelData

                        width: sidebar.width - Style.space(8)
                        height: Style.space(28)
                        radius: Math.min(Style.cornerRadius, Style.space(6))
                        color: root.typeFilter === index ? Qt.alpha(root.foreground, 0.09)
                             : sideHover.hovered ? Qt.alpha(root.foreground, 0.05) : "transparent"

                        HoverHandler { id: sideHover }

                        TapHandler { onTapped: root.typeFilter = index }

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(8)
                            spacing: Style.space(8)

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.icon
                                textFormat: Text.PlainText
                                color: root.typeFilter === index ? Color.accent : Qt.alpha(root.foreground, 0.7)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                width: sidebar.width - Style.space(52)
                                color: root.typeFilter === index ? root.foreground : Qt.alpha(root.foreground, 0.7)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                font.bold: root.typeFilter === index
                            }
                        }
                    }
                }

                PanelSeparator {}

                Rectangle {
                    width: sidebar.width - Style.space(8)
                    height: Style.space(28)
                    radius: Math.min(Style.cornerRadius, Style.space(6))
                    color: root.settingsOpen ? Qt.alpha(root.foreground, 0.09)
                         : settingsHover.hovered ? Qt.alpha(root.foreground, 0.05) : "transparent"

                    HoverHandler { id: settingsHover }

                    TapHandler { onTapped: root.settingsOpen = true }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(8)
                        spacing: Style.space(8)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.glyphSettings
                            textFormat: Text.PlainText
                            color: root.settingsOpen ? Color.accent : Qt.alpha(root.foreground, 0.7)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Settings"
                            textFormat: Text.PlainText
                            color: root.settingsOpen ? root.foreground : Qt.alpha(root.foreground, 0.7)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            font.bold: root.settingsOpen
                        }
                    }
                }
            }

            // Toolbar, search and selection — right of the sidebar.
            Column {
                id: listingTop
                visible: !root.settingsOpen
                anchors.top: fixedTop.bottom
                anchors.left: sidebar.right
                anchors.right: parent.right
                anchors.topMargin: Style.space(6)
                spacing: Style.space(6)

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
                        // Stay clear of the toolbar buttons; overflow
                        // clips instead of sliding under them.
                        width: parent.width - Style.space(110)
                        clip: true
                        spacing: Style.space(2)

                        PanelActionButton {
                            visible: !!root.svc && root.svc.currentFolder !== "/"
                            iconText: root.glyphChevronLeft
                            tooltipText: "Up one folder"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: if (root.svc) {
                                root.exitSearch()
                                root.svc.navigate(SafeModel.parentOf(root.svc.currentFolder))
                            }
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
                                    onTapped: if (root.svc) {
                                        root.exitSearch()
                                        root.svc.navigate(crumb.modelData.path)
                                    }
                                }
                            }
                        }
                    }

                    PanelActionButton {
                        id: selectToggle
                        anchors.right: sortToggle.left
                        anchors.rightMargin: Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: root.selectMode ? root.glyphClose : root.glyphSelect
                        tooltipText: root.selectMode ? "Stop selecting" : "Select items"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.toggleSelectMode()
                    }

                    PanelActionButton {
                        id: sortToggle
                        anchors.right: layoutToggle.left
                        anchors.rightMargin: Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: root.glyphSort
                        tooltipText: "Sort: " + root.sortLabels[root.sortMode] + " — click to change"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.cycleSort()
                    }

                    PanelActionButton {
                        id: layoutToggle
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: root.gridMode ? root.glyphList : root.glyphGrid
                        tooltipText: root.gridMode ? "List view" : "Grid view"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: {
                            if (!root.svc)
                                return
                            root.svc.gridMode = !root.svc.gridMode
                            root.svc._savePrefs()
                        }
                    }
                }

                // Search gets its own full-width row: squeezed next
                // to the crumbs it overlapped the listing below.
                Item {
                    visible: root.showContents
                    width: parent.width
                    height: searchField.height

                    TextField {
                        id: searchField
                        anchors.left: parent.left
                        anchors.right: parent.right
                        placeholderText: "Search the whole safe…"
                        foreground: root.foreground
                        font.family: root.fontFamily
                        enabled: !!root.svc && !root.svc.busy
                        // Room for the clear button when it shows.
                        rightPadding: root.searchMode ? Style.space(28) : 0
                        onTextChanged: root.searchQuery = text
                        Keys.onEscapePressed: root.exitSearch()
                    }

                    PanelActionButton {
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.searchMode
                        iconText: root.glyphClose
                        tooltipText: "Clear search"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: {
                            root.exitSearch()
                            searchField.forceActiveFocus()
                        }
                    }
                }

                // Selection bar — the bulk actions for whatever is
                // picked in select mode.
                Row {
                    visible: root.showContents && root.selectMode
                             && root.selectedCount > 0
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - selectActions.implicitWidth - Style.space(16)
                        text: root.selectedCount === 1
                              ? "1 item selected"
                              : root.selectedCount + " items selected"
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    Row {
                        id: selectActions
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)

                        Button {
                            text: "Delete"
                            foreground: root.foreground
                            accent: Color.urgent
                            fontFamily: root.fontFamily
                            enabled: !root.svc || !root.svc.busy
                            onClicked: root.deleteSelected()
                        }
                    }
                }
            }

            Flickable {
                id: scroll
                visible: !root.settingsOpen
                anchors.top: listingTop.bottom
                anchors.bottom: fixedBottom.top
                anchors.left: sidebar.right
                anchors.right: parent.right
                anchors.topMargin: Style.space(6)
                anchors.bottomMargin: Style.space(6)
                contentWidth: width
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                Column {
                    id: content
                    width: scroll.width
                    spacing: Style.space(12)

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

                        // Optional third copy: the dedicated keyring keeps the
                        // back-up key behind its own password, so losing the
                        // vault password (but not the keyring password) is
                        // still recoverable.
                        Rectangle {
                            width: parent.width
                            height: keyringBox.implicitHeight + Style.space(20)
                            radius: Style.space(8)
                            color: Qt.alpha(Color.accent, 0.08)
                            border.width: 1
                            border.color: Qt.alpha(Color.accent, 0.3)

                            Column {
                                id: keyringBox
                                anchors.fill: parent
                                anchors.margins: Style.space(10)
                                spacing: Style.space(8)

                                Text {
                                    width: parent.width
                                    text: root.keyringSaveDone
                                        ? "A copy is in the OmaSafe keyring — it opens only with that keyring's own password, never with the session."
                                        : "Or keep a copy in a dedicated OmaSafe keyring. Its password is separate — the session does not unlock it."
                                    wrapMode: Text.WordWrap
                                    textFormat: Text.PlainText
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                }

                                Button {
                                    width: parent.width
                                    text: root.keyringSaveDone ? "Saved in the keyring" : "Save in a keyring"
                                    foreground: root.foreground
                                    accent: Color.accent
                                    fontFamily: root.fontFamily
                                    enabled: !root.svc || (!root.svc.busy && !root.keyringSaveDone)
                                    onClicked: if (root.svc) root.svc.keyringSavePendingKey()
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

                        // One-click recovery when the dedicated keyring
                        // exists: pops the keyring's password dialog and
                        // unlocks with the copy it guards.
                        Button {
                            width: parent.width
                            text: "Recover from the keyring"
                            visible: !!root.svc && root.svc.keyringAvailable
                            enabled: !root.svc || !root.svc.busy
                            foreground: root.foreground
                            accent: Color.accent
                            fontFamily: root.fontFamily
                            onClicked: if (root.svc) root.svc.recoverFromKeyring()
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

                        // Items — list view
                        Column {
                            visible: root.showContents && !root.gridMode
                            width: parent.width
                            spacing: Style.space(8)

                        Repeater {
                            model: root.currentListing

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
                                // Where the item lives — in search mode the
                                // row shows this instead of size, since the
                                // hit may sit outside the open folder.
                                readonly property string parentDir: SafeModel.dirname(modelData.path)
                                readonly property string kindLabel: modelData.isDir
                                    ? "FOLDER" : (rowDelegate.ext !== "" ? rowDelegate.ext.toUpperCase() : "FILE")
                                readonly property int childCount: rowDelegate.isFolder
                                    ? (root.svc ? SafeModel.childrenOf(root.svc.items, modelData.path).length : 0) : 0
                                // Plaintext staged for a drag-out (and for the
                                // thumbnail): decrypted on hover or press.
                                readonly property string stagePath: !!root.svc && root.svc.staged && root.svc.staged[modelData.path]
                                    ? String(root.svc.staged[modelData.path].path) : ""
                                readonly property url thumbUrl: root.showThumbnails && rowDelegate.stagePath !== "" && SafeModel.isImage(rowDelegate.name)
                                    ? SafeModel.urlFromPath(rowDelegate.stagePath) : ""
                                // Highlight while a dragged payload hovers a
                                // folder: that drop lands inside it.
                                property bool folderHover: false

                                width: parent.width
                                implicitHeight: Style.space(56)
                                radius: Math.min(Style.cornerRadius, Style.space(8))
                                color: rowDelegate.modelData.path === root.flashPath ? Qt.alpha(Color.accent, 0.22)
                                    : rowDelegate.folderHover || rowHover.hovered ? Qt.alpha(root.foreground, 0.07) : Qt.alpha(root.foreground, 0.035)
                                border.width: 1
                                border.color: root.isSelected(modelData.path) || rowDelegate.folderHover
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
                                Drag.mimeData: root.dragMimeDataFor(rowDelegate.modelData.path, rowDelegate.stagePath)
                                Drag.imageSource: rowDelegate.dragImage

                                property url dragImage: ""

                                function refreshDragImage() {
                                    thumbBox.grabToImage(function (result) {
                                        rowDelegate.dragImage = result.url
                                    }, Qt.size(Style.space(44), Style.space(44)))
                                }

                                function beginDrag() {
                                    // In select mode a picked item drags the
                                    // whole selection (staged asynchronously;
                                    // the service's stagedChanged finishes it).
                                    if (root.beginGroupDrag(rowDelegate, rowDelegate.modelData.path))
                                        return
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
                                        // In search mode a click reveals the
                                        // hit at its real location; in select
                                        // mode it toggles the pick instead.
                                        if (dragging || !root.svc)
                                            return
                                        if (root.selectMode) {
                                            root.toggleSelected(rowDelegate.modelData.path)
                                            return
                                        }
                                        if (root.searchMode || root.typeFilter > 0) {
                                            root.revealItem(rowDelegate.modelData.path, rowDelegate.isFolder)
                                            return
                                        }
                                        if (rowDelegate.browsable) {
                                            root.svc.navigate(rowDelegate.modelData.path)
                                            return
                                        }
                                        if (!rowDelegate.isFolder)
                                            root.openPreview(rowDelegate.modelData.path)
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
                                            if (root.searchMode || root.typeFilter > 0)
                                                return "in " + (rowDelegate.parentDir === "/" ? "safe root" : rowDelegate.parentDir)
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
                                        tooltipText: "Delete — undoable for a few seconds"
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
                            id: tilesGrid
                            visible: root.showContents && root.gridMode
                            width: parent.width
                            // The floating window can be pulled wide — more
                            // room, more columns.
                            columns: Math.max(3, Math.floor(width / Style.space(200)))
                            columnSpacing: Style.space(8)
                            rowSpacing: Style.space(8)

                                Repeater {
                                model: root.currentListing

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
                                    // In search mode the tile shows where the
                                    // hit lives instead of its size.
                                    readonly property string parentDir: SafeModel.dirname(modelData.path)
                                    readonly property string stagePath: !!root.svc && root.svc.staged && root.svc.staged[modelData.path]
                                        ? String(root.svc.staged[modelData.path].path) : ""
                                    readonly property url thumbUrl: root.showThumbnails && tileDelegate.stagePath !== "" && SafeModel.isImage(tileDelegate.name)
                                        ? SafeModel.urlFromPath(tileDelegate.stagePath) : ""
                                    property bool folderHover: false

                                    width: Math.floor((parent.width - Style.space(16)) / parent.columns)
                                    height: Style.space(84)
                                    radius: Math.min(Style.cornerRadius, Style.space(8))
                                    color: tileDelegate.modelData.path === root.flashPath ? Qt.alpha(Color.accent, 0.22)
                                        : tileDelegate.folderHover || tileHover.hovered ? Qt.alpha(root.foreground, 0.07) : Qt.alpha(root.foreground, 0.035)
                                    border.width: 1
                                    border.color: root.isSelected(modelData.path) || tileDelegate.folderHover
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
                                    Drag.mimeData: root.dragMimeDataFor(tileDelegate.modelData.path, tileDelegate.stagePath)
                                    Drag.imageSource: tileDelegate.dragImage

                                    property url dragImage: ""

                                    function refreshDragImage() {
                                        tileThumbBox.grabToImage(function (result) {
                                            tileDelegate.dragImage = result.url
                                        }, Qt.size(Style.space(44), Style.space(44)))
                                    }

                                    function beginDrag() {
                                        if (root.beginGroupDrag(tileDelegate, tileDelegate.modelData.path))
                                            return
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
                                            // In select mode a click toggles
                                            // the pick; in search mode it
                                            // reveals the hit at its real
                                            // location.
                                            if (dragging || !root.svc)
                                                return
                                            if (root.selectMode) {
                                                root.toggleSelected(tileDelegate.modelData.path)
                                                return
                                            }
                                            if (root.searchMode || root.typeFilter > 0) {
                                                root.revealItem(tileDelegate.modelData.path, tileDelegate.isFolder)
                                                return
                                            }
                                            if (tileDelegate.browsable) {
                                                root.svc.navigate(tileDelegate.modelData.path)
                                                return
                                            }
                                            if (!tileDelegate.isFolder)
                                                root.openPreview(tileDelegate.modelData.path)
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
                                            text: root.searchMode || root.typeFilter > 0
                                                ? "in " + (tileDelegate.parentDir === "/" ? "safe root" : tileDelegate.parentDir)
                                                : tileDelegate.isFolder
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
                                            tooltipText: "Delete — undoable for a few seconds"
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
                        // is not; the wording follows the location. A live
                        // search or a type filter has its own empty story.
                        Column {
                            visible: root.showContents && !root.searchMode
                                     && (!root.svc || root.currentListing.length === 0)
                            width: parent.width
                            spacing: Style.space(6)

                            Item {
                                width: 1
                                height: Style.space(6)
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width
                                text: root.typeFilter > 0 ? root.typeFilterModel[root.typeFilter].icon
                                      : !root.svc || (root.svc.currentFolder === "/" && root.svc.itemCount === 0)
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
                                text: root.typeFilter > 0
                                      ? "No " + root.typeFilterModel[root.typeFilter].empty + " in the safe"
                                      : !root.svc || (root.svc.currentFolder === "/" && root.svc.itemCount === 0)
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
                                text: root.typeFilter > 0
                                      ? "Everything of this type shows up here, from any folder."
                                      : !root.svc || (root.svc.currentFolder === "/" && root.svc.itemCount === 0)
                                      ? "Drop files or folders here — or on the bar icon. Press an item and drag it anywhere to take it out."
                                      : "Drop files here to add them inside this folder."
                                textFormat: Text.PlainText
                                wrapMode: Text.WordWrap
                                color: Qt.alpha(root.foreground, 0.55)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                        }

                        // Search found nothing — a different story from an
                        // empty folder.
                        Column {
                            visible: root.showContents && root.searchMode
                                     && root.searchResults.items.length === 0
                            width: parent.width
                            spacing: Style.space(6)

                            Item {
                                width: 1
                                height: Style.space(6)
                            }

                            Text {
                                width: parent.width
                                text: root.glyphSearch
                                textFormat: Text.PlainText
                                horizontalAlignment: Text.AlignHCenter
                                color: Qt.alpha(root.foreground, 0.5)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.display
                            }

                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: "No matches for “" + root.searchQuery.trim() + "”"
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                            }

                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: "Search matches file and folder names everywhere in the safe."
                                textFormat: Text.PlainText
                                wrapMode: Text.WordWrap
                                color: Qt.alpha(root.foreground, 0.55)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                        }

                        // The result cap is a rendering guard, so say when it
                        // bit instead of silently hiding matches.
                        Text {
                            visible: root.showContents && root.searchMode && root.searchResults.truncated
                            width: parent.width
                            text: "Showing the first " + root.searchResults.items.length + " matches — try a longer query."
                            textFormat: Text.PlainText
                            horizontalAlignment: Text.AlignHCenter
                            color: Qt.alpha(root.foreground, 0.55)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }
                    }

                }
            }

            // Fixed bottom: busy label and hints.
            Column {
                id: fixedBottom
                visible: !root.settingsOpen
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(4)

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

            // Settings view — the preferences as their own page, reachable
            // from the header gear instead of buried at the bottom of the
            // listing's scroll.
            Column {
                visible: root.showContents && root.settingsOpen
                anchors.fill: parent
                spacing: Style.space(10)

                Item {
                    width: parent.width
                    height: Style.space(26)

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.glyphSettings + "  Settings"
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

                        PanelActionButton {
                            anchors.verticalCenter: parent.verticalCenter
                            iconText: root.glyphCheck
                            tooltipText: "Done"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.settingsOpen = false
                        }

                        PanelActionButton {
                            anchors.verticalCenter: parent.verticalCenter
                            iconText: root.glyphClose
                            tooltipText: "Close"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.close()
                        }
                    }
                }

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

                Toggle {
                    width: parent.width
                    label: "Auto-lock when idle"
                    description: "The safe locks itself after 10 minutes of no keyboard or mouse activity, wherever the focus is. A running job waits for it to finish."
                    checked: !!root.svc && root.svc.idleLockMinutes > 0
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onClicked: {
                        if (!root.svc)
                            return
                        root.svc.idleLockMinutes = root.svc.idleLockMinutes > 0 ? 0 : 10
                        root.svc._savePrefs()
                    }
                }

                Toggle {
                    width: parent.width
                    label: "Grid thumbnails"
                    description: "Image tiles and list rows show a decrypted preview thumbnail. The preview lightbox is unaffected."
                    checked: !!root.svc && root.svc.showThumbnails
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onClicked: {
                        if (!root.svc)
                            return
                        root.svc.showThumbnails = !root.svc.showThumbnails
                        root.svc._savePrefs()
                    }
                }
            }

            // Preview lightbox — a file viewed large over the listing. It
            // takes the keyboard while open: ESC closes, the arrows step
            // through the files of the current listing.
            Rectangle {
                id: previewBox
                anchors.fill: parent
                z: 15
                visible: root.previewOpen && root.previewPath !== ""
                         && root.previewablePaths.indexOf(root.previewPath) !== -1
                color: Color.background

                readonly property string stagePath: !!root.svc && root.svc.staged && root.svc.staged[root.previewPath]
                    ? String(root.svc.staged[root.previewPath].path) : ""
                readonly property bool isImg: SafeModel.isImage(root.previewPath)
                readonly property bool isTxt: SafeModel.isText(root.previewPath)

                onVisibleChanged: if (visible) previewBox.forceActiveFocus()
                onStagePathChanged: {
                    if (visible && isTxt && stagePath !== "") {
                        previewReader.command = ["head", "-c", "6000", "--", stagePath]
                        previewReader.running = true
                    }
                }

                Process {
                    id: previewReader
                    stdout: StdioCollector {
                        onStreamFinished: root.previewText = this.text
                    }
                }

                Keys.onEscapePressed: root.closePreview()
                Keys.onLeftPressed: root.previewStep(-1)
                Keys.onRightPressed: root.previewStep(1)

                Item {
                    id: previewHeader
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: Style.space(34)

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - previewClose.implicitWidth - Style.space(20)
                        text: root.previewPath === "" ? "" : SafeModel.baseNameOf(root.previewPath)
                        textFormat: Text.PlainText
                        elide: Text.ElideMiddle
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                    }

                    PanelActionButton {
                        id: previewClose
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: root.glyphClose
                        tooltipText: "Close preview"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.closePreview()
                    }
                }

                Item {
                    anchors.top: previewHeader.bottom
                    anchors.bottom: previewFooter.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: Style.space(8)

                    Image {
                        id: previewImg
                        anchors.fill: parent
                        visible: previewBox.isImg && previewBox.stagePath !== "" && status !== Image.Error
                        source: visible ? SafeModel.urlFromPath(previewBox.stagePath) : ""
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: previewBox.isImg && previewBox.stagePath !== "" && previewImg.status === Image.Error
                        text: "Qt cannot decode this image format — extract the file to view it"
                        textFormat: Text.PlainText
                        color: Qt.alpha(root.foreground, 0.6)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    // Text previews flick: long files scroll under the
                    // pinned header and footer instead of getting cut off.
                    Flickable {
                        id: previewTextFlick
                        anchors.fill: parent
                        visible: previewBox.isTxt
                        clip: true
                        contentWidth: width
                        contentHeight: previewText.implicitHeight
                        boundsBehavior: Flickable.StopAtBounds

                        Text {
                            id: previewText
                            width: previewTextFlick.width
                            visible: previewBox.isTxt
                            text: previewBox.stagePath === "" ? "" : root.previewText
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: !previewBox.isImg && !previewBox.isTxt
                        text: root.glyphSearch + "  no preview for this file type"
                        textFormat: Text.PlainText
                        color: Qt.alpha(root.foreground, 0.6)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: (previewBox.isImg || previewBox.isTxt) && previewBox.stagePath === ""
                        text: "Decrypting…"
                        textFormat: Text.PlainText
                        color: Qt.alpha(root.foreground, 0.6)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }
                }

                Item {
                    id: previewFooter
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: Style.space(30)

                    PanelActionButton {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: root.glyphChevronLeft
                        tooltipText: "Previous file"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        enabled: root.previewablePaths.indexOf(root.previewPath) > 0
                        onClicked: root.previewStep(-1)
                    }

                    Text {
                        anchors.centerIn: parent
                        text: (root.previewablePaths.indexOf(root.previewPath) + 1) + " / "
                              + root.previewablePaths.length
                        textFormat: Text.PlainText
                        color: Qt.alpha(root.foreground, 0.6)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                    }

                    PanelActionButton {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: root.glyphChevronRight
                        tooltipText: "Next file"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        enabled: root.previewablePaths.indexOf(root.previewPath) < root.previewablePaths.length - 1
                        onClicked: root.previewStep(1)
                    }
                }
            }

            // Toast -------------------------------------------------------------
            // A passive pill for service messages; carries an action button
            // when the widget raises it with one (the delete Undo).
            Rectangle {
                id: toastPill
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                width: Math.min(parent.width, toastRow.implicitWidth + Style.space(20))
                height: toastLabel.implicitHeight + Style.space(12)
                radius: height / 2
                color: Color.accent
                opacity: root.toastText ? 1 : 0
                visible: opacity > 0
                z: 20

                Behavior on opacity {
                    NumberAnimation { duration: 140 }
                }

                Row {
                    id: toastRow
                    anchors.centerIn: parent
                    spacing: Style.space(10)

                    Text {
                        id: toastLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.toastText
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        // Capped by the card, not the Row — the Row sizes
                        // itself from this label and must not loop back.
                        width: Math.min(implicitWidth, toastPill.parent.width - Style.space(60))
                        color: Color.background
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.toastActionText !== ""
                        text: root.toastActionText
                        textFormat: Text.PlainText
                        color: Color.background
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        font.underline: actionHover.hovered

                        HoverHandler { id: actionHover }

                        TapHandler {
                            onTapped: if (root.toastActionFn) root.toastActionFn()
                        }
                    }
                }
            }
        }
    }

    // Accent border while a drag hovers the card. Lives outside the
    // FloatingCard on purpose — its default property routes children into
    // the holder, and the border belongs to the surface itself.
    Binding {
        target: panel
        property: "accentBorder"
        value: true
        when: root.cardDropActive
    }
}
