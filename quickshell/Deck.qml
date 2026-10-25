import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland

// ---- Land / ship deck (Super+F12, Super+F11) ----
// One tile per repo with something going on (bin/deck-status), each with chips for
// what can happen next: Commit the drafted message, Push, Bump ~/nixos to a flake
// input, Ship a .ship target, Discard a stale draft. A click is the "yes": the chip runs
// `land …` / `ship target …` with LAND_YES=1 and the tile shows its progress. The top
// strip shows the running system and offers Switch when ~/nixos would change it (the
// password through PolkitPrompt). One action at a time. The terminal versions stay on
// Super+Shift+F12 / Super+Shift+F11. Esc closes, R refreshes.
Scope {
    id: deck
    required property var theme

    property bool open: false
    property var data: ({ system: {}, repos: [], timeline: [] })
    property bool loading: false

    // switch check: "checking" | "differs" | "same" | "broken" | ""
    property string switchState: ""

    // the running action
    property string busyRepo: ""          // repo path, or "system"
    property string busyLabel: ""
    property string busyLine: ""
    // last result per repo path: { ok, label, line }
    property var results: ({})

    readonly property string home: Quickshell.env("HOME")
    readonly property string land: home + "/dotfiles/bin/land"
    readonly property string ship: home + "/dotfiles/bin/ship"

    // While loading, chips stay disabled: right after an action the tiles still show the
    // old state (e.g. Commit on a draft that's already committed) until the refresh lands.
    readonly property bool idle: busyRepo === "" && !loading
    property string needsLogin: ""     // set when a run stopped for a re-login; shown in the top tab
    property string loginCmd: ""       // the command that logs in again (bin/reauth runs it)
    function logIn() {
        Quickshell.execDetached([home + "/dotfiles/bin/reauth", loginCmd]);
        needsLogin = ""; loginCmd = "";
        hide();                          // the login window reopens the deck when it's done
    }
    function refresh() { loading = true; statusProc.running = true; }
    function checkSwitch() { switchState = "checking"; switchProc.running = true; }
    function show() { open = true; skipped = ({}); refresh(); checkSwitch(); }

    // ---- y/N, like the terminal land: the next step, in land's order ----
    // Commit each drafted repo (~/nixos last), push / push + bump, switch, push ~/nixos,
    // then ship. y or Enter runs it, n or Space skips it for this opening, Esc closes.
    property var skipped: ({})
    readonly property string nixosPath: home + "/nixos"
    readonly property var plan: {
        const steps = [];
        const repos = data.repos || [];
        const nixos = repos.find(r => r.path === nixosPath);
        const say = r => r.name;
        for (const r of repos)
            if (r.path !== nixosPath && r.draft && r.staged.length)
                steps.push({ key: "commit " + r.path, repo: r.path, label: "Commit",
                             ask: "Commit " + say(r) + "?", detail: r.draft.subject, args: [land, "commit", r.path] });
        for (const r of repos)
            if (r.path !== nixosPath && (r.ahead || 0) > 0)
                steps.push(r.input
                    ? { key: "bump " + r.path, repo: r.path, label: "Bump", ask: "Push " + say(r) + " and update ~/nixos to it?",
                        detail: r.ahead + " commit(s) to push", args: [land, "bump", r.path] }
                    : { key: "push " + r.path, repo: r.path, label: "Push", ask: "Push " + say(r) + "?",
                        detail: r.ahead + " commit(s): " + (r.commits[0] ? r.commits[0].subject : ""), args: [land, "push", r.path] });
        if (nixos && nixos.draft && nixos.staged.length)
            steps.push({ key: "commit " + nixosPath, repo: nixosPath, label: "Commit", ask: "Commit ~/nixos?",
                         detail: nixos.draft.subject, args: [land, "commit", nixosPath] });
        if (switchState === "differs")
            steps.push({ key: "switch", repo: "system", label: "Switch", ask: "Switch to the new ~/nixos now?",
                         detail: "password through the prompt", args: [land, "switch"] });
        if (nixos && (nixos.ahead || 0) > 0)
            steps.push({ key: "push " + nixosPath, repo: nixosPath, label: "Push", ask: "Push ~/nixos?",
                         detail: nixos.ahead + " commit(s)", args: [land, "push", nixosPath] });
        for (const r of repos)
            for (const t of (r.ship ? r.ship.targets : []))
                if (t.count > 0)
                    steps.push({ key: "ship " + r.path + " " + t.name, repo: r.path, label: "Ship " + t.name,
                                 ask: "Ship " + t.name + " from " + say(r) + "?", detail: t.count + " file(s) changed",
                                 args: [ship, "target", r.path, t.name] });
        return steps;
    }
    readonly property var pending: plan.filter(s => !skipped[s.key])
    readonly property var nextStep: pending.length ? pending[0] : null

    // ---- layout: hot repos big in the middle, the rest compact on the sides by subject ----
    // (hot = something to do, or worked on in the last two days; groups from
    // ~/.config/deck/groups.txt via deck-status.) Groups alternate sides, biggest first, so
    // the two columns come out about the same height.
    readonly property var hotRepos: {
        const hot = (data.repos || []).filter(r => r.hot);
        return hot.length ? hot : (data.repos || []).slice(0, 3);
    }
    readonly property var coolGroups: {
        const byName = {};
        const order = [];
        for (const r of (data.repos || [])) {
            if (hotRepos.indexOf(r) >= 0) continue;
            if (!byName[r.group]) { byName[r.group] = { name: r.group, order: r.group_order, repos: [] }; order.push(r.group); }
            byName[r.group].repos.push(r);
        }
        return order.map(n => byName[n]).sort((a, b) => a.order - b.order);
    }
    readonly property var sides: {
        const left = [], right = [];
        let lh = 0, rh = 0;
        // weigh a group by what it will show (a header, a tile each, and their commit lines),
        // not by its repo count: a repo with one commit is a short tile
        const weight = g => 1 + g.repos.reduce((s, r) => s + 1 + Math.min(r.commits.length, 12) / 4, 0);
        for (const g of coolGroups.slice().sort((a, b) => weight(b) - weight(a))) {
            const h = weight(g);
            if (lh <= rh) { left.push(g); lh += h; } else { right.push(g); rh += h; }
        }
        const byOrder = (a, b) => a.order - b.order;
        const rows = gs => gs.reduce((s, g) => s + 1 + g.repos.length, 0);   // headers + tiles
        return { left: left.sort(byOrder), right: right.sort(byOrder), leftRows: rows(left), rightRows: rows(right) };
    }

    function yes() { if (idle && nextStep) run(nextStep.repo, nextStep.label, nextStep.args); }
    function no() {
        if (!nextStep) return;
        const s = Object.assign({}, skipped); s[nextStep.key] = true; skipped = s;
    }
    function hide() { open = false; }

    function run(repo, label, args) {
        if (!idle) return;
        busyRepo = repo; busyLabel = label; busyLine = "";
        actionProc.command = ["env", "LAND_YES=1"].concat(args);
        actionProc.running = true;
    }

    function setResult(repo, ok, label, line) {
        const r = Object.assign({}, results);
        r[repo] = { ok: ok, label: label, line: line };
        results = r;
    }

    Process {
        id: statusProc
        command: [deck.home + "/dotfiles/bin/deck-status"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { deck.data = JSON.parse(this.text); } catch (e) {}
                deck.loading = false;
            }
        }
    }

    Process {
        id: switchProc
        command: [deck.land, "needs-switch"]
        onExited: (code) => deck.switchState = code === 0 ? "differs" : code === 1 ? "same" : "broken"
    }

    Process {
        id: actionProc
        stdout: SplitParser {
            onRead: line => {
                const clean = line.replace(/\x1b\[[0-9;]*m/g, "").trim();
                if (clean) deck.busyLine = clean;
            }
        }
        stderr: SplitParser {
            onRead: line => {
                const clean = line.replace(/\x1b\[[0-9;]*m/g, "").trim();
                if (clean) deck.busyLine = clean;
            }
        }
        onExited: (code) => {
            deck.setResult(deck.busyRepo, code === 0, deck.busyLabel, deck.busyLine);
            // a run that stopped for a re-login: the tab turns red with a Log in button
            const login = /run `([^`]+)`/.exec(deck.busyLine);
            deck.loginCmd = code !== 0 && login ? login[1] : "";
            deck.needsLogin = deck.loginCmd ? deck.busyLabel + " needs a login" : "";
            const wasSwitch = deck.busyRepo === "system";
            deck.busyRepo = "";
            deck.refresh();
            if (wasSwitch || deck.busyLabel.indexOf("Commit") === 0 || deck.busyLabel.indexOf("Bump") === 0)
                deck.checkSwitch();
        }
    }

    IpcHandler {
        target: "deck"
        function open(): void { deck.show(); }
        function close(): void { deck.hide(); }
        function toggle(): void { if (deck.open) deck.hide(); else deck.show(); }
    }

    // ---- small pieces ----
    component Chip: Rectangle {
        id: chip
        property string text: ""
        property color tone: deck.theme.muted
        property bool filled: false
        property bool action: false
        property bool enabledAction: true
        // text colour; on a filled chip it must differ from the fill (the Y chip is filled with
        // the surface colour, so its default surface-coloured text was invisible)
        property color textColor: filled ? deck.theme.surface : tone
        signal clicked()
        height: 22
        width: chipText.implicitWidth + 16
        radius: 4
        color: filled ? tone : (hover.containsMouse && action && enabledAction ? Qt.alpha(tone, 0.18) : "transparent")
        border.width: 1
        border.color: tone
        opacity: action && !enabledAction ? 0.4 : 1
        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.text
            color: chip.textColor
            font.pixelSize: 11
            font.bold: chip.action
            font.letterSpacing: 0.5
        }
        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            enabled: chip.action && chip.enabledAction
            cursorShape: chip.action ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: chip.clicked()
        }
    }

    LazyLoader {
        active: deck.open

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
            WlrLayershell.namespace: "deck"

            Rectangle {
                anchors.fill: parent
                color: deck.theme.bg
                opacity: 0
                Component.onCompleted: opacity = 0.6
                Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                MouseArea { anchors.fill: parent; onClicked: deck.hide() }
            }

            Rectangle {
                id: panel
                anchors.centerIn: parent
                width: parent.width - 100
                height: parent.height - 100
                radius: 10
                color: deck.theme.surface
                border.width: 1
                border.color: deck.theme.dim
                opacity: 0
                scale: 0.98
                Component.onCompleted: { opacity = 1; scale = 1; forceActiveFocus(); }
                Behavior on opacity { NumberAnimation { duration: 120 } }
                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                MouseArea { anchors.fill: parent }

                focus: true
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) deck.hide();
                    else if (event.key === Qt.Key_Y || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (deck.needsLogin) deck.logIn(); else deck.yes();
                    }
                    else if (event.key === Qt.Key_N || event.key === Qt.Key_Space) deck.no();
                    else if (event.key === Qt.Key_R) { deck.refresh(); deck.checkSwitch(); }
                    else return;
                    event.accepted = true;
                }

                SciFrame {
                    anchors.fill: parent
                    theme: deck.theme
                    title: "Land · Ship"
                    detail: "Super+F12"
                    hint: "Y run next · N skip · or click a chip · R refresh · Esc close · terminal: Super+Shift+F12"
                }

                // ---- system strip ----
                Row {
                    id: strip
                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: 24; topMargin: 34 }
                    spacing: 10
                    height: 26

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "SYSTEM"
                        color: deck.theme.violet
                        font.pixelSize: 12; font.bold: true; font.letterSpacing: 1.5
                    }
                    Chip {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "generation " + (deck.data.system.generation || "?")
                        tone: deck.theme.dim
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "~/nixos " + (deck.data.system.head || "")
                        color: deck.theme.fg
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, strip.width * 0.45)
                    }
                    Chip {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: deck.switchState !== ""
                        text: deck.switchState === "checking" ? "building to compare…"
                            : deck.switchState === "same" ? "running = ~/nixos ✓"
                            : deck.switchState === "broken" ? "~/nixos doesn't build ✗"
                            : "~/nixos differs from running"
                        tone: deck.switchState === "same" ? deck.theme.green
                            : deck.switchState === "broken" ? deck.theme.red : deck.theme.yellow
                    }
                    Chip {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: deck.switchState === "differs"
                        text: deck.busyRepo === "system" ? "switching… " + deck.busyLine.slice(0, 60) : "Switch now"
                        tone: deck.theme.violet
                        filled: true
                        action: true
                        enabledAction: deck.idle
                        onClicked: deck.run("system", "Switch", [deck.land, "switch"])
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: deck.results["system"] !== undefined
                        text: deck.results["system"] ? (deck.results["system"].ok ? "✓ " : "✗ ") + deck.results["system"].line.slice(0, 80) : ""
                        color: deck.results["system"] && deck.results["system"].ok ? deck.theme.green : deck.theme.red
                        font.pixelSize: 12
                    }
                }

                // ---- NEXT: the y/N question, as a tab on the top border, centred ----
                // Where the eye lands when the deck opens; the title tab sits at the left.
                Rectangle {
                    id: askTab
                    z: 20
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: -height / 2
                    height: 40
                    width: askRow.width + 36
                    radius: 8
                    color: deck.needsLogin ? deck.theme.red
                         : deck.nextStep || deck.busyRepo !== "" ? deck.theme.violet : deck.theme.green
                    border.width: 1
                    border.color: deck.theme.dim

                    Row {
                        id: askRow
                        anchors.centerIn: parent
                        spacing: 12
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: deck.busyRepo !== "" ? "RUNNING" : deck.needsLogin ? "LOGIN" : deck.nextStep ? "NEXT" : "DONE"
                            color: deck.theme.surface
                            opacity: 0.85
                            font.pixelSize: 12; font.bold: true; font.letterSpacing: 2
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: deck.busyRepo !== "" ? deck.busyLabel + " · " + deck.busyLine
                                : deck.needsLogin ? deck.needsLogin
                                : deck.loading ? "reading repos…"
                                : deck.nextStep ? deck.nextStep.ask
                                : deck.switchState === "checking" ? "checking whether a switch is needed…"
                                : "Nothing left to land or ship"
                            color: deck.theme.surface
                            font.pixelSize: 16; font.bold: true
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, panel.width * 0.45)
                        }
                        Chip {
                            visible: !!deck.nextStep && !deck.needsLogin
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Y  yes"; tone: deck.theme.surface; textColor: deck.theme.violet; filled: true; action: true
                            enabledAction: deck.idle
                            onClicked: deck.yes()
                        }
                        Chip {
                            visible: !!deck.nextStep && !deck.needsLogin
                            anchors.verticalCenter: parent.verticalCenter
                            text: "N  skip"; tone: deck.theme.surface; action: true
                            enabledAction: deck.idle
                            onClicked: deck.no()
                        }
                        Chip {
                            visible: !!deck.needsLogin
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Log in"; tone: deck.theme.surface; textColor: deck.theme.red
                            filled: true; action: true
                            onClicked: deck.logIn()
                        }
                    }
                }

                // quiet context under the tab: what the step is about, and how many follow
                Text {
                    id: nextBar
                    anchors { top: strip.bottom; topMargin: 6; horizontalCenter: parent.horizontalCenter }
                    width: Math.min(implicitWidth, panel.width * 0.7)
                    height: visible ? implicitHeight : 0
                    visible: !!deck.nextStep && deck.busyRepo === ""
                    horizontalAlignment: Text.AlignHCenter
                    text: deck.nextStep ? deck.nextStep.detail
                          + (deck.pending.length > 1 ? "   ·   " + (deck.pending.length - 1) + " more after this" : "") : ""
                    color: deck.theme.dim
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                Rectangle {
                    id: rule
                    anchors { top: nextBar.bottom; topMargin: 10; left: parent.left; right: parent.right }
                    height: 1; color: deck.theme.muted; opacity: 0.4
                }

                // ---- the quieter repos: compact tiles by subject, left and right ----
                component SideColumn: Column {
                    id: side
                    required property var groupsHere
                    required property int rowsHere     // tiles + headers, for sharing the height
                    spacing: 6
                    // spare height goes to recent commits inside each compact tile
                    readonly property int tiles: Math.max(1, rowsHere - groupsHere.length)
                    readonly property int extraLines: Math.max(0, Math.floor((height - rowsHere * 64) / tiles / 15))

                    Repeater {
                        model: side.groupsHere
                        Column {
                            required property var modelData
                            width: side.width
                            spacing: 5
                            Text {
                                text: modelData.name.toUpperCase()
                                color: deck.theme.violet
                                font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.5
                                topPadding: 4
                            }
                            Repeater {
                                model: modelData.repos
                                Rectangle {
                                    required property var modelData
                                    readonly property var r: modelData
                                    width: side.width
                                    height: compact.implicitHeight + 14
                                    radius: 6
                                    color: "transparent"
                                    border.width: 1
                                    border.color: deck.theme.muted
                                    Column {
                                        id: compact
                                        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 8; topMargin: 7 }
                                        spacing: 3
                                        Row {
                                            spacing: 6
                                            Text { text: r.name; color: deck.theme.fg; font.pixelSize: 13; font.bold: true }
                                            Chip { text: r.branch; tone: deck.theme.cyan; height: 18 }
                                            Chip { visible: (r.dirty || 0) > 0; text: r.dirty + " unstaged"; tone: deck.theme.muted; height: 18 }
                                            Chip { visible: !!r.input; text: "flake input"; tone: deck.theme.violet; height: 18 }
                                        }
                                        Repeater {
                                            model: r.commits.slice(0, 1 + side.extraLines)
                                            Row {
                                                required property var modelData
                                                spacing: 6
                                                Text { text: modelData.hash; color: deck.theme.yellow; font.family: "monospace"; font.pixelSize: 11 }
                                                Text {
                                                    width: side.width - 110
                                                    text: modelData.subject
                                                    color: deck.theme.dim
                                                    font.pixelSize: 11
                                                    elide: Text.ElideRight
                                                }
                                                Text { text: modelData.ago; color: deck.theme.muted; font.pixelSize: 11 }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                SideColumn {
                    id: leftSide
                    anchors { top: rule.bottom; bottom: parent.bottom; left: parent.left; margins: 16; bottomMargin: 22 }
                    width: panel.width * 0.22
                    groupsHere: deck.sides.left
                    rowsHere: deck.sides.leftRows
                }
                SideColumn {
                    id: rightSide
                    anchors { top: rule.bottom; bottom: parent.bottom; right: parent.right; margins: 16; bottomMargin: 22 }
                    width: panel.width * 0.22
                    groupsHere: deck.sides.right
                    rowsHere: deck.sides.rightRows
                }

                // ---- timeline: under the hot tiles, in the middle ----
                Rectangle {
                    id: timeline
                    anchors { bottom: parent.bottom; left: leftSide.right; right: rightSide.left; margins: 16; bottomMargin: 22 }
                    height: (panel.height - rule.y) * 0.34
                    radius: 8
                    color: deck.theme.bg
                    opacity: 0.92

                    Text {
                        id: tlHead
                        anchors { top: parent.top; left: parent.left; margins: 12 }
                        text: "RECENT COMMITS · 2 WEEKS"
                        color: deck.theme.violet
                        font.pixelSize: 12; font.bold: true; font.letterSpacing: 1.5
                    }
                    // two columns, as many entries as fit: full, never scrolls
                    Flow {
                        id: tlFlow
                        anchors { top: tlHead.bottom; topMargin: 6; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
                        flow: Flow.TopToBottom
                        spacing: 4
                        readonly property int perCol: Math.max(1, Math.floor((height + 4) / 20))
                        Repeater {
                            model: deck.data.timeline.slice(0, tlFlow.perCol * 2)
                            Row {
                                required property var modelData
                                width: tlFlow.width / 2 - 8
                                height: 16
                                spacing: 6
                                Text { text: modelData.repo; color: deck.theme.cyan; font.pixelSize: 11; font.bold: true; width: 90; elide: Text.ElideRight }
                                Text { text: modelData.hash; color: deck.theme.yellow; font.family: "monospace"; font.pixelSize: 11 }
                                Text {
                                    width: parent.width - 220
                                    text: modelData.subject
                                    color: deck.theme.fg
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                                Text { text: modelData.ago; color: deck.theme.muted; font.pixelSize: 11 }
                            }
                        }
                    }
                }

                // ---- hot tiles: the middle, above the timeline ----
                Item {
                    id: tilesArea
                    anchors { top: rule.bottom; bottom: timeline.top; left: leftSide.right; right: rightSide.left; margins: 16; bottomMargin: 12 }
                    // columns: as many as fit at >= 330 px, but the count that leaves the
                    // fewest empty cells in the last row (10 tiles: 5 x 2, not 4 + 4 + 2)
                    readonly property int cols: {
                        const n = Math.max(1, deck.hotRepos.length);
                        const most = Math.max(1, Math.min(n, Math.floor(width / 300)));
                        let best = most, waste = 1e9;
                        for (let c = most; c >= Math.max(1, Math.ceil(most * 0.6)); c--) {
                            const w = Math.ceil(n / c) * c - n;
                            if (w < waste) { waste = w; best = c; }
                        }
                        return best;
                    }
                    readonly property real tileW: (width - (cols - 1) * 12) / cols
                    // tiles share the whole height: no empty band below them, and each
                    // tile spends its spare room on unstaged files and recent commits
                    readonly property int rows: Math.max(1, Math.ceil(deck.hotRepos.length / cols))
                    readonly property real tileH: (height - (rows - 1) * 12) / rows

                    Flow {
                        anchors.fill: parent
                        spacing: 12

                        Repeater {
                            model: deck.hotRepos

                            Rectangle {
                                id: tile
                                required property var modelData
                                readonly property var r: modelData
                                readonly property bool busy: deck.busyRepo === r.path
                                readonly property var result: deck.results[r.path]
                                readonly property var targets: r.ship ? r.ship.targets : []
                                width: tilesArea.tileW
                                height: Math.max(tilesArea.tileH, tileCol.implicitHeight + 24)
                                clip: true
                                radius: 8
                                color: r.active ? deck.theme.bg : "transparent"
                                // the tile the NEXT question is about
                                readonly property bool isNext: !!deck.nextStep && deck.nextStep.repo === r.path
                                border.width: busy || isNext ? 2 : 1
                                border.color: busy || isNext ? deck.theme.violet
                                    : r.draft ? deck.theme.yellow
                                    : r.active ? deck.theme.dim : deck.theme.muted
                                opacity: r.active || busy ? 1 : 0.75

                                Column {
                                    id: tileCol
                                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: 12 }
                                    spacing: 7

                                    // name, branch, sync state
                                    Flow {
                                        width: parent.width
                                        spacing: 6
                                        Text {
                                            text: r.name
                                            color: deck.theme.fg
                                            font.pixelSize: 15; font.bold: true
                                        }
                                        Chip { text: r.branch; tone: deck.theme.cyan }
                                        Chip { visible: (r.ahead || 0) > 0; text: "↑" + r.ahead + " unpushed"; tone: deck.theme.orange }
                                        Chip { visible: (r.behind || 0) > 0; text: "↓" + r.behind; tone: deck.theme.blue }
                                        Chip { visible: (r.dirty || 0) > 0; text: r.dirty + " unstaged"; tone: deck.theme.muted }
                                        Chip { visible: !!r.input; text: "flake input"; tone: deck.theme.violet }
                                    }

                                    // drafted commit
                                    Column {
                                        visible: !!r.draft
                                        width: parent.width
                                        spacing: 2
                                        Text {
                                            width: parent.width
                                            text: r.draft ? r.draft.subject : ""
                                            color: deck.theme.yellow
                                            font.pixelSize: 13; font.bold: true
                                            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                                        }
                                        Text {
                                            width: parent.width
                                            text: r.draft ? r.draft.body : ""
                                            visible: text !== ""
                                            color: deck.theme.dim
                                            font.pixelSize: 11
                                            wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                                        }
                                    }

                                    // staged files
                                    Flow {
                                        visible: r.staged.length > 0
                                        width: parent.width
                                        spacing: 4
                                        Repeater {
                                            model: r.staged.slice(0, 6)
                                            Chip {
                                                required property var modelData
                                                text: modelData.file.split("/").pop() + "  +" + modelData.add + " −" + modelData.del
                                                tone: deck.theme.green
                                            }
                                        }
                                        Chip { visible: r.staged.length > 6; text: "+" + (r.staged.length - 6) + " more"; tone: deck.theme.green }
                                    }

                                    // ship targets
                                    Repeater {
                                        model: tile.targets
                                        Text {
                                            required property var modelData
                                            width: tileCol.width
                                            text: "⇪ " + modelData.name + ": " + (modelData.count === 0 ? "up to date"
                                                : modelData.count + " changed" + (modelData.first ? " (first ship)" : "")
                                                  + "  ·  " + modelData.changed.slice(0, 3).join(", "))
                                            color: modelData.count ? deck.theme.orange : deck.theme.muted
                                            font.pixelSize: 11
                                            elide: Text.ElideRight
                                        }
                                    }

                                    // newest commit when nothing is drafted
                                    Text {
                                        visible: !r.draft && r.commits.length > 0
                                        width: parent.width
                                        text: r.commits.length ? r.commits[0].hash + "  " + r.commits[0].subject + "  · " + r.commits[0].ago : ""
                                        color: deck.theme.dim
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }

                                    // actions
                                    Flow {
                                        width: parent.width
                                        spacing: 6
                                        Chip {
                                            visible: !!r.draft && r.staged.length > 0
                                            text: "Commit"; tone: deck.theme.violet; filled: true; action: true
                                            enabledAction: deck.idle
                                            onClicked: deck.run(r.path, "Commit", [deck.land, "commit", r.path])
                                        }
                                        Chip {
                                            visible: !!r.draft && r.staged.length === 0
                                            text: "Discard stale draft"; tone: deck.theme.red; action: true
                                            enabledAction: deck.idle
                                            onClicked: deck.run(r.path, "Discard", [deck.land, "discard", r.path])
                                        }
                                        Chip {
                                            visible: !!r.input && (r.ahead || 0) > 0
                                            text: "Push + bump ~/nixos"; tone: deck.theme.violet; action: true
                                            enabledAction: deck.idle
                                            onClicked: deck.run(r.path, "Bump", [deck.land, "bump", r.path])
                                        }
                                        Chip {
                                            visible: !r.input && (r.ahead || 0) > 0
                                            text: "Push ↑" + r.ahead; tone: deck.theme.orange; action: true
                                            enabledAction: deck.idle
                                            onClicked: deck.run(r.path, "Push", [deck.land, "push", r.path])
                                        }
                                        Repeater {
                                            model: tile.targets.filter(t => t.count > 0)
                                            Chip {
                                                required property var modelData
                                                text: "Ship " + modelData.name; tone: deck.theme.orange; filled: true; action: true
                                                enabledAction: deck.idle
                                                onClicked: deck.run(r.path, "Ship " + modelData.name, [deck.ship, "target", r.path, modelData.name])
                                            }
                                        }
                                    }

                                    // progress / last result
                                    Text {
                                        visible: tile.busy || tile.result !== undefined
                                        width: parent.width
                                        text: tile.busy ? "⟳ " + deck.busyLabel + ": " + deck.busyLine
                                            : tile.result ? (tile.result.ok ? "✓ " : "✗ ") + tile.result.label + ": " + tile.result.line : ""
                                        color: tile.busy ? deck.theme.violet : tile.result && tile.result.ok ? deck.theme.green : deck.theme.red
                                        font.pixelSize: 11
                                        font.family: "monospace"
                                        elide: Text.ElideRight
                                    }
                                }

                                // ---- filler: spare room shows unstaged files, then recent commits ----
                                Column {
                                    id: filler
                                    anchors { top: tileCol.bottom; topMargin: 8; left: parent.left; right: parent.right; margins: 12 }
                                    readonly property real room: tile.height - tileCol.implicitHeight - 32
                                    readonly property int lines: Math.max(0, Math.floor(room / 16))
                                    readonly property var dirtyShown: (r.dirty_files || []).slice(0, Math.min(6, Math.max(0, lines - 2)))
                                    readonly property int commitLines: Math.max(0, lines - (dirtyShown.length ? dirtyShown.length + 1 : 0) - 1)
                                    spacing: 2
                                    visible: lines > 1

                                    Text {
                                        visible: filler.dirtyShown.length > 0
                                        text: "UNSTAGED"
                                        color: deck.theme.muted
                                        font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2
                                    }
                                    Repeater {
                                        model: filler.dirtyShown
                                        Text {
                                            required property var modelData
                                            width: filler.width
                                            text: "· " + modelData
                                            color: deck.theme.dim
                                            font.family: "monospace"
                                            font.pixelSize: 11
                                            elide: Text.ElideMiddle
                                        }
                                    }
                                    Text {
                                        visible: filler.commitLines > 0 && r.commits.length > (r.draft ? 0 : 1)
                                        topPadding: 4
                                        text: "RECENT"
                                        color: deck.theme.muted
                                        font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2
                                    }
                                    Repeater {
                                        // the newest commit already shows above when there's no draft
                                        model: r.commits.slice(r.draft ? 0 : 1, (r.draft ? 0 : 1) + filler.commitLines)
                                        Row {
                                            required property var modelData
                                            spacing: 6
                                            Text { text: modelData.hash; color: deck.theme.yellow; font.family: "monospace"; font.pixelSize: 11 }
                                            Text {
                                                width: filler.width - 110
                                                text: modelData.subject
                                                color: deck.theme.dim
                                                font.pixelSize: 11
                                                elide: Text.ElideRight
                                            }
                                            Text { text: modelData.ago; color: deck.theme.muted; font.pixelSize: 11 }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        visible: deck.data.repos.length === 0
                        anchors.centerIn: parent
                        text: deck.loading ? "Reading repos…" : "Nothing going on in any repo."
                        color: deck.theme.muted
                        font.pixelSize: 14
                    }
                }
            }
        }
    }
}
