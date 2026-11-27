# Reverse engineering: ATTACK SHARK X3 SOFT

Findings log with REA Evidence IDs (Hopper provider, `X3.exe`). Each item says whether it was **observed** (in the binary or on the hardware), **inferred**, or is **unknown**. Static analysis only: no feature report was sent while writing this document.

The X3 runs on the same Beken platform as the DELUX M900 Pro (VID `1d57`). This document confirms or corrects the M900 findings (`com.aeonarc.delux-m900/docs/re/findings.md`) for the X3.

Evidence IDs are shortened to their first 8 hex digits (`ev_93eafbb9…`).

## Artifacts

| File | SHA-256 | Source |
|---|---|---|
| `ATTACK SHARK X3 SOFT.exe` (Inno Setup installer) | `1c56d7c5…bc4c07` | vendor download, unpacked with `innoextract` |
| `app/X3.exe` (DuiLib UI, x86, 646,360 bytes) | `db7e366f…52ab41` | extracted |
| `app/hiddriver_1.dll`, `app/hiddriver_2.dll` (identical, 81,408 bytes) | `f9efbf06…ac39f4` | extracted |
| `app/hidapi.dll` | `f4e23fe7…7a92bd` | extracted |
| `app/DuiLib.dll` | `57e26980…54c88f` | extracted |
| `app/res/MS/MS_1/ms_1_page.xml`, `ms_1_lightpage.xml`, `ms_1_menu.xml`, `res/lan.xml` | n/a | UI layout and strings |

**Observed**: `hiddriver_*.dll` is byte-identical (same SHA-256) to the M900's `hiddriver_*.dll`. So the M900 hiddriver findings carry over unchanged: `SetFeature`/`GetFeature` pass the buffer straight to `HidD_SetFeature`/`HidD_GetFeature` (byte 0 = report ID), and the interface is chosen from HIDP_CAPS (UsagePage `0x0A`/Usage 0 for input, UsagePage `0x0B`/Usage 0 for feature, with the VID/PID given to `Set_VIDPID`).

## Transport

`X3.exe` uses three separate paths (`ev_bd21d841…` overview, `ev_5e40826e…` imports, `ev_2c0540ed…` `sub_40e480`):

| Path | Library | Use |
|---|---|---|
| Wired (USB cable) | `hiddriver_2.dll`, loaded with `LoadLibrary`/`GetProcAddress` | input events and `SetFeature` |
| 2.4G receiver | `hiddriver_1.dll`, same way | input events and `SetFeature` with ACK and retries |
| Bluetooth LE | `BluetoothGATT*` APIs; `hidapi` only for detection | GATT notifications and writes |

- **Observed**: `hidapi.dll` is used only for `hid_init`, `hid_enumerate` and `hid_free_enumeration`. There is no `hid_send_feature_report` or `hid_get_feature_report` import (`ev_f5b217e7…`, `ev_3402deed…`). This differs from the M900, which talks to the receiver through hidapi.
- **Observed** (`ev_2c0540ed…`): function pointer slots in the main window object:

  | | Set_VIDPID | Open_DevMonitor | Close_DevMonitor | Open_FeatureDevice | Close_FeatureDevice | SetFeature | GetFeature | handle |
  |---|---|---|---|---|---|---|---|---|
  | driver 2 (wired) | +0x48 | +0x30 | +0x34 | +0x38 | +0x3c | +0x40 | +0x44 | +0x54 |
  | driver 1 (2.4G) | +0x28 | +0x10 | +0x14 | +0x18 | +0x1c | +0x20 | +0x24 | +0x50 |

- **Observed**: `Open_DevMonitor(hwnd, dataMsg, devChangeMsg)` makes the DLL post window messages. Wired uses `0x52f` (data) and `0x530` (arrive/remove); 2.4G uses `0x52d` and `0x52e` (`ev_2c0540ed…`). The window procedure `sub_4086c0` sends `0x52d`/`0x52e` to `sub_412fe0` and `0x52f`/`0x530` to `sub_413110` (`ev_b9951165…`).

## VID/PID and identification

