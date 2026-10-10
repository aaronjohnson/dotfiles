# dotfiles

Desktop configuration for my Framework Laptop 13 Pro running NixOS and Hyprland.
The system itself (packages, hibernation, Japanese input, the NPU driver) lives in
[nixos](https://github.com/aaronjohnson/nixos); this repo is the per-user side.

Everything follows one light/dark switch: the Quickshell bar flips it at local
sunrise and sunset (Solarized Light by day, Solarized Dark by night), and kitty,
tofi, mako, GTK apps and Emacs follow.

| Folder | What it is |
|---|---|
| `hypr/` | Hyprland (Lua config), hypridle (dim, lock, sleep), hyprlock (lock screen) |
| `quickshell/` | The top bar: workspaces, battery, volume/brightness, wifi with MLO link chips, a log-log network graph, an NPU activity chip, and sun/moon skies for four cities, all computed offline |
| `kitty/` | Terminal: Solarized themes that switch with the system, JP-keyboard font keys |
| `tofi/` | App launcher on Super+R, light or dark to match |
| `yazi/` | Terminal file manager on Super+E, opening files in Emacs |
| `mako/` | Notifications that age out and group repeats |
| `fcitx5/` | Japanese input (Anthy): 半角/全角 toggles, 変換/無変換 on/off |
| `emacs/` | `init.el`: Wayland clipboard from the terminal, Solarized that follows the switch, nix-mode |

## Install

Each folder belongs in `~/.config/` (`emacs/init.el` goes in `~/.emacs.d/`). I keep the
repo in `~/dotfiles` and symlink:

```sh
for d in hypr quickshell kitty tofi yazi mako fcitx5; do ln -s ~/dotfiles/$d ~/.config/$d; done
ln -s ~/dotfiles/emacs/init.el ~/.emacs.d/init.el
```

Some settings are specific to this machine: the home city's coordinates in
`quickshell/shell.qml`, `BAT1`/`intel_backlight` sysfs paths, and the
`/run/user/1000` socket paths.
