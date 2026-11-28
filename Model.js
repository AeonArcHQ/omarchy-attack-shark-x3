// Bar rules for the ATTACK SHARK X3 battery. x3-hid prints one JSON object
// per line; everything the bar shows is decided here so tests/tst_model.qml
// covers it.

var GLYPH_MOUSE = "󰍽"
var LOW_LEVEL = 15

var NOTICES = {
  starting: "reading the mouse",
  missing: "receiver and cable disconnected",
  "access-denied": "no permission on the mouse interface (install the udev rule)",
  asleep: "the receiver stopped sending events",
  error: "invalid response from the helper"
}

var STATE_LABELS = {
  discharging: "on battery",
  charging: "charging",
  asleep: "asleep"
}

var TRANSPORT_LABELS = {
  receiver: "receiver",
  cable: "cable"
}

function emptyBattery() {
  return { connection: "starting", state: "", level: -1, measuredAt: null, transport: "" }
}

// Folds one helper line into the widget state. The last known level survives
// errors, so the tooltip can still say what the battery had. `now` is ms
// since epoch: every power line with a level is a fresh measurement. The
// cable itself carries no measurement, so a charging line without a level
// keeps the last one instead of inventing a percentage.
function applyLine(previous, line, now) {
  var prev = previous || emptyBattery()
  var message = null
  try { message = JSON.parse(String(line || "")) } catch (error) { message = null }
  if (!message || typeof message !== "object") return Object.assign({}, prev, { connection: "error" })
  // DPI and polling events also prove the mouse is answering.
  if (message.ok === true && message.event !== undefined && message.event !== "power") {
    return prev.level >= 0 ? Object.assign({}, prev, { transport: transportOf(message, prev.transport) }) : prev
  }
  if (message.ok !== true) {
    var code = NOTICES[message.error] ? String(message.error) : "error"
    return Object.assign({}, prev, { connection: code })
  }
  var state = String(message.state)
  if (!STATE_LABELS[state]) return Object.assign({}, prev, { connection: "error" })
  var hasLevel = message.level !== undefined && message.level !== null
  var level = hasLevel ? Number(message.level) : NaN
  if (hasLevel && !(level >= 0 && level <= 100)) return Object.assign({}, prev, { connection: "error" })
  if (!hasLevel && state !== "charging") return Object.assign({}, prev, { connection: "error" })
  var rounded = hasLevel ? Math.round(level) : prev.level
  var measuredAt = hasLevel ? now : prev.measuredAt
  return { connection: "ready", state: state, level: rounded, measuredAt: measuredAt,
    transport: transportOf(message, prev.transport) }
}

function transportOf(message, fallback) {
  var transport = String(message.transport || "")
  return TRANSPORT_LABELS[transport] ? transport : fallback
}

// `formatNumber` localizes the percentage like the shell's battery widget
// (Commons.I18n.formatNumber in power/Panel.qml); tests leave it out.
function barView(model, showPercentage, formatNumber) {
  var m = model || emptyBattery()
  var ready = m.connection === "ready"
  var format = formatNumber || String
  return {
    glyph: GLYPH_MOUSE,
    label: ready && showPercentage && m.level >= 0 ? format(m.level) + "%" : "",
    active: ready && m.state === "discharging" && m.level <= LOW_LEVEL,
    dimmed: !ready || m.state === "asleep"
  }
}

// Local "HH:MM" (24-hour, zero-padded) for a ms-since-epoch time. Passed to
// `tooltip` so tests pin the clock instead of reading the machine's.
function hhmm(ms) {
  var d = new Date(ms)
  return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
}

function tooltip(model, formatTime, profile, stageKnown) {
  var m = model || emptyBattery()
  var title = "Attack Shark X3"
  if (m.connection === "ready" && m.level >= 0) title += " · " + m.level + "%"
  return title + " · " + statusLine(m, formatTime, profile, stageKnown)
}

