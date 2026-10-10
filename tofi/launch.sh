#!/bin/sh
# Super + R: open tofi in Solarized Light or Dark, matching the system setting.
scheme=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)
case "$scheme" in
  *light*) colours=light ;;
  *)       colours=dark ;;
esac
exec tofi-drun --include "$HOME/.config/tofi/solarized-$colours.conf" "$@"
