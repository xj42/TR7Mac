# TR7Mac

A native SwiftUI macOS app for T&D TR72A data loggers. It supports upload, network, clock, recording, measurement, warning, naming, and recorded-data workflows. Protocol behavior was researched using separately obtained T&D software and firmware. This repository contains the Swift implementation and research notes; it does not contain T&D installers, firmware, executables, or DLLs. The app uses macOS CoreBluetooth and USB serial APIs, with no Windows runtime or third-party dependencies. Full feature parity and physical-device validation remain incomplete.

## Start

Open `dist/TR7Mac.app`. Choose **Bluetooth** and click **Scan Bluetooth**. Nearby loggers appear as they advertise; scanning continues until **Stop Scan** is pressed or a logger is opened. Select one and click **Read Settings**. Allow Bluetooth access when macOS asks. Leave the passcode blank if Bluetooth Lock is disabled; otherwise enter the logger's existing six-digit passcode. The passcode stays in memory for the current session.

Settings must be read before they can be changed. Save actions require confirmation; settings writes verify readback where supported. The Upload page includes T&D cloud presets, complete upload OFF, and the logger's network/destination connection test. The Network page can scan nearby access points using the logger and copy a discovered SSID into the selected profile. The test uses settings already saved on the logger and can upload recorded data.

The **Warnings** page independently enables upper, lower, and sensor warnings for each channel, plus battery warnings. Judgment-time choices match Windows: 30 seconds, or 1, 2, 5, 10, 15, 20, 30, and 60 minutes. Existing nonstandard times and untouched disabled limits are preserved. Saving checks for changes made since the settings were read, preserves unrelated control bits, and verifies the full warning block. The confirmation lists the proposed warning settings; changing settings can clear an active ALM warning. Settings JSON exports include warning values and enable switches.

Bluetooth discovery finds devices with a TR7 name, the supported service UUID, or T&D manufacturer data (`0x0392`). It shows an advertised serial when available, including for customized device names. **Register** remembers an explicitly selected peripheral identifier and display name for later connections; registration codes, Bluetooth passcodes, serials, and signal strength are not persisted. The registration code used by T&D's mobile app is separate from the optional six-digit Bluetooth Lock passcode. Bluetooth control supports the vendor's `6E400008…` notify interface with either GATT write mode advertised by the logger. The older `6E400002…`/`6E400003…` handshake remains unsupported.

For USB, choose **USB**, connect a data cable, and click **Refresh Devices**. Supported automatic discovery is T&D VID `0x0CCF`, PID `0x0800`, the TR7A CDC serial interface. Legacy vendor-driver USB interfaces are not implemented.

## Build and verify

macOS 12 or newer and Swift 5.9 or newer are required. Builds target the Mac's current architecture.

```sh
./scripts/build-app.sh
open dist/TR7Mac.app
swift build
swift run TR7Checks
python3 tests/serial_integration.py .build/debug/tr7
```

The serial integration checks use the debug CLI built by `swift build`. `./scripts/build-app.sh debug` creates a debug app instead. The script signs the app locally with a stable designated requirement so Bluetooth permission survives rebuilds; it does not publish or notarize it. If permission was granted to an older build that used a code-hash requirement, reset that old grant once with `tccutil reset BluetoothAlways "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Packaging/Info.plist)"`, then reopen the app and allow Bluetooth. Open `Package.swift` in Xcode to work on the source.

Optional build-path overrides: `TR7_BUILD_PATH`, `TR7_CACHE_PATH`, and `TR7_MODULE_CACHE`.

The app bundle includes a logger-and-graph icon in `Packaging/TR7Mac.icns`. Regenerate the icon and its 1024-pixel PNG preview with `swift scripts/generate-icon.swift`, then rebuild the app. In restricted environments that cannot run SwiftPM's nested manifest sandbox, set `TR7_SWIFTPM_DISABLE_SANDBOX=1`; set `CLANG_MODULE_CACHE_PATH` and `TR7_MODULE_CACHE` to a writable directory when needed.

The USB command-line tool is also packaged as `dist/tr7`:

```sh
dist/tr7 scan
dist/tr7 read /dev/cu.usbmodem123
dist/tr7 destination /dev/cu.usbmodem123 logger.example.com 443
dist/tr7 interval /dev/cu.usbmodem123 600
dist/tr7 verify /dev/cu.usbmodem123 --writes --connection-test
dist/tr7 wifi-scan /dev/cu.usbmodem123
```

CLI write commands apply their explicit arguments directly. The GUI asks for confirmation. Clock commands send literal calendar fields, preserving timezone/DST and automatic synchronization settings. The UTC/Local selector controls which calendar fields the GUI sends; it does not change the logger's timezone configuration.

## Validation and scope

The Swift app, core library, and CLI have been built on macOS. Core checks cover independent CRC vectors, malformed replies, Bluetooth request padding/passcode encoding, settings layout, preserving destination mode and schedules, stale-snapshot rejection, write/readback verification, and configuration cleanup. Warning checks cover recovered byte vectors, all seven enable switches, reserved bits, sentinel preservation, judgment times, invalid limits, exports, stale reads, failed readback, and transport cleanup. Nine independent PTY scenarios exercise the actual serial code with fragmented responses, destination/interval/clock writes, bad checksums, mismatched commands, device rejection, timeouts, and failed readback verification.

Physical USB validation was completed with a TR72A running 1.20 firmware. Settings, measurements, logs, recordings, adjustment history, Wi-Fi scanning, a successful saved-network connection test, same-value configuration writes, and certificate install/read/delete were exercised. The test certificate was removed and the logger remained recording. A continuous physical Bluetooth scan captured four distinct T&D loggers, and the app's discovery class accumulated all four in one live scan as they advertised. A read-only GATT probe connected to a 1.20 logger and found the newer characteristic with notify and write-without-response properties. GUI Bluetooth settings reads and GATT commands remain unverified on hardware. Destructive recording/reset actions, calibration writes while recording, and warning behavior also remain unverified.

The app also includes three Wi-Fi profiles with IP/proxy settings, timezone/SNTP and max/min reset timers, recording start/stop, recent-period and date-filtered downloads, graphs and CSV/JSON/HTML export, live measurements, operation logs, names, units, Bluetooth controls, and factory reset. The Adjustment page supports one- and two-point correction, initialization, history, and the recovered TR7 for Windows adjustment-file format. USB certificate management validates DER/PEM files, displays validity and SHA-256, transfers the certificate, and verifies device metadata. Vendor `.trz` recording files, warning-duration summaries, scheduled-upload editing, enterprise Wi-Fi configuration, legacy transports, and model-specific TR7A2 features remain gaps.

See the [feature comparison](docs/PARITY-REVIEW.md) for current gaps and validation evidence, and [protocol notes](docs/PROTOCOL.md) for wire formats and research findings. Those notes refer to separately obtained vendor materials; the materials themselves are excluded from the repository.
