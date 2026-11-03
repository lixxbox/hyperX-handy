#!/usr/bin/env bash
# uninstall.sh — entfernt Dienst und Skript, laesst Handy und PipeWire unberuehrt.

set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
UNIT_DIR="${UNIT_DIR:-$HOME/.config/systemd/user}"
UNIT_NAME="mute-bridge.service"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

info "stoppe und deaktiviere $UNIT_NAME"
systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true

info "entferne Unit"
rm -f "$UNIT_DIR/$UNIT_NAME"
systemctl --user daemon-reload

info "entferne Skript"
rm -f "$BIN_DIR/mute-bridge.sh"

info "fertig. Mikrofon-Zustand bleibt wie er ist."