| Path | VID:PID | Evidence |
|---|---|---|
| Wired | `1d57:fa61` | constructor `sub_407e60` stores it at `+0x60/+0x64` and passes it to driver 2 `Set_VIDPID` (`ev_dba0f86a…`, `ev_2c0540ed…`) |
| 2.4G receiver | `1d57:fa60` | stored at `+0x68/+0x6c`, passed to driver 1 `Set_VIDPID` (same) |
| BLE | VID `0x045e`, PID `0x0040` | `hid_enumerate(0x45e, 0x40)` and the strings `VID&02045e`, `PID&0040` (BLE device-ID form) (`ev_dba0f86a…`, `ev_2c0540ed…`) |

- **Observed**: the interface on fa60/fa61 is picked inside hiddriver by HIDP_CAPS, as on the M900 (identical DLL).
- **Observed (hardware, 2026-11-27)**: the model code in byte 1 of input report 3 is `0x10`. On the M900 it is `0x3d`; the M900 app's model table maps `0x10` to index 0.
- **Observed**: `X3.exe` checks the model byte only for events `0x40` (power) and `0x50` (ACK): its codes are `0x4010` and `0x5010`. The other events are matched with model byte `0x00` (codes `0x1000`, `0x2000`, …; `ev_f96006e8…`, `ev_a7d736fa…`). Whether the firmware sends those with model `0x00` or `0x10` is **unknown**. If it sends `0x10`, the app would ignore DPI and polling events from the mouse.

## Input report 3: events

### Packing

- **Observed** (`ev_b9951165…`): for data messages the window procedure computes `code = wParam` and `value = lParam & 0xffff` (it packs `(wParam << 16) ^ (lParam & 0xffff)` and unpacks it in the handlers). The arrive/remove messages become code `0x7f00` with value 1 (arrived) or 2 (removed).
- **Observed** (BLE, `sub_414e10`, `ev_e1887921…`): the GATT callback calls `sub_4132d0(Data[1] << 8 | Data[0], Data[3] << 8 | Data[2])`. The BLE payload has no report ID, so `Data[0]` = model, `Data[1]` = event, `Data[2]` = state, `Data[3]` = level.
- **Inferred**: hiddriver packs report 3 the same way (`wParam = b2 << 8 | b1`, `lParam = b4 << 8 | b3`), so `code = (event << 8) | model` and `value = (b4 << 8) | b3`. This matches the M900 and the live X3 events below.

### Dispatcher `sub_4132d0(code, value)` (`ev_f96006e8…`, `ev_a7d736fa…`), observed

| Code | Meaning | Value | Action |
|---|---|---|---|
| `0x1000` | DPI stage changed on the mouse | b3 = 1..8 | profile `+0x934` = b3 − 1; selects the stage option, posts the DPI OSD (`0x469`, value × 50), saves |
| `0x2000` | polling changed on the mouse | b3 = 1..8 | profile `+0x938` = b3 (raw, not −1); saves |
| `0x4010` | power / heartbeat | b3 = state, b4 = level | see below |
| `0x5010` | ACK of a feature report | b3 = status | `[+0x3f8]` = (b3 == 0); the 2.4G sender waits for this flag |
| `0x6000` | battery level only | 1..10 | `[+0x174]` = value; no UI update |
| `0x7000` | light mode changed on the mouse | 0..7 | profile `+0x94c` = value; saves |
| `0x8000` | unknown | 1..5 | saves only |

M900 comparison: `0x10` (DPI), `0x20` (polling), `0x40` (power) and `0x50` (ACK) have the same roles. `0x60`, `0x70` and `0x80` were not decoded on the M900.

### Power event `0x40` and battery level

**Observed in X3.exe** (`ev_f96006e8…`, `ev_a7d736fa…`):

