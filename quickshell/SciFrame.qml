import QtQuick

// ---- Sci-fi frame for popup panels ----
// Put inside a panel Rectangle with `anchors.fill: parent`. Draws, around the panel:
//  - a title tab straddling the top border (half in, half out), reversed colours,
//    bold spaced capitals, a small status light and an optional detail field;
//  - an optional hint tab on the bottom border;
//  - corner brackets just outside the corners and tick marks along the top edge.
// Colours come from the shell theme (root.c), so it follows light/dark mode.
Item {
    id: frame
    required property var theme
    property string title: ""
    property string detail: ""           // e.g. the shortcut that opened the panel
    property string hint: ""             // bottom tab; empty hides it
    property color accent: theme.violet
    property int tabInset: 28            // distance of the title tab from the left edge

    readonly property int tabH: 28
    z: 10

    // Title tab
    Rectangle {
        id: tab
        x: frame.tabInset
        y: -height / 2
        height: frame.tabH
        width: tabRow.width + 28
        radius: 6
        color: frame.theme.fg
        border.width: 1
        border.color: frame.theme.dim

        Row {
            id: tabRow
            anchors.centerIn: parent
            spacing: 10

            Rectangle {                       // status light
                anchors.verticalCenter: parent.verticalCenter
                width: 9; height: 9; radius: 2
                color: frame.accent
                border.width: 1                  // keeps it visible on the slate (light mode) tab
                border.color: frame.theme.bg
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutSine }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: frame.title
                color: frame.theme.bg
                font.pixelSize: 13
                font.bold: true
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 2.5
            }
            Rectangle {                       // divider
                visible: frame.detail !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: 1; height: 14
                color: frame.theme.bg
                opacity: 0.5
            }
            Text {
                visible: frame.detail !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: frame.detail
                color: frame.theme.bg
                opacity: 0.8
                font.family: "monospace"
                font.pixelSize: 11
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 1
            }
        }
    }

    // Hint tab, bottom right, quieter than the title
    Rectangle {
        visible: frame.hint !== ""
        anchors.right: parent.right
        anchors.rightMargin: frame.tabInset
        y: parent.height - height / 2
        height: 22
        width: hintText.width + 22
        radius: 5
        color: frame.theme.surface
        border.width: 1
        border.color: frame.theme.muted

        Text {
            id: hintText
            anchors.centerIn: parent
            text: frame.hint
            color: frame.theme.dim
            font.family: "monospace"
            font.pixelSize: 10
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 1
        }
    }

    // Tick marks along the top edge, right of centre
    Row {
        x: parent.width - width - frame.tabInset - 4
        y: -4
        spacing: 6
        Repeater {
            model: 5
            Rectangle {
                required property int index
                width: 2
                height: index === 4 ? 9 : 5
                y: 4 - height / 2
                color: frame.accent
                opacity: 0.4 + index * 0.12
            }
        }
    }

    // Corner brackets, just outside each corner
    Repeater {
        model: [[0, 0], [1, 0], [0, 1], [1, 1]]
        Item {
            required property var modelData
            readonly property int len: 18
            readonly property int gap: 6
            width: len; height: len
            x: modelData[0] ? frame.width + gap - len : -gap
            y: modelData[1] ? frame.height + gap - len : -gap

            Rectangle {   // horizontal arm
                width: parent.len; height: 2
                y: modelData[1] ? parent.len - 2 : 0
                color: frame.accent
            }
            Rectangle {   // vertical arm
                width: 2; height: parent.len
                x: modelData[0] ? parent.len - 2 : 0
                color: frame.accent
            }
        }
    }
}