// The tooltip without the title and the current level, for the panel line
// under the big percentage.
function statusLine(model, formatTime, profile, stageKnown) {
  var m = model || emptyBattery()
  var dpiText = ""
  if (stageKnown === true && profile && profile.dpi && Number(profile.dpi.length) === 8) {
    var stage = clamp(profile.stage, 0, USER_STAGES - 1)
    dpiText = "DPI " + profile.dpi[stage] + " (stage " + (stage + 1) + ")"
  }
  if (m.connection === "ready") {
    var parts = [STATE_LABELS[m.state]]
    if (TRANSPORT_LABELS[m.transport]) parts.push(TRANSPORT_LABELS[m.transport])
    if (dpiText !== "") parts.push(dpiText)
    var text = parts.join(" · ")
    // The cable carries no measurement; when the last receiver measurement is
    // shown next to the charging state, say when it was taken.
    if (m.state === "charging" && m.level >= 0 && m.measuredAt != null) {
      var format = formatTime || hhmm
      text += "\nlast measured at " + format(m.measuredAt)
    }
    return text
  }
  var notice = NOTICES[m.connection]
  if (m.level >= 0) notice += " (last: " + m.level + "%)"
  if (dpiText !== "") notice += " · " + dpiText
  return notice
}

// The machine-readable state exposed over IPC. `stage` is one-based because
// it is for people and scripts outside the panel; the profile stores it
// zero-based for report 0x04.
function stateJson(busy, error, profile, stageKnown, battery) {
  var p = profile || normalizeProfile(null)
  var b = battery || emptyBattery()
  var level = Number(b.level)
  if (!isFinite(level)) level = -1
  return JSON.stringify({
    busy: !!busy,
    error: String(error || ""),
    stage: clamp(p.stage, 0, USER_STAGES - 1) + 1,
    stageKnown: stageKnown === true,
    battery: Math.round(level),
    connection: String(b.connection || "starting")
  })
}

// ---------- Configuration (feature reports, docs/re/findings.md) ----------

// The firmware report carries eight DPI slots; only the first six are user
// stages.
var USER_STAGES = 6

var DPI_MIN = 50
var DPI_MAX = 26000
var POLLING_RATES = [125, 250, 500, 1000]
var COLOR_PRESETS = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
  [0, 255, 255], [255, 0, 255]]

// X3.exe's restore routine (sub_4155e0). The firmware report still carries
// eight DPI slots, but only the first six are user stages; slots 7-8 keep
// these factory bytes and are never enabled.
var FACTORY = {
  dpi: [800, 1600, 2400, 3200, 5000, 26000, 800, 800],
  stages: USER_STAGES,
  stage: 1,
  colors: [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
    [0, 255, 255], [255, 0, 255], [255, 64, 0], [255, 255, 255]],
  polling: 3,
  lift: 0,
  ripple: 0,
  angle: 0,
  motionSync: 0,
  sleepTime: 1,
  deepSleep: 10,
  debounce: 4,
  buttons: ["left", "right", "middle", "dpiCycle", "hidden3c", "dpiDown", "forward", "back",
    "hidden3c", "off", "off", "off", "off", "off", "off", "off", "scrollDown", "scrollUp"]
}

// Report 0x05 keeps these factory light bytes. The X3 has no configurable
// lighting and X3.exe hides the controls, so v1 has no lighting profile.
var LIGHT_FACTORY = { mode: 0, brightness: 8, speed: 6, color: [0, 0, 255] }

function clamp(value, low, high) {
  var n = Math.round(Number(value))
  if (isNaN(n)) n = low
  return Math.max(low, Math.min(high, n))
}

function copy(value) { return JSON.parse(JSON.stringify(value)) }

function normalizeDpi(value) {
  return Math.round(clamp(value, DPI_MIN, DPI_MAX) / 50) * 50
}

function normalizeColor(value, fallback) {
  if (!value || Number(value.length) !== 3) return fallback.slice()
  return [clamp(value[0], 0, 255), clamp(value[1], 0, 255), clamp(value[2], 0, 255)]
}

