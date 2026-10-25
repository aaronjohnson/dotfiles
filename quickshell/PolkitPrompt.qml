import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Polkit

// ---- Password prompt (polkit agent) ----
// Quickshell is the session's polkit agent (replacing hyprpolkitagent), so pkexec and
// friends ask for the password in the same frame and colours as the other popups.
// There is only ever one prompt: the window shows the agent's current request; a
// second request waits until the first is answered or cancelled, it never stacks.
// Enter submits, Esc cancels; a wrong password shows inline and the field clears.
Scope {
    id: auth
    required property var theme          // root.c from shell.qml

    PolkitAgent { id: agent }

    readonly property var flow: agent.flow

    // "org.freedesktop.policykit.exec" -> "pkexec"; otherwise the last two parts.
    function actionLabel(id) {
        if (!id) return "";
        if (id === "org.freedesktop.policykit.exec") return "pkexec";
        const p = id.split(".");
        return p.slice(-2).join(".");
    }

    LazyLoader {
        active: agent.isActive && auth.flow !== null

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
            WlrLayershell.namespace: "polkit"

            Rectangle {
                anchors.fill: parent
                color: auth.theme.bg
                opacity: 0
                Component.onCompleted: opacity = 0.6
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }

            Rectangle {
                id: panel
                anchors.centerIn: parent
                width: Math.min(parent.width - 80, 620)
                height: body.implicitHeight + 70
                radius: 10
                color: auth.theme.surface
                border.width: 1
                border.color: auth.flow && auth.flow.failed ? auth.theme.red : auth.theme.dim
                opacity: 0
                scale: 0.97
                Component.onCompleted: { opacity = 1; scale = 1; }
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                SciFrame {
                    anchors.fill: parent
                    theme: auth.theme
                    title: "Authenticate"
                    detail: auth.actionLabel(auth.flow ? auth.flow.actionId : "")
                    accent: auth.flow && auth.flow.failed ? auth.theme.red : auth.theme.violet
                    hint: "Enter submit · Esc cancel"
                }

                Column {
                    id: body
                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: 28; topMargin: 34 }
                    spacing: 14

                    Text {
                        width: parent.width
                        text: auth.flow ? auth.flow.message : ""
                        color: auth.theme.fg
                        font.pixelSize: 15
                        wrapMode: Text.Wrap
                    }

                    // Password line
                    Rectangle {
                        width: parent.width
                        height: 40
                        radius: 6
                        color: auth.theme.bg
                        border.width: 1
                        border.color: field.activeFocus ? auth.theme.violet : auth.theme.muted

                        Text {
                            id: label
                            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            text: (auth.flow && auth.flow.inputPrompt ? auth.flow.inputPrompt : "Password:").replace(/:\s*$/, "")
                            color: auth.theme.violet
                            font.pixelSize: 12
                            font.bold: true
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1.5
                        }
                        TextInput {
                            id: field
                            anchors { left: label.right; leftMargin: 14; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            color: auth.theme.fg
                            font.pixelSize: 16
                            font.letterSpacing: 2
                            echoMode: auth.flow && auth.flow.responseVisible ? TextInput.Normal : TextInput.Password
                            passwordCharacter: "●"
                            enabled: auth.flow && auth.flow.isResponseRequired
                            focus: true
                            Component.onCompleted: forceActiveFocus()

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Escape) {
                                    if (auth.flow) auth.flow.cancelAuthenticationRequest();
                                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    if (auth.flow && auth.flow.isResponseRequired) auth.flow.submit(field.text);
                                    field.text = "";
                                } else return;
                                event.accepted = true;
                            }
                        }
                    }

                    // Errors and info from polkit / PAM ("Authentication failure", fingerprint hints)
                    Text {
                        width: parent.width
                        visible: text !== ""
                        text: !auth.flow ? ""
                            : auth.flow.supplementaryMessage ? auth.flow.supplementaryMessage
                            : auth.flow.failed ? "Wrong password, try again." : ""
                        color: auth.flow && (auth.flow.supplementaryIsError || auth.flow.failed) ? auth.theme.red : auth.theme.dim
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                    }

                    Text {
                        width: parent.width
                        text: auth.flow ? auth.flow.actionId : ""
                        color: auth.theme.muted
                        font.family: "monospace"
                        font.pixelSize: 10
                        elide: Text.ElideMiddle
                    }
                }
            }
        }
    }
}
