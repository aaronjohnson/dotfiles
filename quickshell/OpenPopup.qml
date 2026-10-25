import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland

// ---- Open a link (Super+O) ----
// Type or paste a URL, a bare host, or words to search; Enter opens it through
// bin/open-url (a new tab in Epiphany, browser focused) and the popup closes, so no
// terminal is left behind. A URL already on the clipboard is filled in. Below: pinned
// sites (~/.config/open-url/pinned.txt, kept out of the repo), most-visited hosts and the browser's recent
// pages, from Epiphany's history. Typing filters all three; Up/Down pick, Enter opens
// the pick (or the typed text when nothing is picked), Esc closes.
Scope {
    id: op
    required property var theme

    property bool open: false
    property var data: ({ pinned: [], hosts: [], recent: [] })
    property string query: ""
    property int sel: -1                  // index into `choices`; -1 = the typed text

    readonly property string tool: Quickshell.env("HOME") + "/dotfiles/bin/open-url"

    function matches(...texts) {
        const q = query.toLowerCase();
        return q === "" || texts.some(t => (t || "").toLowerCase().indexOf(q) >= 0);
    }
    // rows that fit in a column (set by the panel); lists are cut to it so the keyboard
    // never walks onto a row that isn't drawn
    property int fit: 16
    readonly property var pinned: data.pinned.filter(p => matches(p.label, p.url)).slice(0, fit)
    // top pages fill the rest of the first column, under the pinned sites and a heading
    readonly property var top: (data.top || []).filter(t => matches(t.title, t.url))
        .slice(0, Math.max(0, fit - pinned.length - 2))
    readonly property var hosts: data.hosts.filter(h => matches(h.host, h.title)).slice(0, fit)
    readonly property var recent: data.recent.filter(r => matches(r.title, r.url)).slice(0, fit)
    // one list for Up/Down, in screen order: pinned, top pages, hosts, recent
    readonly property var choices: pinned.map(p => p.url)
        .concat(top.map(t => t.url))
        .concat(hosts.map(h => h.url))
        .concat(recent.map(r => r.url))

    function show() {
        query = ""; sel = -1;
        listProc.running = true;
        clip.running = true;
        open = true;
    }
    function hide() { open = false; }

    function go(target) {
        const t = (target || "").trim();
        if (!t) return;
        hide();
        Quickshell.execDetached([tool, t]);
    }
    function enter() { go(sel >= 0 ? choices[sel] : query); }
    function move(n) {
        const len = choices.length;
        if (!len) return;
        sel = sel < 0 ? (n > 0 ? 0 : len - 1) : Math.max(-1, Math.min(len - 1, sel + n));
    }

    Process {
        id: listProc
        command: [op.tool, "--list"]
        stdout: StdioCollector {
            onStreamFinished: { try { op.data = JSON.parse(this.text); } catch (e) {} }
        }
    }

    // A URL on the clipboard becomes the starting text (selected, so typing replaces it).
    Process {
        id: clip
        command: ["wl-paste", "--no-newline", "--type", "text"]
        property string got: ""
        stdout: StdioCollector {
            onStreamFinished: {
                const t = this.text.trim();
                if (/^(https?:\/\/|www\.)\S+$/.test(t) && op.query === "") op.query = t;
            }
        }
    }

    IpcHandler {
        target: "open"
        function open(): void { op.show(); }
        function close(): void { op.hide(); }
        function toggle(): void { if (op.open) op.hide(); else op.show(); }
    }

    component Section: Text {
        color: op.theme.violet
        font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.5
    }

    // a pickable row: index into op.choices, so keyboard and mouse agree
    component Pick: Rectangle {
        id: pick
        property int choice: 0
        property string main: ""
        property string side: ""
        property color mainColor: op.theme.fg
        readonly property bool current: op.sel === choice
        width: parent ? parent.width : 0
        height: 24
        radius: 5
        color: current ? op.theme.bg : (ma.containsMouse ? Qt.alpha(op.theme.bg, 0.5) : "transparent")
        border.width: current ? 1 : 0
        border.color: op.theme.violet
        Text {
            anchors { left: parent.left; leftMargin: 8; right: sideText.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
            text: pick.main
            color: pick.current ? op.theme.violet : pick.mainColor
            font.pixelSize: 13; font.bold: pick.current
            elide: Text.ElideRight
        }
        Text {
            id: sideText
            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
            text: pick.side
            color: op.theme.muted
            font.pixelSize: 11
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            onClicked: op.go(op.choices[pick.choice])
        }
    }

    LazyLoader {
        active: op.open

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
            WlrLayershell.namespace: "open-url"

            Rectangle {
                anchors.fill: parent
                color: op.theme.bg
                opacity: 0
                Component.onCompleted: opacity = 0.5
                Behavior on opacity { NumberAnimation { duration: 120 } }
                MouseArea { anchors.fill: parent; onClicked: op.hide() }
            }

            Rectangle {
                id: panel
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, 1180)
                height: Math.min(parent.height - 80, 640)
                radius: 10
                color: op.theme.surface
                border.width: 1
                border.color: op.theme.dim
                MouseArea { anchors.fill: parent }

                SciFrame {
                    anchors.fill: parent
                    theme: op.theme
                    title: "Open"
                    detail: "Super+O"
                    hint: "Enter open · ↑↓ pick · Esc close · words search"
                }

                // input line
                Rectangle {
                    id: inputBox
                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: 22; topMargin: 32 }
                    height: 42
                    radius: 6
                    color: op.theme.bg
                    border.width: 1
                    border.color: op.sel < 0 ? op.theme.violet : op.theme.muted

                    Text {
                        id: arrow
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        text: "↗"
                        color: op.theme.violet
                        font.pixelSize: 18
                    }
                    TextInput {
                        id: input
                        anchors { left: arrow.right; leftMargin: 10; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: op.query
                        color: op.theme.fg
                        font.pixelSize: 17
                        clip: true
                        focus: true
                        Component.onCompleted: forceActiveFocus()
                        onTextChanged: { if (text !== op.query) { op.query = text; op.sel = -1; } }
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) op.hide();
                            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) op.enter();
                            else if (event.key === Qt.Key_Down || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) op.move(1);
                            else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) op.move(-1);
                            else return;
                            event.accepted = true;
                        }
                        Text {
                            visible: !input.text
                            text: "URL, host, or words to search"
                            color: op.theme.muted
                            font.pixelSize: 17
                        }
                    }
                }

                // three columns: pinned | hosts | recent pages
                Row {
                    id: cols
                    anchors { top: inputBox.bottom; topMargin: 16; bottom: parent.bottom; bottomMargin: 26; left: parent.left; right: parent.right; leftMargin: 22; rightMargin: 22 }
                    spacing: 18
                    readonly property real narrow: (width - 2 * spacing) * 0.22
                    readonly property real wide: width - 2 * spacing - 2 * narrow
                    onHeightChanged: op.fit = Math.max(1, Math.floor((height - 20) / 27))
                    Component.onCompleted: op.fit = Math.max(1, Math.floor((height - 20) / 27))

                    Column {
                        width: cols.narrow
                        spacing: 3
                        Section { text: "PINNED" }
                        Repeater {
                            model: op.pinned
                            Pick {
                                required property var modelData
                                required property int index
                                choice: index
                                main: modelData.label
                                mainColor: op.theme.cyan
                            }
                        }
                        Section { visible: op.top.length > 0; topPadding: 10; text: "TOP PAGES" }
                        Repeater {
                            model: op.top
                            Pick {
                                required property var modelData
                                required property int index
                                choice: op.pinned.length + index
                                main: modelData.title
                                side: modelData.count
                            }
                        }
                    }

                    Column {
                        width: cols.narrow
                        spacing: 3
                        Section { text: "MOST VISITED" }
                        Repeater {
                            model: op.hosts
                            Pick {
                                required property var modelData
                                required property int index
                                choice: op.pinned.length + op.top.length + index
                                main: modelData.host
                                side: modelData.count
                            }
                        }
                    }

                    Column {
                        width: cols.wide
                        spacing: 3
                        Section { text: "RECENT · FROM THE BROWSER" }
                        Repeater {
                            model: op.recent
                            Pick {
                                required property var modelData
                                required property int index
                                choice: op.pinned.length + op.top.length + op.hosts.length + index
                                main: (modelData.title || modelData.url) + "   " + modelData.host
                                side: modelData.ago
                            }
                        }
                    }
                }
            }
        }
    }
}