// A saved profile with every field checked; anything missing or out of range
// falls back to the factory value.
function normalizeProfile(raw) {
  var p = raw && typeof raw === "object" ? raw : {}
  var f = FACTORY
  var out = copy(f)
  if (p.dpi && Number(p.dpi.length) === 8) {
    out.dpi = []
    for (var d = 0; d < 8; d++) out.dpi.push(normalizeDpi(p.dpi[d]))
  }
  if (p.colors && Number(p.colors.length) === 8) {
    out.colors = []
    for (var c = 0; c < 8; c++) out.colors.push(normalizeColor(p.colors[c], f.colors[c]))
  }
  for (var hidden = USER_STAGES; hidden < 8; hidden++) {
    out.dpi[hidden] = f.dpi[hidden]
    out.colors[hidden] = f.colors[hidden].slice()
  }
  if (p.stages !== undefined) {
    out.stages = clamp(p.stages, 1, USER_STAGES)
  } else if (p.enabled && Number(p.enabled.length) === 8) {
    // The first saved shape carried one enabled bit per stage. Count only the
    // leading enabled user stages; slots 7-8 were never user stages.
    var leading = 0
    while (leading < USER_STAGES && clamp(p.enabled[leading], 0, 1) === 1) leading++
    out.stages = Math.max(1, leading)
  }
  out.stage = clamp(p.stage !== undefined ? p.stage : f.stage, 0, out.stages - 1)
  // Whether the mouse really reported or acknowledged this stage. The mouse
  // cannot be read back, so a profile without the field does not know it.
  out.stageKnown = p.stageKnown === true
  out.polling = clamp(p.polling !== undefined ? p.polling : f.polling, 0, 3)
  out.lift = clamp(p.lift !== undefined ? p.lift : f.lift, 0, 1)
  out.ripple = clamp(p.ripple !== undefined ? p.ripple : f.ripple, 0, 1)
  out.angle = clamp(p.angle !== undefined ? p.angle : f.angle, 0, 1)
  out.motionSync = clamp(p.motionSync !== undefined ? p.motionSync : f.motionSync, 0, 1)
  out.sleepTime = clamp(p.sleepTime !== undefined ? p.sleepTime : f.sleepTime, 1, 60)
  out.deepSleep = clamp(p.deepSleep !== undefined ? p.deepSleep : f.deepSleep, 1, 60)
  out.debounce = clamp(p.debounce !== undefined ? p.debounce : f.debounce, 2, 25)
  if (p.buttons && Number(p.buttons.length) === 18) {
    var buttons = []
    for (var b = 0; b < 18; b++) buttons.push(normalizeButton(p.buttons[b], f.buttons[b]))
    out.buttons = buttons
  }
  return out
}

// The checksum is the 16-bit sum of bytes 3..last, stored big-endian after it.
function withChecksum(bytes, last) {
  var sum = 0
  for (var i = 3; i <= last; i++) sum += bytes[i]
  bytes[last + 1] = (sum >> 8) & 0xff
  bytes[last + 2] = sum & 0xff
  return bytes
}

function toHex(bytes) {
  var hex = ""
  for (var i = 0; i < bytes.length; i++) hex += hexByte(bytes[i])
  return hex
}

function hexByte(value) {
  var text = (value & 0xff).toString(16)
  return text.length === 1 ? "0" + text : text
}

function colorHex(c) {
  return "#" + hexByte(c[0]) + hexByte(c[1]) + hexByte(c[2])
}

function filled(length) {
  var bytes = []
  for (var i = 0; i < length; i++) bytes.push(0)
  return bytes
}

// Report 0x04: DPI stages, stage colours and sensor options (sub_413fe0).
function report4(p) {
  var b = filled(56)
  b[0] = 0x04; b[1] = 0x38; b[2] = 0x01
  b[3] = p.lift
  b[4] = p.ripple
  b[5] = (1 << clamp(p.stages, 1, USER_STAGES)) - 1
  b[6] = p.angle
  b[7] = p.motionSync
  for (var i = 0; i < 8; i++) {
    var dpi = i < USER_STAGES ? p.dpi[i] : FACTORY.dpi[i]
    var color = i < USER_STAGES ? p.colors[i] : FACTORY.colors[i]
    var v = dpi / 50 - 1
    b[8 + i] = v & 0xff
    b[16 + i] = (v >> 8) & 0xff
    b[25 + 3 * i] = color[0]
    b[26 + 3 * i] = color[1]
    b[27 + 3 * i] = color[2]
  }
  b[24] = p.stage + 1
  b[49] = 0x01
  return toHex(withChecksum(b, 49))
}

