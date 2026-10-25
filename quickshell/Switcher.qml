import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Widgets

// ---- App switcher (Super+Tab, Super+Shift+Tab, Super+`) ----
// Mac Cmd+Tab habits on Super (the Keychron's Cmd key), leaving Ctrl/Alt to Emacs and
// the terminal. Super+Tab: apps, most recently used first; a quick tap goes back to the
// previous app, holding Super and tapping Tab walks the strip, releasing Super switches.
// Super+Shift+Tab walks backwards. Super+` walks the windows of the current app (Cmd+`).
// Esc cancels, Enter switches. Order comes from Hyprland's focus history.
Scope {
    id: sw
    required property var theme

    property bool open: false
    property string mode: "apps"          // "apps" | "windows"
    property var items: []                // apps: [{ cls, name, icon, windows: [...] }]; windows: [client]
    property int sel: 0
    property int pendingStep: 0           // steps requested before the client list arrived

    function step(n) {
        if (!items.length) return;
        sel = ((sel + n) % items.length + items.length) % items.length;
    }

    // ipc entry points: first press loads the list and opens, later presses step
    function start(m, n) {
        if (open && mode === m) { step(n); return; }
        mode = m; pendingStep = n; items = []; sel = 0;
        clients.running = true;
    }

    function commit() {
        if (!open) return;
        const it = items[sel];
        open = false;
        if (!it) return;
        const addr = mode === "apps" ? it.windows[0].address : it.address;
        Quickshell.execDetached(["hyprctl", "eval", "hl.dispatch(hl.dsp.focus({ window = \"address:" + addr + "\" }))"]);
    }

    function cancel() { open = false; }

    function build(list) {
        list.sort((a, b) => a.focusHistoryID - b.focusHistoryID);   // 0 = focused now
        if (mode === "windows") {
            const cls = list.length ? list[0].class : "";
            items = list.filter(c => c.class === cls);
        } else {
            const byClass = {};
            const order = [];
            for (const c of list) {
                if (!byClass[c.class]) { byClass[c.class] = []; order.push(c.class); }
                byClass[c.class].push(c);
            }
            items = order.map(k => {
                const entry = DesktopEntries.heuristicLookup(k);
                return { cls: k, name: entry ? entry.name : k, icon: entry ? entry.icon : "", windows: byClass[k] };
            });
        }
        sel = 0;
        if (items.length > 1) step(pendingStep);
        open = items.length > 0;
    }

    Process {
        id: clients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = [];
                try { list = JSON.parse(this.text).filter(c => c.mapped && !c.hidden && c.workspace.id > 0); } catch (e) {}
                sw.build(list);
            }
        }
    }

    IpcHandler {
        target: "switcher"
        function next(): void { sw.start("apps", 1); }
        function prev(): void { sw.start("apps", -1); }
        function nextWindow(): void { sw.start("windows", 1); }
        function prevWindow(): void { sw.start("windows", -1); }
        function commit(): void { sw.commit(); }
        function cancel(): void { sw.cancel(); }
    }

    LazyLoader {
        active: sw.open

        PanelWindow {
            screen: {
                const name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
                const screens = Quickshell.screens;
                for (let i = 0; i < screens.length; i++)
                    if (screens[i].name === name) return screens[i];
                return screens[0];
            }
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            WlrLayershell.namespace: "switcher"

            MouseArea { anchors.fill: parent; onClicked: sw.cancel() }

            Rectangle {
                id: panel
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, strip.implicitWidth + 48)
                height: strip.implicitHeight + 64
                radius: 10
                color: sw.theme.surface
                border.width: 1
                border.color: sw.theme.dim

                focus: true
                Component.onCompleted: forceActiveFocus()
                // Super is still held from the Super+Tab that opened us: its release switches.
                Keys.onReleased: event => {
                    if (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta) {
                        sw.commit(); event.accepted = true;
                    }
                }
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) sw.cancel();
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) sw.commit();
                    else if (event.key === Qt.Key_Backtab) sw.step(-1);
                    else if (event.key === Qt.Key_Tab) sw.step((event.modifiers & Qt.ShiftModifier) ? -1 : 1);
                    else if (event.key === Qt.Key_Left) sw.step(-1);
                    else if (event.key === Qt.Key_Right) sw.step(1);
                    else return;
                    event.accepted = true;
                }

                SciFrame {
                    anchors.fill: parent
                    theme: sw.theme
                    title: sw.mode === "apps" ? "Apps" : "Windows"
                    detail: sw.mode === "apps" ? "Super+Tab" : "Super+`"
                    hint: "release Super to switch · Esc cancel"
                    tabInset: 20
                }

                Row {
                    id: strip
                    anchors { centerIn: parent; verticalCenterOffset: 4 }
                    spacing: 10

                    Repeater {
                        model: sw.items
                        Rectangle {
                            required property var modelData
                            required property int index
                            readonly property bool current: index === sw.sel
                            width: sw.mode === "apps" ? 128 : 260
                            height: sw.mode === "apps" ? 128 : 72
                            radius: 8
                            color: current ? sw.theme.bg : "transparent"
                            border.width: current ? 2 : 1
                            border.color: current ? sw.theme.violet : "transparent"

                            // apps: icon, name, window count
                            Column {
                                visible: sw.mode === "apps"
                                anchors.centerIn: parent
                                spacing: 6
                                Item {
                                    width: 64; height: 64
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    IconImage {
                                        anchors.fill: parent
                                        source: modelData.icon ? Quickshell.iconPath(modelData.icon, true) : ""
                                        visible: source != ""
                                    }
                                    Rectangle {               // no icon: a lettered tile
                                        anchors.fill: parent
                                        visible: !modelData.icon
                                        radius: 10
                                        color: sw.theme.violet
                                        Text {
                                            anchors.centerIn: parent
                                            text: (modelData.name || "?").charAt(0).toUpperCase()
                                            color: sw.theme.surface
                                            font.pixelSize: 30; font.bold: true
                                        }
                                    }
                                }
                                Text {
                                    width: 116
                                    horizontalAlignment: Text.AlignHCenter
                                    text: modelData.name + (modelData.windows && modelData.windows.length > 1 ? "  ×" + modelData.windows.length : "")
                                    color: parent.parent.current ? sw.theme.violet : sw.theme.fg
                                    font.pixelSize: 12; font.bold: parent.parent.current
                                    elide: Text.ElideRight
                                }
                            }

                            // windows: title and workspace
                            Column {
                                visible: sw.mode === "windows"
                                anchors { fill: parent; margins: 10 }
                                spacing: 4
                                Text {
                                    width: parent.width
                                    text: modelData.title || ""
                                    color: parent.parent.current ? sw.theme.violet : sw.theme.fg
                                    font.pixelSize: 13; font.bold: parent.parent.current
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: modelData.workspace ? "workspace " + modelData.workspace.name : ""
                                    color: sw.theme.muted
                                    font.pixelSize: 11
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: { sw.sel = index; sw.commit(); }
                            }
                        }
                    }
                }
            }
        }
    }
}
