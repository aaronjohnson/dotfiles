;;; init.el --- Emacs configuration  -*- lexical-binding: t; -*-

;; ---- Clipboard ----
;; GUI Emacs (emacs-pgtk) talks to the Wayland clipboard natively. In the
;; terminal (`emacs -nw` in kitty) there are two fallbacks:
;;
;; 1. On this laptop, with wl-clipboard installed: kills go through wl-copy and
;;    C-y reads wl-paste, so the clipboard behaves like any other app.
;; 2. Anywhere else (e.g. over SSH, where wl-paste can't reach your clipboard):
;;    kills are sent to kitty with the OSC 52 escape code and kitty puts them on
;;    the clipboard; paste from other apps with kitty's Ctrl+Shift+V.

;; Fallback 2. Only setSelection (Emacs -> clipboard): getSelection would make
;; kitty show a permission prompt on every yank.
(setq xterm-extra-capabilities '(setSelection modifyOtherKeys))
(setq select-enable-clipboard t)

;; Fallback 1, used when running in a terminal inside the Wayland session.
(defun my/wl-copy (text &optional primary)
  ;; wl-copy reads TEXT, then forks into the background to serve it, so the
  ;; clipboard keeps it even after Emacs quits. PRIMARY targets the
  ;; middle-click selection instead of the clipboard.
  (let ((proc (make-process :name "wl-copy" :buffer nil :noquery t
                            :command (if primary '("wl-copy" "-n" "--primary") '("wl-copy" "-n"))
                            :connection-type 'pipe)))
    (process-send-string proc text)
    (process-send-eof proc)))

(defun my/wl-paste ()
  ;; Return nil when the clipboard just holds our own latest kill, so Emacs
  ;; does not push it into the kill ring a second time.
  (let ((text (shell-command-to-string "wl-paste -n 2>/dev/null | tr -d '\\r'")))
    (unless (or (string-empty-p text) (equal text (car kill-ring)))
      text)))

(when (and (not (display-graphic-p))
           (getenv "WAYLAND_DISPLAY")
           (executable-find "wl-copy")
           (executable-find "wl-paste"))
  (setq interprogram-cut-function #'my/wl-copy
        interprogram-paste-function #'my/wl-paste))

;; ---- Highlighted region -> selection ----
;; Whatever you highlight (C-SPC then move, or mouse) is shared as you go, like
;; selecting text anywhere else on Linux.
(defvar my/region-selection 'PRIMARY
  "Where a highlighted region goes.
'PRIMARY: the middle-click selection; Ctrl+V's clipboard is left alone.
'CLIPBOARD: the main clipboard (replaces whatever you last copied).")

(defvar my/last-region-text nil)

(defun my/share-region ()
  (when (region-active-p)
    (let ((text (buffer-substring-no-properties (region-beginning) (region-end))))
      (unless (or (string-empty-p text) (equal text my/last-region-text))
        (setq my/last-region-text text)
        (cond
         ;; GUI Emacs already puts the region in PRIMARY by itself.
         ((and (display-graphic-p) (eq my/region-selection 'PRIMARY)) nil)
         ((eq interprogram-cut-function #'my/wl-copy)
          (my/wl-copy text (eq my/region-selection 'PRIMARY)))
         ;; Terminal without wl-clipboard (or over SSH): OSC 52 through kitty.
         (t (gui-set-selection my/region-selection text)))))))

;; Checked once whenever you pause for a quarter second, not on every keystroke.
(run-with-idle-timer 0.25 t #'my/share-region)

;; ---- Solarized, following the system light/dark switch ----
;; The Quickshell bar flips the system colour scheme at Vancouver's sunrise and
;; sunset (click the VAN sky to flip by hand); kitty follows it, and so does this.
;; - GUI Emacs: loads solarized-light or solarized-dark (package solarized-theme).
;; - Terminal Emacs: no theme, so it uses kitty's colours, which are already
;;   Solarized and already follow the switch.
(require 'dbus)

(defun my/system-prefers-light-p ()
  "Ask the desktop portal: color-scheme 1 = dark, 2 = light, 0 = no preference."
  (let ((v (ignore-errors
             (dbus-call-method :session "org.freedesktop.portal.Desktop"
                               "/org/freedesktop/portal/desktop"
                               "org.freedesktop.portal.Settings" "ReadOne"
                               "org.freedesktop.appearance" "color-scheme"))))
    (eql (if (consp v) (car v) v) 2)))

(defun my/apply-solarized (&optional light)
  (when (and (display-graphic-p) (locate-library "solarized-theme"))
    (let ((theme (if (if light (eq light 'light) (my/system-prefers-light-p))
                     'solarized-light 'solarized-dark)))
      (unless (custom-theme-enabled-p theme)
        (mapc #'disable-theme custom-enabled-themes)
        (load-theme theme t)))))

;; Apply now (GUI only), and again whenever the system switch flips.
(add-hook 'after-init-hook #'my/apply-solarized)
(ignore-errors
  (dbus-register-signal :session "org.freedesktop.portal.Desktop"
                        "/org/freedesktop/portal/desktop"
                        "org.freedesktop.portal.Settings" "SettingChanged"
                        (lambda (namespace key value)
                          (when (and (equal namespace "org.freedesktop.appearance")
                                     (equal key "color-scheme"))
                            (let ((v (if (consp value) (car value) value)))
                              (my/apply-solarized (if (eql v 2) 'light 'dark)))))))

;; ---- Nix files ----
;; nix-mode (package) colours and indents .nix files; its autoloads register
;; *.nix themselves, this just makes it explicit.
(when (locate-library "nix-mode")
  (add-to-list 'auto-mode-alist '("\\.nix\\'" . nix-mode)))