// Report 0x05: factory light bytes, Sleep Time, Deep Sleep and debounce
// (sub_413ca0). Byte 9 is Sleep Time in half-minute steps; the value nibbled
// across bytes 4–5 is Deep Sleep in minutes.
function report5(p) {
  var b = filled(15)
  var l = LIGHT_FACTORY
  b[0] = 0x05; b[1] = 0x0f; b[2] = 0x01
  b[3] = (l.mode << 4) & 0xff
  b[4] = (p.deepSleep & 0xf0) | (9 - l.speed)
  b[5] = ((p.deepSleep << 4) & 0xff) | (l.mode === 1 || l.mode === 9 ? l.brightness : 8)
  b[6] = l.color[0]; b[7] = l.color[1]; b[8] = l.color[2]
  b[9] = p.sleepTime
  b[10] = p.debounce
  return toHex(withChecksum(b, 10))
}

// Report 0x06: polling interval in milliseconds plus its complement. x3-hid's
// polling_packet() builds the same bytes so `watch` can prime the receiver on
// its own; tests/tst_model.qml and tests/test_x3_hid.py pin both to one hex.
function report6(p) {
  var x = [8, 4, 2, 1][p.polling]
  return toHex([0x06, 0x09, 0x01, x, (~x) & 0xff, 0, 0, 0, 0])
}

// Header X3.exe sends before rewriting a whole profile.
var REPORT_RESET = "0c0a01fe01fe00000000"

// One report table: which profile fields it carries and how to rebuild it.
var REPORT_ORDER = ["0c", "04", "05", "06", "08"]
var REPORTS = {
  "0c": { fields: [], build: function(profile) { return REPORT_RESET } },
  "04": { fields: ["dpi", "stages", "stage", "colors", "lift", "ripple", "angle", "motionSync"],
    build: function(profile) { return report4(profile) } },
  "05": { fields: ["sleepTime", "deepSleep", "debounce"], build: function(profile) { return report5(profile) } },
  "06": { fields: ["polling"], build: function(profile) { return report6(profile) } },
  "08": { fields: ["buttons"], build: function(profile) { return report8(profile.buttons) } }
}

function reportForField(field) {
  for (var i = 0; i < REPORT_ORDER.length; i++) {
    var id = REPORT_ORDER[i]
    if (REPORTS[id].fields.indexOf(field) >= 0) return id
  }
  return ""
}

function packetsFor(field, profile) {
  var id = reportForField(field)
  return id === "" ? [] : [REPORTS[id].build(profile)]
}

function factoryPackets() {
  var p = normalizeProfile(FACTORY)
  return REPORT_ORDER.map(function(id) { return REPORTS[id].build(p) })
}

// A changed copy of the profile.
function withValue(profile, field, value) {
  var next = copy(profile)
  next[field] = value
  return normalizeProfile(next)
}

// The mouse's own DPI button and rate shortcut move these without the host;
// the receiver reports them so the saved profile can follow. A DPI event
// also makes the current stage known.
function applyEvent(profile, line) {
  var message = null
  try { message = JSON.parse(String(line || "")) } catch (error) { return null }
  if (!message || message.ok !== true) return null
  if (message.event === "dpi") {
    var moved = withValue(profile, "stage", Number(message.stage) - 1)
    return withValue(moved, "stageKnown", stageKnownAfterEvent(profile.stageKnown, message))
  }
  if (message.event === "polling") return withValue(profile, "polling", Number(message.index))
  return null
}

// Only the receiver's DPI event (`03 00 10 <stage> 00`) reports the stage.
function stageKnownAfterEvent(known, message) {
  return known === true || (!!message && message.ok === true && message.event === "dpi")
}

