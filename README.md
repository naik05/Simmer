# Simmer

Menu bar app for macOS 14+ that limits and controls battery charging: charge limit with Sailing Mode, discharging while plugged in, Top Up, heat protection, calibration, schedules, Shortcuts, and live telemetry. Supports Apple Silicon and Intel.

## Building

```bash
./build.sh          # Release build, ad-hoc signed → build/Simmer.app
./build.sh test     # Unit tests (SimmerCore)
./build.sh probe    # read-only: check SMC keys and telemetry of this Mac
./build.sh run      # build and run
```

Alternatively, open `Simmer.xcodeproj` in Xcode (Scheme “Simmer”). For custom code signing:
`SIGN_IDENTITY="Developer ID Application: …" ./build.sh`.

## Architecture

| Path | Contents |
|---|---|
| `SimmerCore/` | Swift Package containing the entire core logic: SMC wrapper, hardware layer, telemetry, state machine, schedules, settings, helper logic, XPC client, and app model. Also includes `simmerctl` (diagnostic CLI) and tests. |
| `Helper/` | Privileged daemon `com.simmer.helper` (root, XPC). |
| `App/` | SwiftUI interface (menu bar popover, settings) and App Intents. |
| `Support/` | LaunchDaemon plist for `SMAppService`. |

The app runs without root privileges. It reads telemetry directly (no root required), calculates the desired hardware state (`ChargeCommand`) on each tick, and sends it to the helper via XPC. The helper only understands these semantic, restricted commands—arbitrary SMC keys cannot be written over XPC.

## Installing the Helper

In the app under **Settings → Helper**:

- **Install (Login Items)** – `SMAppService`; requires one-time approval in System Settings.
  Requires a full code signature; macOS may refuse to launch the daemon for ad-hoc signed builds.
- **Install with administrator password** – reliable option for local builds: copies the
  helper to `/Library/PrivilegedHelperTools` and loads a LaunchDaemon (single password prompt). Can be uninstalled from the same tab.

Without the helper, Simmer only displays telemetry. With **Dry run** enabled, all SMC writes are simulated and logged in-process—allowing you to safely test everything.

## SMC Keys

Key mapping is determined at runtime based on key availability, never via the macOS version (`simmerctl caps` displays the result).

| Function | Key(s) | Values |
|---|---|---|
| Inhibit charging (firmware band, macOS 27) | `bfF0`, `bfD0`, `bfE0` | `bfF0`: 0 = off, 2 = active; `bfD0`/`bfE0`: upper/lower limit in %, little-endian |
| Inhibit charging (Apple Silicon, newer) | `CHTE` | `00000000` charge, `01000000` inhibit |
| Inhibit charging (older, including Intel) | `CH0B` + `CH0C` | `00` charge, `02` inhibit |
| Disconnect power adapter (discharge) | `CHIE` / `CH0J` / `CH0I` | `CHIE`: `08` disconnected; `CH0J`, `CH0I`: `01` disconnected; `00` connected |
| Limit while shut down / asleep | `bfF0…` / `BCLM` (Intel, %) / `CHWA` (fixed 80%) | |
| MagSafe LED | `ACLC` | `00` system, `01` off, `03` green, `04` orange, `05`–`07` blinking |
| Battery temperature | `TB0T`, `TB1T`, `TB2T` | `flt ` (Apple Silicon) or `sp78` (Intel) |

**Restricted Keys (macOS 27):** On current firmware, the SMC rejects access to `bfF0/bfD0/bfE0` even for root (`kIOReturnNotPrivileged`, presumably due to an entitlement check). Such keys are treated as unusable.

**macOS charge limit (macOS 27):** When no SMC charging key is usable, the helper steers macOS's own charge limit instead. It writes `MCLFeatureState` and `mclLimitValue` (1–99) to root's `com.apple.smartcharging.topoffprotection` preferences and posts `com.apple.smartcharging.defaultschanged`, which `PowerUIAgent` picks up (the mechanism used by `batt`; `pmset -g battlimit` shows the registered limit). At the limit the Mac runs from the adapter and the battery idles, and macOS keeps enforcing it during sleep. Because macOS holds the battery right at the limit itself, the sailing buffer is not used in this mode. To stop charging immediately (heat protection, calibration rest) Simmer sets the limit to the current level. macOS drains the battery down to a lower limit, so Simmer never sets one below the current level on its own: after a top-up the battery is held where it is until you unplug or use Discharge. A new target can take a few minutes to register while charging. Whatever charge limit you had set in System Settings is saved before the first change and restored when Simmer resets. This path is only enabled on macOS 27, the one release whose preference schema was checked.

**Adapter Cycling:** Last resort when neither an SMC charging key nor the macOS charge limit is available but a power adapter key (`CHIE`) is: upon reaching the limit, the power adapter is electrically disconnected, the Mac runs on battery power down to the Sailing lower bound, and then charges back up to the limit. This is not a true hardware bypass—the battery cycles within the Sailing window. In this mode, there is no charge limit while asleep or shut down (the battery charges normally during sleep), and heat protection as well as calibration rest phases also run on battery power.

Sources for these values: the open-source projects `battery` (actuallymentor) and `batt` (charlie0129), cross-referenced with a read-only probe on a MacBook Pro M5 Pro (macOS 27.2): on that machine, `bfF0/bfD0/bfE0`, `CHIE`, `CH0J`, `ACLC`, and `TB0T–TB2T` are present, while `CHTE`, `CH0B/C`, `CHWA`, and `BCLM` are absent. Because the `bf…` keys are locked even for root on that device, Simmer uses the macOS charge limit there, with `CHIE` for discharging. Voltage, current, cycle count, and capacities are read from `AppleSmartBattery` (IORegistry).

## History

Settings → History charts charge level (with the limit in effect), battery power and temperature for the last 6 hours, 24 hours or 7 days. Simmer records one sample per minute while it runs and keeps a week of them in `~/Library/Application Support/Simmer/history.json`; nothing leaves the Mac. Hours the Mac was asleep or off show as gaps.

## Battery Health

Settings → Health shows the current health (full charge capacity relative to design capacity) and cycle count, and tracks both over time with one record per day in `~/Library/Application Support/Simmer/health.json`. Once there is enough data it also shows the change since tracking began, cycles per week and wear per 100 cycles. The capacity estimate moves by about a percent from day to day, so the trend only means something over weeks.

## Safety

- **Fail-Safe:** Upon startup, receiving `SIGTERM`, or losing connection to the app, the helper resets to default behavior (power adapter connected, charging enabled, system-controlled LED). A watchdog triggers the same reset if the app stops sending commands for 120 seconds.
- If “Reset on quit” is disabled, the current charge state is preserved—though forced discharging is always stopped.
- Before entering sleep, the power adapter is always reconnected; in limiter mode, charging is (optionally) inhibited or the limit is handed off to the firmware.
- SMC keys are reset by the firmware when the Mac restarts (except for explicitly persistent limit keys).

## Diagnostics

```bash
cd SimmerCore
swift run simmerctl probe      # known keys and their values
swift run simmerctl caps       # detected key mapping
swift run simmerctl battery    # a single telemetry snapshot
swift run simmerctl simulate   # test control commands against the dry-run SMC
swift run simmerctl keys CH bf # all keys matching these prefixes
```
