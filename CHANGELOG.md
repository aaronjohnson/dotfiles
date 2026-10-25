# Recipe journal of the rasa

Kept by the stove. Newest entry on top. Each entry is a day at the spice cabinet:
a new jar on the shelf when something arrives, a recipe refined when something
that was already there tastes better, a blend adjusted when the balance shifts.
*Rasa* is Sanskrit for flavour, or essence; this is where it is written down.

## The deck · 25 October 2026 · the whole kitchen on one counter

Committing, pushing and deploying across several repos used to be a terminal
conversation. It is now a full-screen board in Quickshell (Super+F12 to land,
Super+F11 to ship), with one tile per repo.

- **Tiles** show each repo's branch, how far ahead or behind it is, a waiting
  commit draft, staged and unstaged files, ship targets and recent commits, with
  buttons that run one step each: Commit, Push, Push and update the NixOS flake,
  Ship, Discard a stale draft. Repos with work waiting, or touched in the last two
  days, sit large in the middle; the rest are grouped by subject down the sides.
- **One question at a time.** The deck asks the next step in the usual order
  (commit drafts, push, update and commit the system, switch, ship). Y runs it, N
  skips it, and A runs the whole queue, re-reading the repos after each step so
  new steps join in, and stopping at the first failure or login request.
- **One log** in the lower right holds everything: live output, each result,
  system generation changes, and the question at its foot. Failures that a later
  success fixed are dimmed, and the header gives a verdict ("all clear: 3 failed,
  all fixed"), worked out by the rules of [misra](https://github.com/aaronjohnson/misra).
  A "command not found" comes with advice on which package to add where.
- **Logins.** When a deploy stops because a token has expired, the deck says so
  and offers a Log in button that opens the login in a small terminal, then
  brings the deck back.

Also new jars on the same shelf: a Mac-style app switcher (Super+Tab, and
Super+\` through one app's windows); an Open popup (Super+O) that takes a URL,
host or search words and suggests pages from the browser's history; and a
**public-repo guard**, global git hooks that stop a commit to a public GitHub
repo from mentioning terms on a private list kept outside the repo, or real email
addresses. The bar can now be told to stay light or dark until the next sunrise
or sunset, and it stays dark on grey days when misra's sky rules call it gloomy.

## Framed popups · 24–25 October 2026 · a matching set of jars

The pop-up windows got a common label. `SciFrame.qml` is a reusable sci-fi frame
(title tab across the top border, pulsing status light, corner brackets, a hint
tab below) that follows the light/dark theme, and the new popups wear it:

- **Keys menu** (Super+F2): every Hyprland binding with a description, read live
  from Hyprland, plus commands for the focused window.
- **Password prompt**: Quickshell is now the polkit agent, so password requests
  (for a system switch, say) appear in the same frame, one at a time, with an
  inline error on a wrong password.
- **Power menu**: tapping the power button locks the screen; holding it opens
  Sleep, Screensaver, Hibernate, Reboot and Power off, with a second press
  required for the last three.

The land/ship window now blurs and dims what is behind it. With an external
USB-C screen plugged in, that screen becomes the main one and the laptop panel
sits beside it; closing the lid turns the panel off and keeps working. An
external Keychron keyboard gets its own US layout (Caps Lock as Ctrl) while the
laptop keyboard stays Japanese.

## Ship, and a second opinion · 17–19 October 2026 · tasting before serving

- **ship** (Super+F11) is land's partner for deploys. A repo lists its targets in
  a `.ship` file (name, command, paths); ship shows what changed since each target
  last went out, plus an optional note, and runs the command on a yes. It commits
  waiting drafts first, so what ships always matches a commit, can add a dated
  entry to a changelog, and offers to log in again and retry when a deploy fails
  on an expired token. A repeated ship no longer finds phantom changes in its
  own changelog entry.
- **A second opinion on the battery.** After one resume from hibernation the
  firmware reported 0 % and a 100 W charger for an hour on battery. The bar and
  `hud` now read [misra](https://github.com/aaronjohnson/misra)'s verdict, and when
  it says a power sensor is lying they show its best estimate with a warning
  mark, or "?" when nothing trustworthy knows.

## land and the privacy switches · 12–16 October 2026 · new jars on the shelf

- **Privacy indicators**: small mic and camera icons on the bar show the laptop's
  hardware privacy switches, plus a software kill on Super+F7 (orange and struck
  through), and a notification when the mic switch moves.
- **land** (Super+F12): one command that commits every repo with a drafted
  message, pushes the repos the NixOS config takes as flake inputs, updates and
  builds the system, switches through polkit and pushes, asking before each
  outward step. It skips the switch when the new build would change nothing.
- **auto-brightness**: the screen follows the light sensor and learns from the
  brightness keys (Super+F8 toggles). The keyboard backlight breathes while the
  screen is off.
- Super+T toggles the bar's autohide; Alt+C / Alt+V copy and paste in any window;
  Super+F9 screenshots; Super+F1 opens Claude Code in a new terminal.

## Instruments in the pantry · 10 October 2026 · measuring spoons

The first day kept going, and most of it went into seeing what the machine is
doing without making it work harder to tell you.

- **Stats dropdown**: clicking the bar's small HUD glyph (CPU, memory and network
  in one 30 px dial) opens wifi, network, memory, CPU, GPU, NPU, thermals and
  battery as polar-clock dials: now at twelve o'clock, older samples trailing
  behind and fading, wrapping round in spirograph laps. Any dial flips to a time
  strip. Sampling rides the bar's existing 2-second tick, with expensive reads
  only while the dropdown is open.
- **CI chip** for the self-hosted GitHub Actions runner: idle, running (with the
  job's age, current step, build progress and an ETA) or failed, read from the
  service's cgroup without any network calls. Idle sleep now waits while a Nix
  build runs on the charger, so it no longer suspends mid-build.
- **usbc-power**: what a USB-C charger offers, what was negotiated, and what the
  battery is taking, per named port. The bar shows battery watts in and out.
- **hud**: the same dials as a full-screen terminal monitor, in braille, half
  blocks or ASCII, and with `--fb` anti-aliased on the bare console framebuffer.
- **Text console**: the desktop clipboard reaches the console's bash (Alt+V
  pastes), and Alt works as Meta there.

## First shelf · 10 October 2026 · the cabinet is built

The per-user side of a NixOS laptop running Hyprland: a Hyprland config in Lua,
hypridle and hyprlock, a Quickshell top bar (workspaces, battery, volume and
brightness, wifi links, a network graph, an NPU activity chip, offline sun and
moon skies), and kitty, tofi, mako and Emacs. Everything follows one light/dark
switch that the bar flips at local sunrise and sunset, Solarized Light by day and
Solarized Dark by night. Japanese input through fcitx5, and the bar learned to
hide until the pointer touches the top edge.