- Every `0x4010` event re-arms timer `0x64` (6000 ms). When that timer fires, the app marks the mouse offline: `[+0x3ec]` = 0, the wireless icon is hidden and, if neither BLE nor wired is up, `sleep_label` is shown (`ev_b9951165…`). So the event doubles as a heartbeat.
- The first event after a timeout sets `[+0x3ec]` = 1 and shows the wireless icon.
- **State byte (b3)**: only tested against zero. `0` means asleep: `[+0x3e8]` = 1, `sleep_label` ("Device Sleep!") is shown, and applying settings is blocked. Any non-zero value means awake: `[+0x3e8]` = 0, the label is hidden.
- **Level byte (b4)**: accepted only when `1 ≤ b4 ≤ 10`. Then `[+0x174]` = b4, `progress_power.SetValue(b4 × 10)`, and `label_power` shows `Format("%d%%", b4 × 10)`. **So the level is in 10 % steps, not a percentage: `0x04` = 40 %, `0x0a` = 100 %.** Values 0 or above 10 are ignored.

**Observed on hardware (2026-11-27, `python3 -I tools/listen.py /dev/hidraw2`, receiver fa60)**:

- Cable unplugged: `03 10 40 01 04` every 2.0 s (49 reports in a row). That is model `0x10`, event `0x40`, state `01` (awake, on battery), level 4 = **40 %**.
- About 4.3 s after the previous report, around the moment the cable was plugged in, one final `03 10 40 01 0a` (level 10 = **100 %**), then silence on the receiver.
- **Inferred**: the jump from 4 to 10 at plug-in comes from the firmware re-estimating under charge voltage (or reporting "full while charging"), not from a real change in charge. The state byte stayed `01`, so the X3 does not use a separate "charging" state the way the M900 does (`03 3d 40 03 46`: state 3 = charging, level = percent). After that the mouse switches to the cable (fa61) and the receiver goes quiet, which matches the observed silence.
- **Inferred**: 40 % should be read as "between 40 and 49 %" or a rounded estimate; the resolution is 10 %.

### Wired path (fa61) and battery

**Observed** (`sub_413110`, `ev_c4063fc6…`; `sub_40e480`, `ev_2c0540ed…`):

- On arrive (code `0x7f00`, value 1): `Sleep(1000)`, `Open_FeatureDevice` (driver 2), `[+0x3dc]` = 1, `[+0x3e8]` = 0, `sleep_label` hidden, wired icon shown, `label_power` set to `charging_text` ("Charging..."), and timer `0x35` started on `progress_power` at 30 ms (an animation).
- On remove: `Close_FeatureDevice`, `[+0x3e8]` = 1, `sleep_label` shown, wired icon and `label_power` hidden, timer `0x35` killed.
- Other wired codes go to the same dispatcher `sub_4132d0`. So if the wired interface sent `0x4010`, the percentage would update over the cable too. **Unknown**: whether fa61 sends power events at all. The app does not depend on them; on the cable it only shows "Charging..." with an animated bar.
- **Observed**: `GetFeature` is resolved for both drivers but no call through slot `+0x24`/`+0x44` was found in the routines read (`sub_40e480`, `sub_412fe0`, `sub_413110`, `sub_413570`). A full indirect-call search was not done. So the app has no way to poll the battery; it only listens.

## Configuration commands (feature reports)

### General rules

- **Observed**: every command is `[reportID][total length][0x01][data…][checksum]`. The checksum is the 16-bit sum of bytes 3 up to the byte before it, stored **big-endian**. Same as the M900.
- **Observed** (`ev_74b0a580…`, `ev_e41b94f8…`, apply `sub_413ca0`): the apply compares the working profile (`[+0x5dba4]`, 0x80e0 bytes) with the last applied copy (`[+0x5dba8]`) and sends only the groups that changed:

  | Dirty flag | Report |
  |---|---|
  | `0xf1` | 0x04 (DPI and sensor) |
  | `0xfb` | 0x05 (light, sleep, debounce) |
  | `0xf6` | 0x06 (polling) |
  | `0x100` | 0x08 (buttons) |
  | `0x109 + n` | 0x09 (macro of button n, for buttons whose function is `0x11`) |

  When `[+0x50cdc]` = 1 (after a profile reset or profile switch), every group is sent, preceded by report 0x0C.
- **Observed**: the apply runs on a worker thread (`sub_40e030`, message `0x670`), triggered by window message `0x531`, which timer `0x2b` and the UI handlers post (`ev_b9a63859…`, `ev_b9951165…`).

