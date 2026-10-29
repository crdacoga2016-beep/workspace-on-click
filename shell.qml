pragma ComponentBehavior: Bound

// workspace-on-click
// Clickable workspace numbers in the corner of the focused Hyprland window.
//
// Requirements: Hyprland (Wayland) + Quickshell (0.3+).
// Run:    qs -c workspace-on-click
// Toggle: qs -c workspace-on-click ipc call wsnums toggle
//
// Colours are read from ~/.config/hypr/scheme/current.lua when present
// (Caelestia-style schemes); otherwise a neutral palette is used.
// Override the path with WSNUMS_SCHEME and the number of chips with WSNUMS_CHIPS.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

ShellRoot {
    id: root

    // How many workspaces to show (1..N). Override with WSNUMS_CHIPS.
    property int chipCount: {
        const v = parseInt(Quickshell.env("WSNUMS_CHIPS") ?? "");
        return Math.max(1, Math.min(9, isNaN(v) ? 5 : v));
    }

    property bool enabled: true

    // Neutral fallback palette, replaced by the Hyprland scheme if available.
    property var palette: ({
        surfaceContainer: "#1f1f1f",
        surfaceContainerHigh: "#272727",
        onSurface: "#eeeeee",
        onSurfaceVariant: "#c4c4c4",
        outlineVariant: "#555555",
        primary: "#8ab4f8",
        onPrimary: "#101010"
    })

    property var pending: null

    function col(name) {
        return palette[name] ?? "#ffffff";
    }

    function tint(name, alpha) {
        const hex = String(col(name)).replace("#", "");
        if (hex.length !== 6)
            return Qt.rgba(1, 1, 1, alpha);
        return Qt.rgba(parseInt(hex.slice(0, 2), 16) / 255, parseInt(hex.slice(2, 4), 16) / 255, parseInt(hex.slice(4, 6), 16) / 255, alpha);
    }

    // The focused window of the given screen, or null.
    function targetFor(screen) {
        if (!enabled)
            return null;
        const mon = Hyprland.monitorFor(screen);
        if (!mon)
            return null;
        let best = null;
        for (const t of Hyprland.toplevels.values) {
            const ipc = t.lastIpcObject;
            if (!ipc || ipc.focusHistoryID !== 0)
                continue;
            if (ipc.mapped === false || ipc.hidden)
                continue;
            if (!ipc.size || ipc.size[0] <= 0 || ipc.size[1] <= 0)
                continue;
            if (String(ipc.workspace?.name ?? "").startsWith("special"))
                continue;
            if (!mon.activeWorkspace || ipc.workspace?.id !== mon.activeWorkspace.id)
                continue;
            if (ipc.monitor !== undefined && mon.lastIpcObject && ipc.monitor !== mon.lastIpcObject.id)
                continue;
            best = t;
        }
        return best;
    }

    // Send a window to a workspace without following it.
    function moveWindow(t, wsId) {
        if (!t)
            return;
        const addr = t.address ? (String(t.address).startsWith("0x") ? t.address : "0x" + t.address) : "";
        const ws = String(wsId);
        Hyprland.dispatch(Hyprland.usingLua ? `hl.dsp.window.move({ window = "address:${addr}", workspace = "${ws}", follow = false })` : `movetoworkspacesilent ${ws},address:${addr}`);
    }

    FileView {
        id: schemeFile

        path: Quickshell.env("WSNUMS_SCHEME") || Quickshell.env("HOME") + "/.config/hypr/scheme/current.lua"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const found = {};
            const re = /(\w+)\s*=\s*"([0-9a-fA-F]{6})"/g;
            let m;
            while ((m = re.exec(text())) !== null)
                found[m[1]] = "#" + m[2];
            if (Object.keys(found).length)
                root.palette = Object.assign({}, root.palette, found);
        }
    }

    // Emitted after refreshing Hyprland's client cache.
    signal tick

    // Hyprland does not push focus/geometry updates to Quickshell's client
    // cache, so poll it a few times per second.
    Timer {
        interval: 250
        running: root.enabled
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            Hyprland.refreshToplevels();
            root.tick();
            lateTick.restart();
        }
    }

    Timer {
        id: lateTick

        interval: 60
        onTriggered: root.tick()
    }

    Timer {
        id: commitTimer

        interval: 140
        onTriggered: {
            if (!root.pending)
                return;
            root.moveWindow(root.pending.t, root.pending.ws);
            root.pending = null;
        }
    }

    IpcHandler {
        target: "wsnums"

        function toggle(): void {
            root.enabled = !root.enabled;
        }

        function enable(): void {
            root.enabled = true;
        }

        function disable(): void {
            root.enabled = false;
        }

        function setCount(n: int): void {
            root.chipCount = Math.max(1, Math.min(9, n));
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: PanelWindow {
            id: win

            required property var modelData

            readonly property var mon: Hyprland.monitorFor(win.screen)

            // Assigned imperatively on every tick instead of a binding: Hyprland
            // client objects change while bindings evaluate, which triggers
            // Qt binding-loop warnings.
            property var target: null
            property var ipc: null

            function sync() {
                const t = root.targetFor(win.screen);
                target = t;
                ipc = t ? t.lastIpcObject : null;
            }

            Component.onCompleted: sync()

            Connections {
                target: root

                function onTick() {
                    win.sync();
                }
            }

            readonly property int chipSize: 15
            readonly property int chipGap: 2
            readonly property int padding: 3
            readonly property int rowW: root.chipCount * chipSize + (root.chipCount - 1) * chipGap + padding * 2
            readonly property int rowH: chipSize + padding * 2

            // Distance from the window's top/right corner.
            readonly property int insetX: 6
            readonly property int insetY: 4

            readonly property real monX: mon ? (mon.x ?? 0) : 0
            readonly property real monY: mon ? (mon.y ?? 0) : 0
            readonly property real monW: (mon && mon.width > 0) ? mon.width : (mon?.lastIpcObject?.width ?? 1920)
            readonly property real monH: (mon && mon.height > 0) ? mon.height : (mon?.lastIpcObject?.height ?? 1080)

            readonly property real winX: (ipc && ipc.at) ? ipc.at[0] - monX : 0
            readonly property real winY: (ipc && ipc.at) ? ipc.at[1] - monY : 0
            readonly property real winW: (ipc && ipc.size) ? ipc.size[0] : 0

            readonly property real posX: Math.round(Math.max(4, Math.min(monW - rowW - 4, winX + winW - rowW - insetX)))
            readonly property real posY: Math.round(Math.max(4, Math.min(monH - rowH - 4, winY + insetY)))

            screen: modelData
            color: "transparent"
            implicitWidth: rowW
            implicitHeight: rowH
            visible: root.enabled && ipc !== null

            surfaceFormat.opaque: false
            WlrLayershell.namespace: "wsnums"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            anchors.top: true
            anchors.left: true
            margins.top: posY
            margins.left: posX

            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: root.tint("surfaceContainerHigh", 0.88)
                border.width: 1
                border.color: root.tint("outlineVariant", 0.55)

                Row {
                    anchors.centerIn: parent
                    spacing: win.chipGap

                    Repeater {
                        model: root.chipCount

                        delegate: Item {
                            id: chip

                            required property int index

                            readonly property int wsId: index + 1
                            readonly property bool current: win.ipc?.workspace?.id === wsId

                            property bool firing: false

                            width: win.chipSize
                            height: win.chipSize
                            scale: firing ? 0.82 : 1

                            Behavior on scale {
                                NumberAnimation {
                                    duration: 110
                                    easing.type: Easing.OutCubic
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: 5
                                color: chip.firing ? root.tint("primary", 1) : chip.current ? root.tint("primary", 0.16) : (mouse.containsMouse ? root.tint("primary", 0.92) : "transparent")
                                border.width: chip.current ? 1 : 0
                                border.color: root.tint("primary", 0.6)

                                Behavior on color {
                                    ColorAnimation {
                                        duration: 120
                                    }
                                }
                            }

                            Text {
                                anchors.centerIn: parent
                                text: chip.wsId
                                color: (chip.firing || mouse.containsMouse) ? root.col("onPrimary") : (chip.current ? root.col("primary") : root.tint("onSurfaceVariant", 0.95))
                                font.pixelSize: 9
                                font.weight: Font.DemiBold
                            }

                            Timer {
                                id: resetTimer

                                interval: 700
                                onTriggered: chip.firing = false
                            }

                            MouseArea {
                                id: mouse

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: chip.current ? Qt.ArrowCursor : Qt.PointingHandCursor
                                onClicked: {
                                    if (chip.current || chip.firing)
                                        return;
                                    chip.firing = true;
                                    root.pending = {
                                        t: win.target,
                                        ws: chip.wsId
                                    };
                                    commitTimer.restart();
                                    resetTimer.restart();
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
