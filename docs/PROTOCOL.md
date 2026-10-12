# Recovered TR7A configuration protocol

## Evidence and limits

Sources: `docs/app-tr7win-430-eng.exe`, TR7 for Windows 4.30, and `docs/app-tr71a-72a-firm-120-all.exe`.

SHA-256: `3c5c28282c7d85871efac3378009eae5ffd5e1db39e2eca7c4d3fa77e05a511b`.

Firmware installer SHA-256: `563afbe0b188797e946c139495afa49622b98b9534bc7c8aedac921f0365bba2`. Its extracted 170,632-byte `TR71A_Firm.bin` SHA-256 is `6fe6d0a5c93f4b426a63bf7153771f1521ba0b090018ba01a400cd7932c74a59`; `UpDateMng.txt` identifies version 1.20. The raw STM32L4 image was mapped at `0x08006000` and inspected as Thumb code. Its shared SCMD dispatcher confirms that wired USB and the newer BLE path use the same command handlers.

The installer was unpacked as data; no Windows executable was launched. Its Unicode InstallShield overlay contains CAB/HDR files. Inspection used unshield, pefile, and Capstone in a temporary research directory. The implementation is original Swift; vendor binaries are not redistributed. Addresses below are virtual addresses in the extracted DLLs (image base `0x10000000`). These are static-analysis findings, not hardware captures.

Vendor references:

- [TR7 for Windows](https://tandd.com/software/tr7win.html)
- [TR7 for Windows help](https://cdn.tandd.co.jp/glb/html_help/tr7win-help-eng/)
- [TR7A manual](https://tandd.com/manual/pdf/man-users-tr7a-eng.pdf)

## SCMD framing

```
01 command parameter length-low length-high payload CRC-high CRC-low
```

CRC-16/XMODEM: polynomial `0x1021`, initial value `0`, no final XOR. It covers header plus payload. Independent golden vectors: ASCII `123456789` → `31C3`; USB page-one read → `01 6D 01 00 00 FD 35`.

Responses echo the command and use parameter `06` for success. Errors, checksum failures, unexpected commands, truncated replies, and lengths exceeding 4096 are rejected. The app never retries a settings write automatically.

USB serial: 38400 baud, 8 data bits, no parity, 1 stop bit, no flow control. The vendor calls Td500OpenComm with baud `0x9600`. macOS uses its CDC serial device, with an exclusive-open lock and original terminal settings restored at close.

## Bluetooth

Firmware 1.20 was observed advertising configured device names and manufacturer data beginning with the little-endian T&D Bluetooth SIG company identifier `92 03`. The next four bytes encode the logger serial in little-endian order. One advertisement included Device Information service `180A`, but not the command service `6E400001…`; filtering scans by the command service or a `TR7` name misses such loggers. Across a continuous scan, four distinct loggers were observed. One initially arrived without a name and supplied it in a subsequent advertisement, so discovery accepts repeated reports and updates the displayed name. A later read-only GATT probe connected to one logger; a physical GATT command session remains unverified.

`TdTR7BleCom.dll` stores the service and characteristic UUIDs at `0x1003D168` through `0x1003D398`:

- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA42`.
- Newer command characteristic: `6E400008-B5A3-F393-E0A9-E50E24DCCA42`, used for writes and notifications (`BleDevice2::doOpen`, `0x1001C830`).
- Older interface: characteristics `0002` through `0007`, with additional transport framing/control; unsupported by this implementation.

The newer send routine at `0x1001C960` splits raw SCMD packets into 20-byte GATT writes. A live connection to a firmware 1.20 logger exposed characteristic `0008` with properties `0x14`: notify and write without response. The app now selects the GATT write type advertised by the characteristic and uses CoreBluetooth's flow control when writing without response. Incoming notifications are concatenated and the SCMD length/checksum is validated. CoreBluetooth delegates run on a dedicated queue; the serializing SensorClient actor waits off the main thread. Notification setup precedes authentication. The vendor break routine at `0x1001D610` writes a single zero byte to this characteristic; the app waits 50 ms before unlocking when no GATT acknowledgement is available. A settings-command response over Bluetooth has not yet been captured.

The base serializer at `0x100086F0` emits four zero bytes for requests whose USB equivalent has an empty payload. EEPROM-read parameter is the page index (`0x1000EBB0`). The page-response parser at `0x1000EAE0` requires exactly 256 payload bytes.

Authentication is command `76`, parameter `00`, payload a four-byte little-endian numeric passcode. `TdTR7BleCom_Open` at `0x10005AE0` constructs it via serializer `0x10009480`. Six ASCII decimal digits are accepted; blank means numeric zero for an unlocked logger. No guessing or passcode-reset command is implemented.

## EEPROM and destination

Read page zero: `6D / 00`; read page one: `6D / 01`. Both replies contain 256 bytes. USB read payload is empty; BLE read payload is four zeros.

Page one begins with a 128-byte upload-destination block:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 124 | UTF-8 address or hostname/path, zero padded |
| 124 | 2 | Destination mode, little endian; preserved |
| 126 | 2 | TCP port, little endian |

The Windows GUI setter call order is address, port, mode. The implemented protocol picker uses the recovered secure/plain mapping: 0 for HTTPS, 7 for HTTP. Existing unknown modes remain visible; callers omitting a new mode preserve the existing field. Neither protocol has physical-device acceptance here.

Write `6C / 1B`, payload `[00 01]` followed by the 128-byte destination block. The USB builder is at `TdTR7wfCom.dll:0x100172F0`; the BLE builder at `TdTR7BleCom.dll:0x10020E10` allocates 130 bytes and places the fields at offsets 2, 126, and 128 within that payload.

Enter configuration using `50 / 1B`; exit with `50 / 00`. The BLE parameter selector `0x10020FA0` returns `1B` when the configuration state is 1, otherwise 0. Empty USB configuration payloads become four zero bytes on BLE.

Before writing, fresh settings are compared with the loaded block. Unrelated bytes and certificates are preserved; mode changes only when explicitly selected. The written block is read back and must match byte-for-byte. Configuration exit is attempted after any failure.

## Regular upload interval

Page zero contains a 64-byte upload block at offsets 192–255:

| Offset | Size | Field |
| --- | --- | --- |
| 192 | 1 | Regular upload enabled |
| 193 | 1 | Scheduled upload enabled |
| 194 | 2 | Reserved; preserved |
| 196 | 4 | Regular interval in seconds, little endian |
| 200 | 32 | Eight scheduled times; preserved |
| 232 | 24 | Other/reserved data; preserved |

Write `6C / 1B` with `[C0 00]` plus the entire 64-byte block. Only regular enable and interval are changed. Scheduled times and flags remain unchanged.

## Clock and names

Read calendar fields: `6F / 03`. Write: `6F / 00`, six bytes: year minus 2000, month, day, hour, minute, second. The BLE setter serializer at `0x10028850` produces six bytes; its year arithmetic truncates the supplied full year to the same year-minus-2000 byte.

Timezone interpretation of these calendar fields has not been established by an actual upload capture. The GUI sends the explicitly selected UTC or local calendar fields; the separate Time Settings action configures timezone/DST/SNTP. Current code reads timezone at page-zero offset 128 (signed 16-bit minutes), DST enabled at 130, and DST minutes at 132. SNTP settings occupy page-one offsets 128–191. These offsets supersede the earlier 124/126/128 notes; physical-device acceptance is still required.

Optional name read: `56 / 00`; expected layout is device name 26 bytes, group 16 bytes, and two channel names 16 bytes each. Name-read failure does not hide essential settings.

## Warning settings

Read `36 / 00`; write `36 / 01`, with an 18-byte payload. This write does not enter EEPROM configuration mode.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | Control flags; bit 3 enables battery warnings; other bits preserved |
| 1 | 1 | Bit 0 upper CH1, bit 1 lower CH1, bit 2 sensor CH1, bit 3 lower CH2, bit 4 upper CH2, bit 5 sensor CH2; bits 6–7 preserved |
| 2 | 4 | CH1 judgment time in seconds, little endian |
| 6 | 2 | CH1 lower limit, little endian |
| 8 | 2 | CH1 upper limit, little endian |
| 10 | 4 | CH2 judgment time in seconds, little endian |
| 14 | 2 | CH2 lower limit, little endian |
| 16 | 2 | CH2 upper limit, little endian |

Threshold encoding is `round(value * 10 + 1000)`. Unchanged disabled thresholds, including sentinel values, are retained exactly. New judgment times use Windows' nine choices: 30, 60, 120, 300, 600, 900, 1200, 1800, 3600 seconds; existing other times remain selectable and are preserved.

Re-inspected the repository installer on 12 October 2026. USB `TdTR7wfCom_SetLimit_7A` at `0x10007A70` constructs the command and threshold layout; `GetLimit_7A` at `0x10008080` extracts the control byte, mask, delays, and limits. Windows' DDX bindings around `Tr7WF.exe:0x004A95B2` map the upper/lower controls to members 0x118/0x11C (CH1) and 0x120/0x124 (CH2). The mask construction at `0x004AD9E5` establishes the channel bit order. Battery ON is radio control 0x562, bound to member 0x23C; `0x004AD9C1` translates ON to setter argument 0x2C, encoded into control bit 3 by the USB builder. Labels are corroborated by dialog 98 in `Tr7WF(ENG).dll` and the [vendor warning help](https://cdn.tandd.co.jp/glb/html_help/tr7win-help-eng/html/020_how_to_use/020_settings/030_warning_monitoring.html). The extracted Windows files were inspected as data and were not run.

Saving rejects stale full warning blocks, validates before opening the transport, sends one write, and requires an exact readback. Bluetooth uses the same nonempty payload through the newer SCMD transport. Checks use independent literal byte fixtures, not sensor captures; physical warning writes and notification behavior remain unverified.

## Connection test

Start the saved network/destination test with `79 / 00` and payload `[profile, 00, 00, 00]`, where profile is 1–3. Firmware 1.20 dispatches this to job `0x10` and returns the normal SCMD success status with no payload. Poll `7C / 00` with `[cursor-low, 00, 00, 00]`. Status `13` means job `0x10` is active or its retained result has not yet been consumed; the app resumes that result stream and waits through active polls without starting a duplicate job. The eight-byte result contains a little-endian index, Unix timestamp, category, and operation-log code. The app advances the cursor, reports each event, stops at the final result, and never retries an accepted start command.

## Wi-Fi access-point scan

Start scanning with `78 / 00` and four zero payload bytes. Poll `7B / 00` with four zero bytes; each reply contributes at most 1,024 bytes. Stop with `7A / 00` and four zero bytes on success, cancellation, or failure. TR7 for Windows accumulates chunks until `No.Of AP Found:`. Firmware 1.20 returns a text table whose comma-separated rows contain BSSID, SSID, channel, network type, RSSI, and security. The parser validates BSSID/channel/RSSI fields and requires the number of valid rows to match the footer. SSIDs containing commas and hidden SSIDs are retained. The three commands are enabled on USB and the newer shared-SCMD BLE transport.

## Sensor adjustment and history

Read adjustment with `53 / 00`; write `52 / 00` with twelve bytes: Unix timestamp, then slope UInt16 and signed offset Int16 for each channel. Coefficients use units of 1/1000. Read/write the 80-byte history with `60 / 00` and `61 / 00`; it contains four 15-byte entries, two IEEE-754 scaled slopes, and four reserved bytes. Writes require recording to be stopped, compare a fresh adjustment snapshot, preserve unselected channels/reserved history, and verify both commands.

The recovered Windows adjustment file starts with `TR7WF-Adjustment\n`, followed by two 40-byte channel blocks containing enable/method words and four eight-byte ASCII numeric fields. Runtime round-trip with Windows remains unverified.

## Custom HTTPS root certificate

USB selector 7 reads a 64-byte metadata table with `CB / 00 [07 00]` and bounded identity text with `CE / 00 [07 00]`. Firmware 1.20 returns only the populated identity bytes, including a short `CA certificate not found` response when empty; it does not pad installed identities to 128 bytes. Certificate DER is sent in `CA` chunks of at most 1,024 bytes, prefixed by selector, chunk index, and total DER length. `CC` writes `[07 00]` plus the 64-byte filename/validity table; `CD [07 00]` deletes it. BLE uses a different typed selector, so certificate management is restricted to USB. Metadata is read back, but the DER itself cannot be retrieved by these commands.

## Acceptance still needed

USB reads, same-value settings writes, access-point scanning, a successful connection test, and certificate install/read/delete were exercised on a TR72A running this firmware. Physical BLE remains unverified. Check clock fields against a captured upload timestamp before choosing a persistent time convention. Older BLE transport support requires a separate implementation based on its control handshake. Destructive recording/reset actions, adjustment writes while recording, and on-device warning behavior remain outside this acceptance run.