### Sender `sub_413570(buf, len)` (`ev_ae4d8f12…`), observed

| Path | Behaviour |
|---|---|
| Wired | driver 2 `SetFeature(buf, len)`, then `Sleep(500)`. No ACK wait. |
| 2.4G | driver 1 `SetFeature`; up to 10 tries until the ACK flag `[+0x3f8]` is set by event `0x5010` with b3 = 0. Report 0x09 is split into 3 chunks of 0x3c bytes with header `0x4009`. |
| BLE | `sub_4058e0` (GATT write), for every report **except 0x06**. So polling is not set over BLE. |

### Report 0x04: DPI and sensor (`sub_413fe0`, `ev_93eafbb9…`), 56 bytes

| Index | Content | Profile field |
|---|---|---|
| 0–2 | `04 38 01` | |
| 3 | lift-off distance: 0 = 1 mm, 1 = 2 mm | `+0x8b4` |
| 4 | ripple control: 0 off, 1 on | `+0x940` |
| 5 | bitmask of enabled stages (bit n set when the dword at `+0x904 + 4n` is 1) | `+0x904..+0x920` |
| 6 | angle snapping: 0 off, 1 on | `+0x944` |
| 7 | motion sync: 0 off, 1 on | `+0x948` |
| 8–15 | low byte of `(dpi_n − 1)`, n = 0..7; `dpi_n` = DPI / 50 | `+0x8c4 + 4n` |
| 16–23 | high byte of `(dpi_n − 1)` | |
| 24 | current stage + 1 | `+0x934` |
| 25–48 | 8 × (R, G, B) stage colors | bytes `+0x960 + 4n`, `+0x961`, `+0x962` |
| 49 | `01` | |
| 50–51 | BE checksum of bytes 3..49 | |
| 52–55 | `00` | |

- **Observed**: the field-to-control map comes from the UI refresh `sub_40f280` (`ev_6450b7fb…`): `+0x8b4` selects `ms_1_option_lift_of_distance_*` ("1 MM", "2 MM"), `+0x940` `ms_1_option_ripple_control_*`, `+0x944` `ms_1_option_angle_snap_*`, `+0x948` `ms_1_option_motion_sync_*` (each "off"/"on").
- **Differences from the M900** (observed): no nibble packing. Each setting has its own byte: lift 3, ripple 4, angle 6, motion 7. The M900 packed `lift << 4 | ripple` in byte 3, `angle << 4 | motion` in byte 4, and had the sensor mode in byte 6. The X3 has no sensor-mode field. Byte 49 is `01` (M900: `03`).
- **Inferred**: the firmware accepts this layout, since the app is the vendor's own for this mouse. **Unknown** until a live send: whether the firmware ignores byte 49.

### Report 0x05: light, sleep, debounce (`sub_413ca0`), 15 bytes

| Index | Content | Profile field |
|---|---|---|
| 0–2 | `05 0f 01` | |
| 3 | `light_mode << 4` | `+0x94c` |
| 4 | `(sleep & 0xF0) \| (9 − speed)` | `+0x92c`, `+0x928` |
| 5 | `((sleep << 4) & 0xFF) \| brightness` when the mode is 1 or 9; otherwise `((sleep << 4) & 0xFF) \| 8` | `+0x92c`, `+0x924` |
| 6–8 | light color R, G, B | bytes `+0x95c..+0x95e` |
| 9 | light off after | `+0x930` |
| 10 | debounce | `+0x958` |
| 11–12 | BE checksum of bytes 3..10 | |
| 13–14 | `00` | |

