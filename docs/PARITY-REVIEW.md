# TR7 for Windows comparison

Updated 12 October 2026 against `docs/app-tr7win-430-eng.exe`, TR7 for Windows 4.30, and the supplied TR71A/TR72A 1.20 firmware. The Swift app now covers many of the TR72A workflows. Full replacement parity remains incomplete.

## Evidence

- Installer SHA-256: `3c5c28282c7d85871efac3378009eae5ffd5e1db39e2eca7c4d3fa77e05a511b`.
- Firmware installer SHA-256: `563afbe0b188797e946c139495afa49622b98b9534bc7c8aedac921f0365bba2`; extracted `TR71A_Firm.bin`: `6fe6d0a5c93f4b426a63bf7153771f1521ba0b090018ba01a400cd7932c74a59`.
- Extracted the installer CAB/HDR payloads and inspected `Tr7WF.exe`, `Tr7WF(ENG).dll`, `TdTR7wfCom.dll`, and `TdTR7BleCom.dll` as data. Windows executables were not launched.
- This continuation covered warnings, download ranges, connection testing, certificates, adjustment, and Bluetooth registration. Static DLL and executable evidence is recorded in [PROTOCOL.md](PROTOCOL.md).
- Existing implementation includes workflows added after the initial narrow upload-settings review. Source coverage below does not imply completed hardware acceptance or equal automated coverage.

## Completed in this continuation

The Warnings page previously edited numeric limits and arbitrary delays while preserving hidden enable flags. It now independently enables upper, lower, and sensor warnings for each channel, plus battery warnings. Judgment times use the same nine choices as Windows. Existing nonstandard times remain available; unchanged disabled thresholds, including sentinel values, remain byte-for-byte intact.

Saving requires confirmation of the selected switches, thresholds, and delays, rejects a changed device snapshot, preserves unrelated control bits, validates before communication, and verifies the complete written block. The UI explains that only enabled items are monitored and that an active ALM warning can clear when settings change. Settings exports include decoded warning settings. This does not configure server-side email recipients.

Recorded-data downloads now accept a recent hours/days period derived from the logger's current interval. The viewer filters by date and exports the selected readings while preserving complete native archives. Upload controls add both T&D service presets, a complete OFF action, and the firmware-confirmed `79/7C` connection-test flow. The Network page implements firmware commands `78/7B/7A` to scan, validate, display, and select nearby SSIDs.

The Adjustment page implements one- and two-point corrections, composition with existing coefficients, initialization, four-entry device history, and Windows adjustment-file import/export. Writes require stopped recording, fresh snapshots, and coefficient/history readback. USB certificate management parses DER or PEM X.509 certificates, previews validity and SHA-256, transfers vendor-format chunks and metadata, and verifies metadata readback. Bluetooth registrations persist only an explicitly selected UUID and display name.

## Feature coverage

| Official capability | TR7Mac coverage |
| --- | --- |
| USB / Bluetooth connection | Partial: TR7A CDC USB and newer BLE SCMD transport |
| Destination host, path, port, HTTP/HTTPS | Implemented; unknown existing modes remain visible |
| Destination service presets, root certificates | T&D presets; custom root certificate read/install/delete over USB |
| Regular upload interval | Implemented; interval choices match Windows |
| Upload OFF | Complete OFF action disables regular and scheduled flags while preserving stored times |
| Upload connection test | Implemented for saved network/destination settings |
| Operation logs | Read, display, and CSV export implemented |
| Device clock | Literal calendar setting plus separate timezone, DST, and SNTP controls; hardware timestamp interpretation unverified |
| Wi-Fi, DHCP/static IP, DNS, proxy | Three profiles plus physical access-point scan implemented; security mode preserved, not selectable; enterprise authentication missing |
| Recording interval, mode, start/stop, scheduled start | Implemented for TR72A normal recording; starting warns that recorded data is erased |
| Stored readings, download ranges | All, fixed counts, recent hours/days, and date-filtered viewing/export |
| Graph/report workflow | Native graph, sample range, channel visibility, cursor, paged table, CSV, JSON archive, HTML report |
| Vendor recording/report files and graph integration | Missing; native JSON archives are not vendor files |
| Download warning-duration summary | Missing |
| Monitor current readings | Refresh and five-second monitoring implemented |
| Warning limits, upper/lower enable, sensor and battery warnings | Implemented with Windows judgment-time choices and exact write verification |
| Clear ALM | Implemented |
| Max/min settings and reset | Manual reset and daily reset timers implemented |
| Device/group/channel names | Read and edit implemented |
| Temperature units | Device display command implemented; downloaded measurements exported in Celsius |
| Calibration | One-/two-point adjustment, initialization, device history, and Windows adjustment file import/export |
| Bluetooth passcode and enable/disable | Session authentication, passcode/availability controls, and explicit UUID/name registration |
| Factory reset | Implemented with confirmation |
| Export operation log and settings | CSV logs and JSON settings; settings import/cloning and Windows text output missing |
| Multiple connected devices / batch operations | Single selected logger only |
| Other logger models and TR7A2 power-saving / vaccine controls | Outside the current TR72A implementation |

The initial review's statement that recording, downloads, Wi-Fi, warning settings, naming, unit changes, Bluetooth settings, and logs were absent no longer reflects the source. Legacy transports and the remaining file/model-specific workflows are substantive gaps.

## Remaining differences and limits

### Transport and discovery

Bluetooth requires the newer write/notify characteristic ending in `0008`. The older `0002`/`0003` interface uses a separate handshake and is explicitly rejected. Discovery accepts names starting with TR7 or an advertised supported service UUID; renamed loggers advertising neither may be missed. Automatic USB discovery covers VID `0x0CCF`, PID `0x0800`, not all Windows-supported families.

### Network and upload

HTTPS and custom root certificate installation are implemented. Certificate DER cannot be read back, so verification covers metadata followed by a connection test rather than byte-for-byte certificate retrieval. Scheduled-upload times are preserved but still have no editor.

### Recordings and adjustment

Downloaded samples use recovered metadata and measurement conversion. Native archives, CSV, and HTML reports support offline use; they do not replace vendor `.trz` interoperability, automatic report processing, or warning-duration summaries. Adjustment file interoperability is statically reconstructed but has not been round-tripped through Windows. Model-specific modes remain outside scope.

## Acceptance status

| Area | Evidence |
| --- | --- |
| Static and simulated | Swift build, core checks, and nine PTY serial scenarios pass |
| Physical USB reads | Firmware 1.20 settings/live values, names, logs, recordings, adjustment history, certificate state, and Wi-Fi scan pass |
| Physical USB writes | Same-value destination, interval, timezone/SNTP, names, all three Wi-Fi profiles, warnings, reset timers, and clock writes pass readback; temporary certificate install/read/delete passes |
| Physical network | Saved profile/destination connection test completes with `Operation succeeded` |
| Physical Bluetooth | Not yet exercised |
| Destructive/device-behavior acceptance | Recording start/stop, factory reset, clear actions, calibration writes while recording, warning notification behavior, and certificate-backed HTTPS delivery remain untested |
| Visual/deployed | App builds and packages; interactive GUI acceptance remains untested |

For warning acceptance, compare a real TR72A's loaded switches, limits, and judgment times with Windows. Save one confirmed warning change, read it back with both applications, and verify sensor, threshold, battery, and ALM behavior. Confirm unrelated control bits and existing inactive limits remain intact.

For existing workflows, compare the same logger's BLE characteristics and advertised identity with Windows. Confirm warning behavior, certificate-backed HTTPS delivery, and calendar/timezone semantics. Full parity also requires the missing workflows above and validation across their intended supported models.
