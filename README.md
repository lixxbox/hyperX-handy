# hyperX-handy

Koppelt den **Mute-Taster des HyperX SoloCast 2** bidirektional an
[Handy](https://github.com/cjpais/handy), die Diktat-App:

| Aktion | Ergebnis |
|---|---|
| Taster drücken (stumm → offen) | Handy startet die Aufnahme |
| Taster drücken (offen → stumm) | Handy stoppt die Aufnahme |
| Handy startet Aufnahme (Shortcut, Tray) | Mikrofon wird entstummt |
| Handy stoppt Aufnahme | Mikrofon wird stummgeschaltet |

Damit wird aus dem großen Taster am Mikrofon ein Start/Stop-Knopf fürs
Diktieren — ohne die Tastatur zu benutzen und ohne die Hände vom Mikrofon
zu nehmen.

## Warum das nicht offensichtlich ist

Der Taster ist **kein** normales Eingabegerät. Er sendet keine
Tastatur-Events und taucht nicht als HID-Taste auf. Er schaltet einen
USB-Audio-Control in der Firmware, der als ALSA-Capture-Switch erscheint
und von PipeWire als `Mute: yes/no` gespiegelt wird.

Der naheliegende Weg über `/dev/hidraw*` bzw. evdev ist eine Sackgasse:
Handy greift das Consumer-Control-Gerät exklusiv (`EVIOCGRAB`), und der
Taster sendet dort ohnehin nichts. Details und Messungen stehen in
[docs/reverse-engineering.md](docs/reverse-engineering.md).

## Funktionsweise

```
        ┌──────────────┐
Taster ─► ALSA cswitch ├─► PipeWire-Mute ─┐
        └──────────────┘                  │
                                          ▼
                                   ┌─────────────┐   ctrl+space   ┌───────┐
                                   │ mute-bridge │ ─────────────► │ Handy │
                                   └─────────────┘ ◄───────────── └───────┘
                                          ▲        cpal-Stream
                                          │
                                   pactl set-source-mute
```

Die Bridge reagiert auf **Zustände**, nicht auf Tastendrücke:

- **Richtung 1** — Mute-Zustand ändert sich → Handy folgt (`ctrl+space`).
- **Richtung 2** — Handys Aufnahme-Stream erscheint/verschwindet → Mikrofon folgt.

Weil Richtung 2 am Aufnahme-Stream hängt, ist es egal, welche Bindung in
Handy eingestellt ist: `ctrl+space`, `ctrl+shift+space`, Tray-Knopf oder
eine selbst gewählte Kombination funktionieren alle.

### Rückkopplung

Ohne Schutz würde die Bridge ihre eigene Wirkung als Nutzeraktion
interpretieren und endlos weiterschalten. Statt eines pauschalen
Sperrfensters (das auch echte Tastendrücke verschluckt) merkt sich die
Bridge nach jeder eigenen Aktion genau die erwartete Änderung und
ignoriert sie **einmal**. Echte Eingaben bleiben jederzeit wirksam.

### Schutzfilter

- Läuft nur, wenn Handy läuft.
- Greift nicht, wenn ein **fremdes** Programm das Mikrofon aufnimmt
  (Teams, Zoom, Discord …). HushMic-Filterkette und Handys eigener Stream
  zählen nicht als fremd.
- Ein Zustandswechsel muss 300 ms stabil sein. Kurz aufblitzende Streams
  (Geräte-Probe, Feedback-Beep) schalten das Mikrofon nicht.

## Voraussetzungen

- Linux mit **PipeWire/WirePlumber** (getestet: CachyOS/Arch, GNOME auf Wayland)
- **HyperX SoloCast 2**
- **Handy** ≥ 0.10 mit `keyboard_implementation = handy_keys`
- **ydotool** mit laufendem `ydotoold` (Tasteninjektion unter Wayland)
- `pactl` (pipewire-pulse), `pgrep`, `awk`

## Installation

```bash
git clone <repo> ~/Projekte/hyperX-handy
cd ~/Projekte/hyperX-handy
./install.sh
```

Das Skript prüft die Abhängigkeiten, installiert
`~/.local/bin/mute-bridge.sh`, legt die systemd-User-Unit an und startet
den Dienst. Es ist idempotent — erneutes Ausführen aktualisiert die
Installation.

## Benutzung

```bash
~/.local/bin/mute-bridge.sh --status             # Zustand anzeigen
journalctl --user -u mute-bridge.service -f      # live mitlesen
systemctl --user stop mute-bridge.service        # pausieren
systemctl --user restart mute-bridge.service     # neu starten
```

`--status` zeigt:

```
quelle=alsa_input.usb-...SoloCast_2... mute=yes soll=still ist=still fremd=0 handy=ja sync_back=1
```

| Feld | Bedeutung |
|---|---|
| `mute` | aktueller Hardware-Mute des Mikrofons |
| `soll` | Soll-Zustand laut Taster (`aufnahme` / `still`) |
| `ist` | läuft in Handy gerade eine Aufnahme? |
| `fremd` | Anzahl fremder Capture-Streams (Call-Schutz) |
| `handy` | läuft Handy? |
| `sync_back` | ist Richtung 2 aktiv? |

## Konfiguration

Die Quelle wird nicht über einen festen PipeWire-Namen gesucht. PipeWire
hängt nach einem USB-Reconnect bei Bedarf `.2`, `.3`, … an und die
ALSA-Kartennummer kann sich ebenfalls ändern. Stattdessen erkennt die
Bridge das Gerät an seinen stabilen Eigenschaften
(`device.product.name`, Beschreibung, Gerätename).

Per `systemctl --user edit mute-bridge.service` oder als Umgebungsvariablen:

| Variable | Default | Wirkung |
|---|---|---|
| `SOLOCAST_MATCH` | `HyperX SoloCast` | Geräte-Match für die automatische Suche |
| `SOLOCAST_SOURCE` | automatisch erkannt | PipeWire-Quellname exakt überschreiben |
| `SYNC_BACK` | `1` | `0` = nur Taster steuert Handy, Mikrofon bleibt unangetastet |
| `DRY_RUN` | `0` | `1` = nur loggen, nichts senden/schalten |
| `FORCE` | `0` | `1` = Call-Schutz ignorieren |
| `DEBOUNCE` | `0.15` | Sekunden zwischen Event und Auswertung |
| `REC_CONFIRM` | `0.30` | Stabilitätsfenster für den Aufnahme-Status |
| `EXPECT_MS` | `3000` | Wartezeit auf eine eigene Änderung |

## Grenzen

- **Nach jedem Diktat ist das Mikrofon stumm.** Das ist die gewünschte
  Logik, heißt aber: vor einem Call einmal den Taster drücken.
- **Erster Start aus entstummtem Zustand braucht zwei Drücke**
  (stumm → offen). Im Alltag irrelevant, weil das Mikrofon nach jedem
  Stopp stumm ist.
- Getestet ausschließlich mit dem SoloCast 2. Andere Mikrofone mit
  `HW_MUTE_CTRL` sollten funktionieren, sind aber ungeprüft.
- Tasteninjektion läuft über `uinput`/`ydotoold` und damit nur in der
  laufenden Wayland-Session.

## Fehlersuche

```bash
# Läuft ydotoold?
pgrep -a ydotoold
systemctl --user status ydotool.service

# Wird das Mikrofon gefunden? (zeigt den aktuell aufgelösten Quellnamen)
~/.local/bin/mute-bridge.sh --detect
pactl list short sources | grep -i solocast

# Erkennt die Bridge den Taster?
amixer -c "$(pactl list short sources | grep -i solocast | head -1 | cut -d' ' -f1)" sget Mic
```

Kein Effekt, obwohl der Taster gedrückt wird? Im Journal steht der Grund,
z. B. `uebersprungen: 1 fremde(r) Capture-Stream(s) aktiv` (Call-Schutz)
oder `aufnahme-status instabil (1 -> 0) — ignoriert` (Stream-Flap).

## Deinstallation

```bash
./uninstall.sh
```

## Lizenz

Noch nicht festgelegt.
