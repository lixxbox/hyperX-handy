#!/usr/bin/env bash
# mute-bridge.sh — bidirektionale Kopplung zwischen dem Mute-Taster des
# HyperX SoloCast 2 und Handy (Diktat).
#
# Richtung 1 (Taster -> Handy):
#   entstummt (Mute: no)  -> Aufnahme soll laufen   -> ctrl+space
#   stumm     (Mute: yes) -> Aufnahme soll stehen   -> ctrl+space
#
# Richtung 2 (Handy -> Taster), SYNC_BACK=1:
#   Aufnahme startet (egal wodurch: ctrl+space, Tray, andere Bindung)
#     -> Mikrofon entstummen
#   Aufnahme endet
#     -> Mikrofon stummschalten
#
# Beide Richtungen reagieren auf Zustaende, nicht auf Tastendruecke.
# Rueckkopplung wird ueber Erwartungsmarken verhindert: nach einer eigenen
# Aktion wird genau die erwartete Zustandsaenderung einmal ignoriert.
# Andere (echte) Nutzeraktionen bleiben dadurch jederzeit wirksam.
#
# Schutzfilter:
#   1. laeuft nur, wenn Handy laeuft
#   2. greift nicht, wenn ein fremdes Programm das Mikrofon aufnimmt
#      -> in Calls (Teams/Zoom/Discord) bleibt alles unveraendert
#
# Env:
#   DRY_RUN=1         nur loggen, nichts senden/schalten
#   SYNC_BACK=0       Richtung 2 (Handy -> Taster) abschalten
#   SOLOCAST_SOURCE   Quellname exakt ueberschreiben
#   SOLOCAST_MATCH    Geraete-Match fuer die automatische Suche
#                     (Default "HyperX SoloCast")
#   DEBOUNCE          Sekunden zwischen Event und Auswertung (Default 0.15)
#   EXPECT_MS         Wartezeit auf eigene Aenderung in ms (Default 3000)
#   REC_CONFIRM       Stabilitaetsfenster fuer Aufnahme-Status (Default 0.30)
#   FORCE=1           Schutzfilter 2 umgehen

set -uo pipefail

SRC="${SOLOCAST_SOURCE:-}"
SOURCE_MATCH="${SOLOCAST_MATCH:-HyperX SoloCast}"
DRY_RUN="${DRY_RUN:-0}"
SYNC_BACK="${SYNC_BACK:-1}"
FORCE="${FORCE:-0}"
DEBOUNCE="${DEBOUNCE:-0.15}"
EXPECT_MS="${EXPECT_MS:-3000}"

# evdev-Codes: 29 = KEY_LEFTCTRL, 57 = KEY_SPACE
KEY_SEQ="29:1 57:1 57:0 29:0"

log() { printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$*"; }
now_ms() { date +%s%3N; }

# Quelle automatisch finden. Der PipeWire-Name ist NICHT stabil: nach einem
# USB-Reconnect haengt PipeWire bei Bedarf ".2", ".3", ... an
# (...-00.analog-stereo -> ...-00.2.analog-stereo), und die ALSA-Karten-
# nummer kann sich ebenfalls aendern. Deshalb wird das Geraet anhand der
# stabilen Eigenschaften (device.product.name / Description / Name) gesucht.
# Bei mehreren Treffern (alter Node lebt beim Reconnect kurz weiter) gewinnt
# der hoechste Index, also der neu angelegte Node.
detect_source() {
    pactl list sources 2>/dev/null | awk -v needle="$SOURCE_MATCH" '
        BEGIN { m = tolower(needle) }
        function remember(idx, name, prod, desc) {
            if (idx == "" || name == "" || name ~ /\.monitor$/) return
            if (index(tolower(prod " " desc " " name), m) == 0) return
            if (idx + 0 >= best) { best = idx + 0; bestname = name }
        }
        /^Source #[0-9]+/ {
            remember(idx, name, prod, desc)
            idx = $0; sub(/^Source #/, "", idx)
            name = ""; prod = ""; desc = ""
            next
        }
        /^\tName: / { name = $0; sub(/^\tName: /, "", name); next }
        /^\tDescription: / { desc = $0; sub(/^\tDescription: /, "", desc); next }
        /^\t\tdevice.product.name = / {
            prod = $0; sub(/^\t\tdevice.product.name = /, "", prod); gsub(/"/, "", prod); next
        }
        END {
            remember(idx, name, prod, desc)
            if (bestname != "") print bestname
        }'
}

mute_state() {
    [ -n "$SRC" ] || return 1
    pactl get-source-mute "$SRC" 2>/dev/null | awk '{print $2}'
}

handy_running() {
    pgrep -f 'handy|Handy_[0-9]' >/dev/null 2>&1
}

# Handys eigener Capture-Stream (cpal-pulseaudio-<pid>)
# Rueckgabe: 0 = nimmt auf, 1 = nimmt nicht auf, 2 = nicht ermittelbar.
# Wichtig: nur ein FEHLGESCHLAGENES pactl ist "nicht ermittelbar". Eine
# erfolgreiche, leere Ausgabe bedeutet dagegen eindeutig: es gibt keinen
# Capture-Stream, also laeuft keine Aufnahme. Wird das als "unklar"
# behandelt, verwirft die Bridge im Leerlauf (keine Source-Outputs) jedes
# Taster-Event und startet nie eine Aufnahme.
handy_recording() {
    local out
    out="$(pactl list source-outputs 2>/dev/null)" || return 2
    case "$out" in
        *cpal-pulseaudio*) return 0 ;;
        *)                 return 1 ;;
    esac
}

# Anzahl fremder Capture-Streams (HushMic, Handy und PipeWire ausgenommen)
foreign_streams() {
    pactl list source-outputs 2>/dev/null | awk -v RS='Source Output #' '
        NR > 1 {
            s = tolower($0)
            if (s ~ /hushmic|filter-chain|cpal-pulseaudio|pipewire/) next
            n++
        }
        END { print n + 0 }'
}

status_line() {
    local mute rec
    mute="$(mute_state)"
    handy_recording; local hr=$?
    if [ "$hr" = 0 ]; then rec="aufnahme"; elif [ "$hr" = 1 ]; then rec="still"; else rec="unklar"; fi
    printf 'mute=%s soll=%s ist=%s fremd=%s handy=%s sync_back=%s' \
        "$mute" \
        "$([ "$mute" = "no" ] && echo aufnahme || echo still)" \
        "$rec" \
        "$(foreign_streams)" \
        "$(handy_running && echo ja || echo nein)" \
        "$SYNC_BACK"
}

# --- Aktionen ---------------------------------------------------------------

fire_key() {
    local want="$1"

    if ! handy_running; then
        log "uebersprungen (Taster): Handy laeuft nicht"
        return 1
    fi
    if [ "$FORCE" != "1" ]; then
        local n
        n="$(foreign_streams)"
        if [ "${n:-0}" -gt 0 ]; then
            log "uebersprungen (Taster): ${n} fremde(r) Capture-Stream(s) aktiv"
            return 1
        fi
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: wuerde ctrl+space senden (ziel=$want)"
        return 0
    fi

    log "sende ctrl+space (ziel=$want)"
    if ! ydotool key $KEY_SEQ; then
        log "FEHLER: ydotool fehlgeschlagen (Socket: ${YDOTOOL_SOCKET:-$XDG_RUNTIME_DIR/.ydotool_socket})"
        return 1
    fi
    return 0
}

set_mute() {
    local target="$1"   # yes = stumm, no = entstummt

    if ! handy_running; then
        log "uebersprungen (Handy): Handy laeuft nicht"
        return 1
    fi
    if [ "$FORCE" != "1" ]; then
        local n
        n="$(foreign_streams)"
        if [ "${n:-0}" -gt 0 ]; then
            log "uebersprungen (Handy): ${n} fremde(r) Capture-Stream(s) aktiv — Mikrofon unveraendert"
            return 1
        fi
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: wuerde Mikrofon auf mute=$target setzen"
        return 0
    fi

    log "setze Mikrofon mute=$target"
    pactl set-source-mute "$SRC" "$([ "$target" = "yes" ] && echo 1 || echo 0)" || {
        log "FEHLER: pactl set-source-mute fehlgeschlagen"
        return 1
    }
    return 0
}