- **Observed**: same layout as the M900.
- **Observed** (`ev_6450b7fb…`): the controls are `ms_1_combo_light` (`+0x94c`), brightness slider 1–8 (`+0x924`), speed slider 4–8 (`+0x928`), color button (`+0x95c`), `ms_1_slider_light_off` 1–60 (`+0x930`), `ms_1_slider_sleep_timer` 1–60 (`+0x92c`), `ms_1_slider_key_debounce` 2–25 (`+0x958`).
- **Observed**: the debounce label shows `value × 2` with a "ms" format (`lea eax, [edi+edi]` before `Format`). So the byte sent is half the displayed time: the slider covers 4–50 ms in 2 ms steps. **Unknown** whether the firmware uses the byte as ms or as 2 ms units; the app's label implies 2 ms units.
- **Observed**: the light controls are hidden in `ms_1_page.xml`, but the combo lists the same 12 modes as the M900 (`lan.xml`): 0 LED Off, 1 Static, 2 Breathing, 3 Neon, 4 Color Breathing, 5 Color Static, 6 Mixed Breathing, 7 Rainbow Wave, 8 Lightning, 9 Static Mixed Color, 10 Marquee, 11 Marquee 2. **Inferred**: the X3 has no user-visible RGB, so report 0x05 matters mainly for sleep and debounce.
- A separate combo `ms_1_combo_light_ble` reads `+0x950` (`ev_6450b7fb…`). Where `+0x950` is sent is **unknown**.
- **Unknown**: the units of light-off and sleep (minutes on the M900; the labels are formatted by `sub_40fe00` and `sub_40fc80`, not read).
- `ms_1_check_movemode` (Move Wake) exists in the page but is hidden, and the UI refresh does not touch it. Its profile field and report are **unknown**.

### Report 0x06: polling rate, 9 bytes

`06 09 01 X ~X 00 00 00 00`, with `X` from the index in `+0x938`: 0 → `08`, 1 → `04`, 2 → `02`, 3 → `01`. `~X` is the bitwise complement.

- **Observed**: the index drives `ms_1_btn_prate_1..4` and the label `prate_1..4_text` ("Power Saving", "Office", "Gaming", "E-sports") (`ev_6450b7fb…`).
- **Inferred**: `X` is the report interval in ms, so 0 → 125 Hz, 1 → 250 Hz, 2 → 500 Hz, 3 → 1000 Hz.
- **Differences from the M900** (observed): the M900 sends `((hs + 1) << 4) | (normal + 1)`; the X3 sends one interval byte and has no high-speed rates.
- **Unknown**: event `0x2000` stores b3 raw into `+0x938`, while the report uses 0..3. Whether the mouse reports 1..4, 0..3 or interval values is unknown; the app may simply be inconsistent.

### Report 0x08: button functions (`sub_4145f0`, `ev_70602aee…`, `ev_cc83292f…`), 59 bytes

- `08 3b 01`, then 18 entries of 3 bytes (indices 3..56), one per button slot. BE checksum of bytes 3..56 at indices 57–58. **Observed**, same as the M900.
- Each button's data lives in the profile at `+0x9a0 + n·0x4f8` (n = 0..17). Byte `+1` is the function ID (`mov bh, [edi-2]` with `edi = +0x9a3`). The M900 used `+0x9a8 + n·0x1020`.
- The ID goes through the table at `0x41c4ac` (20-byte entries `id, b0, b1, b2, extra`; `ev_df74e889…`), which yields the 3 bytes sent. An ID with no entry yields `00 00 00`. Exceptions:
  - ID `0x10` (keyboard shortcut): `b1` = byte `+7` (modifier), `b2` = byte `+3` (key).
  - ID `0x11` (macro): `b0` = `12` from the table, `b1` = 0, `b2` = slot index + 1.
- **Observed**: the table is the same as the M900's `0x519730` table (same IDs and bytes), plus a few extra entries: `0x13` → `13`, `0x73` → `14`, `0x15` → `2b`, `0x36/0x37/0x38` → `34/35/36`. Key rows:

