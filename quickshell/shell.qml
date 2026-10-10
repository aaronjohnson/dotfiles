import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire

ShellRoot {
    id: root

    // ---- Shared system stats ----
    // These live on ShellRoot (not inside the per-screen PanelWindow) so the
    // timers/readers run once no matter how many monitors you have.

    // ---- Dial laps: tune the spirographs here ----
    // On a polar-clock graph one revolution lasts this many seconds. When that
    // is shorter than the graph's history (30 minutes for temperature, clock,
    // fan and power), the history wraps round as several overlapping laps,
    // older laps fainter, like a spirograph. Graphs not listed make one lap
    // over their whole history. Keys are the graphs' keys in the dropdown:
    // wifi, net, mem, npu, cpu, temp, clock, fan, power, gpu-busy-N, gpu-clock-N.
    property var dialPeriods: ({
        temp: 300,                       // CPU package temperature: 5 min laps (6 laps)
        fan: 300,                        // fan speed: 5 min laps (6 laps)
        clock: 120,                      // average CPU clock: 2 min laps (15 laps)
        power: 600                       // battery power: 10 min laps (3 laps)
    })

    property int netSamples: 150         // sparkline history (150 x 2s = 5 minutes)
    property int netIntervalMs: 2000
    property var rxHistory: []           // bytes/sec, oldest first
    property var txHistory: []
    property real rxRate: 0
    property real txRate: 0
    property real lastRx: -1
    property real lastTx: -1

    property int wifiSignal: -1          // 0-100, -1 = not connected
    property string wifiSsid: ""

    // MLO link state from `iw`: one entry per radio link, e.g.
    // [{ id: 1, freq: 5220, active: false }, { id: 2, freq: 6535, active: true }]
    property var wifiLinks: []
    property int wifiWidth: 0            // channel width (MHz) of the active link
    property int wifiDbm: 0
    property real wifiBitrate: 0         // Mbit/s

    // ---- Sunrise / sunset ----
    // Calculated here from latitude/longitude (the standard sunrise equation,
    // accurate to about a minute), so it needs no internet and no API.
    property var cities: [
        { code: "VAN", name: "Vancouver WA", lat: 45.6387, lon: -122.6615, tz: "America/Los_Angeles", home: true },
        { code: "LON", name: "London",       lat: 51.5074, lon: -0.1278,  tz: "Europe/London" },
        { code: "TYO", name: "Tokyo",        lat: 35.6762, lon: 139.6503, tz: "Asia/Tokyo" },
        { code: "BUE", name: "Buenos Aires", lat: -34.6037, lon: -58.3816, tz: "America/Argentina/Buenos_Aires" }
    ]
    property var tzOffsets: [-420, 60, 540, -180]   // minutes from UTC; refreshed hourly for DST
    property real nowMs: Date.now()

    // ---- Theme: Solarized, light by day and dark by night ----
    // At Vancouver's sunrise and sunset the bar flips the system colour scheme,
    // which kitty (~/.config/kitty/*-theme.auto.conf) and GTK apps follow too.
    // Click the VAN sky to flip it by hand; the next sunrise/sunset takes over again.
    readonly property var solarizedDark: ({
        bg: "#002b36", surface: "#073642", muted: "#586e75", dim: "#657b83",
        fg: "#93a1a1", night: "#268bd2", moonLit: "#eee8d5",
        yellow: "#b58900", orange: "#cb4b16", red: "#dc322f", violet: "#6c71c4",
        blue: "#268bd2", cyan: "#2aa198", green: "#859900"
    })
    readonly property var solarizedLight: ({
        bg: "#fdf6e3", surface: "#eee8d5", muted: "#93a1a1", dim: "#839496",
        fg: "#586e75", night: "#268bd2", moonLit: "#657b83",
        yellow: "#b58900", orange: "#cb4b16", red: "#dc322f", violet: "#6c71c4",
        blue: "#268bd2", cyan: "#2aa198", green: "#859900"
    })
    property bool lightMode: false
    readonly property var c: lightMode ? solarizedLight : solarizedDark

    // "#rrggbb" plus opacity -> "rgba(r, g, b, a)", for the canvas drawings.
    function alpha(hex, a) {
        return "rgba(" + parseInt(hex.substr(1, 2), 16) + "," + parseInt(hex.substr(3, 2), 16) + ","
               + parseInt(hex.substr(5, 2), 16) + "," + a + ")";
    }

    // cities[0] is home. Re-evaluated once a minute with nowMs.
    readonly property bool homeIsDay: sunState(cities[0], tzOffsets[0], nowMs).isDay
    onHomeIsDayChanged: setTheme(homeIsDay)
    Component.onCompleted: setTheme(homeIsDay)

    function setTheme(light) {
        lightMode = light;
        schemeSetter.running = false;
        schemeSetter.running = true;
    }

    // color-scheme is what kitty, libadwaita/GTK4 apps and the desktop portal
    // read; gtk-theme covers older GTK3 apps; makoctl recolours notifications.
    Process {
        id: schemeSetter
        command: ["sh", "-c",
                  "gsettings set org.gnome.desktop.interface color-scheme " + (root.lightMode ? "prefer-light" : "prefer-dark")
                  + "; gsettings set org.gnome.desktop.interface gtk-theme " + (root.lightMode ? "Adwaita" : "Adwaita-dark")
                  + "; makoctl mode -s " + (root.lightMode ? "light" : "dark") + " 2>/dev/null"]
    }


    // One shared clock for the bar and the sun skies. It wakes exactly on each
    // minute boundary instead of every second, since nothing shows seconds.
    Timer {
        id: minuteTimer
        interval: 60000 - (Date.now() % 60000) + 50
        running: true
        onTriggered: {
            root.nowMs = Date.now();
            interval = 60000 - (root.nowMs % 60000) + 50;
            restart();
        }
    }

    // ---- Battery ----
    // Read straight from sysfs with FileView: no `cat` process per refresh.
    property string batDir: "/sys/class/power_supply/BAT1/"
    property int batPercent: -1
    property string batStatus: ""        // Charging / Discharging / Full / Not charging
    property real batMinutesLeft: -1     // to empty when discharging, to full when charging
    property real batWatts: 0            // power into (+) or out of (-) the battery
    property real chargerWatts: 0        // what the USB-C charger agreed to supply; 0 = none

    FileView { id: batCapacity; blockLoading: true; path: root.batDir + "capacity" }
    FileView { id: batStatusFile; blockLoading: true; path: root.batDir + "status" }
    FileView { id: batChargeNow; blockLoading: true; path: root.batDir + "charge_now" }
    FileView { id: batChargeFull; blockLoading: true; path: root.batDir + "charge_full" }
    FileView { id: batCurrent; blockLoading: true; path: root.batDir + "current_now" }
    FileView { id: batVoltage; blockLoading: true; path: root.batDir + "voltage_now" }

    // USB-C chargers: the firmware reports one power supply per port (UCSI). The
    // online one carries the negotiated contract: voltage, and the current
    // allowed. Its path is only pointed at the charger while one is connected.
    property var ucsiPorts: [1, 2, 3, 4].map(function (n) {
        return "/sys/class/power_supply/ucsi-source-psy-USBC000:00" + n + "/";
    })
    FileView { id: ucsiOnline1; blockLoading: true; path: root.ucsiPorts[0] + "online" }
    FileView { id: ucsiOnline2; blockLoading: true; path: root.ucsiPorts[1] + "online" }
    FileView { id: ucsiOnline3; blockLoading: true; path: root.ucsiPorts[2] + "online" }
    FileView { id: ucsiOnline4; blockLoading: true; path: root.ucsiPorts[3] + "online" }
    property string chargerDir: ""
    FileView { id: chargerVoltage; blockLoading: true; path: root.chargerDir ? root.chargerDir + "voltage_now" : "" }
    FileView { id: chargerCurrent; blockLoading: true; path: root.chargerDir ? root.chargerDir + "current_max" : "" }

    function readCharger() {
        var online = [ucsiOnline1, ucsiOnline2, ucsiOnline3, ucsiOnline4];
        var dir = "";
        for (var i = 0; i < online.length; i++) {
            online[i].reload();
            if (online[i].text().trim() === "1") dir = root.ucsiPorts[i];
        }
        root.chargerDir = dir;
        if (!dir) { root.chargerWatts = 0; return; }
        chargerVoltage.reload();
        chargerCurrent.reload();
        // microvolts x microamps -> watts
        root.chargerWatts = Number(chargerVoltage.text()) * Number(chargerCurrent.text()) / 1e12;
    }

    function readBattery() {
        var files = [batCapacity, batStatusFile, batChargeNow, batChargeFull, batCurrent, batVoltage];
        for (var i = 0; i < files.length; i++) files[i].reload();
        root.batPercent = parseInt(batCapacity.text());
        root.batStatus = batStatusFile.text().trim();
        var now = Number(batChargeNow.text()), full = Number(batChargeFull.text());
        var current = Number(batCurrent.text());
        if (current > 0 && root.batStatus === "Discharging")
            root.batMinutesLeft = now / current * 60;
        else if (current > 0 && root.batStatus === "Charging")
            root.batMinutesLeft = (full - now) / current * 60;
        else
            root.batMinutesLeft = -1;
        root.batWatts = powerFrom(current);
        root.readCharger();
    }

    // Power into (+) or out of (-) the battery, from the files already reloaded.
    function powerFrom(current) {
        var watts = current * Number(batVoltage.text()) / 1e12;   // µA x µV -> W
        return root.batStatus === "Discharging" ? -watts : watts;
    }

    // Just the power, for the 2 s history: three small sysfs reads.
    function readPower() {
        batCurrent.reload();
        batVoltage.reload();
        batStatusFile.reload();
        root.batStatus = batStatusFile.text().trim();
        root.batWatts = powerFrom(Number(batCurrent.text()));
    }

    function formatMinutes(m) {
        m = Math.round(m);
        return Math.floor(m / 60) + "h" + (m % 60 < 10 ? "0" : "") + (m % 60);
    }

    Timer {
        interval: 10000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.readBattery()
    }

    // ---- Brightness ----
    // sysfs can't notify on changes, so the bar re-reads it with the battery
    // and right after you scroll it. Writing goes through brightnessctl,
    // which has permission to change the backlight.
    property string blDir: "/sys/class/backlight/intel_backlight/"
    property int brightnessPct: -1

    FileView { id: blNow; blockLoading: true; path: root.blDir + "brightness" }
    FileView { id: blMax; blockLoading: true; path: root.blDir + "max_brightness" }

    function readBrightness() {
        blNow.reload();
        blMax.reload();
        var max = Number(blMax.text());
        if (max > 0) root.brightnessPct = Math.round(Number(blNow.text()) / max * 100);
    }

    Process {
        id: brightnessSetter
        onExited: root.readBrightness()
    }

    function stepBrightness(up) {
        if (brightnessSetter.running) return;
        brightnessSetter.command = ["brightnessctl", "-q", "-c", "backlight", "set", up ? "5%+" : "5%-"];
        brightnessSetter.running = true;
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.readBrightness()
    }

    // ---- NPU ----
    // The intel_vpu driver keeps a running total of NPU busy time. Reading it
    // (on the network graph's 2s tick) leaves the NPU asleep, so watching costs nothing.
    property string npuDir: "/sys/class/accel/accel0/device/"
    property bool npuPresent: false
    property bool npuAwake: false
    property real npuLoad: 0             // share of the last tick the NPU was busy, 0..1
    property real npuLastBusy: -1
    property int npuMHz: 0

    FileView { id: npuBusy; blockLoading: true; path: root.npuDir + "npu_busy_time_us" }
    FileView { id: npuFreq; blockLoading: true; path: root.npuDir + "npu_current_frequency_mhz" }
    FileView { id: npuPm; blockLoading: true; path: root.npuDir + "power/runtime_status" }

    function readNpu() {
        npuBusy.reload();
        var busy = Number(npuBusy.text());
        root.npuPresent = npuBusy.text().length > 0;
        if (!root.npuPresent) return;
        npuFreq.reload();
        npuPm.reload();
        root.npuAwake = npuPm.text().trim() === "active";
        root.npuMHz = Number(npuFreq.text()) || 0;
        if (root.npuLastBusy >= 0) {
            root.npuLoad = Math.max(0, Math.min(1, (busy - root.npuLastBusy) / (root.netIntervalMs * 1000)));
            root.npuHistory = pushHist(root.npuHistory, root.npuLoad, root.netSamples);
        }
        root.npuLastBusy = busy;
    }

    // ---- Memory ----
    // /proc/meminfo on the same 2s tick: used = MemTotal - MemAvailable, which
    // is what the kernel thinks apps really hold (page cache doesn't count).
    property var memHistory: []          // used share 0..1, oldest first
    property var memInfo: ({})           // kB fields from /proc/meminfo
    property real memTotalKb: 0
    property real memUsedKb: 0

    FileView { id: memFile; blockLoading: true; path: "/proc/meminfo" }

    function readMem() {
        memFile.reload();
        var info = {}, lines = memFile.text().split("\n");
        for (var i = 0; i < lines.length; i++) {
            var m = lines[i].match(/^(\w+):\s+(\d+)/);
            if (m) info[m[1]] = Number(m[2]);
        }
        if (!(info.MemTotal > 0)) return;
        root.memInfo = info;
        root.memTotalKb = info.MemTotal;
        root.memUsedKb = info.MemTotal - info.MemAvailable;
        root.memHistory = root.memHistory.concat([root.memUsedKb / root.memTotalKb]).slice(-root.netSamples);
    }

    // kB -> "6.1G" / "512M"
    function formatKb(kb) {
        if (kb >= 1048576) return (kb / 1048576).toFixed(1) + "G";
        if (kb >= 1024) return Math.round(kb / 1024) + "M";
        return Math.round(kb) + "K";
    }

    // ---- CPU ----
    // /proc/stat deltas on the 2s tick: busy = everything but idle and iowait.
    // The first line is all cores together, then one line per core.
    property var cpuHistory: []          // overall load 0..1, oldest first
    property real cpuLoad: 0
    property var cpuCoreLoad: []         // per core, 0..1
    property var cpuIds: []              // core numbers, from /proc/stat
    property var cpuLastTimes: []        // [busy, total] jiffies per /proc/stat line

    FileView { id: statFile; blockLoading: true; path: "/proc/stat" }

    function readCpu() {
        statFile.reload();
        var lines = statFile.text().split("\n"), now = [], ids = [];
        for (var i = 0; i < lines.length && lines[i].startsWith("cpu"); i++) {
            var f = lines[i].split(/\s+/), total = 0;
            for (var j = 1; j <= 8; j++) total += Number(f[j]);   // user..steal (guest is inside user)
            now.push([total - Number(f[4]) - Number(f[5]), total]);
            if (i > 0) ids.push(Number(f[0].substring(3)));
        }
        var last = root.cpuLastTimes;
        if (last.length === now.length) {
            var loads = now.map(function (t, k) {
                var dt = t[1] - last[k][1];
                return dt > 0 ? Math.max(0, Math.min(1, (t[0] - last[k][0]) / dt)) : 0;
            });
            root.cpuLoad = loads[0];
            root.cpuCoreLoad = loads.slice(1);
            root.cpuHistory = root.cpuHistory.concat([loads[0]]).slice(-root.netSamples);
        }
        root.cpuLastTimes = now;
        if (root.cpuIds.length !== ids.length) root.cpuIds = ids;
    }

    // ---- Slow histories ----
    // Cheap sysfs readings kept all the time on the 2 s tick that already
    // wakes the bar for the network and NPU, so they add no wake-ups: CPU
    // package temperature, average CPU clock, battery power (+ charging,
    // - draining) and fan speed, 900 samples each (30 minutes). Wifi signal
    // joins them from its own 20 s reader (90 samples, also 30 minutes),
    // since each wifi read starts a process.
    property int slowSamples: 900
    property int wifiSamples: 90
    property var tempHistory: []         // deg C
    property var clockHistory: []        // GHz, mean over all cores
    property var powerHistory: []        // W, signed like batWatts
    property var fanHistory: []          // rpm
    property var wifiHistory: []         // 0-100, null = offline
    property bool wifiTick: false        // the running wifi read is the 20 s one
    property real cpuClockAvg: -1        // GHz
    property int fanRpm: -1
    property string fanPath: ""          // found at startup; cros_ec preferred

    // The NPU's load on its 2 s tick (the counter read leaves it asleep).
    property var npuHistory: []

    FileView { id: fanFile; blockLoading: true; path: root.fanPath }

    function pushHist(arr, v, n) {
        return arr.concat([v]).slice(-n);
    }

    // Per-core clocks (MHz) from cpufreq, as [{ id, mhz, maxMhz }].
    function readCpuFreqs() {
        var freqs = [], inst = cpuFreqFiles.instances;
        for (var i = 0; i < inst.length; i++) {
            inst[i].cur.reload();
            freqs.push({ id: inst[i].modelData, mhz: Number(inst[i].cur.text()) / 1000,
                         maxMhz: Number(inst[i].max.text()) / 1000 });
        }
        return freqs;
    }

    function sampleSlow() {
        var n = root.slowSamples;
        if (root.cpuTempPath !== "") {
            cpuTempFile.reload();
            root.cpuTemp = Number(cpuTempFile.text()) / 1000;
            root.tempHistory = pushHist(root.tempHistory, root.cpuTemp, n);
        }
        var f = readCpuFreqs();
        root.cpuFreqs = f;                   // the dropdown's core rings use these too
        if (f.length > 0) {
            var sum = 0;
            for (var i = 0; i < f.length; i++) sum += f[i].mhz;
            root.cpuClockAvg = sum / f.length / 1000;
            root.clockHistory = pushHist(root.clockHistory, root.cpuClockAvg, n);
        }
        if (root.batPercent >= 0) {
            readPower();
            root.powerHistory = pushHist(root.powerHistory, root.batWatts, n);
        }
        if (root.fanPath !== "") {
            fanFile.reload();
            var rpm = parseInt(fanFile.text());
            if (!isNaN(rpm)) {
                root.fanRpm = rpm;
                root.fanHistory = pushHist(root.fanHistory, rpm, n);
            }
        }
    }

    // ---- Stats dropdown ----
    // Opened by clicking the HUD/NPU group in the bar. Only the GPU and the
    // NPU's memory are read just for it, and only while it is open.
    // statsScreen is the screen it is open on ("" = closed).
    property bool graphsPolar: true      // dropdown graphs: polar clocks (true) or strips
    property var graphModes: ({})        // per-graph overrides: key -> true = polar clock (session only)
    property string statsScreen: ""
    readonly property bool statsOpen: statsScreen !== ""
    onStatsOpenChanged: if (statsOpen) {
        gpuLastIdle = [];                // GPU busy is measured from now, not since the last open
        gpuBusyHist = [];                // and its graphs start now too
        gpuMhzHist = [];
        readDetails();
        if (!wifiReader.running) wifiReader.running = true;
    }

    // Where this machine keeps its sensors, found once at startup (hwmon and
    // card numbers can change between boots): the coretemp "Package id 0"
    // input, the xe GPU's GTs (gt0 = render/compute, gt1 = media), and which
    // cores are P-cores.
    property string cpuTempPath: ""
    property var gpuGts: []              // sysfs dirs, e.g. ".../tile0/gt0"
    property string gpuDriver: ""
    property var cpuPCores: []           // P-core numbers on a hybrid CPU

    Process {
        running: true
        command: ["sh", "-c",
                  "for d in /sys/class/hwmon/hwmon*; do [ \"$(cat $d/name)\" = coretemp ] || continue; "
                  + "for l in $d/temp*_label; do grep -q '^Package' $l && echo \"TEMP ${l%_label}_input\"; done; done; "
                  + "for c in /sys/class/drm/card[0-9]; do dev=$(readlink -f $c/device); "
                  + "echo \"DRV $(basename $(readlink -f $dev/driver))\"; "
                  + "for g in $dev/tile*/gt*; do [ -e $g/gtidle/idle_residency_ms ] && echo \"GT $g\"; done; done; "
                  + "[ -r /sys/devices/cpu_core/cpus ] && echo \"PCORES $(cat /sys/devices/cpu_core/cpus)\"; "
                  + "for d in /sys/class/hwmon/hwmon*; do [ -r $d/fan1_input ] || continue; "
                  + "[ \"$(cat $d/name)\" = cros_ec ] && echo \"FAN $d/fan1_input\" || echo \"FAN2 $d/fan1_input\"; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                var gts = [], fan2 = "", lines = this.text.trim().split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var sp = lines[i].indexOf(" "), key = lines[i].substring(0, sp), val = lines[i].substring(sp + 1);
                    if (key === "TEMP" && root.cpuTempPath === "") root.cpuTempPath = val;
                    else if (key === "DRV" && root.gpuDriver === "") root.gpuDriver = val;
                    else if (key === "GT") gts.push(val);
                    else if (key === "PCORES") root.cpuPCores = root.parseCpuList(val);
                    else if (key === "FAN" && root.fanPath === "") root.fanPath = val;
                    else if (key === "FAN2" && fan2 === "") fan2 = val;
                }
                if (root.fanPath === "") root.fanPath = fan2;   // any other fan, e.g. acpi_fan
                root.gpuGts = gts;
            }
        }
    }

    // Per-core clock, and its maximum (which tells E and LP-E cores apart).
    Variants {
        id: cpuFreqFiles
        model: root.cpuIds
        Scope {
            required property var modelData
            property alias cur: curFreq
            property alias max: maxFreq
            FileView { id: curFreq; blockLoading: true; path: "/sys/devices/system/cpu/cpu" + modelData + "/cpufreq/scaling_cur_freq" }
            FileView { id: maxFreq; blockLoading: true; path: "/sys/devices/system/cpu/cpu" + modelData + "/cpufreq/cpuinfo_max_freq" }
        }
    }

    // GPU: busy share from the change in idle (C6) residency, plus the actual clock.
    Variants {
        id: gpuFiles
        model: root.gpuGts
        Scope {
            required property var modelData
            property alias idle: gtIdle
            property alias act: gtAct
            property alias max: gtMax
            property alias name: gtName
            FileView { id: gtIdle; blockLoading: true; path: modelData + "/gtidle/idle_residency_ms" }
            FileView { id: gtAct; blockLoading: true; path: modelData + "/freq0/act_freq" }
            FileView { id: gtMax; blockLoading: true; path: modelData + "/freq0/max_freq" }
            FileView { id: gtName; blockLoading: true; path: modelData + "/gtidle/name" }
        }
    }

    FileView { id: cpuTempFile; blockLoading: true; path: root.cpuTempPath }
    FileView { id: npuMem; blockLoading: true; path: root.npuDir + "npu_memory_utilization" }
    FileView { id: npuMaxFreq; blockLoading: true; path: root.npuDir + "npu_max_frequency_mhz" }

    property var cpuFreqs: []            // [{ id, mhz, maxMhz }]
    property real cpuTemp: -1            // deg C
    property var gpuStats: []            // [{ name, busy (-1 = not yet), mhz, maxMhz }]
    property var gpuLastIdle: []         // [idle ms, at ms] per GT
    property var gpuBusyHist: []         // per GT: busy 0..1 history (dropdown open only)
    property var gpuMhzHist: []          // per GT: clock history
    property real npuMemBytes: -1
    property int npuMaxMHz: 0

    // CPU clocks and temperature come from sampleSlow on the same tick.
    function readDetails() {
        var gpus = [], lastIdle = [], at = Date.now(), g = gpuFiles.instances;
        for (var k = 0; k < g.length; k++) {
            g[k].idle.reload();
            g[k].act.reload();
            var idle = Number(g[k].idle.text()), prev = root.gpuLastIdle[k];
            var busy = prev && at > prev[1] ? Math.max(0, Math.min(1, 1 - (idle - prev[0]) / (at - prev[1]))) : -1;
            gpus.push({ name: g[k].name.text().trim(), busy: busy,
                        mhz: Number(g[k].act.text()), maxMhz: Number(g[k].max.text()) });
            lastIdle.push([idle, at]);
        }
        root.gpuStats = gpus;
        root.gpuLastIdle = lastIdle;
        // Per-GT histories, only while the dropdown is open (null = no busy figure yet).
        var bh = [], mh = [];
        for (var m = 0; m < gpus.length; m++) {
            bh.push(pushHist(root.gpuBusyHist[m] || [], gpus[m].busy < 0 ? null : gpus[m].busy, root.netSamples));
            mh.push(pushHist(root.gpuMhzHist[m] || [], gpus[m].mhz, root.netSamples));
        }
        root.gpuBusyHist = bh;
        root.gpuMhzHist = mh;

        if (root.npuPresent) {
            npuMem.reload();
            root.npuMemBytes = Number(npuMem.text());
            root.npuMaxMHz = Number(npuMaxFreq.text()) || 0;
        }
    }

    // "0-3,8" -> [0, 1, 2, 3, 8]
    function parseCpuList(s) {
        var out = [], parts = s.trim().split(",");
        for (var i = 0; i < parts.length; i++) {
            var r = parts[i].split("-"), a = parseInt(r[0]), b = r.length > 1 ? parseInt(r[1]) : a;
            for (var n = a; n <= b; n++) out.push(n);
        }
        return out;
    }

    function formatBytes(b) {
        if (b >= 1073741824) return (b / 1073741824).toFixed(2) + " GB";
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB";
        if (b >= 1024) return Math.round(b / 1024) + " KB";
        return Math.round(b) + " B";
    }

    function formatDuration(secs) {
        secs = Math.round(secs);
        var h = Math.floor(secs / 3600), m = Math.floor(secs % 3600 / 60), s = secs % 60;
        return h > 0 ? h + "h " + m + "m" : m > 0 ? m + "m " + s + "s" : s + "s";
    }

    // Time series as dots, the look of the network graph, in one of two views.
    // Click a graph in the dropdown to flip between them (remembered per graph
    // for the session, in root.graphModes under its key).
    //  - Strip: time runs on a log axis. The newest sample sits at the right
    //    edge and older ones crowd toward the left and fade, so the last few
    //    samples get most of the width while the whole history still shows.
    //    valueText sits at the right end, level with the newest dot.
    //  - Polar clock: a full turn is one period (root.dialPeriods; by default the
    //    whole history, else several overlapping laps). "Now" is the faint hand at
    //    12 o'clock and older samples trail anticlockwise behind it, like the wake
    //    of a clock hand; rim ticks mark 5 min, 1 min or 30 s. Radius is the
    //    value, from an inner ring (so old points don't collapse into the centre)
    //    out to the rim; mirrored values swing outward (positive) or inward
    //    (negative) from a zero ring.
    //    valueText sits in the centre.
    // Value axis: linear from lo to hi (autoRange grows it in rangeStep steps
    // to fit), or log10 from 10^logLo to 10^logHi (a zero then draws nothing:
    // idle). mirrored: positive values in tint, negative ones (and values2,
    // e.g. upload) in negTint. null = no sample. Newest dots glow. While live
    // is false (dropdown closed) it never paints.
    component TimeGraph: Item {
      id: tg
      property var values: []
      property var values2: []
      property int samples: root.netSamples   // the history the graph covers
      property int windowMinutes: 5           // how long that is
      // Polar: seconds per revolution (root.dialPeriods, else the whole window).
      readonly property real period: root.dialPeriods[key] > 0 ? root.dialPeriods[key] : windowMinutes * 60
      readonly property int laps: Math.max(1, Math.round(windowMinutes * 60 / period))
      property bool mirrored: false
      property bool logScale: false
      property real logLo: 0
      property real logHi: 1
      property real lo: 0
      property real hi: 1
      property bool autoRange: false
      property real rangeStep: 1
      property var guides: []                 // faint dotted lines (or rings) at these values
      property string tint: root.c.violet
      property string negTint: tint
      property string caption: ""
      property string valueText: ""
      property int valueWidth: valueText !== "" ? 50 : 0
      property bool live: true

      // View: key names this graph in root.graphModes; no key = fixed strip.
      property string key: ""
      property bool polarDefault: root.graphsPolar
      readonly property bool polar: key !== "" && (root.graphModes[key] !== undefined ? root.graphModes[key] : polarDefault)
      property int stripHeight: 40
      property int polarMax: 150              // largest dial diameter
      readonly property real dial: Math.min(width, polarMax)
      height: polar ? dial + (laps > 1 ? 23 : 12) : stripHeight  // polar: square dial, caption under it

      // Repaint only when a sample arrives (or the theme flips), never on a loop.
      onValuesChanged: if (live) graphCanvas.requestPaint()
      onLiveChanged: if (live) graphCanvas.requestPaint()
      onPolarChanged: graphCanvas.requestPaint()

      readonly property var range: {
        var a = lo, b = hi;
        if (autoRange) {
          for (var i = 0; i < values.length; i++) {
            var v = values[i];
            if (typeof v !== "number" || !isFinite(v)) continue;
            if (v > b) b = Math.ceil(v / rangeStep) * rangeStep;
            if (v < a) a = Math.floor(v / rangeStep) * rangeStep;
          }
        }
        return { lo: a, hi: Math.max(b, a + 1e-9) };
      }
      readonly property var latest: {
        var v = values.length ? values[values.length - 1] : null;
        return typeof v === "number" && isFinite(v) ? v : null;
      }

      // 0..1 along the value axis (of |v| when mirrored or log).
      function reach(v) {
        var f;
        if (logScale) {
          var m = Math.abs(v);
          if (m <= 0) return 0;
          f = (Math.log(m) / Math.LN10 - logLo) / (logHi - logLo);
        } else if (mirrored) {
          f = Math.abs(v) / Math.max(Math.abs(range.lo), Math.abs(range.hi));
        } else {
          f = (v - range.lo) / (range.hi - range.lo);
        }
        return Math.max(0, Math.min(1, f));
      }
      // Strip: canvas y for value v, h = canvas height.
      function yOf(v, h) {
        if (mirrored) {
          var mid = h / 2;
          return mid - (v < 0 ? -1 : 1) * reach(v) * (mid - 3);   // leave room for the glow
        }
        return h - 3 - reach(v) * (h - 6);
      }
      // Polar: radius for value v, between inner ring r0 and outer ring r1.
      function rOf(v, r0, r1) {
        if (mirrored) {
          var mid = (r0 + r1) / 2;
          return mid + (v < 0 ? -1 : 1) * reach(v) * (r1 - mid);
        }
        return r0 + reach(v) * (r1 - r0);
      }

      HoverHandler { enabled: tg.key !== ""; cursorShape: Qt.PointingHandCursor }
      TapHandler {
        enabled: tg.key !== ""
        onTapped: {
          var m = Object.assign({}, root.graphModes);
          m[tg.key] = !tg.polar;
          root.graphModes = m;
        }
      }

      Canvas {
        id: graphCanvas
        width: tg.polar ? tg.width : tg.width - tg.valueWidth
        height: tg.height
        property var themeColors: root.c
        onThemeColorsChanged: requestPaint()   // redraw when light/dark flips

        // A dot. The newest three are round with a soft halo; the rest (up to
        // 900 on a 30-minute dial) are plain 2 px squares faded with
        // globalAlpha, which keeps a full repaint cheap.
        function dot(ctx, x, y, age, rgb) {
          if (age >= 3) {
            ctx.globalAlpha = 1 - 0.8 * Math.sqrt(age / tg.samples);
            ctx.fillStyle = rgb;
            ctx.fillRect(x - 1, y - 1, 2, 2);
            ctx.globalAlpha = 1;
            return;
          }
          var r = 2.2 - age * 0.4;
          var g = ctx.createRadialGradient(x, y, 0, x, y, r * 3);
          g.addColorStop(0, root.alpha(rgb, 0.5));
          g.addColorStop(1, root.alpha(rgb, 0));
          ctx.fillStyle = g;
          ctx.beginPath();
          ctx.arc(x, y, r * 3, 0, 2 * Math.PI);
          ctx.fill();
          ctx.fillStyle = rgb;
          ctx.beginPath();
          ctx.arc(x, y, r, 0, 2 * Math.PI);
          ctx.fill();
        }

        // Calls place(v, age) -> [x, y] for each sample, oldest first, so newer
        // dots paint over older ones.
        function eachDot(ctx, place) {
          function series(data, flip) {
            for (var i = 0; i < data.length; i++) {
              var v = data[i];
              if (typeof v !== "number" || !isFinite(v)) continue;
              if (flip) v = -v;
              if (tg.logScale && tg.reach(v) === 0) continue;   // idle: nothing to draw
              var age = data.length - 1 - i;
              var p = place(v, age);
              dot(ctx, p[0], p[1], age, v < 0 ? tg.negTint : tg.tint);
            }
          }
          series(tg.values2, true);
          series(tg.values, false);
        }

        function paintStrip(ctx) {
          var h = height, xSpan = width - 4;
          function xAt(age) {
            return 2 + xSpan * (1 - Math.log(1 + age) / Math.log(1 + tg.samples));
          }
          ctx.fillStyle = root.alpha(root.c.dim, 0.35);
          tg.guides.forEach(function (g) {
            var ys = tg.mirrored ? [tg.yOf(g, h), tg.yOf(-g, h)] : [tg.yOf(g, h)];
            for (var x = 2; x < width; x += 4)
              ys.forEach(function (y) { ctx.fillRect(x, Math.round(y), 1, 1); });
          });
          ctx.fillStyle = root.alpha(root.c.dim, 0.6);
          ctx.fillRect(0, tg.mirrored ? h / 2 - 0.5 : h - 1.5, width, 1);
          eachDot(ctx, function (v, age) { return [xAt(age), tg.yOf(v, h)]; });
        }

        function paintPolar(ctx) {
          var R = tg.dial / 2, cx = width / 2, cy = R;
          var r1 = R - 7, r0 = R * 0.36;             // value rings: inner .. outer
          function at(r, a) { return [cx + r * Math.cos(a), cy + r * Math.sin(a)]; }
          // Age in samples -> angle: now at 12 o'clock, older anticlockwise,
          // wrapping every period (so a short period lays down several laps).
          var secsPerSample = tg.windowMinutes * 60 / tg.samples;
          function angle(age) { return -Math.PI / 2 - (age * secsPerSample % tg.period) / tg.period * 2 * Math.PI; }

          // Rim ticks: every 5 min on long laps, every minute, or every 30 s.
          var tickSec = tg.period >= 1200 ? 300 : tg.period >= 240 ? 60 : 30;
          ctx.strokeStyle = root.alpha(root.c.dim, 0.5);
          ctx.lineWidth = 1;
          for (var t = 0; t < tg.period - 0.5; t += tickSec) {
            var a = -Math.PI / 2 - t / tg.period * 2 * Math.PI;
            var p = at(R - 4, a), q = at(R - 1, a);
            ctx.beginPath();
            ctx.moveTo(p[0], p[1]);
            ctx.lineTo(q[0], q[1]);
            ctx.stroke();
          }
          // Faint rings: the inner edge, guides (dotted), and zero when mirrored.
          ctx.strokeStyle = root.alpha(root.c.dim, 0.25);
          ctx.beginPath();
          ctx.arc(cx, cy, r0, 0, 2 * Math.PI);
          ctx.stroke();
          if (tg.mirrored) {
            ctx.strokeStyle = root.alpha(root.c.dim, 0.6);
            ctx.beginPath();
            ctx.arc(cx, cy, (r0 + r1) / 2, 0, 2 * Math.PI);
            ctx.stroke();
          }
          ctx.fillStyle = root.alpha(root.c.dim, 0.45);
          tg.guides.forEach(function (g) {
            var rs = tg.mirrored ? [tg.rOf(g, r0, r1), tg.rOf(-g, r0, r1)] : [tg.rOf(g, r0, r1)];
            rs.forEach(function (r) {
              var n = Math.max(12, Math.round(2 * Math.PI * r / 4));
              for (var k = 0; k < n; k++) {
                var d = at(r, k / n * 2 * Math.PI);
                ctx.fillRect(d[0] - 0.5, d[1] - 0.5, 1, 1);
              }
            });
          });
          // The "now" hand at 12 o'clock.
          ctx.strokeStyle = root.alpha(root.c.dim, 0.5);
          ctx.beginPath();
          ctx.moveTo(cx, cy - r0);
          ctx.lineTo(cx, cy - R + 1);
          ctx.stroke();

          eachDot(ctx, function (v, age) { return at(tg.rOf(v, r0, r1), angle(age)); });
        }

        onPaint: {
          var ctx = getContext("2d");
          ctx.clearRect(0, 0, width, height);
          ctx.lineWidth = 1;
          if (tg.polar) paintPolar(ctx); else paintStrip(ctx);
        }
      }

      // Current value: beside the newest dot (strip) or in the dial's centre.
      Text {
        visible: tg.valueText !== ""
        x: tg.polar ? (tg.width - width) / 2 : graphCanvas.width + 4
        y: {
          if (tg.polar) return tg.dial / 2 - height / 2;
          var cy = tg.latest === null ? tg.height / 2 : tg.yOf(tg.latest, tg.height);
          return Math.max(-2, Math.min(tg.height - height + 2, cy - height / 2));
        }
        text: tg.valueText
        color: tg.latest !== null && tg.latest < 0 ? tg.negTint : tg.tint
        font.pixelSize: tg.polar ? 12 : 11
        font.bold: true
        font.family: "monospace"
      }
      Text {
        visible: tg.caption !== ""
        x: tg.polar ? (tg.width - width) / 2 : 3
        y: tg.polar ? tg.dial : 0
        width: tg.polar ? implicitWidth : Math.min(implicitWidth, graphCanvas.width - 6)
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        text: tg.caption + (tg.polar && tg.laps > 1
                            ? "\n" + tg.laps + " laps of " + (tg.period >= 60 ? Math.round(tg.period / 60) + " min" : tg.period + " s")
                            : "")
        color: root.c.muted
        font.pixelSize: 9
        font.family: "monospace"
      }
    }

    // Network: mirrored log-log. Download rises above the center line, upload
    // drops below it, on a fixed 100 B/s to 100 MB/s scale so it never
    // rescales; dotted guides at 1 KB/s and 1 MB/s.
    component NetGraph: TimeGraph {
      values: root.rxHistory
      values2: root.txHistory
      mirrored: true
      logScale: true
      logLo: 2                                // 10^2 = 100 B/s
      logHi: 8                                // 10^8 = 100 MB/s
      guides: [1e3, 1e6]
      tint: root.c.blue
      negTint: root.c.orange
    }

    // Dropdown section heading and body text.
    component StatTitle: Text {
      color: root.c.fg
      font.pixelSize: 12
      font.bold: true
      font.family: "monospace"
    }
    component StatText: Text {
      color: root.c.dim
      font.pixelSize: 12
      font.family: "monospace"
      textFormat: Text.PlainText
    }

    // ---- Volume ----
    // PipeWire pushes changes to Quickshell, so there is no polling at all.
    // The tracker keeps the default output's volume data live.
    property var sink: Pipewire.defaultAudioSink

    PwObjectTracker { objects: [root.sink] }

    function stepVolume(up) {
        if (!root.sink || !root.sink.audio) return;
        var v = root.sink.audio.volume + (up ? 0.05 : -0.05);
        root.sink.audio.volume = Math.max(0, Math.min(1, Math.round(v * 20) / 20));
    }

    // QML's JavaScript has no time zone database, so ask `date` once an hour
    // for each city's current UTC offset (this is what tracks DST changes).
    Process {
        id: tzReader
        command: ["sh", "-c", "for z in " + root.cities.map(function (c) { return c.tz; }).join(" ")
                  + "; do TZDIR=/etc/zoneinfo TZ=$z date +%z; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.trim().split("\n");
                if (lines.length !== root.cities.length) return;
                root.tzOffsets = lines.map(function (z) {
                    var sign = z[0] === "-" ? -1 : 1;
                    return sign * (parseInt(z.substring(1, 3)) * 60 + parseInt(z.substring(3, 5)));
                });
            }
        }
    }

    Timer {
        interval: 3600000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: tzReader.running = true
    }

    // Sunrise/sunset (unix ms) for the city's local calendar day containing nowMs.
    function sunTimes(lat, lon, offsetMin, nowMs) {
        var rad = Math.PI / 180;
        var localDays = Math.floor((nowMs + offsetMin * 60000) / 86400000);
        var jStar = localDays - 10957 - lon / 360;   // days since J2000, at local solar noon
        var M = (357.5291 + 0.98560028 * jStar) % 360;
        var C = 1.9148 * Math.sin(M * rad) + 0.02 * Math.sin(2 * M * rad) + 0.0003 * Math.sin(3 * M * rad);
        var L = (M + C + 180 + 102.9372) % 360;
        var transit = 2451545 + jStar + 0.0053 * Math.sin(M * rad) - 0.0069 * Math.sin(2 * L * rad);
        var sinD = Math.sin(L * rad) * Math.sin(23.4397 * rad);
        var cosW = (Math.sin(-0.833 * rad) - Math.sin(lat * rad) * sinD)
                   / (Math.cos(lat * rad) * Math.cos(Math.asin(sinD)));
        var w = Math.acos(Math.max(-1, Math.min(1, cosW))) / rad / 360;
        return { rise: (transit - w - 2440587.5) * 86400000, set: (transit + w - 2440587.5) * 86400000 };
    }

    // Everything the widget needs for one city: is it day, how far through the
    // day (or night) it is, and the next sunrise or sunset.
    function sunState(city, offsetMin, now) {
        var day = 86400000;
        var t = sunTimes(city.lat, city.lon, offsetMin, now);
        var s = { rise: t.rise, set: t.set, offset: offsetMin };
        if (now >= t.rise && now < t.set) {
            s.isDay = true;
            s.frac = (now - t.rise) / (t.set - t.rise);
            s.next = t.set;
        } else {
            var prevSet = now < t.rise ? sunTimes(city.lat, city.lon, offsetMin, now - day).set : t.set;
            var nextRise = now < t.rise ? t.rise : sunTimes(city.lat, city.lon, offsetMin, now + day).rise;
            s.isDay = false;
            s.frac = (now - prevSet) / (nextRise - prevSet);
            s.next = nextRise;
        }
        return s;
    }

    // Lunar ephemeris (after Agafonkin's SunCalc, BSD, plus the main Meeus terms).
    // Checked against PyEphem: moonrise/moonset within 4 minutes.
    function moonApi() {
        var rad = Math.PI / 180, e = rad * 23.4397;
        function toDays(ms) { return ms / 86400000 - 0.5 + 2440588 - 2451545; }
        function ra(l, b) { return Math.atan2(Math.sin(l) * Math.cos(e) - Math.tan(b) * Math.sin(e), Math.cos(l)); }
        function dec(l, b) { return Math.asin(Math.sin(b) * Math.cos(e) + Math.cos(b) * Math.sin(e) * Math.sin(l)); }
        function moonCoords(d) {
            var L = rad * (218.316 + 13.176396 * d), M = rad * (134.963 + 13.064993 * d), F = rad * (93.272 + 13.229350 * d);
            var D = rad * (297.850 + 12.190749 * d), S = rad * (357.529 + 0.98560028 * d), sin = Math.sin;
            // The main periodic terms (Meeus ch. 47, largest first): orbit shape,
            // evection, variation, the sun's pull, then smaller wobbles.
            var l = L + rad * (6.289 * sin(M) - 1.274 * sin(M - 2 * D) + 0.658 * sin(2 * D) - 0.186 * sin(S)
                               - 0.059 * sin(2 * M - 2 * D) - 0.057 * sin(M - 2 * D + S) + 0.053 * sin(M + 2 * D)
                               + 0.046 * sin(2 * D - S) + 0.041 * sin(M - S) - 0.035 * sin(D) - 0.031 * sin(M + S)
                               - 0.015 * sin(2 * F - 2 * D) + 0.011 * sin(M - 4 * D));
            var b = rad * (5.128 * sin(F) + 0.281 * sin(M + F) + 0.278 * sin(M - F) + 0.173 * sin(2 * D - F)
                           + 0.055 * sin(2 * D - M + F) + 0.046 * sin(2 * D - M - F) + 0.033 * sin(2 * D + F)
                           + 0.017 * sin(2 * M + F));
            var dist = 385001 - 20905 * Math.cos(M) - 3699 * Math.cos(2 * D - M) - 2956 * Math.cos(2 * D);
            return { ra: ra(l, b), dec: dec(l, b), dist: dist };
        }
        function sunCoords(d) {
            var M = rad * (357.5291 + 0.98560028 * d);
            var L = M + rad * (1.9148 * Math.sin(M) + 0.02 * Math.sin(2 * M) + 0.0003 * Math.sin(3 * M)) + rad * 102.9372 + Math.PI;
            return { ra: ra(L, 0), dec: dec(L, 0) };
        }
        // How far the moon's centre is above the altitude at which its top edge
        // touches the horizon (radians; positive = visible). The rising altitude
        // depends on distance: h0 = 0.7275 x parallax - 0.5667 deg (Meeus ch. 15),
        // which folds in refraction, the moon's radius and its parallax.
        function moonAlt(ms, lat, lon) {
            var d = toDays(ms), c = moonCoords(d), phi = rad * lat;
            var H = rad * (280.16 + 360.9856235 * d) + rad * lon - c.ra;
            var h = Math.asin(Math.sin(phi) * Math.sin(c.dec) + Math.cos(phi) * Math.cos(c.dec) * Math.cos(H));
            var h0 = 0.7275 * Math.asin(6378.14 / c.dist) - rad * 0.5667;
            return h - h0;
        }
        // Rise/set within the 24h after startMs, by stepping 2h and fitting a parabola.
        function moonTimes(startMs, lat, lon) {
            var hour = 3600000, rise, set, ye = 0;
            var h0 = moonAlt(startMs, lat, lon);
            for (var i = 1; i <= 24; i += 2) {
                var h1 = moonAlt(startMs + i * hour, lat, lon);
                var h2 = moonAlt(startMs + (i + 1) * hour, lat, lon);
                var a = (h0 + h2) / 2 - h1, b = (h2 - h0) / 2, xe = -b / (2 * a);
                ye = (a * xe + b) * xe + h1;
                var disc = b * b - 4 * a * h1, roots = 0, x1 = 0, x2 = 0;
                if (disc >= 0) {
                    var dx = Math.sqrt(disc) / (Math.abs(a) * 2);
                    x1 = xe - dx; x2 = xe + dx;
                    if (Math.abs(x1) <= 1) roots++;
                    if (Math.abs(x2) <= 1) roots++;
                    if (x1 < -1) x1 = x2;
                }
                if (roots === 1) { if (h0 < 0) rise = i + x1; else set = i + x1; }
                else if (roots === 2) { rise = i + (ye < 0 ? x2 : x1); set = i + (ye < 0 ? x1 : x2); }
                if (rise !== undefined && set !== undefined) break;
                h0 = h2;
            }
            return { rise: rise === undefined ? NaN : startMs + rise * hour,
                     set: set === undefined ? NaN : startMs + set * hour };
        }
        // phase: 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter. fraction: lit share.
        function moonPhase(ms) {
            var d = toDays(ms), s = sunCoords(d), m = moonCoords(d), sdist = 149598000;
            var phi = Math.acos(Math.sin(s.dec) * Math.sin(m.dec) + Math.cos(s.dec) * Math.cos(m.dec) * Math.cos(s.ra - m.ra));
            var inc = Math.atan2(sdist * Math.sin(phi), m.dist - sdist * Math.cos(phi));
            var angle = Math.atan2(Math.cos(s.dec) * Math.sin(s.ra - m.ra),
                                   Math.sin(s.dec) * Math.cos(m.dec) - Math.cos(s.dec) * Math.sin(m.dec) * Math.cos(s.ra - m.ra));
            return { fraction: (1 + Math.cos(inc)) / 2, phase: 0.5 + 0.5 * inc * (angle < 0 ? -1 : 1) / Math.PI };
        }
        return { moonAlt: moonAlt, moonTimes: moonTimes, moonPhase: moonPhase };
    }

    readonly property var moonLib: moonApi()
    // Phase is the same everywhere on Earth, so work it out once per minute.
    property var moonPhaseNow: moonLib.moonPhase(nowMs)

    function phaseName(p) {
        var names = ["New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
                     "Full moon", "Waning gibbous", "Last quarter", "Waning crescent"];
        var icons = ["🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘"];
        var i = Math.round(p * 8) % 8;
        return icons[i] + " " + names[i];
    }

    // Moon for one city: is it up, how far across the sky it is (0..1 from
    // moonrise to moonset), today's rise/set, and the next event. Moonrise drifts
    // ~50 min later each day, so look at yesterday, today and tomorrow.
    function moonState(city, offsetMin, now) {
        var day = 86400000;
        var start = Math.floor((now + offsetMin * 60000) / day) * day - offsetMin * 60000;
        var events = [], today = null;
        for (var k = -1; k <= 1; k++) {
            var t = moonLib.moonTimes(start + k * day, city.lat, city.lon);
            if (k === 0) today = t;
            if (!isNaN(t.rise)) events.push({ t: t.rise, rise: true });
            if (!isNaN(t.set)) events.push({ t: t.set, rise: false });
        }
        events.sort(function (a, b) { return a.t - b.t; });
        var prevRise = NaN, nextSet = NaN, next = null;
        for (var i = 0; i < events.length; i++) {
            if (events[i].t <= now && events[i].rise) prevRise = events[i].t;
            if (events[i].t > now) {
                if (!next) next = events[i];
                if (!events[i].rise && isNaN(nextSet)) nextSet = events[i].t;
            }
        }
        var up = moonLib.moonAlt(now, city.lat, city.lon) > 0;
        return {
            up: up,
            frac: up && !isNaN(prevRise) && !isNaN(nextSet) ? (now - prevRise) / (nextSet - prevRise) : -1,
            rise: today.rise,
            set: today.set,
            next: next
        };
    }

    function clockAt(ms, offsetMin) {
        var d = new Date(ms + offsetMin * 60000);
        function pad(n) { return (n < 10 ? "0" : "") + n; }
        return pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes());
    }

    function bandOf(freq) {
        return freq < 3000 ? "2.4" : freq < 5925 ? "5" : "6";
    }

    function formatRate(bytesPerSec) {
        if (bytesPerSec >= 1048576) return (bytesPerSec / 1048576).toFixed(1) + "M";
        if (bytesPerSec >= 1024) return Math.round(bytesPerSec / 1024) + "K";
        return Math.round(bytesPerSec) + "B";
    }

    // `iw dev X info` lists the MLO links and gives a channel line only for the
    // link that is currently up; `iw dev X link` gives every link's frequency.
    // A plain (non-MLO) connection has no "Link N" lines, so it becomes link 0.
    function parseIw(text) {
        var links = {}, order = [];
        var activeId = -1, width = 0, dbm = 0, bitrate = 0;
        var infoLink = -1, linkLink = 0;
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i], m;
            if ((m = line.match(/- link ID\s+(\d+)/))) {
                infoLink = parseInt(m[1]);
            } else if ((m = line.match(/channel \d+ \((\d+) MHz\), width: (\d+) MHz/))) {
                activeId = infoLink >= 0 ? infoLink : 0;
                width = parseInt(m[2]);
            } else if ((m = line.match(/Link (\d+) BSSID/))) {
                linkLink = parseInt(m[1]);
            } else if ((m = line.match(/^\s*freq: ([\d.]+)/))) {
                if (!(linkLink in links)) order.push(linkLink);
                links[linkLink] = Math.round(parseFloat(m[1]));
            } else if ((m = line.match(/^\s*signal: (-?\d+) dBm/))) {
                dbm = parseInt(m[1]);
            } else if ((m = line.match(/tx bitrate: ([\d.]+) MBit/))) {
                bitrate = parseFloat(m[1]);
            }
        }
        if (order.length === 1) activeId = order[0];
        root.wifiLinks = order.map(function (id) {
            return { id: id, freq: links[id], active: id === activeId };
        });
        root.wifiWidth = width;
        root.wifiDbm = dbm;
        root.wifiBitrate = bitrate;
    }

    // /proc/net/dev holds byte counters for every interface. Reading it through
    // FileView happens inside quickshell itself, so no process is spawned per sample.
    FileView {
        id: netDev
        path: "/proc/net/dev"
        onLoaded: {
            var rx = 0, tx = 0;
            var lines = this.text().split("\n");
            for (var i = 2; i < lines.length; i++) {
                var parts = lines[i].split(":");
                if (parts.length < 2 || parts[0].trim() === "lo") continue;
                var f = parts[1].trim().split(/\s+/);
                rx += Number(f[0]);
                tx += Number(f[8]);
            }
            if (root.lastRx >= 0) {
                var secs = root.netIntervalMs / 1000;
                root.rxRate = Math.max(0, (rx - root.lastRx) / secs);
                root.txRate = Math.max(0, (tx - root.lastTx) / secs);
                root.rxHistory = root.rxHistory.concat([root.rxRate]).slice(-root.netSamples);
                root.txHistory = root.txHistory.concat([root.txRate]).slice(-root.netSamples);
            }
            root.lastRx = rx;
            root.lastTx = tx;
        }
    }

    Timer {
        interval: root.netIntervalMs
        running: true
        repeat: true
        onTriggered: {
            netDev.reload();
            root.readNpu();
            root.readMem();
            root.readCpu();
            root.sampleSlow();
            if (root.statsOpen) root.readDetails();
        }
    }

    // Wifi signal: ask NetworkManager for the signal it already has cached
    // (--rescan no), so this never triggers a power-hungry radio scan.
    // The same process then asks `iw` for the MLO links. Both only read state
    // the driver already holds, and one shell per refresh covers both.
    Process {
        id: wifiReader
        command: ["sh", "-c",
                  "nmcli -t -f IN-USE,SIGNAL,SSID device wifi list --rescan no; echo @@IW; " +
                  "command -v iw >/dev/null && for i in $(iw dev | awk '/Interface/{print $2}'); " +
                  "do iw dev \"$i\" info; iw dev \"$i\" link; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                var sections = this.text.split("@@IW");
                root.parseIw(sections.length > 1 ? sections[1] : "");
                var signal = -1, ssid = "";
                var lines = sections[0].split("\n");
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i].startsWith("*:")) {
                        var rest = lines[i].substring(2);
                        var sep = rest.indexOf(":");
                        signal = parseInt(rest.substring(0, sep));
                        ssid = rest.substring(sep + 1).replace(/\\:/g, ":");
                        break;
                    }
                }
                root.wifiSignal = signal;
                root.wifiSsid = ssid;
                // History only from the 20 s timer's reads, not hover/open refreshes.
                if (root.wifiTick) {
                    root.wifiTick = false;
                    root.wifiHistory = root.pushHist(root.wifiHistory, signal >= 0 ? signal : null, root.wifiSamples);
                }
            }
        }
    }

    // Click the wifi widget to flip between a router's paired networks, worked
    // out from the current name: "Home_MLO" <-> "Home_6G". No network names are
    // stored here. Each needs a saved NetworkManager profile with that name.
    property string wifiPartner: wifiSsid.endsWith("_MLO") ? wifiSsid.slice(0, -4) + "_6G"
                               : wifiSsid.endsWith("_6G") ? wifiSsid.slice(0, -3) + "_MLO"
                               : ""

    Process {
        id: wifiSwitcher
        command: ["nmcli", "connection", "up", root.wifiPartner]
        onExited: wifiReader.running = true
    }

    Timer {
        interval: 20000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.wifiTick = true;
            wifiReader.running = true;
        }
    }

    // ---- Autohide ----
    // The bar stays hidden until the pointer touches the top edge of the screen,
    // then fades in over the windows (Hyprland's layer animation) and fades out
    // a second after the pointer leaves it. While hidden, windows get the full
    // screen height. Set autoHide to false for an always-visible bar that
    // reserves its 40 px, as before.
    property bool autoHide: true

    Variants {
        model: Quickshell.screens

        Scope {
          id: screenScope
          required property var modelData
          property bool revealed: false

          // A 1 px invisible strip along the top edge. Touching it reveals the bar.
          PanelWindow {
            screen: screenScope.modelData
            visible: root.autoHide && !screenScope.revealed
            anchors {
              top: true
              left: true
              right: true
            }
            implicitHeight: 1
            exclusiveZone: 0
            color: "transparent"

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: screenScope.revealed = true
            }
          }

        PanelWindow {
	  id: barWindow
	  screen: screenScope.modelData
          visible: !root.autoHide || screenScope.revealed
          anchors {
	    top: true
	    left: true
	    right: true
          }
	  implicitHeight: 40
          exclusiveZone: root.autoHide ? 0 : 40

          // Hide again once the pointer has been off the bar for a second
          // (the stats dropdown, while open, keeps it up).
          Timer {
            interval: 1000
            running: root.autoHide && screenScope.revealed && !barHover.hovered && !statsArea.open
            onTriggered: screenScope.revealed = false
          }

          Rectangle {
            anchors.fill: parent
            color: root.c.bg
            opacity: 0.85

            HoverHandler { id: barHover }

            Row {
              anchors.fill: parent
              anchors.leftMargin: 16
              anchors.rightMargin: 20
              spacing: 18

              // ---- Workspaces: a pill for the focused one, dots for the rest ----
              // Hyprland pushes workspace events to Quickshell, so this never polls.
              // Click a dot to go there. (This Hyprland uses the Lua config, so the
              // switch is sent as hl.dsp.focus(...) rather than the old "workspace N".)
              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5

                Repeater {
                  model: Hyprland.workspaces

                  Rectangle {
                    id: wsDot
                    required property var modelData
                    property bool focused: Hyprland.focusedWorkspace === modelData
                    visible: modelData.id > 0          // hide special/scratch workspaces
                    anchors.verticalCenter: parent.verticalCenter
                    width: focused ? 26 : 10
                    height: 10
                    radius: 5
                    color: focused ? root.c.violet : wsMouse.hovered ? root.c.dim : root.c.muted
                    Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                    Text {
                      anchors.centerIn: parent
                      visible: wsDot.focused
                      text: wsDot.modelData.id
                      color: root.c.bg
                      font.pixelSize: 9
                      font.bold: true
                    }

                    HoverHandler { id: wsMouse }
                    TapHandler {
                      onTapped: Hyprland.dispatch("hl.dsp.focus({workspace = " + wsDot.modelData.id + "})")
                    }
                  }
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDateTime(new Date(root.nowMs), "ddd d MMM  HH:mm")
                color: root.c.fg
                font.pixelSize: 14
                font.family: "monospace"
              }

              // ---- Battery: drawn icon that fills with charge, plus time left ----
              Row {
                id: batWidget
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                visible: root.batPercent >= 0
                property bool charging: root.batStatus === "Charging"
                property color tint: charging ? root.c.green
                                     : root.batPercent < 15 ? root.c.red
                                     : root.batPercent < 30 ? root.c.orange : root.c.yellow

                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  Rectangle {
                    width: 22
                    height: 12
                    radius: 3
                    color: "transparent"
                    border.color: batWidget.tint
                    border.width: 1.5

                    Rectangle {
                      x: 2.5
                      y: 2.5
                      height: parent.height - 5
                      width: Math.max(1, (parent.width - 5) * root.batPercent / 100)
                      radius: 1
                      color: batWidget.tint
                    }

                    Text {
                      anchors.centerIn: parent
                      visible: batWidget.charging
                      text: "⚡"
                      color: root.c.bg
                      font.pixelSize: 9
                    }
                  }
                  Rectangle {                        // the battery's nub
                    anchors.verticalCenter: parent.verticalCenter
                    width: 2
                    height: 5
                    color: batWidget.tint
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.batPercent + "%"
                        + (root.batMinutesLeft > 0
                           ? (batWidget.charging ? "  full in " : "  ") + root.formatMinutes(root.batMinutesLeft)
                           : "")
                  color: batWidget.tint
                  font.pixelSize: 14
                }

                // Power flow: "-44W" draining, "+38W/65W" charging (into the battery /
                // what the charger agreed to supply), "⚡65W" plugged in but not charging.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: text !== ""
                  text: {
                    var w = Math.round(root.batWatts), c = Math.round(root.chargerWatts);
                    if (w > 0) return "+" + w + "W" + (c > 0 ? "/" + c + "W" : "");
                    if (w < 0) return "−" + (-w) + "W";
                    return c > 0 ? "⚡" + c + "W" : "";
                  }
                  color: root.batWatts > 0 ? root.c.green : root.c.dim
                  font.pixelSize: 12
                  font.family: "monospace"
                }
              }

              // ---- Volume and brightness: scroll over them to adjust ----
              // Click the volume to mute. The thin bar under each shows the level.
              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 14

                Column {
                  id: volWidget
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 2
                  property bool muted: root.sink && root.sink.audio ? root.sink.audio.muted : false
                  property real level: root.sink && root.sink.audio ? root.sink.audio.volume : 0

                  Text {
                    text: (volWidget.muted ? "🔇 " : volWidget.level < 0.34 ? "🔈 " : volWidget.level < 0.67 ? "🔉 " : "🔊 ")
                          + Math.round(volWidget.level * 100) + "%"
                    color: volWidget.muted ? root.c.dim : root.c.violet
                    font.pixelSize: 13
                  }
                  Rectangle {
                    width: parent.width
                    height: 2
                    radius: 1
                    color: root.c.surface
                    Rectangle {
                      width: parent.width * Math.min(1, volWidget.level)
                      height: 2
                      radius: 1
                      color: volWidget.muted ? root.c.dim : root.c.violet
                    }
                  }

                  WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => root.stepVolume(event.angleDelta.y > 0)
                  }
                  TapHandler {
                    onTapped: if (root.sink && root.sink.audio) root.sink.audio.muted = !root.sink.audio.muted
                  }
                }

                Column {
                  id: blWidget
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 2
                  visible: root.brightnessPct >= 0

                  Text {
                    text: "☀ " + root.brightnessPct + "%"
                    color: root.c.yellow
                    font.pixelSize: 13
                  }
                  Rectangle {
                    width: parent.width
                    height: 2
                    radius: 1
                    color: root.c.surface
                    Rectangle {
                      width: parent.width * root.brightnessPct / 100
                      height: 2
                      radius: 1
                      color: root.c.yellow
                    }
                  }

                  WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => root.stepBrightness(event.angleDelta.y > 0)
                  }
                }
              }

              // ---- Wifi signal: four bars, lit according to strength ----
              Row {
                id: wifiWidget
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Row {
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 3
                  spacing: 2

                  Repeater {
                    model: 4
                    Rectangle {
                      required property int index
                      anchors.bottom: parent.bottom
                      width: 4
                      height: 5 + index * 4
                      radius: 1
                      color: root.wifiSignal > [0, 30, 55, 80][index] ? root.c.cyan : root.c.surface
                    }
                  }
                }

                Text {
                  text: root.wifiSignal < 0 ? "offline"
                        : root.wifiSignal + "% " + (root.wifiSsid.endsWith("_6G") ? "6G"
                                                  : root.wifiSsid.endsWith("_MLO") ? "MLO" : "")
                  color: wifiSwitcher.running ? root.c.dim
                         : root.wifiSignal < 0 ? root.c.red : root.c.cyan
                  font.pixelSize: 14
                }

                // One chip per MLO link (e.g. "5 6"): bright = carrying traffic now,
                // dim = set up but idle.
                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 3
                  visible: root.wifiSignal >= 0

                  Repeater {
                    model: root.wifiLinks
                    Rectangle {
                      required property var modelData
                      width: chipText.implicitWidth + 6
                      height: 16
                      radius: 3
                      color: modelData.active ? root.c.cyan : "transparent"
                      border.color: modelData.active ? root.c.cyan : root.c.muted
                      border.width: 1

                      Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: root.bandOf(modelData.freq)
                        color: modelData.active ? root.c.bg : root.c.dim
                        font.pixelSize: 11
                        font.bold: modelData.active
                      }
                    }
                  }
                }

                TapHandler {
                  onTapped: if (root.wifiPartner !== "" && !wifiSwitcher.running) wifiSwitcher.running = true
                }

                // Hovering refreshes the readings once, so the popup is current
                // without polling faster the rest of the time.
                HoverHandler {
                  id: wifiHover
                  onHoveredChanged: if (hovered && !wifiReader.running) wifiReader.running = true
                }
              }

              PopupWindow {
                anchor.item: wifiWidget
                anchor.edges: Edges.Bottom | Edges.Left
                anchor.gravity: Edges.Bottom | Edges.Right
                anchor.margins.top: 8
                visible: wifiHover.hovered && root.wifiSignal >= 0
                implicitWidth: popupText.implicitWidth + 24
                implicitHeight: popupText.implicitHeight + 16
                color: "transparent"

                Rectangle {
                  anchors.fill: parent
                  color: root.c.bg
                  border.color: root.c.surface
                  radius: 6

                  Text {
                    id: popupText
                    anchors.centerIn: parent
                    color: root.c.fg
                    font.pixelSize: 12
                    font.family: "monospace"
                    textFormat: Text.PlainText
                    text: {
                      var out = [root.wifiSsid + "   " + root.wifiDbm + " dBm   tx "
                                 + Math.round(root.wifiBitrate) + " Mbit/s"];
                      for (var i = 0; i < root.wifiLinks.length; i++) {
                        var l = root.wifiLinks[i];
                        out.push((l.active ? "● " : "○ ") + "link " + l.id + "  "
                                 + (root.bandOf(l.freq) + " GHz").padEnd(7) + l.freq + " MHz"
                                 + (l.active ? "  " + root.wifiWidth + " MHz wide" : "  idle"));
                      }
                      if (root.wifiPartner !== "")
                        out.push("click: switch to " + (root.wifiPartner.endsWith("_6G") ? "6G" : "MLO"));
                      return out.join("\n");
                    }
                  }
                }
              }

              // ---- System stats: the CPU/memory/network HUD and the NPU chip. Click for the dropdown ----
              // A soft highlight on hover (and while open) shows it is clickable.
              Item {
                id: statsArea
                anchors.verticalCenter: parent.verticalCenter
                width: statsRow.implicitWidth + 12
                height: 32
                property bool open: root.statsScreen === screenScope.modelData.name

                Rectangle {
                  anchors.fill: parent
                  radius: 6
                  color: root.c.surface
                  opacity: statsArea.open ? 0.9 : statsHover.hovered ? 0.5 : 0
                  Behavior on opacity { NumberAnimation { duration: 150 } }
                }

                HoverHandler { id: statsHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  onTapped: root.statsScreen = statsArea.open ? "" : screenScope.modelData.name
                }

                Row {
                  id: statsRow
                  anchors.centerIn: parent
                  spacing: 8

                  // ---- HUD: CPU, memory and network in one tiny dial ----
                  // Outer arc = CPU load, inner arc = memory used, both filling
                  // clockwise from 12 o'clock; the centre dot grows and
                  // brightens with network throughput (download + upload) on
                  // the network graph's log scale, 100 B/s to 100 MB/s.
                  Canvas {
                    id: hud
                    anchors.verticalCenter: parent.verticalCenter
                    width: 30
                    height: 30
                    property var themeColors: root.c
                    onThemeColorsChanged: requestPaint()   // redraw when light/dark flips
                    property var tick: root.cpuHistory     // repaint on the 2 s sample only
                    onTickChanged: requestPaint()

                    onPaint: {
                      var ctx = getContext("2d");
                      ctx.clearRect(0, 0, width, height);
                      var cx = width / 2, cy = height / 2, top = -Math.PI / 2;
                      function ring(r, share, rgb) {
                        ctx.lineWidth = 3;
                        ctx.lineCap = "butt";
                        ctx.strokeStyle = root.alpha(root.c.dim, 0.25);
                        ctx.beginPath();
                        ctx.arc(cx, cy, r, 0, 2 * Math.PI);
                        ctx.stroke();
                        share = Math.max(0, Math.min(1, share));
                        if (share <= 0.005) return;
                        ctx.strokeStyle = rgb;
                        ctx.beginPath();
                        ctx.arc(cx, cy, r, top, top + Math.max(0.08, share * 2 * Math.PI), false);
                        ctx.stroke();
                      }
                      ring(13, root.cpuLoad, root.c.yellow);
                      ring(8.5, root.memTotalKb > 0 ? root.memUsedKb / root.memTotalKb : 0, root.c.violet);

                      var rate = root.rxRate + root.txRate;
                      var f = rate > 0 ? Math.max(0, Math.min(1, (Math.log(rate) / Math.LN10 - 2) / 6)) : 0;
                      var r = 1.2 + 3 * f;
                      if (f > 0.3) {                         // a soft halo once it's busy
                        var g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r * 2.2);
                        g.addColorStop(0, root.alpha(root.c.blue, 0.5 * f));
                        g.addColorStop(1, root.alpha(root.c.blue, 0));
                        ctx.fillStyle = g;
                        ctx.beginPath();
                        ctx.arc(cx, cy, r * 2.2, 0, 2 * Math.PI);
                        ctx.fill();
                      }
                      ctx.fillStyle = root.alpha(root.c.blue, 0.35 + 0.65 * f);
                      ctx.beginPath();
                      ctx.arc(cx, cy, r, 0, 2 * Math.PI);
                      ctx.fill();
                    }
                  }

                  // ---- NPU: grey when asleep, green outline when awake, filling with load ----
                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 5
                    visible: root.npuPresent

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: npuLabel.implicitWidth + 10
                      height: 16
                      radius: 4
                      color: "transparent"
                      border.width: 1
                      border.color: root.npuAwake ? root.c.green : root.c.surface
                      clip: true

                      Rectangle {                    // load fill, left to right
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * root.npuLoad
                        radius: 4
                        color: root.c.green
                        opacity: 0.45
                        Behavior on width { NumberAnimation { duration: 400 } }
                      }

                      Text {
                        id: npuLabel
                        anchors.centerIn: parent
                        text: "NPU"
                        color: root.npuAwake ? root.c.green : root.c.muted
                        font.pixelSize: 10
                        font.bold: true
                      }
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: root.npuAwake
                      text: Math.round(root.npuLoad * 100) + "%" + (root.npuMHz > 0 ? " " + root.npuMHz + "MHz" : "")
                      color: root.c.green
                      font.pixelSize: 12
                      font.family: "monospace"
                    }
                  }
                }
              }

              // ---- Stats dropdown ----
              // Closes on a second click, or a moment after the pointer leaves
              // both the bar and the dropdown. While it is open the bar stays up.
              PopupWindow {
                id: statsPopup
                anchor.item: statsArea
                anchor.edges: Edges.Bottom | Edges.Left
                anchor.gravity: Edges.Bottom | Edges.Right
                anchor.margins.top: 6
                visible: statsArea.open
                // Two columns: wifi, network, memory and NPU on the left; CPU,
                // thermals, battery and GPU on the right. Every graph starts as
                // a polar clock with its details beside it; the switch at the
                // bottom flips them all to strips (details then sit underneath),
                // and clicking one graph flips just that one.
                property int colWidth: 400
                property int dialWidth: 130
                implicitWidth: colWidth * 2 + 24 + 28
                implicitHeight: Math.max(statsColL.implicitHeight, statsColR.implicitHeight) + 24
                color: "transparent"

                // Core types: P-cores from the kernel's hybrid PMU list; among
                // the rest (E-cores), the ones with the lowest top clock are LP-E.
                function coreKind(i) {
                  var f = root.cpuFreqs;
                  if (!f[i] || root.cpuPCores.length === 0) return "";
                  if (root.cpuPCores.indexOf(f[i].id) >= 0) return "P";
                  var top = 0, low = Infinity;
                  for (var k = 0; k < f.length; k++) {
                    if (root.cpuPCores.indexOf(f[k].id) >= 0) continue;
                    top = Math.max(top, f[k].maxMhz);
                    low = Math.min(low, f[k].maxMhz);
                  }
                  return f[i].maxMhz === low && low < top ? "LP" : "E";
                }

                function signedWatts(w) {
                  w = Math.round(w);
                  return w > 0 ? "+" + w + " W" : w < 0 ? "−" + (-w) + " W" : "0 W";
                }

                Rectangle {
                  anchors.fill: parent
                  color: root.c.bg
                  border.color: root.c.surface
                  radius: 6

                  HoverHandler { id: statsPopupHover }

                  Row {
                    x: 14
                    y: 12
                    spacing: 24

                    Column {
                      id: statsColL
                      width: statsPopup.colWidth
                      spacing: 5

                      // -- Wifi --
                      StatTitle { text: "WIFI"; color: root.c.cyan }
                      Flow {
                        width: parent.width
                        spacing: 14
                        TimeGraph {
                          key: "wifi"
                          width: polar ? statsPopup.dialWidth : parent.width
                          stripHeight: 46
                          live: statsArea.open
                          values: root.wifiHistory
                          samples: root.wifiSamples
                          windowMinutes: 30
                          lo: 0
                          hi: 100
                          guides: [50, 75]
                          tint: root.c.cyan
                          caption: "signal · 30 min"
                          valueText: root.wifiSignal >= 0 ? root.wifiSignal + "%" : "off"
                        }
                        StatText {
                          color: root.c.fg
                          text: {
                            if (root.wifiSignal < 0) return "offline";
                            var out = [root.wifiSsid, root.wifiDbm + " dBm · tx " + Math.round(root.wifiBitrate) + " Mbit/s", ""];
                            for (var i = 0; i < root.wifiLinks.length; i++) {
                              var l = root.wifiLinks[i];
                              out.push((l.active ? "● " : "○ ") + "link " + l.id + "  "
                                       + (root.bandOf(l.freq) + " GHz").padEnd(7) + l.freq + " MHz"
                                       + (l.active ? "\n  " + root.wifiWidth + " MHz wide" : "  idle"));
                            }
                            return out.join("\n");
                          }
                        }
                      }

                      Item { width: 1; height: 4 }

                      // -- Network --
                      StatTitle { text: "NETWORK"; color: root.c.blue }
                      Flow {
                        width: parent.width
                        spacing: 14
                        NetGraph {
                          key: "net"
                          width: polar ? statsPopup.dialWidth : parent.width
                          stripHeight: 56
                          windowMinutes: 5
                          live: statsArea.open
                          caption: "5 min"
                        }
                        StatText {
                          color: root.c.fg
                          text: "↓ " + root.formatRate(root.rxRate) + "/s   ↑ " + root.formatRate(root.txRate) + "/s"
                                + "\n\nsince boot\n↓ " + root.formatBytes(Math.max(0, root.lastRx))
                                + "   ↑ " + root.formatBytes(Math.max(0, root.lastTx))
                        }
                        StatText {
                          text: "↓ blue, outward / up; ↑ orange, inward / down\nlog rate: dotted at 1 KB/s and 1 MB/s"
                          font.pixelSize: 10
                          color: root.c.muted
                        }
                      }

                      Item { width: 1; height: 4 }

                      // -- Memory --
                      StatTitle { text: "MEMORY"; color: root.c.violet }
                      Flow {
                        width: parent.width
                        spacing: 14
                        TimeGraph {
                          key: "mem"
                          width: polar ? statsPopup.dialWidth : parent.width
                          stripHeight: 38
                          live: statsArea.open
                          values: root.memHistory
                          guides: [0.5, 0.75]
                          tint: root.c.violet
                          caption: "used · 5 min"
                          valueText: root.memTotalKb > 0 ? Math.round(root.memUsedKb / root.memTotalKb * 100) + "%" : ""
                        }
                        StatText {
                          property var m: root.memInfo
                          color: root.c.fg
                          text: m.MemTotal > 0
                                ? "used " + root.formatKb(root.memUsedKb) + " of " + root.formatKb(m.MemTotal)
                                  + "\navailable " + root.formatKb(m.MemAvailable)
                                  + "\ncached " + root.formatKb(m.Cached) + "   buffers " + root.formatKb(m.Buffers)
                                  + "\nswap " + root.formatKb(m.SwapTotal - m.SwapFree) + " of " + root.formatKb(m.SwapTotal)
                                : "…"
                        }
                      }

                      Item { width: 1; height: 4 }

                      // -- NPU --
                      StatTitle { text: "NPU"; color: root.c.green; visible: root.npuPresent }
                      Flow {
                        visible: root.npuPresent
                        width: parent.width
                        spacing: 14
                        TimeGraph {
                          key: "npu"
                          width: polar ? statsPopup.dialWidth : parent.width
                          stripHeight: 34
                          live: statsArea.open
                          values: root.npuHistory
                          logScale: true
                          logLo: -3                       // 0.1% .. 100%
                          logHi: 0
                          guides: [0.01, 0.1]
                          tint: root.c.green
                          caption: "load · 5 min"
                          valueText: Math.round(root.npuLoad * 100) + "%"
                        }
                        StatText {
                          color: root.c.fg
                          text: (root.npuAwake ? "awake" : "asleep") + "\n" + root.npuMHz + " of " + root.npuMaxMHz + " MHz"
                                + "\nbusy since boot " + root.formatDuration(Math.max(0, root.npuLastBusy) / 1e6)
                                + "\nmemory " + (root.npuMemBytes >= 0 ? root.formatBytes(root.npuMemBytes) : "…")
                                + "\n\nlog load: dotted 1% and 10%"
                        }
                      }

                      Item { width: 1; height: 4 }

                      // The one switch for every graph: all dials, or all strips.
                      Rectangle {
                        width: toggleText.implicitWidth + 16
                        height: 20
                        radius: 4
                        color: toggleHover.hovered ? root.c.surface : "transparent"
                        border.color: root.c.surface
                        Text {
                          id: toggleText
                          anchors.centerIn: parent
                          text: (root.graphsPolar ? "◴ dials" : "▭ strips") + "  ·  switch all to "
                                + (root.graphsPolar ? "strips" : "dials")
                          color: root.c.dim
                          font.pixelSize: 11
                          font.family: "monospace"
                        }
                        HoverHandler { id: toggleHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                          onTapped: {
                            root.graphsPolar = !root.graphsPolar;
                            root.graphModes = ({});     // per-graph flips reset to the new default
                          }
                        }
                      }
                      StatText {
                        text: "click any graph to flip just that one"
                        font.pixelSize: 10
                        color: root.c.muted
                      }
                    }

                    Column {
                      id: statsColR
                      width: statsPopup.colWidth
                      spacing: 5
                      property real third: (width - 24) / 3

                      // -- CPU --
                      StatTitle { text: "CPU"; color: root.c.yellow }
                      StatText {
                        text: {
                          var f = root.cpuFreqs, top = 0;
                          for (var i = 0; i < f.length; i++) top = Math.max(top, f[i].mhz);
                          return "load " + Math.round(root.cpuLoad * 100) + "%"
                                 + (f.length ? "   top core " + (top / 1000).toFixed(1) + " GHz" : "");
                        }
                        color: root.c.fg
                      }
                      // Core rings: one ring per core tier, P innermost, then E,
                      // then LP-E. Each core is an arc segment, a gauge filling
                      // clockwise with its load (green, yellow, orange, red as
                      // it climbs). The tick just outside a segment grows with
                      // that core's clock as a share of its own top clock. The
                      // gap at the top holds the tier labels; overall load and
                      // package temperature sit in the middle.
                      Row {
                        spacing: 12

                        Item {
                          id: coreRings
                          width: 150
                          height: 150

                          Canvas {
                            anchors.fill: parent
                            property var themeColors: root.c
                            onThemeColorsChanged: requestPaint()   // redraw when light/dark flips
                            // Repaint only on new samples, and only while open.
                            property var loads: root.cpuCoreLoad
                            property var freqs: root.cpuFreqs
                            property bool live: statsArea.open
                            onLoadsChanged: if (live) requestPaint()
                            onFreqsChanged: if (live) requestPaint()
                            onLiveChanged: if (live) requestPaint()

                            function loadColor(l) {
                              return l < 0.25 ? root.c.green : l < 0.5 ? root.c.yellow
                                   : l < 0.75 ? root.c.orange : root.c.red;
                            }

                            onPaint: {
                              var ctx = getContext("2d");
                              ctx.clearRect(0, 0, width, height);
                              var cx = width / 2, cy = height / 2;
                              var order = ["P", "E", "LP", ""], rings = {};
                              for (var i = 0; i < root.cpuIds.length; i++) {
                                var k = statsPopup.coreKind(i);
                                (rings[k] = rings[k] || []).push(i);
                              }
                              var wedge = 0.5;                 // label gap at the top, radians
                              var start0 = -Math.PI / 2 + wedge / 2, sweep = 2 * Math.PI - wedge;
                              var lw = 8, r = 30;
                              ctx.lineCap = "butt";
                              ctx.textAlign = "center";
                              ctx.textBaseline = "middle";
                              ctx.font = "bold 8px monospace";
                              for (var o = 0; o < order.length; o++) {
                                var cores = rings[order[o]];
                                if (!cores) continue;
                                var n = cores.length, gap = 0.07;
                                var seg = sweep / n;
                                for (var j = 0; j < n; j++) {
                                  var core = cores[j];
                                  var a0 = start0 + j * seg + gap / 2, span = seg - gap;
                                  ctx.lineWidth = lw;
                                  ctx.strokeStyle = root.alpha(root.c.dim, 0.22);   // track
                                  ctx.beginPath();
                                  ctx.arc(cx, cy, r, a0, a0 + span, false);
                                  ctx.stroke();
                                  var l = Math.max(0, Math.min(1, root.cpuCoreLoad[core] || 0));
                                  if (l > 0.005) {
                                    ctx.strokeStyle = loadColor(l);
                                    ctx.beginPath();
                                    ctx.arc(cx, cy, r, a0, a0 + Math.max(0.03, span * l), false);
                                    ctx.stroke();
                                  }
                                  var f = root.cpuFreqs[core];
                                  if (f && f.maxMhz > 0) {           // clock tick
                                    var share = Math.max(0, Math.min(1, f.mhz / f.maxMhz));
                                    var am = a0 + span / 2, r0 = r + lw / 2 + 1, r1 = r0 + 1 + 5 * share;
                                    ctx.strokeStyle = root.alpha(root.c.fg, 0.75);
                                    ctx.lineWidth = 1.5;
                                    ctx.beginPath();
                                    ctx.moveTo(cx + r0 * Math.cos(am), cy + r0 * Math.sin(am));
                                    ctx.lineTo(cx + r1 * Math.cos(am), cy + r1 * Math.sin(am));
                                    ctx.stroke();
                                  }
                                }
                                if (order[o] !== "") {               // tier label in the top gap
                                  ctx.fillStyle = root.c.muted;
                                  ctx.fillText(order[o], cx, cy - r);
                                }
                                r += 16;
                              }
                            }
                          }

                          Column {
                            anchors.centerIn: parent
                            Text {
                              anchors.horizontalCenter: parent.horizontalCenter
                              text: Math.round(root.cpuLoad * 100) + "%"
                              color: root.c.fg
                              font.pixelSize: 15
                              font.bold: true
                              font.family: "monospace"
                            }
                            Text {
                              anchors.horizontalCenter: parent.horizontalCenter
                              visible: root.cpuTemp >= 0
                              text: Math.round(root.cpuTemp) + "°C"
                              color: root.c.red
                              font.pixelSize: 10
                              font.family: "monospace"
                            }
                          }
                        }

                        Column {
                          width: statsColR.width - coreRings.width - 12
                          spacing: 5
                          TimeGraph {
                            key: "cpu"
                            width: polar ? statsPopup.dialWidth : parent.width
                            stripHeight: 100
                            live: statsArea.open
                            values: root.cpuHistory
                            guides: [0.5, 0.75]
                            tint: root.c.yellow
                            caption: "load · 5 min"
                            valueText: Math.round(root.cpuLoad * 100) + "%"
                          }
                          StatText {
                            text: "rings: P inside, E, LP-E outside\nfill = load, tick = clock / max"
                            font.pixelSize: 10
                            color: root.c.muted
                          }
                        }
                      }

                      Item { width: 1; height: 4 }

                      // -- Thermals: temperature, average clock, fan --
                      StatTitle { text: "THERMALS"; color: root.c.red }
                      Row {
                        spacing: 12
                        TimeGraph {
                          key: "temp"
                          width: statsColR.third
                          stripHeight: 46
                          live: statsArea.open
                          values: root.tempHistory
                          samples: root.slowSamples
                          windowMinutes: 30
                          lo: 30
                          hi: 100
                          autoRange: true
                          rangeStep: 10
                          guides: [50, 90]
                          tint: root.c.red
                          caption: "package · 30 min"
                          valueText: root.cpuTemp >= 0 ? Math.round(root.cpuTemp) + "°C" : ""
                        }
                        TimeGraph {
                          key: "clock"
                          width: statsColR.third
                          stripHeight: 46
                          live: statsArea.open
                          values: root.clockHistory
                          samples: root.slowSamples
                          windowMinutes: 30
                          lo: 0
                          hi: 4
                          autoRange: true
                          guides: [1, 3]
                          tint: root.c.yellow
                          caption: "avg clock · 30 min"
                          valueText: root.cpuClockAvg >= 0 ? root.cpuClockAvg.toFixed(1) + "G" : ""
                        }
                        TimeGraph {
                          key: "fan"
                          visible: root.fanPath !== ""
                          width: statsColR.third
                          stripHeight: 46
                          live: statsArea.open
                          values: root.fanHistory
                          samples: root.slowSamples
                          windowMinutes: 30
                          lo: 0
                          hi: 6000
                          autoRange: true
                          rangeStep: 1000
                          guides: [2000, 4000]
                          tint: root.c.cyan
                          valueWidth: 40
                          caption: "fan rpm · 30 min"
                          valueText: root.fanRpm >= 0 ? String(root.fanRpm) : ""
                        }
                      }

                      Item { width: 1; height: 4 }

                      // -- Battery: power in (charging: outward / up, green) or
                      // out (draining: inward / down, orange) --
                      StatTitle { text: "BATTERY"; color: root.c.green; visible: root.batPercent >= 0 }
                      Flow {
                        width: parent.width
                        spacing: 14
                        visible: root.batPercent >= 0
                        TimeGraph {
                          key: "power"
                          width: polar ? statsPopup.dialWidth : parent.width
                          stripHeight: 46
                          live: statsArea.open
                          values: root.powerHistory
                          samples: root.slowSamples
                          windowMinutes: 30
                          mirrored: true
                          logScale: true
                          logLo: 0                    // 1 W .. 100 W
                          logHi: 2
                          guides: [10]
                          tint: root.c.green
                          negTint: root.c.orange
                          caption: "± W, log · 30 min"
                          valueText: statsPopup.signedWatts(root.batWatts)
                        }
                        StatText {
                          color: root.c.fg
                          text: root.batPercent + "%  " + root.batStatus.toLowerCase()
                                + (root.batMinutesLeft > 0
                                   ? (root.batStatus === "Charging" ? "\nfull in " : "\n") + root.formatMinutes(root.batMinutesLeft)
                                     + (root.batStatus === "Charging" ? "" : " left")
                                   : "")
                                + "\n" + (root.batWatts > 0 ? "charging " : root.batWatts < 0 ? "draining " : "")
                                + statsPopup.signedWatts(root.batWatts)
                                + (root.chargerWatts > 0 ? "\ncharger " + Math.round(root.chargerWatts) + " W" : "")
                        }
                        StatText {
                          text: "charging: green, outward / up\ndraining: orange, inward / down · 10 W dotted"
                          font.pixelSize: 10
                          color: root.c.muted
                        }
                      }

                      Item { width: 1; height: 4 }

                      // -- GPU: sampled only while this is open, so its graphs start then --
                      StatTitle {
                        text: "GPU" + (root.gpuDriver !== "" ? "  (" + root.gpuDriver + ")" : "")
                        color: root.c.orange
                      }
                      StatText {
                        visible: root.gpuStats.length === 0
                        text: "no GPU idle/frequency counters found"
                      }
                      StatText {
                        visible: root.gpuStats.length > 0
                        color: root.c.fg
                        text: root.gpuStats.map(function (g) {
                          var role = g.name.endsWith("-rc") ? "render" : g.name.endsWith("-mc") ? "media" : "";
                          return (g.name + " " + role).padEnd(14) + (g.mhz > 0 ? (g.mhz + " MHz").padEnd(12) : "idle (C6)   ")
                                 + "max " + g.maxMhz + " MHz";
                        }).join("\n")
                      }
                      // Busy and clock for each GT: four small dials in a row, or
                      // two strips per row.
                      Flow {
                        width: parent.width
                        spacing: 12
                        Repeater {
                          model: root.gpuStats.length * 2
                          TimeGraph {
                            required property int index
                            property int gt: Math.floor(index / 2)
                            property bool isClock: index % 2 === 1
                            property var stat: root.gpuStats[gt] || ({ name: "", busy: -1, mhz: 0, maxMhz: 1 })
                            property string role: stat.name.endsWith("-rc") ? "render" : stat.name.endsWith("-mc") ? "media" : stat.name
                            key: (isClock ? "gpu-clock-" : "gpu-busy-") + gt
                            width: polar ? (statsColR.width - 36) / 4 : (statsColR.width - 12) / 2
                            stripHeight: 30
                            live: statsArea.open
                            values: (isClock ? root.gpuMhzHist[gt] : root.gpuBusyHist[gt]) || []
                            logScale: !isClock
                            logLo: -3
                            logHi: 0
                            lo: 0
                            hi: isClock ? Math.max(1, stat.maxMhz) : 1
                            guides: isClock ? [stat.maxMhz / 2] : [0.01, 0.1]
                            tint: root.c.orange
                            valueWidth: isClock ? 44 : 50
                            caption: role + (isClock ? " MHz" : " busy")
                            valueText: isClock ? (stat.mhz > 0 ? String(stat.mhz) : "C6")
                                       : (stat.busy < 0 ? "…" : Math.round(stat.busy * 100) + "%")
                          }
                        }
                      }
                      StatText {
                        text: "GPU graphs: since this opened, 2 s steps"
                        font.pixelSize: 10
                        color: root.c.muted
                      }
                    }
                  }
                }
              }

              Timer {
                interval: 800
                running: statsArea.open && !barHover.hovered && !statsPopupHover.hovered
                onTriggered: root.statsScreen = ""
              }

	    }

            // ---- World sun clocks: one tiny sky per city, right side of the bar ----
            // By day a sun travels the arc from sunrise (left) to sunset (right);
            // by night a moon travels a dimmer arc below the horizon. The time shown
            // is the city's next event: ↓ sunset or ↑ sunrise, in that city's local time.
            Row {
              id: sunWidget
              anchors.right: parent.right
              anchors.rightMargin: 20
              anchors.verticalCenter: parent.verticalCenter
              spacing: 14

              Repeater {
                model: root.cities

                Row {
                  id: cityItem
                  required property var modelData
                  required property int index
                  property var sun: root.sunState(modelData, root.tzOffsets[index], root.nowMs)
                  property var moon: root.moonState(modelData, root.tzOffsets[index], root.nowMs)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 5

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: cityItem.modelData.code
                    color: cityItem.sun.isDay ? root.c.fg : root.c.dim
                    font.pixelSize: 11
                    font.bold: true
                  }

                  Canvas {

                    property var themeColors: root.c

                    onThemeColorsChanged: requestPaint()   // redraw when light/dark flips
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    property var sun: cityItem.sun
                    property var moon: cityItem.moon
                    property real phase: root.moonPhaseNow.phase
                    property bool south: cityItem.modelData.lat < 0
                    onSunChanged: requestPaint()   // once a minute

                    // A glowing dot: soft halo, then a solid core.
                    function glowDot(ctx, x, y, dot, rgb, halo) {
                      var g = ctx.createRadialGradient(x, y, 0, x, y, dot * 2.8);
                      g.addColorStop(0, root.alpha(rgb, halo));
                      g.addColorStop(1, root.alpha(rgb, 0));
                      ctx.fillStyle = g;
                      ctx.beginPath();
                      ctx.arc(x, y, dot * 2.8, 0, 2 * Math.PI);
                      ctx.fill();
                      ctx.fillStyle = rgb;
                      ctx.beginPath();
                      ctx.arc(x, y, dot, 0, 2 * Math.PI);
                      ctx.fill();
                    }

                    // The moon with its real phase: a dark disc, then the lit part
                    // bounded by the bright limb (a half circle) and the terminator
                    // (a half ellipse whose width follows the phase). The southern
                    // hemisphere sees it mirrored left to right.
                    function moonDisc(ctx, x, y, r) {
                      var g = ctx.createRadialGradient(x, y, 0, x, y, r * 2.6);
                      g.addColorStop(0, root.alpha(root.c.fg, 0.35));
                      g.addColorStop(1, root.alpha(root.c.fg, 0));
                      ctx.fillStyle = g;
                      ctx.beginPath();
                      ctx.arc(x, y, r * 2.6, 0, 2 * Math.PI);
                      ctx.fill();

                      ctx.fillStyle = root.c.surface;
                      ctx.beginPath();
                      ctx.arc(x, y, r, 0, 2 * Math.PI);
                      ctx.fill();

                      var litRight = (phase < 0.5) !== south;   // waxing is lit on the right up north
                      var side = litRight ? 1 : -1;
                      var t = Math.cos(2 * Math.PI * phase);    // 1 at new moon, -1 at full
                      ctx.fillStyle = root.c.moonLit;
                      ctx.beginPath();
                      for (var i = 0; i <= 16; i++) {           // limb: top to bottom on the lit side
                        var a = -Math.PI / 2 + Math.PI * i / 16;
                        var px = x + side * r * Math.cos(a), py = y + r * Math.sin(a);
                        if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
                      }
                      for (var j = 16; j >= 0; j--) {           // terminator: bottom back to top
                        var b = -Math.PI / 2 + Math.PI * j / 16;
                        ctx.lineTo(x + side * t * r * Math.cos(b), y + r * Math.sin(b));
                      }
                      ctx.closePath();
                      ctx.fill();
                    }

                    onPaint: {
                      var ctx = getContext("2d");
                      ctx.clearRect(0, 0, width, height);
                      var cx = width / 2, horizon = height / 2 + 3, r = width / 2 - 5;

                      // Sky arc: warm by day, faint at night.
                      ctx.beginPath();
                      ctx.arc(cx, horizon, r, Math.PI, 2 * Math.PI);
                      ctx.strokeStyle = sun.isDay ? root.alpha(root.c.yellow, 0.35) : root.alpha(root.c.night, 0.15);
                      ctx.lineWidth = 1;
                      ctx.stroke();

                      ctx.fillStyle = root.c.muted;
                      ctx.fillRect(1, horizon, width - 2, 1);

                      // At night the sun travels under the horizon, dim, from sunset
                      // (right) back round to sunrise (left).
                      if (!sun.isDay) {
                        var an = sun.frac * Math.PI;
                        ctx.fillStyle = root.alpha(root.c.yellow, 0.35);
                        ctx.beginPath();
                        ctx.arc(cx + r * 0.7 * Math.cos(an), horizon + 1 + (height - horizon - 3) * Math.sin(an), 1.5, 0, 2 * Math.PI);
                        ctx.fill();
                      }

                      // Moon and sun share the sky arc, rising on the left and setting
                      // on the right.
                      if (moon.up && moon.frac >= 0) {
                        var am = Math.PI + moon.frac * Math.PI;
                        moonDisc(ctx, cx + r * Math.cos(am), horizon + r * Math.sin(am), 3.2);
                      }
                      if (sun.isDay) {
                        var as = Math.PI + sun.frac * Math.PI;
                        glowDot(ctx, cx + r * Math.cos(as), horizon + r * Math.sin(as), 2.6, root.c.yellow, 0.6);
                      }
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: (cityItem.sun.isDay ? "↓" : "↑") + root.clockAt(cityItem.sun.next, cityItem.sun.offset)
                    color: cityItem.sun.isDay ? root.c.yellow : root.c.night
                    font.pixelSize: 12
                    font.family: "monospace"
                  }

                  // Click the home sky to flip light/dark by hand.
                  TapHandler {
                    enabled: cityItem.modelData.home === true
                    onTapped: root.setTheme(!root.lightMode)
                  }

                  // Divider after home, so the local sky reads separately from the world clocks.
                  Rectangle {
                    visible: cityItem.modelData.home === true
                    anchors.verticalCenter: parent.verticalCenter
                    width: 1
                    height: 18
                    color: root.c.surface
                  }
                }
              }

              HoverHandler {
                id: sunHover
                onHoveredChanged: if (hovered) root.nowMs = Date.now()
              }
            }

            PopupWindow {
              anchor.item: sunWidget
              anchor.edges: Edges.Bottom | Edges.Right
              anchor.gravity: Edges.Bottom | Edges.Left
              anchor.margins.top: 8
              visible: sunHover.hovered
              implicitWidth: sunText.implicitWidth + 24
              implicitHeight: sunText.implicitHeight + 16
              color: "transparent"

              Rectangle {
                anchors.fill: parent
                color: root.c.bg
                border.color: root.c.surface
                radius: 6

                Text {
                  id: sunText
                  anchors.centerIn: parent
                  color: root.c.fg
                  font.pixelSize: 12
                  font.family: "monospace"
                  textFormat: Text.PlainText
                  text: {
                    // A moon event that falls on another day shows as "--:--".
                    function moonClock(ms, off) { return isNaN(ms) ? "--:--" : root.clockAt(ms, off); }
                    var out = ["".padEnd(14) + "now    sunrise sunset  daylight   moonrise moonset"];
                    for (var i = 0; i < root.cities.length; i++) {
                      var c = root.cities[i], off = root.tzOffsets[i];
                      var s = root.sunState(c, off, root.nowMs);
                      var m = root.moonState(c, off, root.nowMs);
                      var mins = Math.round((s.set - s.rise) / 60000);
                      out.push((s.isDay ? "☀ " : "☾ ") + c.name.padEnd(12)
                               + root.clockAt(root.nowMs, off) + "  "
                               + root.clockAt(s.rise, off) + "   "
                               + root.clockAt(s.set, off) + "   "
                               + (Math.floor(mins / 60) + "h " + (mins % 60 < 10 ? "0" : "") + (mins % 60) + "m").padEnd(11)
                               + moonClock(m.rise, off) + "    "
                               + moonClock(m.set, off)
                               + (m.up ? "  (up)" : ""));
                    }
                    out.push("");
                    out.push(root.phaseName(root.moonPhaseNow.phase) + ", "
                             + Math.round(root.moonPhaseNow.fraction * 100) + "% lit");
                    out.push("times are local to each city");
                    return out.join("\n");
                  }
                }
              }
            }
	  }
	}
        }
    }
}
