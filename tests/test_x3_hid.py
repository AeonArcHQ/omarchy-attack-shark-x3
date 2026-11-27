import importlib.machinery
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("x3_hid", str(ROOT / "x3-hid"))
spec = importlib.util.spec_from_loader("x3_hid", loader)
x3_hid = importlib.util.module_from_spec(spec)
loader.exec_module(x3_hid)

# A minimal vendor interface descriptor: an application collection on usage
# page 0x0b with feature report 4. Real descriptors carry every feature
# report inside this collection.
FEATURE_COLLECTION = bytes.fromhex("050b0900a101850406008f75089534b102c0")
MOUSE_COLLECTION = bytes.fromhex("05010902a1010901a100850105091901")
# Report 0x06 for polling indices 0..3 (125, 250, 500, 1000 Hz). The same list
# is in tests/tst_model.qml for Model.report6.
POLLING_HEX = ["06090108f700000000", "06090104fb00000000", "06090102fd00000000", "06090101fe00000000"]


def make_node(sysfs, name, hid_id, descriptor, interface=2):
    target = sysfs / "devices" / "pci0000:00" / "0000:00:14.0" / "usb3" / "3-2" / f"3-2:1.{interface}" / hid_id.replace("0003:", "")
    target.mkdir(parents=True)
    (target / "uevent").write_text(f"DRIVER=hid-generic\nHID_ID={hid_id}\n")
    (target / "report_descriptor").write_bytes(descriptor)
    node = sysfs / name
    node.mkdir()
    (node / "device").symlink_to(target, target_is_directory=True)


class FindDevicesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sysfs = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_finds_the_receiver_and_cable_vendor_interfaces(self):
        make_node(self.sysfs, "hidraw1", x3_hid.RECEIVER_HID_ID, FEATURE_COLLECTION)
        make_node(self.sysfs, "hidraw2", x3_hid.CABLE_HID_ID, FEATURE_COLLECTION)
        self.assertEqual(x3_hid.find_devices(self.sysfs),
                         {"receiver": "/dev/hidraw1", "cable": "/dev/hidraw2"})

    def test_requires_interface_2_and_the_feature_collection(self):
        make_node(self.sysfs, "hidraw1", x3_hid.RECEIVER_HID_ID, FEATURE_COLLECTION, interface=1)
        make_node(self.sysfs, "hidraw2", x3_hid.RECEIVER_HID_ID, MOUSE_COLLECTION)
        self.assertEqual(x3_hid.find_devices(self.sysfs), {"receiver": None, "cable": None})

    def test_ignores_other_devices_on_the_same_interface(self):
        make_node(self.sysfs, "hidraw3", "0003:0000046D:0000C52B", FEATURE_COLLECTION)
        self.assertEqual(x3_hid.find_devices(self.sysfs), {"receiver": None, "cable": None})


