import QtQuick
import QtTest
import "../Model.js" as Model

TestCase {
  name: "AttackSharkX3Model"

  function line(object) { return JSON.stringify(object) }

  function test_a_power_line_makes_the_widget_ready() {
    var m = Model.applyLine(null, line({ ok: true, device: "/dev/hidraw2", transport: "receiver", event: "power", state: "discharging", level: 40 }), 1000)
    compare(m, { connection: "ready", state: "discharging", level: 40, measuredAt: 1000, transport: "receiver" })
    compare(Model.barView(m, true).label, "40%")
    compare(Model.barView(m, false).label, "")
    compare(Model.tooltip(m), "Attack Shark X3 · 40% · on battery · receiver")
  }

  function test_tooltip_shows_the_current_dpi_stage_live() {
    var m = Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 40, transport: "receiver" }))
    var p = Model.normalizeProfile(null)
    compare(Model.tooltip(m, null, p, true), "Attack Shark X3 · 40% · on battery · receiver · DPI 1600 (stage 2)")
    compare(Model.tooltip(m, null, Model.withValue(p, "stage", 3), true), "Attack Shark X3 · 40% · on battery · receiver · DPI 3200 (stage 4)")
    var asleep = Model.applyLine(m, line({ ok: false, error: "asleep" }))
    compare(Model.tooltip(asleep, null, p, true), "Attack Shark X3 · the receiver stopped sending events (last: 40%) · DPI 1600 (stage 2)")
  }

  function test_the_bar_glyph_is_always_the_mouse() {
    var wireless = Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 40, transport: "receiver" }))
    compare(Model.barView(wireless, true).glyph, Model.GLYPH_MOUSE)
    var cable = Model.applyLine(wireless, line({ ok: true, event: "power", state: "charging", transport: "cable" }))
    compare(Model.barView(cable, true).glyph, Model.GLYPH_MOUSE)
    compare(Model.barView(null, true).glyph, Model.GLYPH_MOUSE)
  }

  function test_asleep_dims_the_icon_but_keeps_the_level() {
    var m = Model.applyLine(null, line({ ok: true, event: "power", state: "asleep", level: 70, transport: "receiver" }))
    compare(m.state, "asleep")
    compare(Model.barView(m, true).dimmed, true)
    compare(Model.barView(m, true).label, "70%")
    compare(Model.tooltip(m), "Attack Shark X3 · 70% · asleep · receiver")
  }

  function test_charging_without_a_level_keeps_the_last_measurement() {
    var ready = Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 40, transport: "receiver" }), 1000)
    var cable = Model.applyLine(ready, line({ ok: true, event: "power", state: "charging", transport: "cable" }), 2000)
    compare(cable.level, 40)
    compare(cable.measuredAt, 1000)
    var at = function(ms) { return ms === 1000 ? "19:12" : "??:??" }
    compare(Model.tooltip(cable, at), "Attack Shark X3 · 40% · charging · cable\nlast measured at 19:12")
    var freshCable = Model.applyLine(null, line({ ok: true, event: "power", state: "charging", transport: "cable" }), 3000)
    compare(freshCable.level, -1)
    compare(Model.barView(freshCable, true).label, "")
    compare(Model.tooltip(freshCable), "Attack Shark X3 · charging · cable")
  }

  function test_errors_dim_the_icon_and_keep_the_last_level() {
    var ready = Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 100 }))
    var asleep = Model.applyLine(ready, line({ ok: false, error: "asleep" }))
    compare(asleep.connection, "asleep")
    compare(Model.barView(asleep, true).dimmed, true)
    compare(Model.tooltip(asleep), "Attack Shark X3 · the receiver stopped sending events (last: 100%)")
    var charging = Model.applyLine(null, line({ ok: true, event: "power", state: "charging", transport: "cable" }))
    var denied = Model.applyLine(charging, line({ ok: false, error: "access-denied" }))
    compare(Model.barView(denied, true).glyph, Model.GLYPH_MOUSE)
  }

  function test_every_error_has_a_notice() {
    var codes = ["missing", "access-denied", "asleep", "nonsense"]
    for (var i = 0; i < codes.length; i++) {
      var m = Model.applyLine(null, line({ ok: false, error: codes[i] }))
      verify(Model.tooltip(m).indexOf("undefined") === -1, codes[i])
    }
    compare(Model.applyLine(null, "not json").connection, "error")
    compare(Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 300 })).connection, "error")
    compare(Model.tooltip(null), "Attack Shark X3 · reading the mouse")
  }

  function test_factory_report5_matches_the_factory_bytes() {
    compare(Model.report5(Model.normalizeProfile(null)), "050f010003a80000ff010401af0000")
  }

  function test_report5_lays_out_sleep_time_deep_sleep_and_debounce() {
    var p = Model.withValue(Model.normalizeProfile(null), "deepSleep", 20)
    p = Model.withValue(p, "sleepTime", 12)
    compare(Model.report5(p), "050f010013480000ff0c04016a0000")
  }

  function test_factory_report6_matches_the_factory_bytes() {
    compare(Model.report6(Model.normalizeProfile(null)), "06090101fe00000000")
  }

  // Same list as POLLING_HEX in tests/test_x3_hid.py for x3-hid's polling_packet.
  function test_report6_matches_the_helper_polling_packet_for_every_rate() {
    var expected = ["06090108f700000000", "06090104fb00000000", "06090102fd00000000", "06090101fe00000000"]
    var p = Model.normalizeProfile(null)
    for (var i = 0; i < 4; i++) compare(Model.report6(Model.withValue(p, "polling", i)), expected[i])
  }

  function test_status_line_omits_dpi_until_the_stage_is_known() {
    var p = Model.normalizeProfile(null)
    var ready = Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 40, transport: "receiver" }), 1000)
    compare(Model.statusLine(ready, null, p, false), "on battery · receiver")
    compare(Model.statusLine(ready, null, p, true), "on battery · receiver · DPI 1600 (stage 2)")
    compare(Model.tooltip(ready, null, p, false), "Attack Shark X3 · 40% · on battery · receiver")
    compare(Model.tooltip(ready, null, p, true), "Attack Shark X3 · 40% · on battery · receiver · DPI 1600 (stage 2)")
    var cable = Model.applyLine(ready, line({ ok: true, event: "power", state: "charging", transport: "cable" }), 2000)
    var at = function(ms) { return "19:12" }
    compare(Model.statusLine(cable, at), "charging · cable\nlast measured at 19:12")
    var asleep = Model.applyLine(ready, line({ ok: false, error: "asleep" }))
    compare(Model.statusLine(asleep, null, p, true), "the receiver stopped sending events (last: 40%) · DPI 1600 (stage 2)")
    compare(Model.statusLine(null), "reading the mouse")
  }

  function test_bar_label_uses_the_given_number_format() {
    var m = Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 40 }))
    compare(Model.barView(m, true, function(n) { return "<" + n + ">" }).label, "<40>%")
  }

  function test_state_json_has_the_ipc_shape_with_a_one_based_stage() {
    var p = Model.normalizeProfile({ stage: 3, stageKnown: true })
    var b = Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 40, transport: "receiver" }))
    var state = JSON.parse(Model.stateJson(true, "The mouse is asleep. Move it and try again.", p, true, b))
    compare(state, {
      busy: true,
      error: "The mouse is asleep. Move it and try again.",
      stage: 4,
      stageKnown: true,
      battery: 40,
      connection: "ready"
    })
    var empty = JSON.parse(Model.stateJson(false, "", Model.normalizeProfile(null), false, null))
    compare(empty, { busy: false, error: "", stage: 2, stageKnown: false, battery: -1, connection: "starting" })
  }

  function test_factory_report8_matches_the_factory_bytes() {
    compare(Model.report8(Model.FACTORY_BUTTONS),
      "083b01" + "020000" + "030000" + "040000" + "0d0000" + "3c0000" + "0f0000"
      + "060000" + "050000" + "3c0000" + "010000010000010000010000010000010000010000"
      + "0a0000" + "090000" + "00c2")
  }

  // The checksum expectation is summed independently here; the other bytes
  // are pinned against the factory table in docs/re/findings.md.
  function test_factory_report4_carries_the_factory_dpi_table_and_sensor_defaults() {
    var hex = Model.report4(Model.normalizeProfile(null))
    compare(hex, "04380100003f00000f1f2f3f63070f0f000000000002000002ff000000ff000000ffffff0000ffffff00ffff4000ffffff010e9b00000000")
    compare(hex.length, 56 * 2)
    compare(hex.substr(0, 6), "043801")
    compare(hex.substr(6, 10), "00003f0000")  // lift, ripple, mask 0x3f, angle, motion sync
    compare(hex.substr(16, 16), "0f1f2f3f63070f0f")  // low bytes of dpi/50 - 1; slots 7-8 are the factory 800 DPI
    compare(hex.substr(32, 16), "0000000000020000")  // high bytes; 26000 is 0x0207
    compare(hex.substr(48, 2), "02")  // current stage 2 is stored as stage + 1
    compare(hex.substr(50, 48), "ff000000ff000000ffffff0000ffffff00ffff4000ffffff")
    compare(hex.substr(98, 2), "01")
    var sum = 0
    for (var i = 3; i <= 49; i++) sum += parseInt(hex.substr(i * 2, 2), 16)
    sum = sum & 0xffff
    compare(parseInt(hex.substr(100, 4), 16), sum)
    compare(hex.substr(104), "00000000")
  }

  function test_hidden_dpi_slots_always_keep_the_factory_bytes() {
    var dpi = [800, 1600, 2400, 3200, 5000, 26000, 1000, 1200]
    var colors = []
    for (var i = 0; i < 8; i++) colors.push([1, 2, 3])
    var p = Model.normalizeProfile({ dpi: dpi, colors: colors })
    compare(p.dpi.slice(6), [800, 800])
    compare(p.colors.slice(6), Model.FACTORY.colors.slice(6))
    var hex = Model.report4(p)
    compare(hex.substr(10, 2), "3f")
    compare(hex.substr(16 + 6 * 2, 4), "0f0f")
    compare(hex.substr(50 + 18 * 2, 12), "ff4000ffffff")
  }

  function test_profile_values_are_clamped() {
    var p = Model.normalizeProfile({ dpi: [10, 26050, 1234, 1600, 3200, 5000, 800, 800], polling: 9, sleepTime: 0, deepSleep: 90, debounce: 40 })
    compare(p.dpi.slice(0, 3), [50, 26000, 1250])
    compare(p.polling, 3)
    compare(p.sleepTime, 1)
    compare(p.deepSleep, 60)
    compare(p.debounce, 25)
    compare(Model.normalizeProfile({ dpi: [77] }).dpi[0], 800)  // wrong length: factory table
  }

  function test_saved_stage_colors_survive_normalising_and_use_the_dpi_report() {
    var colors = [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12], [13, 14, 15], [16, 17, 18], [19, 20, 21], [22, 23, 24]]
    var p = Model.normalizeProfile({ colors: colors })
    compare(p.colors.slice(0, 6), colors.slice(0, 6))
    compare(p.colors.slice(6), Model.FACTORY.colors.slice(6))
    compare(Model.packetsFor("colors", p), [Model.report4(p)])
    compare(Model.report4(p).substr(50, 6), "010203")
    compare(Model.colorHex(p.colors[0]), "#010203")
  }

  function test_stage_colors_are_clamped_and_bad_entries_fall_back() {
    var colors = []
    for (var i = 0; i < 8; i++) colors.push([300, -1, 3])
    colors[3] = [1]
    var p = Model.normalizeProfile({ colors: colors })
    compare(p.colors[0], [255, 0, 3])
    compare(p.colors[3], Model.FACTORY.colors[3])
  }

  function test_active_stage_count_is_clamped_and_maps_to_the_report_mask() {
    compare(Model.normalizeProfile({ stages: 0 }).stages, 1)
    compare(Model.normalizeProfile({ stages: 9 }).stages, 6)
    var p = Model.normalizeProfile({ stages: 2, stage: 5 })
    compare(p.stage, 1)
    compare(Model.report4(p).substr(10, 2), "03")
    compare(Model.packetsFor("stages", p), [Model.report4(p)])
  }

  function test_an_old_per_stage_enable_profile_converts_to_a_leading_count() {
    var converted = Model.normalizeProfile({ enabled: [1, 1, 0, 1, 1, 1, 1, 1], stage: 4 })
    compare(converted.stages, 2)
    compare(converted.stage, 1)
    compare(converted.enabled, undefined)
    compare(Model.report4(converted).substr(10, 2), "03")
    compare(Model.normalizeProfile({ enabled: [0, 1, 1, 1, 1, 1, 1, 1] }).stages, 1)
    compare(Model.normalizeProfile({ enabled: [1, 1, 1, 1, 1, 1, 1, 1] }).stages, 6)
  }

  function test_the_color_picker_offers_only_the_six_factory_user_colors() {
    compare(Model.COLOR_PRESETS, [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [0, 255, 255], [255, 0, 255]])
  }

  function test_receiver_events_move_the_saved_stage_and_rate() {
    var p = Model.normalizeProfile(null)
    compare(Model.applyEvent(p, line({ ok: true, event: "dpi", stage: 4 })).stage, 3)
    compare(Model.applyEvent(p, line({ ok: true, event: "polling", index: 2 })).polling, 2)
    compare(Model.applyEvent(p, line({ ok: true, event: "power", state: "discharging", level: 40 })), null)
  }

  function test_only_a_dpi_event_or_an_acked_report4_makes_the_stage_known() {
    var p = Model.normalizeProfile(null)
    compare(p.stageKnown, false)
    compare(Model.applyEvent(p, line({ ok: true, event: "dpi", stage: 4 })).stageKnown, true)
    compare(Model.applyEvent(p, line({ ok: true, event: "polling", index: 2 })).stageKnown, false)
    compare(Model.stageKnownAfterEvent(false, { ok: true, event: "dpi", stage: 4 }), true)
    compare(Model.stageKnownAfterEvent(false, { ok: true, event: "polling", index: 2 }), false)
    compare(Model.stageKnownAfterEvent(true, { ok: true, event: "polling", index: 2 }), true)
    var others = Model.packetsFor("sleepTime", p).concat(Model.packetsFor("polling", p), Model.packetsFor("buttons", p))
    compare(Model.stageKnownAfterApply(false, others), false)
    compare(Model.stageKnownAfterApply(true, others), true)
    compare(Model.stageKnownAfterApply(false, others.concat(Model.packetsFor("stage", p))), true)
    compare(Model.stageKnownAfterApply(false, Model.factoryPackets()), true)
  }

  function test_a_saved_profile_keeps_the_stage_known_only_when_it_says_so() {
    compare(Model.normalizeProfile({ stage: 3 }).stageKnown, false)
    compare(Model.normalizeProfile({ stage: 3, stageKnown: "yes" }).stageKnown, false)
    compare(Model.normalizeProfile({ stage: 3, stageKnown: true }).stageKnown, true)
    var known = Model.withValue(Model.normalizeProfile(null), "stageKnown", true)
    compare(Model.normalizeProfile(JSON.parse(JSON.stringify(known))).stageKnown, true)
    compare(Model.packetsFor("stageKnown", known), [])
  }

  function test_dpi_events_do_not_disturb_the_battery_state() {
    var ready = Model.applyLine(null, line({ ok: true, event: "power", state: "charging", level: 50, transport: "cable" }))
    compare(Model.applyLine(ready, line({ ok: true, event: "dpi", stage: 2, transport: "cable" })), ready)
  }

  function test_measured_at_marks_when_the_level_was_measured() {
    var m = Model.applyLine(null, line({ ok: true, event: "power", state: "discharging", level: 40 }), 1000)
    compare(m.measuredAt, 1000)
    var repeated = Model.applyLine(m, line({ ok: true, event: "power", state: "discharging", level: 40 }), 2000)
    compare(repeated.measuredAt, 2000)
    var fresh = Model.applyLine(repeated, line({ ok: true, event: "power", state: "discharging", level: 50 }), 3000)
    compare(fresh.measuredAt, 3000)
    var asleep = Model.applyLine(fresh, line({ ok: false, error: "asleep" }), 4000)
    compare(asleep.measuredAt, 3000)
    var dpi = Model.applyLine(fresh, line({ ok: true, event: "dpi", stage: 2 }), 5000)
    compare(dpi.measuredAt, 3000)
  }

  function test_apply_errors_tell_what_to_do() {
    compare(Model.applyError('{"ok": true}'), "")
    compare(Model.applyError('{"ok": false, "error": "timeout"}'), "The mouse is asleep. Move it and try again.")
    compare(Model.applyError('{"ok": false, "error": "other-mouse"}'), "Another mouse's receiver is plugged in. Plug in the X3 receiver.")
    verify(Model.applyError("").length > 0)
    verify(Model.applyError('{"ok": false, "error": "weird"}').length > 0)
  }

  function test_shortcut_slot_and_left_click_guard() {
    var layout = Model.FACTORY_BUTTONS.slice()
    layout[6] = { shortcut: [1, 0x06] }  // Ctrl+C on the forward button
    compare(Model.report8(layout).substr(6 + 6 * 6, 6), "110106")
    var noLeft = Model.FACTORY_BUTTONS.slice()
    noLeft[0] = "right"
    compare(Model.report8(noLeft), "")
    compare(Model.report8(["left"]), "")
  }

  function test_button_options_round_trip_and_keep_a_left_click() {
    var p = Model.withButton(Model.normalizeProfile(null), 7, "shortcut:copy")
    compare(p.buttons[7], { shortcut: [1, 6] })
    compare(Model.buttonOption(p.buttons[7]), "shortcut:copy")
    compare(Model.withButton(p, 0, "right"), null)
    compare(Model.withButton(p, 0, "nonsense"), null)
    var moved = Model.withButton(Model.withButton(p, 6, "left"), 0, "right")
    compare(moved.buttons[0], "right")
  }

  function test_saved_buttons_survive_normalising() {
    var p = Model.withButton(Model.normalizeProfile(null), 6, "volumeUp")
    compare(Model.normalizeProfile(JSON.parse(JSON.stringify(p))).buttons, p.buttons)
    compare(Model.normalizeProfile({ buttons: ["left"] }).buttons, Model.FACTORY_BUTTONS)
  }

  function test_the_physical_buttons_are_the_five_visible_in_x3_exe() {
    compare(Model.PHYSICAL_BUTTONS.map(function(b) { return b.slot }), [0, 1, 2, 6, 7])
  }

  function test_a_change_folded_into_a_waiting_one_keeps_both_reports() {
    var p = Model.normalizeProfile(null)
    var a = Model.withValue(p, "deepSleep", 12)
    var b = Model.withValue(a, "polling", 2)
    var merged = Model.mergePackets(Model.packetsFor("deepSleep", a), Model.packetsFor("polling", b), b)
    compare(merged, [Model.report5(b), Model.report6(b)])
    compare(Model.mergePackets(Model.factoryPackets(), Model.packetsFor("polling", b), b).length, 5)
  }
}
