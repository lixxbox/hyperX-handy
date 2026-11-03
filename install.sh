#!/usr/bin/env bash
# install.sh — installiert mute-bridge als systemd-User-Dienst.
# Idempotent: erneutes Ausfuehren aktualisiert die Installation.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
UNIT_NAME="mute-bridge.service"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- Abhaengigkeiten --------------------------------------------------------
info "pruefe Abhaengigkeiten"
missing=()
for cmd in pactl ydotool pgrep awk; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
    die "fehlende Befehle: ${missing[*]}
   Arch:   sudo pacman -S pipewire-pulse ydotool
   Debian: sudo apt install pulseaudio-utils ydotool"
fi

if ! pgrep -x ydotoold >/dev/null 2>&1 && ! pgrep -f ydotoold >/dev/null 2>&1; then
    warn "ydotoold laeuft nicht — ohne ihn kann die Bridge keine Tasten senden"
    warn "  systemctl --user enable --now ydotool.service"
fi

# --- Mikrofon erkennen ------------------------------------------------------
info "suche HyperX SoloCast"
SRC="$(pactl list short sources 2>/dev/null | awk 'tolower($2) ~ /solocast/ {print $2; exit}' || true)"
if [ -n "$SRC" ]; then
    info "gefunden: $SRC"
else
    warn "kein SoloCast gefunden — die Bridge wartet spaeter auf das Geraet"
fi

# --- Dateien installieren ---------------------------------------------------
info "installiere Skript nach $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 755 "$REPO_DIR/bin/mute-bridge.sh" "$BIN_DIR/mute-bridge.sh"

info "installiere Unit nach $UNIT_DIR"
mkdir -p "$UNIT_DIR"
sed "s|%h/.local/bin|$BIN_DIR|g" \
    "$REPO_DIR/systemd/$UNIT_NAME" > "$UNIT_DIR/$UNIT_NAME"

# --- Dienst aktivieren ------------------------------------------------------
info "aktiviere $UNIT_NAME"
systemctl --user daemon-reload
systemctl --user enable "$UNIT_NAME" >/dev/null
systemctl --user restart "$UNIT_NAME"

sleep 1
if systemctl --user is-active --quiet "$UNIT_NAME"; then
    info "laeuft"
else
    warn "Dienst ist nicht aktiv — Log pruefen:"
    journalctl --user -u "$UNIT_NAME" -n 20 --no-pager
    exit 1
fi

echo
"$BIN_DIR/mute-bridge.sh" --status || true
echo
info "fertig. Log: journalctl --user -u $UNIT_NAME -f"
