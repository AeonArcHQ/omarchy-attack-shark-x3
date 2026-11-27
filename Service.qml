import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Mouse state for one bar entry. `x3-hid watch` stays running for the
// battery and the mouse's own DPI and rate changes; `x3-hid apply` sends one
// change at a time. The mouse cannot be read back, so the profile shown is
// the last one the mouse acknowledged, saved by the helper.
Item {
  id: root

  property var battery: Model.emptyBattery()
  property var profile: Model.normalizeProfile(null)
  property bool busy: false
  property string lastError: ""

  readonly property string helperPath: String(Qt.resolvedUrl("x3-hid")).replace(/^file:\/\//, "")
  readonly property string profilePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/attack-shark-x3/profile.json"

  property var _pending: null
  property var _pendingSave: null
  // The job `applyProcess` is sending, kept to compare with the profile when
  // it ends.
  property var _inFlight: null

  function set(path, value) {
    var next = Model.withValue(root.profile, path, value)
    var packets = Model.packetsFor(path, next)
    root.send(next, packets)
  }

  function setStageDpi(index, dpi) {
    var values = root.profile.dpi.slice()
    values[index] = dpi
    root.set("dpi", values)
  }

  function setStageColor(index, color) {
    var values = []
    for (var i = 0; i < root.profile.colors.length; i++) values.push(root.profile.colors[i].slice())
    values[index] = [color[0], color[1], color[2]]
    root.set("colors", values)
  }

  function setStageEnabled(index, enabled) {
    var next = Model.withStageEnabled(root.profile, index, enabled)
    if (next === null) {
      root.lastError = "At least one DPI stage has to stay enabled."
      return
    }
    root.send(next, Model.packetsFor("enabled", next))
  }

  function setButton(slot, option) {
    var next = Model.withButton(root.profile, slot, option)
    if (next === null) {
      root.lastError = "Some button has to keep the left click."
      return
    }
    root.send(next, Model.packetsFor("buttons", next))
  }

  function resetDefaults() {
    root.send(Model.normalizeProfile(Model.FACTORY), Model.factoryPackets())
  }

  // One job waits while another is in flight. A newer change folds into it:
  // the newest profile holds every change, and the job sends each report that
  // any of them touched.
  function send(next, packets) {
    if (packets.length === 0) return
    root.profile = next
    root.lastError = ""
    var waiting = root._pending === null ? [] : root._pending.packets
    root._pending = { profile: next, packets: Model.mergePackets(waiting, packets, next) }
    root.flush()
  }

  function flush() {
    if (applyProcess.running || root._pending === null) return
    var job = root._pending
    root._pending = null
    root._inFlight = job
    root.busy = true
    applyProcess.command = [root.helperPath, "--profile-path", root.profilePath, "apply", JSON.stringify(job.profile)].concat(job.packets)
    applyProcess.running = true
  }

  function queueSave(profile) {
    root._pendingSave = profile
    root.flushSave()
  }

  function flushSave() {
    if (saveProcess.running || root._pendingSave === null) return
    var profile = root._pendingSave
    root._pendingSave = null
    saveProcess.command = [root.helperPath, "--profile-path", root.profilePath, "save", JSON.stringify(profile)]
    saveProcess.running = true
  }

  function loadProfile(text) {
    var raw = null
    try { raw = JSON.parse(String(text || "")) } catch (error) { raw = null }
    root.profile = Model.normalizeProfile(raw)
  }

  function onWatchLine(line) {
    root.battery = Model.applyLine(root.battery, line, Date.now())
    var moved = Model.applyEvent(root.profile, line)
    if (moved === null || JSON.stringify(moved) === JSON.stringify(root.profile)) return
    root.profile = moved
    root.queueSave(moved)
  }

  FileView {
    id: profileFile
    path: root.profilePath
    watchChanges: true
    printErrors: false
    onLoaded: if (!applyProcess.running && root._pending === null && !saveProcess.running && root._pendingSave === null) root.loadProfile(text())
    // No file yet: nothing was applied from Linux, so the mouse is on what
    // the factory restore of docs/re/findings.md left it with.
    onLoadFailed: if (!applyProcess.running && root._pending === null && !saveProcess.running && root._pendingSave === null) root.loadProfile("")
    onFileChanged: reload()
  }

  Process {
    id: watchProcess
    command: [root.helperPath, "--profile-path", root.profilePath, "watch"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.onWatchLine(line) }
    }
    // The helper retries on its own; it only exits on a crash. Start it again
    // after a pause instead of spinning.
    onExited: function(exitCode) {
      root.battery = Model.applyLine(root.battery, "", Date.now())
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 5000
    onTriggered: watchProcess.running = true
  }

  Process {
    id: applyProcess
    running: false
    command: []
    stdout: StdioCollector { id: applyStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var job = root._inFlight
      root._inFlight = null
      root.busy = false
      root.lastError = Model.applyError(applyStdout.text)
      // A refused change leaves the mouse on the saved profile; show that one.
      if (root.lastError !== "" && root._pending === null) profileFile.reload()
      // A mouse-made change (DPI button, rate shortcut) that arrived while the
      // job was in flight is newer than the job's copy; save it again in case
      // the helper's write landed after it (x3-hid apply also guards this).
      // With another job waiting, that job saves the newest profile instead;
      // saving here would record its settings before the mouse ACKs them.
      if (root.lastError === "" && job !== null && root._pending === null && JSON.stringify(root.profile) !== JSON.stringify(job.profile))
        root.queueSave(root.profile)
      root.flush()
    }
  }

  Process {
    id: saveProcess
    running: false
    command: []
    onExited: function(exitCode) { root.flushSave() }
  }
}