// After a successful apply: report 0x04 carries the stage byte, so the mouse
// is on the sent stage; the other reports leave the stage as unknown as it was.
function stageKnownAfterApply(known, packets) {
  if (known === true) return true
  var list = packets || []
  for (var i = 0; i < list.length; i++) if (String(list[i]).substr(0, 2) === "04") return true
  return false
}

function dpiLabel(dpi) {
  return dpi >= 1000 && dpi % 1000 === 0 ? (dpi / 1000) + "k" : String(dpi)
}

// What the panel says when `x3-hid apply` fails.
var APPLY_ERRORS = {
  timeout: "The mouse is asleep. Move it and try again.",
  rejected: "The mouse rejected the settings.",
  missing: "Receiver and cable disconnected.",
  "access-denied": "No permission on the mouse interface. Install the udev rule from the README.",
  invalid: "Invalid settings; nothing was sent."
}

function applyError(output) {
  var result = null
  try { result = JSON.parse(String(output || "")) } catch (error) { result = null }
  if (result && result.ok === true) return ""
  var code = result && result.error ? String(result.error) : ""
  return APPLY_ERRORS[code] || "The helper failed to send the settings."
}

// ---------- Buttons (report 0x08, docs/re/findings.md) ----------

// Firmware bytes per function, from X3.exe's table at 0x41c4ac. `hidden3c`
// is the factory function of hidden slots 4 and 8; its meaning is unknown.
var BUTTON_CODES = {
  off: [0x01, 0, 0], left: [0x02, 0, 0], right: [0x03, 0, 0], middle: [0x04, 0, 0],
  back: [0x05, 0, 0], forward: [0x06, 0, 0], doubleClick: [0x07, 0, 0], fire: [0x08, 0, 0],
  scrollUp: [0x09, 0, 0], scrollDown: [0x0a, 0, 0], tiltLeft: [0x0b, 0, 0], tiltRight: [0x0c, 0, 0],
  dpiCycle: [0x0d, 0, 0], dpiUp: [0x0e, 0, 0], dpiDown: [0x0f, 0, 0],
  mediaPlayer: [0x15, 0, 0], prevTrack: [0x16, 0, 0], nextTrack: [0x17, 0, 0],
  playPause: [0x18, 0, 0], mediaStop: [0x19, 0, 0], mute: [0x1a, 0, 0],
  volumeUp: [0x1b, 0, 0], volumeDown: [0x1c, 0, 0],
  hidden3c: [0x3c, 0, 0]
}
var SHORTCUT_CODE = 0x11

// Slots in report order (FACTORY.buttons). The physical buttons are slots
// 0 left, 1 right, 2 middle, 6 forward and 7 back.
var FACTORY_BUTTONS = FACTORY.buttons

var PHYSICAL_BUTTONS = [
  { slot: 0, label: "Left" }, { slot: 1, label: "Right" }, { slot: 2, label: "Middle" },
  { slot: 6, label: "Forward side" }, { slot: 7, label: "Back side" }
]

// Ctrl shortcuts from X3.exe's menu that mean the same on Linux.
var SHORTCUTS = {
  copy: [1, 0x06], paste: [1, 0x19], cut: [1, 0x1b], undo: [1, 0x1d], redo: [1, 0x1c],
  selectAll: [1, 0x04], save: [1, 0x16], find: [1, 0x09]
}

