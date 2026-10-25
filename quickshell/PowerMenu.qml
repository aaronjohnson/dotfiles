import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland

// ---- Power menu ----
// Holding the power button opens this on the focused screen (~/dotfiles/bin/power-button);
// `qs ipc call powermenu open` does the same. Arrow keys, Tab or the mouse pick a tile;
// Enter, Space or a click runs it; 1-5 jump straight to one; Esc or a click
// outside closes. Hibernate, reboot and power off ask for a second press first.
// The window only exists while the menu is open, so a closed menu costs nothing.
Scope {
    id: menu
    required property var theme          // root.c from shell.qml

    property bool open: false
    property int selected: 0
    property int armed: -1               // tile waiting for its confirming second press

    readonly property var actions: [
        { glyph: "⏾", label: "Sleep",       cmd: ["systemctl", "suspend-then-hibernate"], confirm: false },
        { glyph: "◐", label: "Screensaver", cmd: ["loginctl", "lock-session"],             confirm: false },
        { glyph: "❄", label: "Hibernate",   cmd: ["systemctl", "hibernate"],               confirm: true },
        { glyph: "↻", label: "Reboot",      cmd: ["systemctl", "reboot"],                  confirm: true },
        { glyph: "⏻", label: "Power off",   cmd: ["systemctl", "poweroff"],                confirm: true }
    ]

    function show() {
        selected = 0;
        armed = -1;
        open = true;
    }

    function hide() {
        open = false;
        armed = -1;
    }

    function activate(i) {
        selected = i;
        const a = actions[i];
        if (a.confirm && armed !== i) {
            armed = i;
            return;
        }
        hide();
        Quickshell.execDetached(a.cmd);
    }

    function move(step) {
        selected = (selected + step + actions.length) % actions.length;
        armed = -1;
    }

    // The screen Hyprland has focused, so the menu shows where you're looking.
    function focusedScreen() {
        const name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; i++)
            if (screens[i].name === name)
                return screens[i];
        return screens[0];
    }

    IpcHandler {
        target: "powermenu"
        function open(): void { menu.show(); }
        function close(): void { menu.hide(); }
        function toggle(): void { if (menu.open) menu.hide(); else menu.show(); }
    }

    // An armed tile disarms after 4 s, and a menu left alone closes after 30 s,
    // so a stray press never leaves it waiting.
    Timer {
        interval: 4000
        running: menu.armed >= 0
        onTriggered: menu.armed = -1
    }
    Timer {
        id: idleTimer
        interval: 30000
        running: menu.open
        onTriggered: menu.hide()
    }

    LazyLoader {
        active: menu.open

        PanelWindow {
            screen: menu.focusedScreen()
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            WlrLayershell.namespace: "powermenu"

            Rectangle {
                id: scrim
                anchors.fill: parent
                color: menu.theme.bg
                opacity: 0
                Component.onCompleted: opacity = 0.9
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                MouseArea {
                    anchors.fill: parent
                    onClicked: menu.hide()
                }
            }

            Item {
                id: keys
                anchors.fill: parent
                focus: true
                Component.onCompleted: forceActiveFocus()

                Keys.onPressed: event => {
                    idleTimer.restart();
                    const k = event.key;
                    if (k === Qt.Key_Escape) menu.hide();
                    else if (k === Qt.Key_Left || k === Qt.Key_H || k === Qt.Key_Backtab) menu.move(-1);
                    else if (k === Qt.Key_Right || k === Qt.Key_L || k === Qt.Key_Tab) menu.move(1);
                    else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) menu.activate(menu.selected);
                    else if (k >= Qt.Key_1 && k < Qt.Key_1 + menu.actions.length) menu.activate(k - Qt.Key_1);
                    else return;
                    event.accepted = true;
                }

                Row {
                    id: tiles
                    anchors.centerIn: parent
                    spacing: 18
                    scale: 0.92
                    opacity: 0
                    Component.onCompleted: { scale = 1; opacity = 1; }
                    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
                    Behavior on opacity { NumberAnimation { duration: 120 } }

                    Repeater {
                        model: menu.actions

                        Rectangle {
                            id: tile
                            required property var modelData
                            required property int index
                            readonly property bool current: menu.selected === index
                            readonly property bool isArmed: menu.armed === index
                            readonly property color accent: isArmed ? menu.theme.red
                                                          : modelData.confirm ? menu.theme.orange
                                                          : menu.theme.violet

                            width: 132
                            height: 148
                            radius: 18
                            color: menu.theme.surface
                            border.width: current ? 2 : 1
                            border.color: current ? accent : menu.theme.muted
                            scale: current ? 1.06 : 1
                            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Behavior on border.color { ColorAnimation { duration: 120 } }

                            Column {
                                anchors.centerIn: parent
                                spacing: 10

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: tile.modelData.glyph
                                    color: tile.current ? tile.accent : menu.theme.fg
                                    font.pixelSize: 46
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: tile.isArmed ? "again to confirm" : tile.modelData.label
                                    color: tile.isArmed ? menu.theme.red : menu.theme.fg
                                    font.pixelSize: tile.isArmed ? 11 : 14
                                    font.bold: tile.current
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: tile.index + 1
                                    color: menu.theme.muted
                                    font.pixelSize: 10
                                    font.family: "monospace"
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: { if (menu.selected !== tile.index) { menu.selected = tile.index; menu.armed = -1; } idleTimer.restart(); }
                                onClicked: menu.activate(tile.index)
                            }
                        }
                    }
                }
            }
        }
    }
}
