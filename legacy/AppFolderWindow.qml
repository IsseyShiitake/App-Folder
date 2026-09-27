/*
 * appfolder — macOS-dock-style app folder popup for the Plasma panel.
 *
 * - Layer-shell surface on LayerTop (same layer as Plasma panel popups),
 *   anchored Bottom|Left; margins.left centers it over the clicked icon.
 * - 3×3 grid of FULL-SIZE taskbar icons.
 * - Panel background frame (widgets/panel-background) — the same SVG the
 *   task manager panel renders.
 * - Pop-open animation from the panel; hides on any click outside
 *   (window deactivation), like Plasma/Quicklaunch popups and macOS folders.
 * - Click icon → launch; drag .desktop files in → add; right-click → remove.
 */
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs as Dialogs

import org.kde.ksvg as KSvg
import org.kde.kirigami as Kirigami
import org.kde.layershell as LayerShell
QQC2.ApplicationWindow {
    id: root

    readonly property int columns: 3
    // Size scales 1..10 (settings sliders): icon 24..60px, tile padding
    // 4..22px, outer padding 6..24px. Scale 6 reproduces the classic look
    // (44px icon, 14px tile pad, 16px outer pad).
    property int iconScale: 6
    property int frameScale: 6
    readonly property int tileIcon: 24 + (iconScale - 1) * 4
    readonly property int tilePad: 4 + (frameScale - 1) * 2
    readonly property int tile: tileIcon + 2 * tilePad
    readonly property int gridPad: 6 + (frameScale - 1) * 2
    readonly property real panelThickness: popupGeometry ? popupGeometry.panelThickness : 55
    readonly property real floatMargin: popupGeometry ? popupGeometry.floatMargin : 8
    readonly property real gap: popupGeometry ? popupGeometry.gap : 6
    // x (logical, screen coords) of the clicked taskbar icon; set from Python
    // after the cursor query resolves; -1 = center on screen
    property real anchorX: -1
    function setAnchorX(x) { anchorX = x; pythonBridge.dumpGeometry("anchor=" + anchorX + " x=" + x + " w=" + width) }
    // Daemon entry: refresh content, anchor over the clicked icon, replay
    function showAt(x) {
        apps = initialApps
        gridPage = 0
        grid.contentY = 0
        anchorX = x
        pinned = false
        tileDrag = false
        dragSource = -1
        dropTarget = -1
        showSettings = false
        loadUi()
        pythonBridge.dumpGeometry("show anchor=" + anchorX + " w=" + width)
        openAnim.stop()
        openProgress = 0
        visible = true
        openAnim.restart()
    }
    // Pin-open mode ("Keep open" menu): suppress auto-hide so apps can be
    // dragged in from other windows (clicking the source would otherwise
    // dismiss us before the drop). Reset on every open.
    property bool pinned: false
    // A drag currently hovers the popup (tiles or empty grid): never hide
    // mid-drop.
    property bool tileDrag: false
    readonly property bool dragHover: gridDrop.containsDrag || tileDrag
    // File picker open: it takes focus, which must not dismiss us.
    readonly property bool pickerOpen: picker.visible
    // Panel opacity mirror: 0 = translucent panel-background, 1 = opaque
    // solid/panel-background (Panel.qml stacks the same two SVGs). Driven
    // live by the daemon from the host panel's opacity mode + touch state.
    property real panelSolidity: 0
    // Custom decoration (settings → uncheck "Adapt to theme"): a single
    // Rectangle replaces the theme SVGs. corner 1=square … 10≈48px radius;
    // outline 1=none … 10=3px highlight border; bgColor "" = theme color.
    // Strictly cheaper to render than SVG frames — no perf cost.
    property bool themeAdapt: true
    property string customBg: ""
    property real customOpacity: 0.95
    property int cornerScale: 6
    property int outlineScale: 1
    function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    // Internal icon reorder (press-drag-release on a tile): source index
    // being dragged, and live drop target in 0..apps.length (length =
    // append at end). -1 = no reorder in progress.
    property int dragSource: -1
    property int dropTarget: -1
    // Paging for folders with more than one 3×3 page: wheel flips pages
    // (the grid is non-interactive so press-drag stays reserved for reorder).
    property int gridPage: 0
    readonly property int pageSize: columns * 3
    readonly property int pageCount: Math.max(1, Math.ceil(apps.length / pageSize))
    function bumpPage(dir) {
        if (pageCount <= 1)
            return
        gridPage = Math.max(0, Math.min(pageCount - 1, gridPage + dir))
        grid.contentY = gridPage * grid.height
    }
    // Target cell under the dragged icon's center, in grid coordinates.
    // Manual cell math (not indexAt) so empty cells count: dropping past
    // the last app appends. Content-aware: works on any page.
    function dropIndexFor(tile) {
        var cx = tile.width / 2 + tile.dragDX
        var cy = tile.height / 2 + tile.dragDY
        var gp = grid.mapFromItem(tile, cx, cy)
        var col = Math.floor(gp.x / grid.cellWidth)
        var row = Math.floor((gp.y + grid.contentY) / grid.cellHeight)
        if (col < 0 || col >= columns || row < 0)
            return -1
        if (gp.y > grid.height + grid.cellHeight / 2)
            return -1
        return Math.min(row * columns + col, apps.length)
    }
    // Removing apps can strand the view past the last page: clamp back.
    // (Moves/adds keep length or grow, so this only fires on real shrinks.)
    onAppsChanged: {
        if (gridPage > pageCount - 1) {
            gridPage = pageCount - 1
            grid.contentY = gridPage * grid.height
        }
    }
    // ---- folder settings page -------------------------------------------
    // Right-click → "Folder settings…": icon picker, icon/frame size
    // sliders (1..10), keep-open, add-app. Swaps the grid view; the window
    // grows to fit (layer-shell resize recenters via margins.left).
    property bool showSettings: false
    property string folderIconName: ""
    property var allIcons: []
    property var shownIcons: []
    property string iconFilter: "folder"
    readonly property int settingsW: 380
    readonly property int settingsH: 620

    function clampScale(v) { return Math.max(1, Math.min(10, Math.round(v))) }

    function loadUi() {
        var envIcon = (popupGeometry && popupGeometry.iconSize) || 44
        var envScale = clampScale((envIcon - 24) / 4 + 1)
        var iconS = envScale, frameS = 6
        try {
            var m = JSON.parse(pythonBridge.folderMeta(confDir, folder) || "{}")
            if (m.ui) {
                if (m.ui.iconScale) iconS = clampScale(m.ui.iconScale)
                if (m.ui.frameScale) frameS = clampScale(m.ui.frameScale)
                if (m.ui.themeAdapt === false) themeAdapt = false
                else themeAdapt = true
                if (typeof m.ui.bgColor === "string") customBg = m.ui.bgColor
                else customBg = ""
                // Restored (S55, M15): these three were persisted but never
                // loaded — custom style reset to defaults on every restart
                // (same defect class as the plasmoid's bgOpacity).
                if (typeof m.ui.bgOpacity === "number"
                    && m.ui.bgOpacity >= 0.2 && m.ui.bgOpacity <= 1)
                    customOpacity = m.ui.bgOpacity
                if (m.ui.cornerScale)
                    cornerScale = clampScale(m.ui.cornerScale)
                if (m.ui.outlineScale)
                    outlineScale = clampScale(m.ui.outlineScale)
            } else {
                themeAdapt = true
                customBg = ""
                customOpacity = 0.95
                cornerScale = 6
                outlineScale = 1
            }
        } catch (e) { /* corrupt meta → defaults */ }
        iconScale = iconS
        frameScale = frameS
    }

    function persistUi() {
        var ok = pythonBridge.saveMeta(confDir, folder, JSON.stringify({ ui: {
            iconScale: iconScale, frameScale: frameScale,
            themeAdapt: themeAdapt, bgColor: customBg, bgOpacity: customOpacity,
            cornerScale: cornerScale, outlineScale: outlineScale } }))
        pythonBridge.debugLog("persistUi scales=" + iconScale + "/" + frameScale
            + " adapt=" + themeAdapt + " saved=" + ok)
        return ok
    }

    function refreshIconChoices() {
        var q = iconFilter.trim().toLowerCase()
        var out = []
        var arr = allIcons
        for (var i = 0; i < arr.length; i++) {
            var n = arr[i]
            if (!q || n.toLowerCase().indexOf(q) >= 0) {
                out.push(n)
                if (out.length >= 150)
                    break
            }
        }
        shownIcons = out
    }

    function openSettings() {
        if (allIcons.length === 0) {
            try {
                allIcons = JSON.parse(pythonBridge.listIcons() || "[]")
            } catch (e) { allIcons = [] }
        }
        folderIconName = pythonBridge.folderIcon(confDir, folder)
        refreshIconChoices()
        showSettings = true
    }

    property list<var> apps: initialApps
    property string folder: folderName
    property string confDir: configDir

    title: qsTr("App Folder")
    visible: false
    flags: Qt.WindowStaysOnTopHint | Qt.FramelessWindowHint

    // ---- layer-shell: above panel, no taskbar entry, no focus stealing ----
    // NOTE: with AnchorBottom alone KWin centers the surface and ignores the
    // Qt-side x — that was the "opens centered" bug. AnchorLeft + margins.left
    // is the layer-shell way to place the left edge at an exact screen x.
    LayerShell.Window.anchors: LayerShell.Window.AnchorBottom | LayerShell.Window.AnchorLeft
    LayerShell.Window.layer: LayerShell.Window.LayerTop
    LayerShell.Window.scope: "appfolder"
    LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityOnDemand
    LayerShell.Window.activateOnShow: false
    LayerShell.Window.exclusionZone: 0
    // Stay on the desktop where opened; the daemon hides us on desktop
    // switch (macOS-folder behavior) instead of following.
    LayerShell.Window.wantsToBeOnActiveScreen: false
    LayerShell.Window.margins.bottom: panelThickness + 2 * floatMargin + gap
    // Left edge so the popup sits centered over the clicked icon (or screen
    // center when the cursor is unknown). Clamped on-screen.
    LayerShell.Window.margins.left: anchorX >= 0
       ? Math.max(0, Math.min(Screen.width - width, Math.round(anchorX - width / 2)))
       : Math.max(0, Math.round((Screen.width - width) / 2))

    color: "transparent"


    width: showSettings ? settingsW : columns * tile + 2 * gridPad
    height: showSettings ? settingsH : columns * tile + 2 * gridPad

    // ---- pop-open (content scales from the bottom edge) ----
    // (ApplicationWindow itself has no scale; animate an inner container)
    // NOTE: this used to be Behavior + SpringAnimation (damping 0.38): the
    // spring overshot past 1 and showAt re-triggered it mid-flight (1→0 while
    // hidden, then back to 1 after 30 ms) — that reversal + overshoot was the
    // "icons bounce down and back up" glitch. Explicit from-0 animation with
    // a monotonic easing cannot overshoot, so it cannot bounce.
    property real openProgress: 0
    NumberAnimation {
        id: openAnim
        target: root
        property: "openProgress"
        from: 0
        to: 1
        duration: 170
        easing.type: Easing.OutCubic
    }

    // ---- close on any click outside / focus loss ----
    // (suppressed while pinned, while a drop hovers, or while the file
    // picker is open — all three legitimately move focus away and back)
    onActiveChanged: {
        if (visible && !active && !holdForTest && !pinned && !pickerOpen && !dragHover) {
            closingSoon.restart()
        }
    }

    // Daemon resident: hiding is not quitting (Python decides lifetime).
    // test-only escape hatch: APPFOLDER_HOLD=1 keeps the popup open for
    // external verification (screenshots); normal launches never set it
    readonly property bool holdForTest: (typeof popupGeometry !== "undefined" && popupGeometry && popupGeometry.holdForTest) ? popupGeometry.holdForTest : false
    // Wayland: clicks on other surfaces give us deactivate — but also poll
    // pointer leaving as a safety net like Quicklaunch's hideOnWindowDeactivate.
    Timer {
        id: closingSoon
        interval: 80
        onTriggered: if (!root.active && !pinned && !pickerOpen && !dragHover) root.visible = false
    }
    // Hidden = fully closed state: park the open animation at 0 so the next
    // showAt always starts from a clean, instant 0 (never mid-flight).
    // Also dismiss any open context menu with the folder (menus are their
    // own windows and would otherwise linger after reopen).
    onVisibleChanged: {
        if (!visible) {
            openAnim.stop()
            openProgress = 0
            gridMenu.close()
        }
    }
    function addApp(desktopPath) {
        if (!desktopPath)
            return
        for (var i = 0; i < apps.length; i++) {
            if (apps[i].desktop === desktopPath)
                return
        }
        var name = desktopName(desktopPath)
        if (!name)
            name = desktopPath.split("/").pop().replace(/\.desktop$/i, "")
        var icon = desktopIcon(desktopPath)
        var na = apps.slice()
        na.push({ desktop: desktopPath, name: name, icon: icon })
        apps = na
        var ok = persist()
        pythonBridge.debugLog("addApp path=" + desktopPath
            + " name=" + name + " icon=" + icon + " saved=" + ok)
    }

    // Shared drop entry: accepts file:// URLs (percent-decoded via Python),
    function handleDrop(drop) {
        var seen = []
        for (var i = 0; i < drop.urls.length; i++) {
            var u = drop.urls[i].toString()
            seen.push(u)
            var local = pythonBridge.localPath(u)
            if (local)
                addApp(local)
        }
        if (drop.urls.length === 0 && drop.text) {
            var t = drop.text.trim()
            seen.push("text=" + t)
            if (t) {
                var lt = pythonBridge.localPath(t)
                if (lt)
                    addApp(lt)
                else if (/\.desktop$/i.test(t))
                    addApp(t)
            }
        }
        pythonBridge.debugLog("drop urls=" + JSON.stringify(seen))
    }

    function removeAt(index) {
        var na = apps.slice()
        na.splice(index, 1)
        apps = na
        persist()
    }

    function move(from, to) {
        var na = apps.slice()
        if (from < 0 || from >= na.length)
            return
        to = Math.max(0, Math.min(na.length, to))
        if (to === from)
            return
        var item = na.splice(from, 1)[0]
        na.splice(to, 0, item)
        apps = na
        persist()
    }

    function persist() {
        return pythonBridge.save(confDir, folder, JSON.stringify(apps))
    }

    function desktopName(p) {
        return pythonBridge.desktopField(p, "Name")
    }
    function desktopIcon(p) {
        return pythonBridge.desktopField(p, "Icon")
    }
    // Panel mirror (Panel.qml stacks the same two SVGs): translucent base
    // always, opaque "solid/" overlay at the host panel's live opacity.
    // Theme switches re-render automatically; opacity mode + touch state
    // arrive via panelSolidity from the daemon. No fixed colors anywhere.
    // Uncheck "Adapt to theme" in settings for the custom branch below.
    KSvg.FrameSvgItem {
        anchors.fill: parent
        imagePath: "widgets/panel-background"
        visible: themeAdapt && panelSolidity < 1
    }
    KSvg.FrameSvgItem {
        anchors.fill: parent
        imagePath: "solid/widgets/panel-background"
        visible: themeAdapt && panelSolidity > 0
        opacity: panelSolidity
        Behavior on opacity {
            NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
        }
    }
    // Custom decoration: one Rectangle (cheaper than SVG frames, so no
    // perf cost). Corner 1=square … 10≈28px; outline 1=none … 10=3px
    // highlight border; empty bgColor follows the theme background color.
    // NOTE: no blur knob — KWin blur needs surface access no out-of-process
    // client has; nothing here can frost the backdrop.
    Rectangle {
        anchors.fill: parent
        visible: !themeAdapt
        radius: (cornerScale - 1) / 9 * 48
        color: customBg === "" ? Kirigami.Theme.backgroundColor : customBg
        opacity: customOpacity
        border.width: outlineScale <= 1 ? 0 : 1 + (outlineScale - 1) / 9 * 2
        border.color: withAlpha(Kirigami.Theme.highlightColor, (outlineScale - 1) / 9)
    }

    Item {
        id: container
        anchors.fill: parent
        anchors.margins: root.gridPad
        visible: !root.showSettings
        transform: Scale {
            origin.x: container.width / 2
            origin.y: container.height
            xScale: 0.6 + 0.4 * root.openProgress
            yScale: 0.6 + 0.4 * root.openProgress
        }
        opacity: root.openProgress

        GridView {
            id: grid

            anchors.fill: parent

            cellWidth: root.tile
            cellHeight: root.tile
            clip: true
            model: root.apps
            boundsBehavior: Flickable.StopAtBounds
            // Fixed 3×3, never scrolls: press-drag is reserved for reorder.
            interactive: false
            reuseItems: true
            Behavior on contentY {
                NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
            }

            keyNavigationEnabled: true
            highlightFollowsCurrentItem: true
            focus: true

            delegate: Item {
                id: tileItem

                required property var model
                required property int index

                width: root.tile
                height: root.tile

                // Internal reorder state (press-move-release with threshold;
                // separate from external file-drop DnD, which uses QDrag).
                property bool maybeDrag: false
                property bool reorderDrag: false
                property bool suppressClick: false
                property real dragDX: 0
                property real dragDY: 0
                property point pressPos: Qt.point(0, 0)

                // Floating layer: carries the icon while reordering so the
                // tile itself stays put (GridView owns delegate positions).
                Item {
                    id: dragLayer
                    width: parent.width
                    height: parent.height
                    x: tileItem.dragDX
                    y: tileItem.dragDY
                    z: tileItem.reorderDrag ? 5 : 0
                    Kirigami.Icon {
                        id: icon
                        anchors.centerIn: parent
                        width: root.tileIcon
                        height: root.tileIcon
                        source: model.modelData.icon || "application-x-executable"
                        isMask: false

                        Behavior on scale {
                            SpringAnimation { spring: 6; damping: 0.42; duration: 180 }
                        }
                    }
                }

                // Drop-position ring on the hovered tile while reordering.
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 6
                    radius: 10
                    color: "transparent"
                    border.width: 2
                    border.color: Kirigami.Theme.highlightColor
                    visible: root.dropTarget !== -1 && root.dropTarget === tileItem.index
                        && root.dragSource !== tileItem.index
                }
                // Menus are their own windows: dismiss with the folder.
                Connections {
                    target: root
                    function onVisibleChanged() {
                        if (!root.visible)
                            removeMenu.close()
                    }
                }

                // In-window tooltip: Plasma's floating tooltip positions
                // itself from window geometry it can't see on layer-shell,
                // so it popped up detached from the popup (red-circle bug).
                // QQC2.ToolTip renders inside our window, next to the cursor.
                QQC2.ToolTip {
                    parent: ma
                    visible: ma.containsMouse && !ma.pressed && !tileItem.reorderDrag
                    text: model.modelData.name || model.modelData.desktop
                    delay: 400
                    x: Math.max(0, Math.min(ma.width - (implicitWidth || 0), ma.mouseX + 12))
                    y: Math.max(0, Math.min(ma.height - (implicitHeight || 0), ma.mouseY + 16))
                }

                MouseArea {
                    id: ma
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    hoverEnabled: true

                    onEntered: if (!tileItem.reorderDrag) icon.scale = 1.18
                    onExited: if (!tileItem.reorderDrag) icon.scale = 1

                    onPressed: (mouse) => {
                        if (mouse.button === Qt.LeftButton) {
                            tileItem.maybeDrag = true
                            tileItem.pressPos = Qt.point(mouse.x, mouse.y)
                        }
                    }

                    onPositionChanged: (mouse) => {
                        if (!tileItem.maybeDrag)
                            return
                        if (!tileItem.reorderDrag) {
                            var d = Math.hypot(mouse.x - tileItem.pressPos.x,
                                               mouse.y - tileItem.pressPos.y)
                            if (d < 12)
                                return
                            tileItem.reorderDrag = true
                            root.dragSource = tileItem.index
                            icon.scale = 1.25
                        }
                        tileItem.dragDX = mouse.x - tileItem.pressPos.x
                        tileItem.dragDY = mouse.y - tileItem.pressPos.y
                        root.dropTarget = root.dropIndexFor(tileItem)
                    }

                    onReleased: (mouse) => {
                        tileItem.maybeDrag = false
                        if (!tileItem.reorderDrag)
                            return
                        tileItem.reorderDrag = false
                        var s = root.dragSource
                        var t = root.dropTarget
                        tileItem.dragDX = 0
                        tileItem.dragDY = 0
                        icon.scale = ma.containsMouse ? 1.18 : 1
                        root.dragSource = -1
                        root.dropTarget = -1
                        tileItem.suppressClick = true
                        // No t-1 adjustment: move() splices out first,
                        // so `to` already addresses the pointed cell.
                        if (t !== -1 && t !== s)
                            root.move(s, t)
                    }

                    onCanceled: {
                        tileItem.maybeDrag = false
                        tileItem.reorderDrag = false
                        tileItem.dragDX = 0
                        tileItem.dragDY = 0
                        root.dragSource = -1
                        root.dropTarget = -1
                    }

                    onClicked: (mouse) => {
                        if (tileItem.suppressClick) {
                            tileItem.suppressClick = false
                            return
                        }
                        if (mouse.button === Qt.LeftButton) {
                            pythonBridge.launch(model.modelData.desktop)
                            root.visible = false
                        } else {
                            removeMenu.openAt(tileItem, index)
                        }
                    }
                }

                QQC2.Menu {
                    id: removeMenu

                    function openAt(item, idx) {
                        removeAction.index = idx
                        popup(item, tileItem.width / 2, tileItem.height / 2)
                    }

                    QQC2.MenuItem {
                        id: removeAction
                        property int index: -1
                        text: qsTr("Remove from folder")
                        onTriggered: root.removeAt(index)
                    }
                    QQC2.MenuSeparator {}
                    QQC2.MenuItem {
                        text: qsTr("Add app…")
                        onTriggered: picker.open()
                    }
                    QQC2.MenuItem {
                        text: qsTr("Keep open")
                        checkable: true
                        checked: root.pinned
                        onTriggered: root.pinned = checked
                    }
                    QQC2.MenuItem {
                        text: qsTr("Folder settings…")
                        onTriggered: root.openSettings()
                    }
                }

                DropArea {
                    anchors.fill: parent
                    onEntered: root.tileDrag = true
                    onExited: root.tileDrag = false
                    onDropped: (drop) => { root.tileDrag = false; root.handleDrop(drop) }
                }
            }

            QQC2.Label {
                anchors.centerIn: parent
                visible: grid.count === 0
                text: qsTr("Drop apps here")
                color: Kirigami.Theme.disabledTextColor
                font: Kirigami.Theme.smallFont
            }

            DropArea {
                id: gridDrop
                anchors.fill: parent
                onDropped: (drop) => { root.handleDrop(drop) }
            }

            // Right-click on empty grid space (not on a tile: those have
            // their own menu). Press filtered so tile clicks fall through.
            MouseArea {
                id: emptyMA
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                // hoverEnabled stays false: hover must reach the tiles below
                // (their 1.18 zoom). onWheel still fires (topmost item).
                onPressed: (mouse) => {
                    // Content coords (add contentY): paged folders otherwise
                    // resolve the hit against page 0 and empty last-page
                    // cells read as occupied (same fix as the plasmoid, S55).
                    if (grid.indexAt(mouse.x, mouse.y + grid.contentY) !== -1)
                        mouse.accepted = false
                }
                onClicked: (mouse) => { gridMenu.popup(emptyMA, mouse.x, mouse.y) }
                // Wheel flips 3×3 pages (only exists past 9 apps). Sits above
                // the tiles so it works everywhere on the grid; tiles don't
                // handle wheel themselves. Touchpad smooth deltas ignored —
                // notched angleDelta only, with a dead zone.
                onWheel: (wheel) => {
                    var d = wheel.angleDelta.y
                    if (Math.abs(d) > 20)
                        root.bumpPage(d < 0 ? 1 : -1)
                }
            }

            // Page dots, only when paging exists. Overlay; tiny and dim.
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 3
                spacing: 4
                opacity: 0.75
                visible: root.pageCount > 1
                Repeater {
                    model: root.pageCount
                    Rectangle {
                        width: 6
                        height: 6
                        radius: 3
                        color: index === root.gridPage
                            ? Kirigami.Theme.highlightColor
                            : Kirigami.Theme.disabledTextColor
                    }
                }
            }

            QQC2.Menu {
                id: gridMenu
                QQC2.MenuItem {
                    text: qsTr("Add app…")
                    onTriggered: picker.open()
                }
                QQC2.MenuItem {
                    text: qsTr("Keep open")
                    checkable: true
                    checked: root.pinned
                    onTriggered: root.pinned = checked
                }
                QQC2.MenuItem {
                    text: qsTr("Folder settings…")
                    onTriggered: root.openSettings()
                }
            }
        }
    }
    // ---- folder settings page -------------------------------------------
    // Right-click → "Folder settings…". Same window grows to fit; the grid
    // hides while open. Everything persists per folder (icon + ui scales).
    Item {
        id: settingsView
        anchors.fill: parent
        anchors.margins: 16
        visible: root.showSettings

        ColumnLayout {
            anchors.fill: parent
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                QQC2.ToolButton {
                    icon.name: "go-previous"
                    text: qsTr("Back")
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: root.showSettings = false
                }
                QQC2.Label {
                    text: qsTr("Folder settings")
                    font.bold: true
                    Layout.fillWidth: true
                }
                Kirigami.Icon {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    source: root.folderIconName || "folder"
                }
            }

            QQC2.Label { text: qsTr("Folder icon") }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                QQC2.TextField {
                    id: iconSearch
                    Layout.fillWidth: true
                    placeholderText: qsTr("Search icons…")
                    text: root.iconFilter
                    onTextChanged: {
                        root.iconFilter = text
                        root.refreshIconChoices()
                    }
                }
                QQC2.Button {
                    text: qsTr("Default")
                    onClicked: {
                        if (pythonBridge.setFolderIcon(root.confDir, root.folder, "folder")) {
                            root.folderIconName = "folder"
                            root.refreshIconChoices()
                        }
                    }
                }
            }

            GridView {
                id: iconGrid
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 110
                clip: true
                cellWidth: 56
                cellHeight: 56
                model: root.shownIcons
                // 150 icon delegates without recycling = scroll jank (each
                // Kirigami.Icon re-rasterizes on creation). Recycle + buffer.
                reuseItems: true
                cacheBuffer: 168
                QQC2.ScrollBar.vertical: QQC2.ScrollBar {
                    policy: QQC2.ScrollBar.AsNeeded
                }
                delegate: Item {
                    width: 56
                    height: 56
                    required property var model
                    required property int index
                    Kirigami.Icon {
                        anchors.centerIn: parent
                        width: 40
                        height: 40
                        source: model.modelData
                    }
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: 8
                        color: "transparent"
                        border.width: 2
                        border.color: Kirigami.Theme.highlightColor
                        visible: model.modelData === root.folderIconName
                    }
                    MouseArea {
                        id: iconMA
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            if (pythonBridge.setFolderIcon(root.confDir, root.folder, model.modelData)) {
                                root.folderIconName = model.modelData
                                root.refreshIconChoices()
                            }
                        }
                    }
                    // Same in-window reasoning as the tile tooltip above:
                    // never detaches from the popup.
                    QQC2.ToolTip {
                        parent: iconMA
                        visible: iconMA.containsMouse && !iconMA.pressed
                        text: model.modelData
                        delay: 400
                        x: Math.max(0, Math.min(iconMA.width - (implicitWidth || 0), iconMA.mouseX + 12))
                        y: Math.max(0, Math.min(iconMA.height - (implicitHeight || 0), iconMA.mouseY + 16))
                    }
                }
            }

            QQC2.Label {
                text: root.shownIcons.length >= 150
                    ? qsTr("First 150 matches — refine the search")
                    : qsTr("%n icon(s)", "", root.shownIcons.length)
                color: Kirigami.Theme.disabledTextColor
                font: Kirigami.Theme.smallFont
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                QQC2.Label {
                    text: qsTr("Icon size")
                    Layout.preferredWidth: 80
                }
                QQC2.Slider {
                    Layout.fillWidth: true
                    from: 1
                    to: 10
                    stepSize: 1
                    value: root.iconScale
                    onMoved: root.iconScale = Math.round(value)
                    onPressedChanged: if (!pressed) root.persistUi()
                }
                QQC2.Label {
                    text: root.iconScale
                    Layout.preferredWidth: 16
                    horizontalAlignment: Text.AlignRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                QQC2.Label {
                    text: qsTr("Frame size")
                    Layout.preferredWidth: 80
                }
                QQC2.Slider {
                    Layout.fillWidth: true
                    from: 1
                    to: 10
                    stepSize: 1
                    value: root.frameScale
                    onMoved: root.frameScale = Math.round(value)
                    onPressedChanged: if (!pressed) root.persistUi()
                }
                QQC2.Label {
                    text: root.frameScale
                    Layout.preferredWidth: 16
                    horizontalAlignment: Text.AlignRight
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                QQC2.Switch {
                    text: qsTr("Adapt to theme")
                    checked: root.themeAdapt
                    onToggled: {
                        root.themeAdapt = checked
                        root.persistUi()
                    }
                }
                QQC2.Label {
                    text: qsTr("Off = custom style below")
                    color: Kirigami.Theme.disabledTextColor
                    font: Kirigami.Theme.smallFont
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: !root.themeAdapt
                QQC2.Label {
                    text: qsTr("Color")
                    Layout.preferredWidth: 80
                }
                Row {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: [Kirigami.Theme.backgroundColor,
                                Kirigami.Theme.highlightColor,
                                Kirigami.Theme.textColor,
                                "#ffffff", "#1a1a1a"]
                        Rectangle {
                            width: 28
                            height: 28
                            radius: 6
                            color: modelData
                            border.width: 2
                            border.color: String(root.customBg).toLowerCase() === String(modelData).toLowerCase()
                                || (root.customBg === "" && modelData === Kirigami.Theme.backgroundColor)
                                ? Kirigami.Theme.highlightColor : "transparent"
                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    root.customBg = String(modelData)
                                    root.persistUi()
                                }
                            }
                        }
                    }
                    QQC2.Button {
                        text: qsTr("Custom…")
                        onClicked: bgPicker.open()
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: !root.themeAdapt
                QQC2.Label {
                    text: qsTr("Opacity")
                    Layout.preferredWidth: 80
                }
                QQC2.Slider {
                    Layout.fillWidth: true
                    from: 0.2
                    to: 1
                    stepSize: 0.05
                    value: root.customOpacity
                    onMoved: root.customOpacity = value
                    onPressedChanged: if (!pressed) root.persistUi()
                }
                QQC2.Label {
                    text: Math.round(root.customOpacity * 100) + "%"
                    Layout.preferredWidth: 40
                    horizontalAlignment: Text.AlignRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: !root.themeAdapt
                QQC2.Label {
                    text: qsTr("Corners")
                    Layout.preferredWidth: 80
                }
                QQC2.Slider {
                    Layout.fillWidth: true
                    from: 1
                    to: 10
                    stepSize: 1
                    value: root.cornerScale
                    onMoved: root.cornerScale = Math.round(value)
                    onPressedChanged: if (!pressed) root.persistUi()
                }
                QQC2.Label {
                    text: root.cornerScale
                    Layout.preferredWidth: 16
                    horizontalAlignment: Text.AlignRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: !root.themeAdapt
                QQC2.Label {
                    text: qsTr("Outline")
                    Layout.preferredWidth: 80
                }
                QQC2.Slider {
                    Layout.fillWidth: true
                    from: 1
                    to: 10
                    stepSize: 1
                    value: root.outlineScale
                    onMoved: root.outlineScale = Math.round(value)
                    onPressedChanged: if (!pressed) root.persistUi()
                }
                QQC2.Label {
                    text: root.outlineScale
                    Layout.preferredWidth: 16
                    horizontalAlignment: Text.AlignRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                QQC2.Switch {
                    text: qsTr("Keep open")
                    checked: root.pinned
                    onToggled: root.pinned = checked
                }
                Item { Layout.fillWidth: true }
                QQC2.Button {
                    text: qsTr("Add app…")
                    onClicked: picker.open()
                }
                QQC2.Button {
                    text: qsTr("Reset")
                    onClicked: {
                        root.iconScale = 6
                        root.frameScale = 6
                        root.themeAdapt = true
                        root.customBg = ""
                        root.customOpacity = 0.95
                        root.cornerScale = 6
                        root.outlineScale = 1
                        root.persistUi()
                        if (pythonBridge.setFolderIcon(root.confDir, root.folder, "folder")) {
                            root.folderIconName = "folder"
                            root.refreshIconChoices()
                        }
                    }
                }
            }
        }
    }

    // .desktop picker: the focus-proof way to add apps (dragging from
    // another window works too once "Keep open" is on). Opening it takes
    // focus, which must not dismiss us (see pickerOpen guards above).
    Dialogs.FileDialog {
        id: picker
        title: qsTr("Add apps to folder")
        fileMode: Dialogs.FileDialog.OpenFiles
        nameFilters: [qsTr("Desktop files (*.desktop)"), qsTr("All files (*)")]
        currentFolder: "file:///usr/share/applications"
        onAccepted: {
            // Multi-select: add every chosen file (skip non-files).
            var files = picker.selectedFiles
            for (var i = 0; i < files.length; i++) {
                var local = pythonBridge.localPath(files[i].toString())
                if (local) {
                    addApp(local)
                } else {
                    pythonBridge.debugLog("picker not-a-file: " + files[i].toString())
                }
            }
        }
    }
    Dialogs.ColorDialog {
        id: bgPicker
        title: qsTr("Folder background color")
        selectedColor: root.customBg === "" ? Kirigami.Theme.backgroundColor : root.customBg
        onAccepted: {
            root.customBg = selectedColor.toString()
            root.persistUi()
        }
    }
}
