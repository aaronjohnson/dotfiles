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

    FileView { id: batCapacity; blockLoading: true; path: root.batDir + "capacity" }
    FileView { id: batStatusFile; blockLoading: true; path: root.batDir + "status" }
    FileView { id: batChargeNow; blockLoading: true; path: root.batDir + "charge_now" }
    FileView { id: batChargeFull; blockLoading: true; path: root.batDir + "charge_full" }
    FileView { id: batCurrent; blockLoading: true; path: root.batDir + "current_now" }

    function readBattery() {
        var files = [batCapacity, batStatusFile, batChargeNow, batChargeFull, batCurrent];
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
    }

    function formatMinutes(m) {
        m = Math.round(m);
        return Math.floor(m / 60) + "h" + (m % 60 < 10 ? "0" : "") + (m % 60);
    }

    Timer {
        interval: 30000
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
        if (root.npuLastBusy >= 0)
            root.npuLoad = Math.max(0, Math.min(1, (busy - root.npuLastBusy) / (root.netIntervalMs * 1000)));
        root.npuLastBusy = busy;
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
        onTriggered: { netDev.reload(); root.readNpu(); }
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
        onTriggered: wifiReader.running = true
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
	  id: barWindow
          required property var modelData
	  screen: modelData
          anchors {
	    top: true
	    left: true
	    right: true
          }
	  implicitHeight: 40
          exclusiveZone: 40

          Rectangle {
            anchors.fill: parent
            color: root.c.bg
            opacity: 0.85

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

              // ---- Network usage sparkline: blue = download, peach = upload ----
              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                // Mirrored log-log dot plot: download rises above the center line,
                // upload drops below it. Height is log(rate) on a fixed 100 B/s to
                // 100 MB/s scale, so it never rescales. Time runs on a log axis too:
                // the newest sample sits at the right edge and older ones crowd
                // toward the left and fade, so the last few seconds get most of
                // the width while still showing 5 minutes of history.
                Canvas {
                  property var themeColors: root.c
                  onThemeColorsChanged: requestPaint()   // redraw when light/dark flips
                  id: sparkline
                  anchors.verticalCenter: parent.verticalCenter
                  width: 90
                  height: 30

                  // Repaint only when a new sample arrives (every 2s), never on a loop.
                  property var rx: root.rxHistory
                  property var tx: root.txHistory
                  onRxChanged: requestPaint()

                  readonly property real logMin: 2   // 10^2 = 100 B/s
                  readonly property real logMax: 8   // 10^8 = 100 MB/s

                  onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    var mid = height / 2;
                    var half = mid - 3;               // leave room for the glow
                    var maxAge = root.netSamples;
                    var xSpan = width - 4;

                    function xAt(age) {
                      return 2 + xSpan * (1 - Math.log(1 + age) / Math.log(1 + maxAge));
                    }
                    function reach(rate) {            // 0..1 up the log scale
                      if (rate <= 0) return 0;
                      var f = (Math.log(rate) / Math.LN10 - logMin) / (logMax - logMin);
                      return Math.max(0, Math.min(1, f));
                    }

                    // Faint guides at 1 KB/s and 1 MB/s, above and below.
                    ctx.fillStyle = root.alpha(root.c.dim, 0.35);
                    [3, 6].forEach(function (d) {
                      var off = half * (d - logMin) / (logMax - logMin);
                      for (var x = 2; x < width; x += 4) {
                        ctx.fillRect(x, mid - off, 1, 1);
                        ctx.fillRect(x, mid + off, 1, 1);
                      }
                    });
                    ctx.fillStyle = root.alpha(root.c.dim, 0.6);
                    ctx.fillRect(0, mid - 0.5, width, 1);

                    function dots(data, sign, rgb) {
                      // Oldest first, so newer dots paint over the crowded history.
                      for (var i = 0; i < data.length; i++) {
                        var age = data.length - 1 - i;
                        var f = reach(data[i]);
                        if (f === 0) continue;        // idle: nothing to draw
                        var fresh = age < 3;
                        var r = fresh ? 2.2 - age * 0.4 : 1.1;
                        var alpha = 1 - 0.8 * Math.sqrt(age / maxAge);
                        var x = xAt(age), y = mid - sign * f * half;
                        if (fresh) {                  // soft halo behind the newest dots
                          var g = ctx.createRadialGradient(x, y, 0, x, y, r * 3);
                          g.addColorStop(0, root.alpha(rgb, 0.5));
                          g.addColorStop(1, root.alpha(rgb, 0));
                          ctx.fillStyle = g;
                          ctx.beginPath();
                          ctx.arc(x, y, r * 3, 0, 2 * Math.PI);
                          ctx.fill();
                        }
                        ctx.fillStyle = root.alpha(rgb, alpha);
                        ctx.beginPath();
                        ctx.arc(x, y, r, 0, 2 * Math.PI);
                        ctx.fill();
                      }
                    }

                    dots(tx, -1, root.c.orange);    // peach, below
                    dots(rx, 1, root.c.blue);     // blue, above
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "↓" + root.formatRate(root.rxRate) + " ↑" + root.formatRate(root.txRate)
                  color: root.c.blue
                  font.pixelSize: 12
                  font.family: "monospace"
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