| ID | `b0 b1 b2` | M900 menu item |
|---|---|---|
| 0x00 | `01 00 00` | off |
| 0x01 / 0x02 / 0x03 | `02` / `03` / `04` | left / right / middle |
| 0x04 / 0x05 | `06` / `05` | forward / back |
| 0x06 / 0x07 / 0x08 | `0d` / `0e` / `0f` | DPI cycle / up / down |
| 0x09 / 0x0a | `07` / `08` | double click / fire |
| 0x0b / 0x0c | `09` / `0a` | scroll up / down |
| 0x0d / 0x0e | `0b` / `0c` | tilt left / right |
| 0x10 | `11 <mod> <key>` | shortcut |
| 0x11 | `12 00 <macro>` | macro |
| 0x16 / 0x17 | `10 00 03` / `29 00 03` | easy aim / LED loop |
| 0x34 | `3c 00 00` | unknown (also unknown on the M900) |
| 0x40–0x47 | `15 18 19 16 17 1b 1c 1a` | media |
| 0x50–0x59 | `25`, `11 03 12`, `20 21 22 24 26`, `1e 1d 23` | browser, e-mail, calculator, my computer |
| 0x20–0x32 | `11 01 1b` … `11 0a 16` | predefined shortcuts (cut, copy, … screenshot) |

#### Slots and physical buttons

- **Observed** (`sub_4155e0`, `ev_7b00e722…`; table `0x41c9e0`, `ev_036cc5f7…`): factory IDs per slot: `1, 2, 3, 6, 0x34, 8, 4, 5, 0x34, 0×7, 0x0c, 0x0b`. Byte `+2` comes from `0x41c998` (all zeros). Bytes `+0x42e` and `+0x432` are set to `0xffffffff` and word `+8` to `0x232`.
- **Observed** (`ms_1_page.xml`): visible buttons `ms_1_btn_key_1` (image `mouse/1.png`), `key_2` (2), `key_3` (3), `key_7` (4), `key_8` (5). All others sit in hidden layouts.
- **Inferred**: `ms_1_btn_key_N` is slot N − 1 (controls at `+0x188 + 4·(N − 1)`, `ev_2c0540ed…`; refreshed by `sub_411e60(i)` for i = 0..17, `ev_6450b7fb…`). So the five physical buttons are slot 0 left, 1 right, 2 middle, 6 forward (ID 4), 7 back (ID 5).
- **Derived** factory report 0x08 (not sent): `08 3b 01 020000 030000 040000 0d0000 3c0000 0f0000 060000 050000 3c0000 010000×7 0a0000 090000 00c2`.
- Note: slots 16/17 are `0a`/`09` (down/up) on the X3, the reverse of the M900 (`09`/`0a`). The X3's slots 3 and 5 hold DPI cycle and DPI down, and 4 and 8 hold `0x34`.

### Report 0x09: macros (`sub_414340`, `ev_c9101a8e…`), 131 bytes, partial

- **Observed**: `09 83 <index>` and length 0x83. Byte 3 = macro byte `+0x0c`; bytes 4–6 = byte `+0x43c` (repeated 3 times, probably the repeat count); byte 7 = byte `+0x40`, or 1 when it is 0 (probably the playback mode). Byte 28 = number of action pairs.
- Actions start at byte 29 as 2-byte pairs: `(round(delay / 10) | flag, key)`. `flag` = `0x01` when the action's byte is 1 (press), else `0x81` (release). The key comes from the action's first byte. Delays over 1270 ms are split into extra pairs with code `03` (up to 10).
- BE checksum of bytes 3..128 at bytes 129–130.
- **Observed**: over 2.4G it is sent as 3 chunks of 0x3c bytes with header `0x4009` (`ev_ae4d8f12…`). The M900 descriptor declares report 9 with 63 data bytes. The exact chunk header layout and how the firmware reassembles it are **unknown**.
- Sent only for buttons whose function ID is `0x11`.

### Report 0x0C, 10 bytes

`0c 0a 01 fe 01 fe 00 00 00 00`, sent first when `[+0x50cdc]` = 1 (profile reset or switch). **Observed**, same as the M900. Meaning **unknown**.

## Profiles

