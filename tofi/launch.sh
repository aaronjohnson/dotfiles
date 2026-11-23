#!/bin/sh
# Super + R: open tofi in Solarized Light, Dark or Glass, matching the bar.
scheme=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)
case "$scheme" in
  *light*) colours=solarized-light ;;
  *)       colours=solarized-dark ;;
esac
# Glass (◌ in the bar) is dark to everyone else; bin/theme-glass leaves a note for us.
mode=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/theme/mode" 2>/dev/null)
[ "$mode" = glass ] && colours=solarized-glass
exec tofi-drun --include "$HOME/.config/tofi/$colours.conf" "$@"