class DecodeTest(unittest.TestCase):
    # Real report from 2026-11-27 (docs/re/findings.md): 40%, awake.
    def test_power_report_uses_steps_of_ten_percent(self):
        self.assertEqual(x3_hid.decode(bytes.fromhex("0310400104")),
                         {"event": "power", "state": "discharging", "level": 40})

    def test_state_zero_means_asleep(self):
        self.assertEqual(x3_hid.decode(bytes.fromhex("031040000a")),
                         {"event": "power", "state": "asleep", "level": 100})

    def test_battery_only_report_uses_the_same_level_packing(self):
        self.assertEqual(x3_hid.decode(bytes.fromhex("0310600107")),
                         {"event": "power", "state": "discharging", "level": 70})

    def test_power_reports_with_the_wrong_model_or_level_are_ignored(self):
        self.assertIsNone(x3_hid.decode(bytes.fromhex("0300400104")))
        self.assertIsNone(x3_hid.decode(bytes.fromhex("0310400100")))
        self.assertIsNone(x3_hid.decode(bytes.fromhex("031040010b")))
        self.assertIsNone(x3_hid.decode(bytes.fromhex("03104001")))

    # Open question in findings.md: DPI and polling events may carry model 0.
    def test_dpi_and_polling_accept_model_zero_or_x3(self):
        self.assertEqual(x3_hid.decode(bytes.fromhex("0300100400")),
                         {"event": "dpi", "stage": 4})
        self.assertEqual(x3_hid.decode(bytes.fromhex("0310100400")),
                         {"event": "dpi", "stage": 4})
        self.assertEqual(x3_hid.decode(bytes.fromhex("0300200200")),
                         {"event": "polling", "index": 2})
        self.assertEqual(x3_hid.decode(bytes.fromhex("0310200200")),
                         {"event": "polling", "index": 2})

    def test_unknown_events_and_bad_values_are_ignored_without_crashing(self):
        for packet in ("0310700100", "0310800100", "0310100900", "0310200400", "0311500000"):
            self.assertIsNone(x3_hid.decode(bytes.fromhex(packet)), packet)

    def test_cable_presence_synthesizes_charging_with_the_last_measured_level(self):
        self.assertEqual(x3_hid.charging_message("/dev/hidraw9", {"level": 40}),
                         {"ok": True, "event": "power", "device": "/dev/hidraw9",
                          "transport": "cable", "state": "charging", "level": 40})
        self.assertNotIn("level", x3_hid.charging_message("/dev/hidraw9", None))


class CommandTest(unittest.TestCase):
    def test_ack_is_event_50_with_status_in_b3(self):
        self.assertEqual(x3_hid.ack_for(bytes.fromhex("0310500006")), (0x06, 0))
        self.assertEqual(x3_hid.ack_for(bytes.fromhex("0310500106")), (0x06, 1))
        self.assertIsNone(x3_hid.ack_for(bytes.fromhex("0300500006")))
        self.assertIsNone(x3_hid.ack_for(bytes.fromhex("0310400104")))

    def test_report_lengths_are_the_full_lengths_x3_exe_builds(self):
        packets = {
            0x04: bytes([0x04, 0x38, 0x01] + [0] * 53),
            0x05: bytes.fromhex("050f010003a80000ff010401af0000"),
            0x06: bytes.fromhex("06090101fe00000000"),
            0x08: bytes([0x08, 0x3B, 0x01] + [0] * 56),
            0x0C: bytes.fromhex("0c0a01fe01fe00000000"),
        }
        for report_id, packet in packets.items():
            self.assertEqual(x3_hid.parse_packet(packet.hex())[0], report_id)

    def test_reports_are_truncated_to_the_firmware_lengths_for_the_ioctl(self):
        self.assertEqual(len(x3_hid.wire_packet(bytes([0x04, 0x38, 0x01] + [0] * 53))), 52)
        self.assertEqual(x3_hid.wire_packet(bytes.fromhex("050f010003a80000ff010401af0000")).hex(),
                         "050f010003a80000ff010401af")
        self.assertEqual(len(x3_hid.wire_packet(bytes.fromhex("06090101fe00000000"))), 9)
        self.assertEqual(len(x3_hid.wire_packet(bytes([0x08, 0x3B, 0x01] + [0] * 56))), 59)
        self.assertEqual(x3_hid.wire_packet(bytes.fromhex("0c0a01fe01fe00000000")).hex(), "0c0a01fe01fe")

    def test_only_known_reports_with_a_matching_length_are_sent(self):
        for bad in ("06090101fe", "050f0100", "0909010100000000", "zz", ""):
            with self.assertRaises(ValueError, msg=bad):
                x3_hid.parse_packet(bad)

    def test_bad_arguments_never_touch_the_device(self):
        self.assertEqual(x3_hid.apply([]), {"ok": False, "error": "invalid"})
        self.assertEqual(x3_hid.apply(["{}"]), {"ok": False, "error": "invalid"})
        self.assertEqual(x3_hid.apply(["[]", "06090101fe00000000"]), {"ok": False, "error": "invalid"})
        self.assertEqual(x3_hid.apply(["{}", "0803010000"]), {"ok": False, "error": "invalid"})

    def test_the_service_can_pass_one_profile_path_to_every_command(self):
        path = Path("/tmp/x3-test-profile.json")
        self.assertEqual(x3_hid.split_profile_args(["x3-hid", "--profile-path", str(path), "watch"]), (path, ["watch"]))
        self.assertEqual(x3_hid.split_profile_args(["x3-hid", "watch"]), (x3_hid.PROFILE_PATH, ["watch"]))
        self.assertIsNone(x3_hid.split_profile_args(["x3-hid", "--profile-path", str(path)]))

    def test_profile_is_written_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "attack-shark-x3" / "profile.json"
            x3_hid.save_profile({"polling": 3}, path)
            self.assertEqual(path.read_text(), '{\n  "polling": 3\n}\n')
            self.assertFalse(path.with_suffix(".tmp").exists())

    def test_ioctl_number_matches_the_x3_report_length(self):
        self.assertEqual(x3_hid.hidiocsfeature(52), 0xC0344806)
        self.assertEqual(x3_hid.hidiocsfeature(13), 0xC00D4806)