- **Observed** (`ev_df6c2434…`, Notify handler `sub_410070`): the profile list (`ms_1_list_profile`) and the add, delete, rename, import and export buttons work on local 0x80e0-byte `*.pro` files in `%APPDATA%\Attack SharkX3Mouse\ms_1`. Export writes the struct as is.
- **Inferred**: there are no onboard profile slots. The app never selects a slot on the mouse; switching profiles rewrites everything (0x0C, then 0x04, 0x05, 0x06, 0x08, 0x09).
- **Observed**: the profile reset button asks `restore_text` ("Are you sure you want to restore this configuration to the default settings?"), then calls `sub_4155e0` (defaults), `sub_40f280` (UI refresh), sets `[+0x50cdc]` = 1 and posts `0x531`.
- **Observed**: the DPI reset button only resets the DPI stages, colors, enables and the current stage, then refreshes and applies.

## Factory defaults (`sub_4155e0`, `ev_7b00e722…`)

| Field | Offset | Default | Meaning |
|---|---|---|---|
| DPI stages (value × 50) | `+0x8c4..+0x8e0` | `0x10, 0x20, 0x30, 0x40, 0x64, 0x208, 0, 0` | 800, 1600, 2400, 3200, 5000, 26000; stages 7–8 off |
| Copy of the stages | `+0x8e4..+0x900` | same | |
| Stage enable | `+0x904..+0x920` | `1,1,1,1,1,1,0,0` | bitmask `0x3f` |
| Current stage | `+0x934` | 1 | stage 2 (1600) |
| Stage colors (`0x00BBGGRR`) | `+0x960 + 4n` | `ff, ff00, ff0000, ffff, ffff00, ff00ff, 40ff, ffffff` | red, green, blue, yellow, cyan, magenta, orange `ff 40 00`, white |
| Polling | `+0x938` | 3 | `X = 01`, inferred 1000 Hz |
| Lift-off, ripple, angle, motion | `+0x8b4`, `+0x940`, `+0x944`, `+0x948` | 0, 0, 0, 0 | 1 mm, all off |
| Light mode | `+0x94c` | 0 | LED Off |
| BLE light mode | `+0x950` | 3 | |
| Brightness | `+0x924` | 8 | |
| Speed | `+0x928` | 6 | |
| Light color | `+0x95c` | `0xff0000` | blue (`00 00 ff`) |
| Palette | `+0x980..+0x99c` | `ff, ff00, ff0000, ff00ff, ffff, ffffff, ffffff, 80ff` | |
| Sleep | `+0x92c` | 10 | |
| Light off after | `+0x930` | 1 | |
| Debounce | `+0x958` | 4 | shown as 8 ms |
| Others | `+0x8b0`, `+0x8b8`, `+0x2280` | 0 | unknown |
| Others | `+0x89c` = 3, `+0x898` = 420, `+0x8a4` = 6 | | unknown |
| Buttons | `+0x9a0 + n·0x4f8` | see "Slots and physical buttons" | |

- **Observed**: the DPI reset button writes the same DPI, colors, enables and current stage (`ev_bfd13aaa…`, `ev_df6c2434…`).
- Note: stage 6 is 26000 DPI (`0x208` = 520, the slider maximum). Only 6 DPI stages are visible in the page; the slider is 1–520 (50–26000 DPI).
- **Derived** factory report 0x06 (not sent): `06 09 01 01 fe 00 00 00 00`.
- **Derived** factory report 0x05 (not sent): `05 0f 01 00 03 a8 00 00 ff 01 04 01 af 00 00`.

## Report lengths on the X3 firmware (observed on hardware, 2026-11-27)

`od -An -tx1 -v /sys/class/hidraw/hidraw{2,9}/device/report_descriptor` on the receiver (`fa60`, interface 2) and on the wired mouse (`fa61`, interface 2). Both have the same UsagePage `0x0A` collection (input report 3, 4 bytes) and a UsagePage `0x0B` collection of feature reports. Data length of each, without the report ID:

| Report | Receiver `fa60` | Wired `fa61` | Length X3.exe builds (with ID) |
|---|---|---|---|
| `0x04` | 51 | 51 | 56 |
| `0x05` | 12 | 12 | 15 |
| `0x06` | 8 | 8 | 9 |
| `0x08` | 58 | 58 | 59 |
| `0x09` | 63 | 63 | 131 (split in chunks over 2.4G) |
| `0x0C` | 5 | 5 | 10 |

