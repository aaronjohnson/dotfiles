#!/usr/bin/env bash
# Keyboard backlight effects for hypridle: fade out slowly, breathe while the screen sleeps,
# or restore the saved level on resume.
# usage: kbd-fade.sh out [seconds] | breathe [period-seconds] | restore
set -u
dev=chromeos::kbd_backlight
pidfile="${XDG_RUNTIME_DIR:-/tmp}/kbd-fade.pid"
case "${1:-}" in
  out)
    secs="${2:-120}"
    brightnessctl -q -s -d "$dev"            # remember the current level for restore
    start=$(brightnessctl -d "$dev" get)
    (( start > 0 )) || exit 0
    echo $$ > "$pidfile"
    steps=20
    for i in $(seq $((steps - 1)) -1 0); do
      brightnessctl -q -d "$dev" set $(( start * i / steps ))
      sleep "$(awk -v s="$secs" -v n="$steps" 'BEGIN{print s/n}')"
    done
    rm -f "$pidfile" ;;
  breathe)
    period="${2:-6}"                          # seconds per breath
    brightnessctl -q -s -d "$dev"
    peak=$(brightnessctl -d "$dev" get 2>/dev/null)
    (( peak > 0 )) || peak=40
    echo $$ > "$pidfile"
    steps=40
    while :; do                               # smooth rise and fall (raised cosine)
      for i in $(seq 0 $((steps - 1))); do
        level=$(awk -v p="$peak" -v i="$i" -v n="$steps" 'BEGIN{printf "%d", p*(1-cos(6.2832*i/n))/2}')
        brightnessctl -q -d "$dev" set "$level"
        sleep "$(awk -v s="$period" -v n="$steps" 'BEGIN{print s/n}')"
      done
    done ;;
  restore)
    [[ -f "$pidfile" ]] && kill "$(cat "$pidfile")" 2>/dev/null; rm -f "$pidfile"
    brightnessctl -q -r -d "$dev" ;;
  *) echo "usage: $0 out [seconds] | breathe [period] | restore" >&2; exit 2 ;;
esac
