import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

// ---- Where you landed: a brief card on each workspace change ----
// Centred, gone after a moment. One tile per open workspace on this monitor: its number,
// a square per window, the title of its first window; the one you're on is lit, and the
// line above it names the window with the focus. Takes no keyboard focus and no clicks,
// so typing and clicking carry straight on through it. Exists only while it's showing.
Scope {
    id: pop
    required property var theme

    property bool showing: false
    property bool armed: false            // not on the first focus after a (re)load

    readonly property var here: Hyprland.focusedWorkspace
    readonly property var tiles: {
        const mon = Hyprland.focusedMonitor;
        return Hyprland.workspaces.values.filter(w => w.id > 0 && w.monitor === mon)
            .sort((a, b) => a.id - b.id);
    }

    Timer { interval: 1500; running: true; onTriggered: pop.armed = true }
    Timer { id: hold; interval: 1400; onTriggered: pop.showing = false }

    Connections {
        target: Hyprland
        function onFocusedWorkspaceChanged() {
            if (!pop.armed || !pop.here || pop.here.id < 0) return;
            pop.showing = true;
            hold.restart();
        }
    }

    LazyLoader {
        active: pop.showing

        PanelWindow {
            id: win
            screen: {
                const name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
                const screens = Quickshell.screens;
                for (let i = 0; i < screens.length; i++)
                    if (screens[i].name === name) return screens[i];
                return screens[0];
            }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "workspace-popup"
            mask: Region {}                   // clicks go through
            implicitWidth: card.width + 16
            implicitHeight: card.height + 16

            // the tiles share the screen if there are many
            readonly property real tileW: Math.min(170, (screen.width - 160) / Math.max(1, pop.tiles.length) - 8)

            Rectangle {
                id: card
                anchors.centerIn: parent
                width: Math.max(tileRow.implicitWidth, 260) + 32
                height: cardCol.implicitHeight + 28
                radius: 10
                color: pop.theme.surface
                border.width: 1
                border.color: pop.theme.dim
                opacity: 0
                Component.onCompleted: opacity = 1
                Behavior on opacity { NumberAnimation { duration: 90 } }

                Column {
                    id: cardCol
                    anchors.centerIn: parent
                    spacing: 10

                    Text {
                        width: card.width - 32
                        horizontalAlignment: Text.AlignHCenter
                        text: {
                            const t = Hyprland.activeToplevel;
                            return t && t.workspace === pop.here ? t.title : "No windows here";
                        }
                        color: pop.theme.fg
                        font.pixelSize: 15; font.bold: true
                        elide: Text.ElideRight
                    }

                    Row {
                        id: tileRow
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 8
                        Repeater {
                            model: pop.tiles
                            Rectangle {
                                required property var modelData
                                readonly property var windows: modelData.toplevels.values
                                readonly property bool current: modelData === pop.here
                                width: win.tileW
                                height: 76
                                radius: 8
                                color: current ? pop.theme.bg : "transparent"
                                border.width: current ? 2 : 1
                                border.color: current ? pop.theme.violet : pop.theme.muted

                                Column {
                                    anchors { fill: parent; margins: 8 }
                                    spacing: 5
                                    Row {
                                        spacing: 8
                                        Text {
                                            text: modelData.name
                                            color: current ? pop.theme.violet : pop.theme.dim
                                            font.family: "monospace"
                                            font.pixelSize: 16; font.bold: true
                                        }
                                        Row {       // a square per window
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 3
                                            Repeater {
                                                model: Math.min(windows.length, 8)
                                                Rectangle {
                                                    width: 8; height: 8; radius: 2
                                                    color: current ? pop.theme.cyan : pop.theme.muted
                                                }
                                            }
                                        }
                                    }
                                    Text {
                                        width: parent.width
                                        text: windows.length ? windows[0].title : ""
                                        color: current ? pop.theme.fg : pop.theme.dim
                                        font.pixelSize: 11
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