Others: `07`=7, `0A`=7, `0B`=7, `10`=7, `A0`=7, `22`=131, `23`=131/130, `24`=7, `25`=12, `26`=8, `27`=7, `28`=131, `29`=128, `2A`=131 (wired 130), `2B`=7, `2C`=3, `2D`=131 (wired 102), `2E`=4.

- **Observed**: reports 0x04, 0x05 and 0x0C are shorter on the X3 than the buffers X3.exe builds (the M900 receiver declares 55, 14 and 9, which match).
- **Inferred**: Windows sends only the declared length of each feature report, so the X3 firmware receives the first 52, 13 and 6 bytes. The checksum still fits inside them (0x04: bytes 50–51; 0x05: bytes 11–12), and the dropped tail is the zero padding. 0x0C becomes `0c 0a 01 fe 01 fe`.
- **Consequence for Linux**: `HIDIOCSFEATURE` must send exactly `1 + declared length` bytes per report. Keep the length byte (index 1) as X3.exe builds it (`0x38`, `0x0f`, `0x0a`). Unverified until a live send gets an ACK.
- `/dev/hidraw2` (receiver) is already accessible to the session through the DELUX M900 udev rule (`1d57:fa60`, interface 02). The wired interface (`fa61`, interface 02) is root-only until a rule for it is installed.

## Differences from the DELUX M900

| Topic | M900 Pro | X3 |
|---|---|---|
| App HID stack | hidapi for 2.4G | `hiddriver_2.dll` (wired) and `hiddriver_1.dll` (2.4G); hidapi only for BLE detection; GATT for BLE |
| PIDs | `fa60` receiver (and `fa61` in the app table) | `fa61` wired, `fa60` receiver, BLE `045e:0040` |
| Model code | `0x3d` | `0x10` (observed) |
| Battery | b3 = state (2 full, 3 charging), b4 = percent | b3 = 0 asleep / non-zero awake, b4 = 1..10 steps of 10 % |
| Report 0x04 sensor bytes | nibble-packed: byte 3 = lift/ripple, 4 = angle/motion, 6 = sensor mode | one byte each: 3 lift, 4 ripple, 6 angle, 7 motion; no sensor mode |
| Report 0x04 byte 49 | `03` | `01` |
| Report 0x06 | `((hs+1) << 4) \| (normal+1)`, up to 8000 Hz | one interval byte `08/04/02/01`, 125–1000 Hz |
| Button struct | `+0x9a8`, stride `0x1020` | `+0x9a0`, stride `0x4f8` |
| Buttons | 5 visible + DPI | 5 visible; slots 16/17 down/up reversed |
| Debounce label | value in ms | value × 2 ms |
| Factory sensor | ripple on, motion sync on, sensor mode 3 | all off, lift 1 mm |
| Factory light | Rainbow Wave | LED Off |
| Factory DPI | 400, 800, 1200, 1600, 3200, 5000 | 800, 1600, 2400, 3200, 5000, 26000 |
| Polling over BLE | n/a | report 0x06 is not sent over BLE |

## Open questions

1. Does the firmware send DPI (`0x10`) and polling (`0x20`) events with model byte `0x00` or `0x10`? With `0x10`, the app would ignore them. A live check: press the DPI button while listening on the receiver hidraw.
2. Does the wired interface (fa61) send power events or ACKs? The wired sender does not wait for an ACK.
3. Does the firmware accept the X3 report 0x04 layout, and what does byte 49 mean?
4. Debounce units: ms or 2 ms steps?
5. Units of sleep and light-off (minutes on the M900).
6. Move Wake (`check_movemode`): profile field and report.
7. Where `+0x950` (BLE light mode) and the unknown fields `+0x898`, `+0x89c`, `+0x8a4` go.
8. The 2.4G chunk format for report 0x09 (header `0x4009`).
9. The meaning of report 0x0C and of function ID `0x34` (`3c 00 00`).
10. Whether the 0x04 → 0x0a battery jump at plug-in is a re-estimate or a "charging" placeholder: compare the level right after unplugging.
11. Resolved: see "Report lengths on the X3 firmware".
