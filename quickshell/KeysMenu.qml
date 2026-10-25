import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland

// ---- Keys menu (Super+F2) ----
// Left: every shortcut that has a description in hypr/hyprland.lua, read live from
// `hyprctl binds -j` each time the menu opens, so it never goes stale. A description
// reads "Section: what it does"; binds sharing a description show as one row.
// Right: Hyprland window commands, run on the window that had focus when the menu
// opened. Type to filter both; Up/Down pick a command, Enter or a click runs it;
// Esc or a click outside closes. The window only exists while open.
Scope {
    id: keys
    required property var theme          // root.c from shell.qml

    property bool open: false
    property var sections: []            // [{ name, items: [{ keys, label }] }]
    property string query: ""
    property int selected: 0
    property string target: ""           // title of the window the commands act on

    readonly property var sectionOrder: ["Ours", "Windows", "Workspaces", "Apps", "Media", "Session"]

    // Each runs as `hyprctl eval "hl.dispatch(<lua>)"` once the menu has closed.
    readonly property var commands: [
        { label: "Close",                     lua: 'hl.dsp.window.close()' },
        { label: "Float / tile",              lua: 'hl.dsp.window.float({ action = "toggle" })' },
        { label: "Fullscreen",                lua: 'hl.dsp.window.fullscreen()' },
        { label: "Maximise",                  lua: 'hl.dsp.window.fullscreen({ mode = "maximized" })' },
        { label: "Centre (floating)",         lua: 'hl.dsp.window.center()' },
        { label: "Pin on every workspace (floating)", lua: 'hl.dsp.window.pin()' },
        { label: "Pseudo-tile",               lua: 'hl.dsp.window.pseudo()' },
        { label: "Flip split direction",      lua: 'hl.dsp.layout("togglesplit")' },
        { label: "Group / ungroup",           lua: 'hl.dsp.group.toggle()' },
        { label: "Move to next workspace",    lua: 'hl.dsp.window.move({ workspace = "r+1" })' },
        { label: "Move to previous workspace", lua: 'hl.dsp.window.move({ workspace = "r-1" })' },
        { label: "Move to scratchpad",        lua: 'hl.dsp.window.move({ workspace = "special:magic" })' },
        { label: "Force kill",                lua: 'hl.dsp.window.kill()' }
    ]

    function matches(text) {
        return query === "" || text.toLowerCase().indexOf(query.toLowerCase()) >= 0;
    }
    readonly property var shownCommands: commands.filter(c => matches(c.label))
    readonly property var shownSections: sections
        .map(s => ({ name: s.name, items: s.items.filter(i => matches(i.label) || matches(i.keys) || matches(s.name)) }))
        .filter(s => s.items.length > 0)

    function show() {
        query = "";
        selected = 0;
        target = Hyprland.activeToplevel ? Hyprland.activeToplevel.title : "";
        bindsProc.running = true;
        open = true;
    }

    function hide() { open = false; }

    function run(i) {
        const c = shownCommands[i];
        if (!c) return;
        hide();
        pending = c.lua;
        runTimer.restart();
    }

    // Give focus back to the window before acting on it.
    property string pending: ""
    Timer {
        id: runTimer
        interval: 60
        onTriggered: Quickshell.execDetached(["hyprctl", "eval", "hl.dispatch(" + keys.pending + ")"])
    }

    // ---- Turning `hyprctl binds -j` into rows ----
    readonly property var modNames: [[64, "Super"], [4, "Ctrl"], [8, "Alt"], [1, "Shift"]]
    readonly property var keyNames: ({
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "mouse:272": "left drag", "mouse:273": "right drag",
        "mouse_down": "scroll", "mouse_up": "scroll",
        "XF86AudioRaiseVolume": "Vol+", "XF86AudioLowerVolume": "Vol−",
        "XF86AudioMute": "Mute", "XF86AudioMicMute": "Mic mute",
        "XF86MonBrightnessUp": "Bright+", "XF86MonBrightnessDown": "Bright−",
        "XF86AudioNext": "Next", "XF86AudioPrev": "Prev",
        "XF86AudioPlay": "Play", "XF86AudioPause": "Pause",
        "XF86PowerOff": "Power button"
    })

    function mods(mask) {
        return modNames.filter(m => mask & m[0]).map(m => m[1]);
    }

    // Binds sharing a description become one row: "Super + ← → ↑ ↓",
    // "Super + 1…0", or "Vol+ / Vol−" when the modifiers differ too.
    function keysText(binds) {
        const groups = [];
        for (const b of binds) {
            const m = mods(b.modmask).join(" + ");
            const k = keyNames[b.key] || b.key;
            let g = groups.find(x => x.mods === m);
            if (!g) groups.push(g = { mods: m, keys: [] });
            if (g.keys.indexOf(k) < 0) g.keys.push(k);
        }
        return groups.map(g => {
            const digits = g.keys.length > 2 && g.keys.every(k => /^[0-9]$/.test(k));
            const ks = digits ? g.keys[0] + "…" + g.keys[g.keys.length - 1] : g.keys.join(" ");
            return g.mods ? g.mods + " + " + ks : ks;
        }).join("  /  ");
    }

    function parse(text) {
        let binds;
        try { binds = JSON.parse(text); } catch (e) { return; }
        const byDesc = {};
        const order = [];
        for (const b of binds) {
            if (!b.description) continue;
            if (!byDesc[b.description]) { byDesc[b.description] = []; order.push(b.description); }
            byDesc[b.description].push(b);
        }
        const secs = {};
        for (const d of order) {
            const cut = d.indexOf(": ");
            const name = cut > 0 ? d.slice(0, cut) : "Other";
            const label = cut > 0 ? d.slice(cut + 2) : d;
            (secs[name] = secs[name] || []).push({ keys: keysText(byDesc[d]), label: label });
        }
        const names = Object.keys(secs).sort((a, b) => {
            const ia = sectionOrder.indexOf(a), ib = sectionOrder.indexOf(b);
            return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
        });
        sections = names.map(n => ({ name: n, items: secs[n] }));
    }

    Process {
        id: bindsProc
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: keys.parse(this.text)
        }
    }

    IpcHandler {
        target: "keys"
        function open(): void { keys.show(); }
        function close(): void { keys.hide(); }
        function toggle(): void { if (keys.open) keys.hide(); else keys.show(); }
    }

    LazyLoader {
        active: keys.open

        PanelWindow {
            id: win
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
            WlrLayershell.namespace: "keysmenu"

            Rectangle {
                anchors.fill: parent
                color: keys.theme.bg
                opacity: 0
                Component.onCompleted: opacity = 0.6
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                MouseArea { anchors.fill: parent; onClicked: keys.hide() }
            }

            Rectangle {
                id: panel
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, 1100)
                height: Math.min(parent.height - 80, 720)
                radius: 10
                color: keys.theme.surface
                border.width: 1
                border.color: keys.theme.dim
                opacity: 0
                scale: 0.97
                Component.onCompleted: { opacity = 1; scale = 1; }
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                MouseArea { anchors.fill: parent }   // clicks inside don't close

                SciFrame {
                    anchors.fill: parent
                    theme: keys.theme
                    title: "Shortcuts"
                    detail: "Super+F2"
                    hint: "↑↓ pick · Enter run · Esc close"
                }

                // Search line (starts below the title tab's lower half)
                Item {
                    id: header
                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: 22; topMargin: 30 }
                    height: 34

                    Text {
                        id: prompt
                        anchors.verticalCenter: parent.verticalCenter
                        text: "⌕"
                        color: keys.theme.violet
                        font.pixelSize: 20
                    }
                    TextInput {
                        id: search
                        anchors { left: prompt.right; leftMargin: 10; right: parent.right; verticalCenter: parent.verticalCenter }
                        color: keys.theme.fg
                        font.pixelSize: 16
                        focus: true
                        Component.onCompleted: forceActiveFocus()
                        onTextChanged: { keys.query = text; keys.selected = 0; }

                        Text {
                            visible: !search.text
                            text: "Type to filter shortcuts and window commands"
                            color: keys.theme.muted
                            font.pixelSize: 16
                        }

                        Keys.onPressed: event => {
                            const n = keys.shownCommands.length;
                            if (event.key === Qt.Key_Escape) keys.hide();
                            else if (event.key === Qt.Key_Down && n) keys.selected = (keys.selected + 1) % n;
                            else if (event.key === Qt.Key_Up && n) keys.selected = (keys.selected - 1 + n) % n;
                            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) keys.run(keys.selected);
                            else return;
                            event.accepted = true;
                        }
                    }
                }

                Rectangle {
                    id: rule
                    anchors { top: header.bottom; topMargin: 12; left: parent.left; right: parent.right }
                    height: 1
                    color: keys.theme.muted
                    opacity: 0.4
                }

                // Shortcuts, by section
                Flickable {
                    id: list
                    anchors { top: rule.bottom; bottom: parent.bottom; left: parent.left; right: side.left; margins: 22 }
                    contentHeight: column.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: column
                        width: list.width
                        spacing: 16

                        Repeater {
                            model: keys.shownSections

                            Column {
                                required property var modelData
                                width: column.width
                                spacing: 5

                                Text {
                                    text: modelData.name
                                    color: modelData.name === "Ours" ? keys.theme.violet : keys.theme.cyan
                                    font.pixelSize: 12
                                    font.bold: true
                                    font.capitalization: Font.AllUppercase
                                    font.letterSpacing: 1.5
                                }

                                Repeater {
                                    model: modelData.items

                                    Row {
                                        required property var modelData
                                        spacing: 14

                                        Text {
                                            width: 260
                                            text: modelData.keys
                                            color: keys.theme.yellow
                                            font.family: "monospace"
                                            font.pixelSize: 13
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            width: column.width - 274
                                            text: modelData.label
                                            color: keys.theme.fg
                                            font.pixelSize: 13
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: keys.shownSections.length === 0
                            text: keys.sections.length ? "No shortcut matches." : "Reading shortcuts…"
                            color: keys.theme.muted
                            font.pixelSize: 13
                        }
                    }
                }

                // Window commands
                Rectangle {
                    id: side
                    anchors { top: rule.bottom; bottom: parent.bottom; right: parent.right; margins: 14 }
                    width: 330
                    radius: 12
                    color: keys.theme.bg
                    opacity: 0.9

                    Column {
                        anchors { fill: parent; margins: 14 }
                        spacing: 3

                        Text {
                            text: "Window"
                            color: keys.theme.violet
                            font.pixelSize: 12
                            font.bold: true
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1.5
                        }
                        Text {
                            width: parent.width
                            text: keys.target || "no window focused"
                            color: keys.theme.muted
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            bottomPadding: 8
                        }

                        Repeater {
                            model: keys.shownCommands

                            Rectangle {
                                required property var modelData
                                required property int index
                                readonly property bool current: keys.selected === index
                                width: parent.width
                                height: 28
                                radius: 7
                                color: current ? keys.theme.surface : "transparent"
                                border.width: current ? 1 : 0
                                border.color: keys.theme.violet

                                Text {
                                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                                    text: modelData.label
                                    color: modelData.label === "Force kill" ? keys.theme.red
                                         : current ? keys.theme.violet : keys.theme.fg
                                    font.pixelSize: 13
                                    font.bold: current
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onPositionChanged: keys.selected = index   // a pointer resting where the menu opens selects nothing
                                    onClicked: keys.run(index)
                                }
                            }
                        }

                        Text {
                            visible: keys.shownCommands.length === 0
                            text: "No command matches."
                            color: keys.theme.muted
                            font.pixelSize: 13
                        }
                    }
                }
            }
        }
    }
}
