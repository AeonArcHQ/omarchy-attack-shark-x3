# Live test

How to try a change on the running bar and the real mouse.

## Loading the code

- The shell loads the plugin from the main checkout, `~/.config/omarchy/plugins/com.aeonarc.attack-shark-x3`, never from `.worktrees/`. To try a branch, check it out there (detached is fine).
- After the checkout, run `omarchy restart shell`. Hot reload and `omarchy-shell shell rescanPlugins` keep the old QML after a git checkout.
- Open and close the panel without clicking: `omarchy-shell com.aeonarc.attack-shark-x3 open` and `close`. The M900's target is `com.aeonarc.delux-m900`.

## The mouse

- The mouse sleeps after `sleepTime` minutes (factory: 1). A sleeping mouse ACKs nothing: `x3-hid apply` ends with `{"ok": false, "error": "timeout"}` and the panel shows "The mouse is asleep. Move it and try again." Ask the owner to move the mouse right before each apply.
- Only the owner can press the mouse buttons (the DPI button, clicks). Ask, then read the result from the receiver or the saved profile, `~/.local/state/attack-shark-x3/profile.json`.
- The receiver is `1d57:fa60`; its vendor interface (2) is the `hidraw` node that `x3-hid` opens. Reading it is safe while the plugin runs: every reader gets every input report.

## The screen

The laptop screen runs at scale 1.25, so a panel can start at a fractional x and a 1 px border can vanish there. Judge borders and spacing by measuring pixels, against the M900 panel, rather than by eye.

## Tools

- `tools/panel-check`: run before calling a UI change done; it captures the X3 and M900 panels, measures the frame and bordered buttons, and fails when an X3 button edge is missing.
- `tools/listen.py`: run when you need the receiver's live report-3 events (power, DPI, polling, ACK) without sending anything to the mouse.
- `state` IPC (`omarchy-shell com.aeonarc.attack-shark-x3 state`): use when a script needs the panel's `busy`, `error`, stage, battery and connection as JSON.