// Panel menu: value is a BUTTON_CODES name or "shortcut:<name>".
var BUTTON_OPTIONS = [
  { value: "left", label: "Left click" }, { value: "right", label: "Right click" },
  { value: "middle", label: "Middle click" }, { value: "back", label: "Back" },
  { value: "forward", label: "Forward" }, { value: "doubleClick", label: "Double click" },
  { value: "fire", label: "Fire (repeated clicks)" },
  { value: "dpiCycle", label: "DPI: next stage" }, { value: "dpiUp", label: "DPI +" },
  { value: "dpiDown", label: "DPI −" },
  { value: "scrollUp", label: "Scroll up" }, { value: "scrollDown", label: "Scroll down" },
  { value: "tiltLeft", label: "Scroll left" }, { value: "tiltRight", label: "Scroll right" },
  { value: "playPause", label: "Play/pause" }, { value: "nextTrack", label: "Next track" },
  { value: "prevTrack", label: "Previous track" }, { value: "mediaStop", label: "Stop media" },
  { value: "volumeUp", label: "Volume +" }, { value: "volumeDown", label: "Volume −" },
  { value: "mute", label: "Mute" },
  { value: "shortcut:copy", label: "Copy (Ctrl+C)" }, { value: "shortcut:paste", label: "Paste (Ctrl+V)" },
  { value: "shortcut:cut", label: "Cut (Ctrl+X)" }, { value: "shortcut:undo", label: "Undo (Ctrl+Z)" },
  { value: "shortcut:redo", label: "Redo (Ctrl+Y)" }, { value: "shortcut:selectAll", label: "Select all (Ctrl+A)" },
  { value: "shortcut:save", label: "Save (Ctrl+S)" }, { value: "shortcut:find", label: "Find (Ctrl+F)" },
  { value: "off", label: "Off" }
]

function buttonOption(slot) {
  if (slot && typeof slot === "object" && slot.shortcut) {
    for (var name in SHORTCUTS) {
      if (SHORTCUTS[name][0] === slot.shortcut[0] && SHORTCUTS[name][1] === slot.shortcut[1]) return "shortcut:" + name
    }
    return ""
  }
  return String(slot)
}

function buttonFromOption(value) {
  var text = String(value)
  if (text.indexOf("shortcut:") === 0) {
    var keys = SHORTCUTS[text.substr(9)]
    return keys ? { shortcut: keys.slice() } : null
  }
  return BUTTON_CODES[text] ? text : null
}

function normalizeButton(slot, fallback) {
  if (slot && typeof slot === "object" && slot.shortcut && Number(slot.shortcut.length) === 2) {
    return { shortcut: [clamp(slot.shortcut[0], 0, 255), clamp(slot.shortcut[1], 0, 255)] }
  }
  return BUTTON_CODES[slot] ? String(slot) : fallback
}

// A copy of the profile with one slot changed, or null when the change would
// leave no left click.
function withButton(profile, slot, option) {
  var button = buttonFromOption(option)
  if (button === null) return null
  var buttons = profile.buttons.slice()
  buttons[slot] = button
  if (buttons.indexOf("left") < 0) return null
  return withValue(profile, "buttons", buttons)
}

// One slot: a BUTTON_CODES name, or { shortcut: [modifier, usage] } with the
// HID modifier bits (1 Ctrl, 2 Shift, 4 Alt, 8 Win) and keyboard usage id.
function buttonBytes(slot) {
  if (slot && typeof slot === "object" && slot.shortcut && Number(slot.shortcut.length) === 2) {
    return [SHORTCUT_CODE, slot.shortcut[0] & 0xff, slot.shortcut[1] & 0xff]
  }
  return BUTTON_CODES[slot] ? BUTTON_CODES[slot].slice() : null
}

// X3.exe refuses a layout without a left click; so does this.
function report8(buttons) {
  if (!buttons || Number(buttons.length) !== 18 || buttons.indexOf("left") < 0) return ""
  var b = filled(59)
  b[0] = 0x08; b[1] = 0x3b; b[2] = 0x01
  for (var i = 0; i < 18; i++) {
    var bytes = buttonBytes(buttons[i])
    if (bytes === null) return ""
    b[3 + 3 * i] = bytes[0]; b[4 + 3 * i] = bytes[1]; b[5 + 3 * i] = bytes[2]
  }
  return toHex(withChecksum(b, 56))
}

// Packets for a change that replaces one still waiting: every report either
// change touched, rebuilt from the newest profile, which already holds both.
function mergePackets(waiting, incoming, profile) {
  var ids = []
  var all = (waiting || []).concat(incoming || [])
  for (var i = 0; i < all.length; i++) {
    var id = all[i].substr(0, 2)
    if (ids.indexOf(id) < 0) ids.push(id)
  }
  return REPORT_ORDER.filter(function(id) { return ids.indexOf(id) >= 0 })
    .map(function(id) { return REPORTS[id].build(profile) })
}