# --- Einmalabfragen fuer Debugging/Installation ------------------------------
if [ "${1:-}" = "--detect" ]; then
    SRC="${SOLOCAST_SOURCE:-$(detect_source)}"
    [ -n "$SRC" ] && { echo "$SRC"; exit 0; }
    exit 1
fi

if [ "${1:-}" = "--status" ]; then
    [ -n "${SOLOCAST_SOURCE:-}" ] || SRC="$(detect_source)"
    if [ -z "$SRC" ]; then
        echo "quelle=nicht gefunden"
        exit 1
    fi
    printf 'quelle=%s ' "$SRC"
    status_line; echo
    exit 0
fi

command -v pactl   >/dev/null || { log "pactl fehlt";   exit 1; }
command -v ydotool >/dev/null || { log "ydotool fehlt"; exit 1; }
command -v pgrep   >/dev/null || { log "pgrep fehlt";   exit 1; }

log "start | dry_run=$DRY_RUN | sync_back=$SYNC_BACK | force=$FORCE"
trap 'log "beende"; exit 0' INT TERM

# Aeussere Schleife: ueberlebt PipeWire-Neustarts (Suspend/Resume) und
# wartet geduldig, wenn das Mikrofon nicht angeschlossen ist.
while true; do
    [ -n "${SOLOCAST_SOURCE:-}" ] || SRC="$(detect_source)"

    while [ -z "$SRC" ] || [ -z "$(mute_state)" ]; do
        if [ -z "$SRC" ]; then
            log "warte auf SoloCast ..."
        else
            log "warte auf Quelle '$SRC' ..."
        fi
        sleep 5
        [ -n "${SOLOCAST_SOURCE:-}" ] || SRC="$(detect_source)"
    done

    last_mute="$(mute_state)"
    handy_recording; hr=$?
    if [ "$hr" = 0 ]; then last_rec=1; elif [ "$hr" = 1 ]; then last_rec=0; else last_rec=-1; fi
    # Erwartete eigene Aenderungen (statt pauschalem Sperrfenster):
    expect_rec=""; expect_rec_until=0
    expect_mute=""; expect_mute_until=0
    log "verbunden | $(status_line)"

    # pactl subscribe laeuft im Coprozess. Bei einer Pipe
    # (pactl subscribe | while ...) haengt der Abbruch sonst: der Leser
    # bricht zwar aus, pactl merkt das aber erst beim naechsten Event und
    # der Parent wartet endlos. Genau daran blieb die Bridge nach einem
    # USB-Reconnect haengen und reagierte danach auf nichts mehr.
    coproc PACTL_SUB { pactl subscribe 2>/dev/null; }
    sub_pid="$PACTL_SUB_PID"
    sub_fd="${PACTL_SUB[0]}"

    while IFS= read -r line <&"$sub_fd"; do
        case "$line" in
            *"on source-output"*) sleep "${REC_DEBOUNCE:-0.35}" ;;
            *"on source"*|*"on card"*) sleep "$DEBOUNCE" ;;
            *) continue ;;
        esac

        # Quelle bei jedem relevanten Event neu aufloesen. Der Name kann
        # sich beim Reconnect aendern, und waehrend der Uebergangsphase
        # koennen alter und neuer Node kurz gleichzeitig existieren.
        if [ -z "${SOLOCAST_SOURCE:-}" ]; then
            new_src="$(detect_source)"
            if [ -z "$new_src" ]; then
                log "quelle nicht erreichbar — Verbindung neu aufbauen"
                break
            fi
            if [ "$new_src" != "$SRC" ]; then
                log "quelle gewechselt: '$SRC' -> '$new_src'"
                SRC="$new_src"
                last_mute="$(mute_state)"
                handy_recording; hr=$?
                if [ "$hr" = 0 ]; then last_rec=1; elif [ "$hr" = 1 ]; then last_rec=0; else last_rec=-1; fi
                continue
            fi
        fi

        mute="$(mute_state)"
        if [ -z "$mute" ]; then
            log "quelle '$SRC' antwortet nicht — Verbindung neu aufbauen"
            break
        fi
        handy_recording; hr=$?
        [ "$hr" = 2 ] && { log "aufnahme-status nicht ermittelbar — uebersprungen"; continue; }
        if [ "$hr" = 0 ]; then rec=1; else rec=0; fi

        now="$(now_ms)"
        [ -n "$expect_rec" ]  && [ "$now" -gt "$expect_rec_until" ]  && expect_rec=""
        [ -n "$expect_mute" ] && [ "$now" -gt "$expect_mute_until" ] && expect_mute=""

        mute_changed=0; rec_changed=0
        [ "$mute" != "$last_mute" ] && mute_changed=1
        [ "$rec"  != "$last_rec"  ] && rec_changed=1
        last_mute="$mute"; last_rec="$rec"

        # Nur die Aenderung verschlucken, die wir selbst herbeigefuehrt haben.
        # Echte Nutzeraktionen bleiben jederzeit wirksam.
        if [ "$rec_changed" = 1 ] && [ -n "$expect_rec" ] && [ "$rec" = "$expect_rec" ]; then
            log "aufnahme $([ "$rec" = 1 ] && echo gestartet || echo gestoppt) (eigene aktion) — ignoriert"
            expect_rec=""; rec_changed=0
        fi
        if [ "$mute_changed" = 1 ] && [ -n "$expect_mute" ] && [ "$mute" = "$expect_mute" ]; then
            log "mute=$mute (eigene aktion) — ignoriert"
            expect_mute=""; mute_changed=0
        fi

        # Vorrang hat immer der physische Taster: hat sich der Mute-Zustand
        # geaendert, folgt Handy. Nur wenn ausschliesslich die Aufnahme
        # wechselte, wurde sie per Tastatur/Tray gestartet -> Mikrofon folgt.
        if [ "$mute_changed" = 1 ]; then
            if [ "$mute" = "no" ]; then want=1; else want=0; fi
            if [ "$want" != "$rec" ]; then
                if fire_key "$([ "$want" = 1 ] && echo aufnahme || echo still)"; then
                    expect_rec="$want"; expect_rec_until=$(( $(now_ms) + EXPECT_MS ))
                fi
            else
                log "taster gedrueckt, aber ziel bereits erreicht — nichts zu tun"
            fi

        elif [ "$rec_changed" = 1 ]; then
            # Stabilitaetspruefung: kurze Stream-Flaps (Geraete-Probe,
            # Feedback-Beep) duerfen das Mikrofon nicht schalten.
            sleep "${REC_CONFIRM:-0.30}"
            handy_recording; hr=$?
            if [ "$hr" = 2 ]; then
                log "aufnahme-status nicht ermittelbar — ignoriert"
                continue
            fi
            if [ "$hr" = 0 ]; then rec_now=1; else rec_now=0; fi
            if [ "$rec_now" != "$rec" ]; then
                log "aufnahme-status instabil ($rec -> $rec_now) — ignoriert"
                last_rec="$rec_now"
                continue
            fi

            if [ "$SYNC_BACK" != "1" ]; then
                log "handy $([ "$rec" = 1 ] && echo startete || echo stoppte) — sync_back aus, Mikrofon unveraendert"
                continue
            fi
            if [ "$rec" = 1 ]; then target=no; else target=yes; fi
            if [ "$mute" != "$target" ]; then
                log "handy $([ "$rec" = 1 ] && echo startete || echo stoppte)"
                if set_mute "$target"; then
                    expect_mute="$target"; expect_mute_until=$(( $(now_ms) + EXPECT_MS ))
                fi
            else
                log "handy $([ "$rec" = 1 ] && echo startete || echo stoppte), mikrofon bereits mute=$target"
            fi
        fi
    done

    kill "$sub_pid" 2>/dev/null
    wait "$sub_pid" 2>/dev/null
    exec {sub_fd}<&-

    log "pactl subscribe beendet — Verbindung in 2s neu aufbauen"
    sleep 2
done
