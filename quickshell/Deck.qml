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
    property string busyErr: ""           // the last line that looks like the reason, for the log

    // ---- the log, lower right: every message the deck has, newest last ----
    // Kept across openings (until quickshell restarts), so a failure is still there
    // when you come back. { t: "HH:MM", state: ok|bad|info, label, repo, detail }
    property var log: []
    property string lastSystem: ""
    function note(state, label, repo, detail) {
        const t = new Date().toTimeString().slice(0, 5);
        log = log.concat([{ t: t, state: state, label: label, repo: repo, detail: detail || "" }]).slice(-40);
    }
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
    function show() { open = true; skipped = ({}); done = []; auto = false; refresh(); checkSwitch(); }

    // ---- y/N, like the terminal land: the next step, in land's order ----
    // Commit each drafted repo (~/nixos last), push / push + bump, switch, push ~/nixos,
    // then ship. y or Enter runs it, n or Space skips it for this opening, Esc closes.
    // a runs them all, one after another (see autoNext).
    property var skipped: ({})
    readonly property string nixosPath: home + "/nixos"
    readonly property var plan: {
        const steps = [];
        const repos = data.repos || [];
        const nixos = repos.find(r => r.path === nixosPath);
        const say = r => r.name;
        // short: the step's name on the on-deck strip
        for (const r of repos)
            if (r.path !== nixosPath && r.draft && r.staged.length)
                steps.push({ key: "commit " + r.path, repo: r.path, label: "Commit",
                             short: "Commit " + say(r), ask: "Commit " + say(r) + "?", detail: r.draft.subject, args: [land, "commit", r.path] });
        for (const r of repos)
            if (r.path !== nixosPath && (r.ahead || 0) > 0)
                steps.push(r.input
                    ? { key: "bump " + r.path, repo: r.path, label: "Bump", short: "Bump " + say(r), ask: "Push " + say(r) + " and update ~/nixos to it?",
                        detail: r.ahead + " commit(s) to push", args: [land, "bump", r.path] }
                    : { key: "push " + r.path, repo: r.path, label: "Push", short: "Push " + say(r), ask: "Push " + say(r) + "?",
                        detail: r.ahead + " commit(s): " + (r.commits[0] ? r.commits[0].subject : ""), args: [land, "push", r.path] });
        if (nixos && nixos.draft && nixos.staged.length)
            steps.push({ key: "commit " + nixosPath, repo: nixosPath, label: "Commit", short: "Commit nixos", ask: "Commit ~/nixos?",
                         detail: nixos.draft.subject, args: [land, "commit", nixosPath] });
        if (switchState === "differs")
            steps.push({ key: "switch", repo: "system", label: "Switch", short: "Switch", ask: "Switch to the new ~/nixos now?",
                         detail: "password through the prompt", args: [land, "switch"] });
        if (nixos && (nixos.ahead || 0) > 0)
            steps.push({ key: "push " + nixosPath, repo: nixosPath, label: "Push", short: "Push nixos", ask: "Push ~/nixos?",
                         detail: nixos.ahead + " commit(s)", args: [land, "push", nixosPath] });
        for (const r of repos)
            for (const t of (r.ship ? r.ship.targets : []))
                if (t.count > 0)
                    steps.push({ key: "ship " + r.path + " " + t.name, repo: r.path, label: "Ship " + t.name,
                                 short: "Ship " + say(r) + " " + t.name, ask: "Ship " + t.name + " from " + say(r) + "?", detail: t.count + " file(s) changed",
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

    function yes() {
        if (!idle || !nextStep) return;
        runningStep = nextStep;
        run(nextStep.repo, nextStep.label, nextStep.args);
    }
    function no() {
        if (auto) { auto = false; return; }   // during A, N stops the run; the queue stays
        if (!nextStep) return;
        const s = Object.assign({}, skipped); s[nextStep.key] = true; skipped = s;
    }
    function hide() { open = false; auto = false; }   // a step already running finishes

    // ---- A: run the queue to the end ----
    // After each step the repos are re-read (and the switch re-checked), so the plan grows
    // as it goes: Commit brings Push, ~/nixos's Commit brings Switch. A stops on a failure,
    // on a login, or on a step that's back after it ran (it would only fail the same way).
    property bool auto: false
    property var runningStep: null
    property var done: []                 // steps run this opening: { key, label, repo, ok, line }
    function all() { if (!idle || !nextStep || needsLogin) return; auto = true; yes(); }
    function autoNext() {
        if (!auto || !idle || switchState === "checking") return;
        if (!nextStep || needsLogin) {
            auto = false;
            if (!nextStep) note(done.every(d => d.ok) ? "ok" : "bad", "A", "all",
                                done.filter(d => d.ok).length + " of " + done.length + " steps done, nothing left");
            return;
        }
        if (done.some(d => d.key === nextStep.key)) { auto = false; return; }
        yes();
    }
    // callLater: an action's onExited clears busyRepo before it starts the refresh;
    // waiting a tick lets loading turn true first, so the plan is never read stale
    onIdleChanged: Qt.callLater(autoNext)
    onSwitchStateChanged: Qt.callLater(autoNext)

    function run(repo, label, args) {
        if (!idle) return;
        busyRepo = repo; busyLabel = label; busyLine = ""; busyErr = "";
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
                // the running system, logged when it changes (and on the first read)
                const sys = deck.data.system || {};
                const said = "generation " + (sys.generation || "?") + " · ~/nixos " + (sys.head || "");
                if (said !== deck.lastSystem) { deck.lastSystem = said; deck.note("info", "System", "system", said); }
            }
        }
    }

    Process {
        id: switchProc
        command: [deck.land, "needs-switch"]
        onExited: (code) => {
            deck.switchState = code === 0 ? "differs" : code === 1 ? "same" : "broken";
            deck.note(code === 1 ? "ok" : code === 0 ? "info" : "bad", "Check", "system",
                      code === 1 ? "running = ~/nixos" : code === 0 ? "~/nixos differs from the running system"
                      : "~/nixos doesn't build (see " + "$XDG_RUNTIME_DIR/land-build.log)");
        }
    }

    Process {
        id: actionProc
        stdout: SplitParser {
            onRead: line => {
                const clean = line.replace(/\x1b\[[0-9;]*m/g, "").trim();
                if (clean) deck.busyLine = clean;
                if (/error|fail|denied|✗/i.test(clean)) deck.busyErr = clean;
            }
        }
        stderr: SplitParser {
            onRead: line => {
                const clean = line.replace(/\x1b\[[0-9;]*m/g, "").trim();
                if (clean) deck.busyLine = clean;
                if (/error|fail|denied|✗/i.test(clean)) deck.busyErr = clean;
            }
        }
        onExited: (code) => {
            deck.setResult(deck.busyRepo, code === 0, deck.busyLabel, deck.busyLine);
            // a failure logs its most telling line (e.g. "the following units failed: …"),
            // not the generic last one ("returned non-zero exit status 4")
            deck.note(code === 0 ? "ok" : "bad", deck.busyLabel, deck.busyRepo,
                      code === 0 ? deck.busyLine : (deck.busyErr || deck.busyLine));
            if (deck.runningStep)
                deck.done = deck.done.concat([{ key: deck.runningStep.key, label: deck.runningStep.label,
                                                repo: deck.runningStep.repo, ok: code === 0, line: deck.busyLine }]);
            deck.runningStep = null;
            if (code !== 0) deck.auto = false;
            // a run that stopped for a re-login: the tab turns red with a Log in button
            const login = /run `([^`]+)`/.exec(deck.busyLine);
            deck.loginCmd = code !== 0 && login ? login[1] : "";
            deck.needsLogin = deck.loginCmd ? deck.busyLabel + " needs a login" : "";
            if (deck.loginCmd) deck.note("bad", "Log in", deck.busyRepo, deck.needsLogin + ": " + deck.loginCmd + " (Y or Log in)");
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
                    else if (event.key === Qt.Key_A) { if (!deck.needsLogin) deck.all(); }
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
                    hint: "Y run next · N skip · A all, then status · or click a chip · R refresh · Esc close · terminal: Super+Shift+F12"
                }

                // ---- system strip ----
                // The system strip's pills (generation, the switch check, Switch now) became
                // log entries, lower right; Switch is a step in the queue. This keeps the anchor.
                Item {
                    id: strip
                    anchors { top: parent.top; left: parent.left; right: parent.right; margins: 24; topMargin: 34 }
                    height: 0
                }

                // ---- NEXT: the y/N question, as a tab on the top border, centred ----
                // Where the eye lands when the deck opens; the title tab sits at the left.
                Rectangle {
                    id: askTab
                    visible: false     // the question lives at the foot of the log, lower right
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
                            text: deck.busyRepo !== "" ? (deck.auto ? "ALL" : "RUNNING") : deck.needsLogin ? "LOGIN" : deck.nextStep ? "NEXT" : "DONE"
                            color: deck.theme.surface
                            opacity: 0.85
                            font.pixelSize: 12; font.bold: true; font.letterSpacing: 2
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            // only the question lives here; every message goes to the log, lower right
                            text: deck.busyRepo !== "" ? deck.busyLabel + " " + onDeck.repoName(deck.busyRepo) + "…"
                                : deck.needsLogin ? "Log in?"
                                : deck.loading || deck.switchState === "checking" ? "…"
                                : deck.nextStep ? deck.nextStep.ask
                                : "Nothing left"
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
                            visible: !!deck.nextStep && !deck.needsLogin && !deck.auto
                            anchors.verticalCenter: parent.verticalCenter
                            text: "A  all"; tone: deck.theme.surface; textColor: deck.theme.violet; filled: true; action: true
                            enabledAction: deck.idle
                            onClicked: deck.all()
                        }
                        Chip {
                            visible: !!deck.nextStep && !deck.needsLogin
                            anchors.verticalCenter: parent.verticalCenter
                            text: deck.auto ? "N  stop" : "N  skip"; tone: deck.theme.surface; action: true
                            enabledAction: deck.idle || deck.auto
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
                    visible: false     // the step's detail is in the log now
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
                    anchors { top: rule.bottom; bottom: onDeck.visible ? onDeck.top : parent.bottom; right: parent.right
                              margins: 16; bottomMargin: onDeck.visible ? 12 : 22 }
                    width: panel.width * 0.22
                    groupsHere: deck.sides.right
                    rowsHere: deck.sides.rightRows
                }

                // ---- ON DECK: the queue as a table, lower right ----
                // Done rows (✓/✗ and their last line), the one running (live output) or
                // next, then the rest in order. A walks down it.
                Rectangle {
                    id: onDeck
                    anchors { right: parent.right; bottom: parent.bottom; margins: 16; bottomMargin: 22 }
                    width: panel.width * 0.22
                    height: visible ? qCol.implicitHeight + 20 : 0
                    visible: true      // it holds the question, so it's always there
                    radius: 8
                    color: deck.theme.bg
                    opacity: 0.92
                    border.width: 1
                    border.color: deck.auto ? deck.theme.violet : deck.theme.muted

                    // the log (past), then the queue: the step running or next, and the rest
                    readonly property var rows: deck.log
                        .concat(deck.pending.map((s, i) => ({
                            t: "", state: i === 0 ? (deck.busyRepo !== "" ? "running" : "next") : "later",
                            label: s.label, repo: s.repo,
                            detail: i === 0 && deck.busyRepo !== "" ? deck.busyLine : s.detail })))
                    function repoName(path) { return path === "system" || path === "all" ? path : path.split("/").pop(); }

                    Column {
                        id: qCol
                        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 10 }
                        spacing: 3
                        Row {
                            spacing: 8
                            Text {
                                text: "LOG · ON DECK"
                                color: deck.theme.violet
                                font.pixelSize: 12; font.bold: true; font.letterSpacing: 1.5
                            }
                            Text {
                                text: (deck.loading ? "reading repos · " : "") + (deck.switchState === "checking" ? "checking switch · " : "")
                                      + deck.pending.length + " to go" + (deck.auto ? " · A running" : "")
                                color: deck.theme.dim
                                font.pixelSize: 11
                            }
                        }
                        Repeater {
                            model: onDeck.rows.slice(-18)     // the newest 18: what's next stays in view
                            Row {
                                required property var modelData
                                readonly property color tone: modelData.state === "ok" ? deck.theme.green
                                    : modelData.state === "bad" ? deck.theme.red
                                    : modelData.state === "later" || modelData.state === "info" ? deck.theme.muted : deck.theme.violet
                                width: qCol.width
                                height: Math.max(17, detailText.implicitHeight)   // a failure wraps to show its reason
                                spacing: 6
                                Rectangle {     // a bar marks the row A is on
                                    width: 3; height: parent.height
                                    color: modelData.state === "next" || modelData.state === "running" ? deck.theme.violet : "transparent"
                                }
                                Text {
                                    width: 32
                                    text: modelData.t
                                    color: deck.theme.muted
                                    font.pixelSize: 10; font.family: "monospace"
                                }
                                Text {
                                    width: 14
                                    text: ({ ok: "✓", bad: "✗", info: "•", running: "⟳", next: "▶", later: "·" })[modelData.state]
                                    color: parent.tone
                                    font.pixelSize: 12; font.bold: true
                                }
                                Text {
                                    width: 78
                                    text: modelData.label
                                    color: parent.tone
                                    font.pixelSize: 11; font.bold: modelData.state !== "later"
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: 88
                                    text: onDeck.repoName(modelData.repo)
                                    color: modelData.state === "later" ? deck.theme.muted : deck.theme.cyan
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                                Text {
                                    id: detailText
                                    width: parent.width - 3 - 32 - 14 - 78 - 88 - 5 * 6
                                    wrapMode: modelData.state === "bad" ? Text.Wrap : Text.NoWrap
                                    maximumLineCount: modelData.state === "bad" ? 3 : 1
                                    text: modelData.detail || ""
                                    color: modelData.state === "bad" ? deck.theme.red
                                         : modelData.state === "later" ? deck.theme.muted : deck.theme.dim
                                    font.pixelSize: 11
                                    font.family: modelData.state === "running" ? "monospace" : Qt.application.font.family
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        // ---- the question: what Y would do now, and the keys ----
                        Rectangle { width: qCol.width; height: 1; color: deck.theme.muted; opacity: 0.4 }
                        Item {
                            width: qCol.width
                            height: askText.implicitHeight + (keys.visible ? keys.height + 6 : 0) + 4
                            Text {
                                id: askText
                                anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 2 }
                                text: deck.busyRepo !== "" ? (deck.auto ? "A: " : "") + deck.busyLabel + " " + onDeck.repoName(deck.busyRepo) + "…"
                                    : deck.needsLogin ? deck.needsLogin
                                    : deck.loading ? "Reading repos…"
                                    : deck.nextStep ? deck.nextStep.ask
                                    : deck.switchState === "checking" ? "Checking whether a switch is needed…"
                                    : "Nothing left to land or ship"
                                color: deck.needsLogin ? deck.theme.red
                                     : deck.nextStep || deck.busyRepo !== "" ? deck.theme.violet : deck.theme.green
                                font.pixelSize: 14; font.bold: true
                                wrapMode: Text.Wrap
                            }
                            Row {
                                id: keys
                                anchors { top: askText.bottom; topMargin: 6; left: parent.left }
                                spacing: 6
                                visible: (!!deck.nextStep || !!deck.needsLogin) && (deck.busyRepo === "" || deck.auto)
                                Chip {
                                    visible: !!deck.nextStep && !deck.needsLogin && !deck.auto
                                    text: "Y  yes"; tone: deck.theme.violet; filled: true; action: true
                                    enabledAction: deck.idle
                                    onClicked: deck.yes()
                                }
                                Chip {
                                    visible: !!deck.nextStep && !deck.needsLogin && !deck.auto
                                    text: "A  all"; tone: deck.theme.violet; filled: true; action: true
                                    enabledAction: deck.idle
                                    onClicked: deck.all()
                                }
                                Chip {
                                    visible: !!deck.nextStep && !deck.needsLogin
                                    text: deck.auto ? "N  stop" : "N  skip"; tone: deck.theme.violet; action: true
                                    enabledAction: deck.idle || deck.auto
                                    onClicked: deck.no()
                                }
                                Chip {
                                    visible: !!deck.needsLogin
                                    text: "Y  log in"; tone: deck.theme.red; filled: true; action: true
                                    onClicked: deck.logIn()
                                }
                            }
                        }
                    }
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
                                        visible: false     // progress and results are in the log
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
