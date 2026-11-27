import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar entry and popup for the ATTACK SHARK X3. Same structure as the
// first-party panels: one Service child owns the processes, the popup is a
// KeyboardPanel, and the protocol and UI rules live in Model.js where
// tests/tst_model.qml covers them.
Panel {
  id: root
  moduleName: "com.aeonarc.attack-shark-x3"
  ipcTarget: "com.aeonarc.attack-shark-x3"
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var view: Model.barView(x3.battery, root.setting("showPercentage", true), Commons.I18n.formatNumber)
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes (power/Panel.qml).
  readonly property real openPanelIndicatorWidth: root.setting("showPercentage", true) && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property var p: x3.profile

  // Restoring defaults takes two clicks; the second must come within 5 s.
  property bool confirmingReset: false
  Timer {
    id: resetConfirmTimer
    interval: 5000
    onTriggered: root.confirmingReset = false
  }

  // Scroll the panel by a wheel step; sliders hand their wheel events here so
  // scrolling past them does not change the mouse.
  function scrollBy(wheel) {
    var dy = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 2
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY - dy))
  }

  function stageOptions() {
    var options = []
    for (var i = 0; i < root.p.stages; i++) options.push({ value: i, label: Model.dpiLabel(root.p.dpi[i]) })
    return options
  }

  onOpenedChanged: if (opened) {
    confirmingReset = false
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: x3
  }

  // Same IPC as the shell's battery widget (power/Panel.qml), plus the mouse
  // settings.
  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function togglePercentage(): void { root.togglePercentage() }
    function status(): string { return x3.battery.connection + " " + x3.battery.level }
    function resetDefaults(): string { x3.resetDefaults(); return "ok" }
    // e.g. set polling 2, set stage 0, set deepSleep 10
    function set(path: string, value: string): string {
      var parsed = null
      try { parsed = JSON.parse(value) } catch (error) { return "invalid value" }
      x3.set(path, parsed)
      return "sent"
    }
    function lastError(): string { return x3.busy ? "busy" : x3.lastError }
  }

  // A right click flips the percentage and saves the choice, as the shell's
  // battery widget does (shell/plugins/panels/power/Panel.qml).
  function togglePercentage(): void {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.setting("showPercentage", true) })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.view.glyph
    labelText: root.view.label !== "" && !button.vertical ? root.view.label : ""
    slotSize: Style.bar.iconSlot * (root.view.label !== "" && !button.vertical ? 2 : 1)
    active: root.view.active
    dimmed: root.view.dimmed
    tooltipText: Model.tooltip(x3.battery, null, x3.profile, x3.stageKnown)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Battery ----------
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: x3.battery.level >= 0 ? x3.battery.level + "%" : "—"
              color: root.view.active ? (root.bar ? root.bar.urgent : Commons.Color.urgent) : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              textFormat: Text.PlainText
            }
            Text {
              width: parent.width
              text: Model.statusLine(x3.battery, null, x3.profile, x3.stageKnown)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }
          }

          Text {
            width: parent.width
            visible: x3.lastError !== ""
            text: x3.lastError
            color: root.bar ? root.bar.urgent : Commons.Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          // ---------- DPI ----------
          Section {
            title: "DPI"
            note: "The mouse's DPI button cycles through the active stages."

            Flow {
              width: parent.width
              spacing: Style.spacing.md
              Repeater {
                model: root.stageOptions()
                delegate: Button {
                  required property var modelData
                  text: modelData.label
                  selected: modelData.value === root.p.stage
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onClicked: x3.set("stage", modelData.value)
                }
              }
            }
            ValueSlider {
              label: "DPI of stage " + (root.p.stage + 1)
              minimum: Model.DPI_MIN
              maximum: Model.DPI_MAX
              step: 50
              value: root.p.dpi[root.p.stage]
              onCommitted: function(v) { x3.setStageDpi(root.p.stage, v) }
            }
            Row {
              spacing: Style.space(8)
              // The colours edit the selected stage: keep them away from "Active stages".
              bottomPadding: Style.space(24)
              Repeater {
                model: Model.COLOR_PRESETS
                delegate: Rectangle {
                  required property var modelData
                  readonly property var swatch: modelData
                  readonly property bool selected: Model.colorHex(swatch) === Model.colorHex(root.p.colors[root.p.stage])
                  width: Style.space(26)
                  height: width
                  radius: width / 2
                  color: Model.colorHex(swatch)
                  border.width: selected ? Style.space(3) : 1
                  border.color: selected ? root.fg : root.dim
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: x3.setStageColor(root.p.stage, parent.swatch)
                  }
                }
              }
            }
            ValueSlider {
              label: "Active stages"
              minimum: 1
              maximum: Model.USER_STAGES
              value: root.p.stages
              onCommitted: function(v) { x3.set("stages", v) }
            }
          }

          // ---------- Polling ----------
          Section {
            title: "POLLING RATE"
            ChoiceRow {
              options: Model.POLLING_RATES.map(function(hz, i) { return { value: String(i), label: hz + " Hz" } })
              value: String(root.p.polling)
              onPicked: function(v) { x3.set("polling", Number(v)) }
            }
          }

          // ---------- Sensor ----------
          Section {
            title: "SENSOR"

            ChoiceRow {
              options: [{ value: "0", label: "Lift 1 mm" }, { value: "1", label: "Lift 2 mm" }]
              value: String(root.p.lift)
              onPicked: function(v) { x3.set("lift", Number(v)) }
            }
            SwitchRow {
              label: "Motion sync"
              checked: root.p.motionSync === 1
              onFlipped: x3.set("motionSync", root.p.motionSync === 1 ? 0 : 1)
            }
            SwitchRow {
              label: "Ripple control"
              checked: root.p.ripple === 1
              onFlipped: x3.set("ripple", root.p.ripple === 1 ? 0 : 1)
            }
            SwitchRow {
              label: "Angle snapping"
              checked: root.p.angle === 1
              onFlipped: x3.set("angle", root.p.angle === 1 ? 0 : 1)
            }
          }

          // ---------- Buttons ----------
          Section {
            title: "BUTTONS"
            note: "Some button has to keep the left click."

            Repeater {
              model: Model.PHYSICAL_BUTTONS
              delegate: Item {
                required property var modelData
                width: parent ? parent.width : 0
                implicitHeight: buttonMenu.implicitHeight

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width * 0.4
                  text: modelData.label
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }
                Dropdown {
                  id: buttonMenu
                  anchors.right: parent.right
                  width: parent.width * 0.6
                  showLabel: false
                  options: Model.BUTTON_OPTIONS
                  value: Model.buttonOption(root.p.buttons[modelData.slot])
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  onChanged: function(v) { x3.setButton(modelData.slot, v) }
                }
              }
            }
          }

          // ---------- Power ----------
          Section {
            title: "POWER AND CLICK"

            ValueSlider {
              label: "Sleep Time"
              minimum: 1
              maximum: 60
              value: root.p.sleepTime
              format: function(v) {
                if (v === 1) return "30 s"
                return (v % 2 === 0 ? String(v / 2) : (v / 2).toFixed(1)) + " min"
              }
              onCommitted: function(v) { x3.set("sleepTime", v) }
            }
            ValueSlider {
              label: "Deep Sleep"
              minimum: 1
              maximum: 60
              value: root.p.deepSleep
              format: function(v) { return v + " min" }
              onCommitted: function(v) { x3.set("deepSleep", v) }
            }
            ValueSlider {
              label: "Debounce"
              minimum: 2
              maximum: 25
              value: root.p.debounce
              format: function(v) { return (v * 2) + " ms" }
              onCommitted: function(v) { x3.set("debounce", v) }
            }
          }

          // ---------- Defaults ----------
          Section {
            title: "FACTORY DEFAULTS"
            note: root.confirmingReset ? "Click again to confirm."
              : "Resets DPI, polling, sensor, timers and buttons to the ATTACK SHARK driver defaults."

            Button {
              width: parent.width
              text: root.confirmingReset ? "Confirm reset" : "Restore factory settings"
              bordered: true
              selected: root.confirmingReset
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: {
                if (!root.confirmingReset) {
                  root.confirmingReset = true
                  resetConfirmTimer.restart()
                  return
                }
                root.confirmingReset = false
                resetConfirmTimer.stop()
                x3.resetDefaults()
              }
            }
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }

  // A titled block, laid out like the sections of omarchy.monitor.
  component Section: Column {
    property string title: ""
    property string note: ""
    default property alias rows: body.data

    width: parent ? parent.width : 0
    spacing: Style.space(6)
    enabled: x3.battery.connection !== "missing" && x3.battery.connection !== "access-denied"
    opacity: enabled ? 1 : 0.45

    PanelSeparator { width: parent.width; foreground: root.fg }
    PanelSectionHeader { text: parent.title; foreground: root.fg; fontFamily: root.fontFamily }
    Text {
      width: parent.width
      visible: parent.note !== ""
      text: parent.note
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
    }
    Column {
      id: body
      width: parent.width
      spacing: Style.space(8)
    }
  }

  component ChoiceRow: ButtonGroup {
    signal picked(string value)

    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { picked(v) }
  }

  // A plain row with the compact switch on the trailing edge, as in the
  // first-party audio and network panels; the whole row flips it.
  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property bool checked: false
    signal flipped()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowLabel.implicitHeight, rowSwitch.implicitHeight)

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: function() { switchRow.flipped() }
    }
    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.right: rowSwitch.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: switchRow.label
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }
    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      foreground: root.fg
      onToggled: switchRow.flipped()
    }
  }

  // Header with the live value on the right, then the slider. The mouse only
  // hears the value where the drag ends.
  component ValueSlider: Column {
    id: valueSlider
    property string label: ""
    property real minimum: 0
    property real maximum: 1
    property real step: 1
    property real value: 0
    property var format: function(v) { return String(Math.round(v)) }
    signal committed(int value)

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

      Text {
        id: labelText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: valueSlider.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        textFormat: Text.PlainText
      }
      Text {
        id: valueText
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: valueSlider.format(Math.round(slider.dragging ? slider.liveValue : valueSlider.value))
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        textFormat: Text.PlainText
      }
    }

    PanelSlider {
      id: slider
      bar: root.bar
      width: parent.width
      minimum: valueSlider.minimum
      maximum: valueSlider.maximum
      step: valueSlider.step
      integer: true
      value: valueSlider.value
      onReleased: function(v) {
        var snapped = Math.round(v / valueSlider.step) * valueSlider.step
        if (snapped !== valueSlider.value) valueSlider.committed(snapped)
      }

      // Above the slider's own MouseArea: takes only the wheel, so clicks and
      // drags still reach the slider and the wheel scrolls the panel.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: function(wheel) { root.scrollBy(wheel) }
      }
    }
  }
}
