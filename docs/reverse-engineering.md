# Wie der Mute-Taster des SoloCast 2 tatsächlich funktioniert

Messprotokoll und Begründung, warum die Bridge über PipeWire-Mute geht und
nicht über HID.

## Ausgangsfrage

Der kapazitive Mute-Taster am HyperX SoloCast 2 soll als Start/Stop-Knopf
für eine Diktat-App dienen. Dafür muss das Betriebssystem den Tastendruck
überhaupt bemerken.

## Was das Gerät im System anbietet

```
USB     03f0:0fbf  HP, Inc HyperX SoloCast 2   (Port 1-3)
ALSA    Karte 3, Gerät 0  "HP, Inc HyperX SoloCast 2 at usb-..."
USB-Interfaces
        1-3:1.0  Klasse 01  Audio Control
        1-3:1.1  Klasse 01  Audio Streaming
        1-3:1.2  Klasse 03  HID
```

Das HID-Interface erzeugt zwei evdev-Geräte und ein hidraw-Node:

```
/dev/input/event26   "HP, Inc HyperX SoloCast 2 Consumer Control"  (EV_KEY)
/dev/input/event27   "HP, Inc HyperX SoloCast 2"                   (EV_ABS)
/dev/hidraw13        nur root lesbar
```

## Sackgasse 1: HID/evdev

Beim Drücken des Tasters kamen auf `event26`, `event27` und `event28`
(Handys Passthrough) **keine Events** an. Zwei Gründe:

1. Handy greift `event26` exklusiv:
   ```
   EVIOCGRAB auf /dev/input/event26 -> EBUSY
   ```
   Nachweis über `/proc/<pid>/fd`: gnome-shell und handy halten das Gerät
   offen, `EVIOCGRAB` schlägt fehl.
2. Die Capability-Liste von `event26` enthält `KEY_MUTE`, `KEY_VOLUMEUP`,
   `KEY_PLAYPAUSE` … aber **kein** `KEY_MICMUTE` (248).

Ein Selbsttest schloss einen Fehler im Reader aus: `ydotool key 29:1 29:0`
erzeugte auf `/dev/input/event25` sauber `EV_KEY code=29`.

## Sackgasse 2: Firmware-Mute

Zwischenzeitliche Annahme: der Taster mutet rein in der Firmware und ist
für das OS unsichtbar. **Das war falsch.**

## Der tatsächliche Weg: USB-Audio-Control

Ein Monitor über drei Ebenen bei drei Tasterdrücken zeigte einen exakten
Zusammenhang:

| Druck | ALSA `Mic` Capture Switch | PipeWire `Mute` | Mute der Standardquelle |
|---|---|---|---|
| 1 | `[off]` | `yes` | `no` |
| 2 | `[on]` | `no` | `no` |
| 3 | `[off]` | `yes` | `no` |
| 4 | `[on]` | `no` | `no` |

Der Taster schreibt also in den ALSA-Capture-Switch
(`HW_MUTE_CTRL`), und PipeWire spiegelt das als `Mute: yes/no`.

Ausschlaggebend: der **Mute der Standardquelle blieb konstant**. Der
Taster sendet keine `KEY_MUTE`-Events an die Sitzung, sondern ändert
ausschließlich den Audio-Control seines eigenen Geräts. Es gibt daher
keine Nebenwirkungen auf andere Anwendungen.

## Konsequenz für die Bridge

Signalquelle ist `pactl get-source-mute <SoloCast-Quelle>`, nicht evdev.
Vorteile:

- kein root nötig
- kein Device-Grab, kollidiert nicht mit Handy
- funktioniert auch bei `SUSPENDED`-Node
- überlebt Replug, solange die Quelle neu erkannt wird

## Gegenrichtung: Handys Aufnahmezustand

Handy bietet kein DBus-Interface für seinen Zustand
(`com.pais.handy.SingleInstance` kennt nur `ExecuteCallback`). Der
Aufnahmezustand ist aber an einem PipeWire-Stream ablesbar:

```
Source Output #17317
  Source: 937
  application.name = "cpal-pulseaudio-472897"
  node.name        = "cpal-pulseaudio-472897"
```

`cpal-pulseaudio-<pid>` ist Handys Capture-Stream (Rust-`cpal` über die
PulseAudio-Kompatibilitätsschicht). Er existiert nur während der Aufnahme.

## Fallstricke, die erst im Betrieb auftraten

1. **Reihenfolge.** „Bei jeder Änderung `ctrl+space` senden" startet beim
   ersten Drücken eine Aufnahme bei stummem Mikrofon. Nötig ist ein
   Soll/Ist-Vergleich.

2. **Stream-Flap.** Ein kurz aufblitzender `cpal-pulseaudio`-Stream
   (Geräte-Probe/Feedback) wurde als „Aufnahme beendet" gedeutet und
   schaltete das Mikrofon mitten im Diktat stumm. Behoben durch
   3-Zustands-Abfrage (aufnehmen / nicht aufnehmen / **nicht ermittelbar**)
   und ein 300-ms-Stabilitätsfenster.

3. **Rückkopplung.** Eigene Aktionen lösten die Gegenrichtung aus. Ein
   pauschales Sperrfenster verschluckte aber auch echte Tastendrücke.
   Lösung: Erwartungsmarken — nach einer eigenen Aktion wird genau die
   erwartete Änderung einmal ignoriert.

4. **Leere Abfrage ≠ keine Aufnahme.** Ein fehlgeschlagenes `pactl` liefert
   leeren Output. Das darf nicht als „nimmt nicht auf" gelten, sonst
   schaltet die Bridge das Mikrofon fälschlich stumm.

## Relevante Befehle zum Nachvollziehen

```bash
# Hardware-Mute direkt am ALSA-Control
amixer -c 3 sget Mic

# PipeWire-Sicht
pactl get-source-mute <quelle>
pactl list source-outputs | grep -A5 cpal

# Wer greift welches Eingabegerät?
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  for fd in /proc/$pid/fd/*; do
    case "$(readlink "$fd" 2>/dev/null)" in
      /dev/input/event2[6-8]) echo "$pid $(cat /proc/$pid/comm)";;
    esac
  done
done 2>/dev/null | sort -u

# Greift jemand exklusiv? (EVIOCGRAB -> EBUSY)
python3 -c "
import fcntl,os
fd=os.open('/dev/input/event26', os.O_RDONLY|os.O_NONBLOCK)
try:
    fcntl.ioctl(fd, 0x40044590, 1); print('frei')
except OSError as e: print('belegt', e)
"
```
