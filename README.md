# Simmer

Menüleisten-App für macOS 14+, die das Laden des Akkus begrenzt und steuert: Ladelimit mit
Sailing Mode, Entladen trotz Netzteil, Top Up, Hitzeschutz, Kalibrierung, Zeitpläne,
Kurzbefehle und Live-Telemetrie. Apple Silicon und Intel.

## Bauen

```bash
./build.sh          # Release-Build, ad-hoc signiert → build/Simmer.app
./build.sh test     # Unit-Tests (SimmerCore)
./build.sh probe    # nur lesend: SMC-Keys und Telemetrie dieses Macs prüfen
./build.sh run      # bauen und starten
```

Alternativ `Simmer.xcodeproj` in Xcode öffnen (Scheme „Simmer“). Für eine eigene Signatur:
`SIGN_IDENTITY="Developer ID Application: …" ./build.sh`.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `SimmerCore/` | Swift Package mit der gesamten Logik: SMC-Wrapper, Hardware-Schicht, Telemetrie, State-Machine, Zeitpläne, Einstellungen, Helper-Logik, XPC-Client, App-Modell. Dazu `simmerctl` (Diagnose-CLI) und die Tests. |
| `Helper/` | Privilegierter Daemon `com.simmer.helper` (root, XPC). |
| `App/` | SwiftUI-Oberfläche (Menüleisten-Popover, Einstellungen) und App Intents. |
| `Support/` | LaunchDaemon-Plist für `SMAppService`. |

Die App läuft ohne Root. Sie liest Telemetrie selbst (kein Root nötig), berechnet pro Tick
den gewünschten Hardware-Zustand (`ChargeCommand`) und schickt ihn per XPC an den Helper.
Der Helper kennt nur diese semantischen, begrenzten Befehle – beliebige SMC-Keys lassen sich
über XPC nicht schreiben.

## Helper installieren

In der App unter **Einstellungen → Helper**:

- **Install (Login Items)** – `SMAppService`; einmalige Freigabe in den Systemeinstellungen.
  Setzt eine vollwertige Signatur voraus; bei ad-hoc signierten Builds kann macOS den Start
  des Daemons verweigern.
- **Install with administrator password** – zuverlässiger Weg für lokale Builds: kopiert den
  Helper nach `/Library/PrivilegedHelperTools` und lädt einen LaunchDaemon (eine
  Passwortabfrage). Deinstallation über denselben Tab.

Ohne Helper zeigt Simmer nur Telemetrie. Mit **Dry run** werden alle SMC-Schreibzugriffe
im Prozess simuliert und protokolliert – so lässt sich alles gefahrlos ausprobieren.

## SMC-Keys

Die Zuordnung wird zur Laufzeit über das Vorhandensein der Keys bestimmt, nie über die
macOS-Version (`simmerctl caps` zeigt das Ergebnis).

| Funktion | Key(s) | Werte |
|---|---|---|
| Laden sperren (Firmware-Band, macOS 27) | `bfF0`, `bfD0`, `bfE0` | `bfF0`: 0 = aus, 2 = aktiv; `bfD0`/`bfE0`: obere/untere Grenze in %, Little Endian |
| Laden sperren (Apple Silicon, neuer) | `CHTE` | `00000000` laden, `01000000` sperren |
| Laden sperren (älter, auch Intel) | `CH0B` + `CH0C` | `00` laden, `02` sperren |
| Netzteil trennen (Entladen) | `CHIE` / `CH0J` / `CH0I` | `CHIE`: `08` getrennt; `CH0J`, `CH0I`: `01` getrennt; `00` verbunden |
| Limit ausgeschaltet/im Ruhezustand | `bfF0…` / `BCLM` (Intel, %) / `CHWA` (fest 80 %) | |
| MagSafe-LED | `ACLC` | `00` System, `01` aus, `03` grün, `04` orange, `05`–`07` Blinken |
| Akkutemperatur | `TB0T`, `TB1T`, `TB2T` | `flt ` (Apple Silicon) bzw. `sp78` (Intel) |

**Gesperrte Keys (macOS 27):** Auf aktueller Firmware lehnt der SMC Zugriffe auf
`bfF0/bfD0/bfE0` auch für root ab (`kIOReturnNotPrivileged`, vermutlich Entitlement-Prüfung).
Solche Keys gelten als nicht nutzbar. Bleibt dann nur ein Netzteil-Key (`CHIE`), hält Simmer
das Limit per **Adapter-Cycling**: Am Limit wird das Netzteil elektrisch getrennt, der Mac
läuft vom Akku bis zur Sailing-Untergrenze und lädt dann wieder bis zum Limit. Das ist kein
echter Bypass – der Akku wird im Sailing-Fenster zyklisiert. In diesem Modus gibt es kein
Limit im Ruhezustand oder ausgeschalteten Zustand (im Ruhezustand wird normal geladen), und
Hitzeschutz sowie Kalibrier-Ruhephase laufen ebenfalls vom Akku.

Quellen für die Werte: die Open-Source-Projekte `battery` (actuallymentor) und `batt`
(charlie0129), abgeglichen mit einer lesenden Probe auf einem MacBook Pro M5 Pro
(macOS 27.2): dort existieren `bfF0/bfD0/bfE0`, `CHIE`, `CH0J`, `ACLC` und `TB0T–TB2T`;
`CHTE`, `CH0B/C`, `CHWA` und `BCLM` fehlen. Die `bf…`-Keys sind dort auch für root gesperrt,
Simmer nutzt auf diesem Gerät also Adapter-Cycling über `CHIE`. Spannung, Strom, Zyklen und Kapazitäten kommen aus `AppleSmartBattery` (IORegistry).

## Sicherheit

- **Fail-Safe:** Der Helper setzt beim Start, bei SIGTERM und beim Wegfall der App-Verbindung
  auf Standardverhalten zurück (Netzteil verbunden, Laden erlaubt, LED System). Ein Watchdog
  löst dasselbe aus, wenn die App 120 s keinen Befehl mehr sendet.
- Ist „Beim Beenden zurücksetzen“ ausgeschaltet, bleibt der Ladezustand bestehen – ein
  erzwungenes Entladen wird trotzdem immer beendet.
- Vor dem Ruhezustand wird das Netzteil immer verbunden; im Limiter-Modus wird (optional) das
  Laden gesperrt bzw. das Limit an die Firmware übergeben.
- SMC-Keys werden beim Neustart des Macs von der Firmware zurückgesetzt (außer den
  ausdrücklich persistenten Limit-Keys).

## Diagnose

```bash
cd SimmerCore
swift run simmerctl probe      # bekannte Keys und ihre Werte
swift run simmerctl caps       # ermittelte Zuordnung
swift run simmerctl battery    # ein Telemetrie-Snapshot
swift run simmerctl simulate   # Steuerbefehle gegen die Dry-Run-SMC
swift run simmerctl keys CH bf # alle Keys mit diesen Präfixen
```
