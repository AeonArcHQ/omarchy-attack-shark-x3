# ATTACK SHARK X3 for Omarchy

Omarchy bar widget for the ATTACK SHARK X3 wireless mouse: battery in the
bar and, in the panel, DPI, polling rate, sensor, timing and button
settings. Everything goes through the 2.4G receiver (`1d57:fa60`) or the USB
cable (`1d57:fa61`), without the Windows driver.

- The bar shows the mouse glyph and the percentage. The glyph takes the
  warning color at 15% battery or less and dims when the mouse or its
  receiver does not respond or the mouse reports itself asleep.
- The X3 reports battery in 10% steps. The tooltip gives the state (on
  battery, charging or asleep), the transport (receiver or cable) and, with
  no answer, the last level read. Once the current DPI stage is known (a
  DPI event from the mouse, or an acknowledged apply of the DPI report), the
  tooltip includes it; the saved profile remembers that.
- `showPercentage` option (default `true`): turned off, only the icon stays
  in the bar. A right click on the bar entry flips it.
- A click opens the panel: one DPI editor for the current stage, buttons for
  the active stages, six indicator colors and an Active stages count (1-6),
  polling (125 to 1000 Hz), lift-off, motion sync, ripple, angle snapping,
  Sleep Time, Deep Sleep, debounce and the function of the 5 physical
  buttons (clicks, DPI, scroll, media, volume and Ctrl shortcuts).
  Restoring factory settings takes two clicks.
- The mouse does not let its settings be read. The panel shows the last
  profile the mouse confirmed, saved in
  `~/.local/state/attack-shark-x3/profile.json`; before the first change, it
  assumes factory defaults for editing but does not claim to know the
  current stage. Changes made on the mouse itself (DPI button) arrive
  through the receiver and update the profile.
- The X3 has no configurable lighting. The DPI indicator color is part of
  each stage; report 0x05 keeps the factory light bytes when timing settings
  are sent.
- While asleep, the mouse does not respond: the panel asks you to move it
  and try again.
- IPC: `omarchy-shell com.aeonarc.attack-shark-x3
  toggle|open|close|status|state|resetDefaults|lastError` and
  `set <field> <json>`, for example `set polling 2`, `set stage 0` or
  `set deepSleep 10`. `state` returns one JSON object with `busy`, `error`,
  the one-based `stage`, `stageKnown`, `battery` and `connection`.

## Receiver versus cable

Over the receiver, the plugin receives the battery heartbeat, DPI-stage and
polling-rate events, and waits for the mouse to acknowledge every setting it
sends; a setting that gets no ACK after the retries fails with "the mouse
is asleep". Over the cable, the X3 firmware does not send those
acknowledgements, so the plugin sends each setting and waits the same
500 ms X3.exe waits.

The receiver carries no charging state and goes quiet when the cable takes
over. While the cable interface exists, the bar therefore shows charging.
If the helper was already running on battery, it keeps the last measured
percentage; if it starts with the cable already connected, the percentage is
unknown until the mouse is used on the receiver again.

## Requirements

`python` (the Omarchy default) and the udev rule below, which gives the
local session access to the receiver and the cable vendor interface.

## Installation

```sh
omarchy plugin add https://github.com/AeonArcHQ/omarchy-attack-shark-x3 --enable
sudo install -m 644 "$HOME/.config/omarchy/plugins/com.aeonarc.attack-shark-x3/udev/71-attack-shark-x3-hidraw.rules" /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=hidraw
```

The udev rule gives the local session (`uaccess`) access only to interface
2 of the receiver and of the mouse's cable interface, the vendor interface.
Motion and clicks stay restricted to root.

## Removing

```sh
omarchy plugin remove com.aeonarc.attack-shark-x3
sudo rm /etc/udev/rules.d/71-attack-shark-x3-hidraw.rules
sudo udevadm control --reload
```

Optionally delete the saved profile:
`rm ~/.local/state/attack-shark-x3/profile.json`.

## How it works

- `x3-hid`: Python helper, standard library only. It finds the receiver and
  cable interface `hidraw` nodes through sysfs and listens to input report
  3: power, DPI stage and polling. When the receiver opens, it sends the
  saved polling report once; that first report makes the receiver deliver
  DPI-stage events. `apply` sends feature reports. Over the receiver it
  retries each report, the polling report included, until its ACK arrives,
  and fails when none comes; over the cable it waits 500 ms. It saves the profile only after every report succeeds.
- `Model.js`: builds reports 0x04 (DPI and sensor), 0x05 (factory light
  bytes and timing), 0x06 (polling) and 0x08 (buttons), and decides what the
  bar and the panel show.
- `Service.qml`: processes and profile. `MousePanel.qml`: bar and panel,
  following the official Omarchy panels.
- The full protocol, recovered from the Windows driver and the hardware
  report descriptors, is in [docs/re/findings.md](docs/re/findings.md).

## Development

```sh
git config core.hooksPath .githooks   # once per clone: enables the pre-commit hook
tests/check.sh                        # unittest, qmltestrunner, plugin validate
```

- Edit the plugin in `~/.config/omarchy/plugins/com.aeonarc.attack-shark-x3`
  as a real folder: through a symlink, Quickshell rejects the QML with
  "File name case mismatch".
- Hot reload does not replace the panel already loaded or the
  `IpcHandler`. After changing QML, run `omarchy restart shell`. QML errors
  only show up in `journalctl --user | grep MousePanel.qml`.
- The `modelData` of a `Repeater` over arrays arrives as a Qt list, which
  fails `Array.isArray`; treat it as array-like (`length` and indexes).

### Checklist with the mouse (wake it before each change)

1. The bar shows the battery percentage on the receiver; on the cable, the
   tooltip and panel say charging. Unplugging returns to the receiver
   percentage.
2. Each active DPI stage changes the cursor speed; so does changing the
   value of the current stage. The mouse's DPI button moves the selection in
   the panel.
3. 500 Hz and 1000 Hz change the measured polling rate.
4. Buttons: the forward side button set to Volume + raises the volume; the
   others stay the same.
5. Restore factory settings goes back to 1600 DPI as the current stage,
   1000 Hz, all sensor toggles off, Sleep Time of 30 seconds, Deep Sleep of
   10 minutes, 8 ms debounce and the side buttons as forward and back.

## License

MIT.