class TransportTest(unittest.TestCase):
    def test_receiver_report_is_retried_until_its_ack_arrives(self):
        packet = x3_hid.parse_packet("06090101fe00000000")
        ioctl_calls = []
        ack_waits = []

        class Clock:
            def __init__(self):
                self.now = 0.0

            def monotonic(self):
                value = self.now
                self.now += 0.6
                return value

        def fake_select(fds, _w, _x, timeout):
            if timeout == 0:
                return [], [], []
            ack_waits.append(timeout)
            if len(ack_waits) <= 4:
                return [], [], []
            return fds, [], []

        with mock.patch.object(x3_hid.os, "open", return_value=7), \
             mock.patch.object(x3_hid.os, "close"), \
             mock.patch.object(x3_hid.os, "read", return_value=bytes.fromhex("0310500006")), \
             mock.patch.object(x3_hid.fcntl, "ioctl", side_effect=lambda fd, op, data: ioctl_calls.append((op, bytes(data)))), \
             mock.patch.object(x3_hid.select, "select", side_effect=fake_select), \
             mock.patch.object(x3_hid.time, "monotonic", side_effect=Clock().monotonic):
            self.assertIsNone(x3_hid.send_packets("/dev/hidraw2", [packet], "receiver"))

        self.assertEqual(len(ioctl_calls), 2)
        self.assertEqual(x3_hid.ACK_SECONDS, 2.0)
        self.assertTrue(all(op == x3_hid.hidiocsfeature(9) for op, _data in ioctl_calls))
        self.assertTrue(all(data == bytes(packet) for _op, data in ioctl_calls))

    def test_receiver_ignores_an_ack_for_another_report(self):
        packet = x3_hid.parse_packet("06090101fe00000000")
        sends = []
        replies = iter([bytes.fromhex("0310500005"), bytes.fromhex("0310500006")])

        def fake_select(fds, _w, _x, timeout):
            return ([], [], []) if timeout == 0 else (fds, [], [])

        class Clock:
            def __init__(self):
                self.now = 0.0

            def monotonic(self):
                value = self.now
                self.now += 0.1
                return value

        with mock.patch.object(x3_hid.os, "open", return_value=7), \
             mock.patch.object(x3_hid.os, "close"), \
             mock.patch.object(x3_hid.os, "read", side_effect=lambda fd, length: next(replies)), \
             mock.patch.object(x3_hid.fcntl, "ioctl", side_effect=lambda fd, op, data: sends.append(bytes(data))), \
             mock.patch.object(x3_hid.select, "select", side_effect=fake_select), \
             mock.patch.object(x3_hid.time, "monotonic", side_effect=Clock().monotonic):
            self.assertIsNone(x3_hid.send_packets("/dev/hidraw2", [packet], "receiver"))

        self.assertEqual(len(sends), 1)

    def test_receiver_gives_up_after_ten_tries(self):
        packet = x3_hid.parse_packet("050f010003a80000ff010401af0000")
        sends = []

        class Clock:
            def __init__(self):
                self.now = 0.0

            def monotonic(self):
                value = self.now
                self.now += 0.6
                return value

        stderr = io.StringIO()
        with mock.patch.object(x3_hid.os, "open", return_value=7), \
             mock.patch.object(x3_hid.os, "close"), \
             mock.patch.object(x3_hid.fcntl, "ioctl", side_effect=lambda fd, op, data: sends.append(bytes(data))), \
             mock.patch.object(x3_hid.select, "select", return_value=([], [], [])), \
             mock.patch.object(x3_hid.time, "monotonic", side_effect=Clock().monotonic), \
             mock.patch.object(x3_hid.sys, "stderr", stderr):
            self.assertEqual(x3_hid.send_packets("/dev/hidraw2", [packet], "receiver"), "timeout")

        self.assertEqual(len(sends), 10)
        self.assertIn("0x05", stderr.getvalue())

    def test_receiver_polling_without_an_ack_times_out_like_any_report(self):
        packet = x3_hid.parse_packet("06090101fe00000000")
        sends = []

        class Clock:
            def __init__(self):
                self.now = 0.0

            def monotonic(self):
                value = self.now
                self.now += 0.6
                return value

        stderr = io.StringIO()
        with mock.patch.object(x3_hid.os, "open", return_value=7), \
             mock.patch.object(x3_hid.os, "close"), \
             mock.patch.object(x3_hid.fcntl, "ioctl", side_effect=lambda fd, op, data: sends.append(bytes(data))), \
             mock.patch.object(x3_hid.select, "select", return_value=([], [], [])), \
             mock.patch.object(x3_hid.time, "monotonic", side_effect=Clock().monotonic), \
             mock.patch.object(x3_hid.sys, "stderr", stderr):
            self.assertEqual(x3_hid.send_packets("/dev/hidraw2", [packet], "receiver"), "timeout")

        self.assertEqual(len(sends), 10)
        self.assertIn("0x06", stderr.getvalue())

    def test_cable_report_is_sent_once_and_gets_no_ack_wait(self):
        packet = x3_hid.parse_packet("06090101fe00000000")
        ioctl_calls = []
        sleeps = []

        def unexpected_read(fd, length):
            raise AssertionError("the cable transport must not wait for an ACK")

        with mock.patch.object(x3_hid.os, "open", return_value=7), \
             mock.patch.object(x3_hid.os, "close"), \
             mock.patch.object(x3_hid.os, "read", side_effect=unexpected_read), \
             mock.patch.object(x3_hid.fcntl, "ioctl", side_effect=lambda fd, op, data: ioctl_calls.append(bytes(data))), \
             mock.patch.object(x3_hid.time, "sleep", side_effect=sleeps.append):
            self.assertIsNone(x3_hid.send_packets("/dev/hidraw9", [packet], "cable"))

        self.assertEqual(ioctl_calls, [bytes(packet)])
        self.assertEqual(sleeps, [0.5])

    def test_watch_nodes_open_for_feature_writes(self):
        with mock.patch.object(x3_hid.os, "open", return_value=7) as open_node:
            fds = x3_hid._open_inputs({"receiver": "/dev/hidraw2", "cable": None})
        self.assertEqual(fds, {7: "/dev/hidraw2"})
        open_node.assert_called_once_with("/dev/hidraw2", x3_hid.os.O_RDWR | x3_hid.os.O_NONBLOCK)

    def test_polling_packet_matches_model_js_report6_for_every_rate(self):
        # tests/tst_model.qml pins Model.report6 to the same hex.
        self.assertEqual([x3_hid.polling_packet(i).hex() for i in range(4)], POLLING_HEX)

    def test_saved_polling_packet_uses_the_saved_rate_and_falls_back_to_1000hz(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "profile.json"
            path.write_text('{"polling": 1}\n')
            self.assertEqual(x3_hid.saved_polling_packet(path).hex(), "06090104fb00000000")
            path.write_text('{"polling": 9}\n')
            self.assertEqual(x3_hid.saved_polling_packet(path).hex(), "06090101fe00000000")
            path.unlink()
            self.assertEqual(x3_hid.saved_polling_packet(path).hex(), "06090101fe00000000")

    def test_priming_the_receiver_sends_one_saved_polling_report(self):
        ioctls = []
        with mock.patch.object(x3_hid, "saved_polling_packet", return_value=x3_hid.polling_packet(1)), \
             mock.patch.object(x3_hid.fcntl, "ioctl", side_effect=lambda fd, op, data: ioctls.append((op, bytes(data)))):
            x3_hid.prime_receiver({7: "/dev/hidraw2"}, "/dev/hidraw2")
        self.assertEqual(ioctls, [(x3_hid.hidiocsfeature(9), x3_hid.polling_packet(1))])

    def test_watch_primes_the_receiver_when_it_opens(self):
        fds = {7: "/dev/hidraw2"}
        with mock.patch.object(x3_hid, "find_devices", return_value={"receiver": "/dev/hidraw2", "cable": None}), \
             mock.patch.object(x3_hid, "_open_inputs", return_value=fds), \
             mock.patch.object(x3_hid, "prime_receiver") as prime, \
             mock.patch.object(x3_hid.select, "select", side_effect=KeyboardInterrupt), \
             mock.patch.object(x3_hid.os, "close"):
            with self.assertRaises(KeyboardInterrupt):
                x3_hid.watch()
        prime.assert_called_once_with(fds, "/dev/hidraw2", x3_hid.PROFILE_PATH)

    def test_apply_prefers_the_cable_node_and_saves_only_after_success(self):
        packet = "06090101fe00000000"
        sent = []
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "profile.json"
            with mock.patch.object(x3_hid, "find_devices", return_value={"receiver": "/dev/hidraw2", "cable": "/dev/hidraw9"}), \
                 mock.patch.object(x3_hid, "send_packets", side_effect=lambda device, packets, transport: sent.append((device, packets, transport)) or None):
                self.assertEqual(x3_hid.apply(['{"polling": 3}', packet], path), {"ok": True})
            self.assertEqual(sent[0][0], "/dev/hidraw9")
            self.assertEqual(sent[0][2], "cable")
            self.assertEqual(json.loads(path.read_text()), {"polling": 3})

            path.unlink()
            with mock.patch.object(x3_hid, "find_devices", return_value={"receiver": "/dev/hidraw2", "cable": None}), \
                 mock.patch.object(x3_hid, "send_packets", return_value="timeout"):
                self.assertEqual(x3_hid.apply(['{"polling": 3}', packet], path), {"ok": False, "error": "timeout"})
            self.assertFalse(path.exists())

    def test_a_dpi_event_saved_while_apply_waits_survives_the_successful_apply(self):
        packet = "06090102fd00000000"
        old = {"polling": 3, "stage": 1}
        job = {"polling": 2, "stage": 1}
        current = {"polling": 2, "stage": 3}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "profile.json"
            x3_hid.save_profile(old, path)

            def dpi_button_during_ack_wait(_device, _packets, _transport):
                x3_hid.save_profile(current, path)
                return None

            with mock.patch.object(x3_hid, "find_devices", return_value={"receiver": "/dev/hidraw2", "cable": None}), \
                 mock.patch.object(x3_hid, "send_packets", side_effect=dpi_button_during_ack_wait):
                self.assertEqual(x3_hid.apply([json.dumps(job), packet], path), {"ok": True})
            self.assertEqual(json.loads(path.read_text()), current)


if __name__ == "__main__":
    unittest.main()
