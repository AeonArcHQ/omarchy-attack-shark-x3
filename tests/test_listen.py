import importlib.util
import io
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("x3_listen", ROOT / "tools" / "listen.py")
listen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(listen)


class DescribeReportTest(unittest.TestCase):
    def test_report3_events_get_their_kind_and_decoded_fields(self):
        self.assertEqual(listen.describe_report(bytes.fromhex("0310400104")),
                         ("power", "state=discharging level=40"))
        self.assertEqual(listen.describe_report(bytes.fromhex("0300100400")),
                         ("dpi", "stage=4"))
        self.assertEqual(listen.describe_report(bytes.fromhex("0300200200")),
                         ("polling", "index=2"))
        self.assertEqual(listen.describe_report(bytes.fromhex("0310500006")),
                         ("ack", "report=0x06 status=0"))

    def test_other_report3_events_are_still_printed_as_unknown(self):
        kind, details = listen.describe_report(bytes.fromhex("0310700100"))
        self.assertEqual(kind, "unknown")
        self.assertIn("event=0x70", details)

    def test_non_report3_is_ignored(self):
        self.assertIsNone(listen.describe_report(bytes.fromhex("0210400104")))
        self.assertIsNone(listen.describe_report(bytes.fromhex("0310")))


class MainTest(unittest.TestCase):
    def test_the_listener_watches_every_receiver_candidate(self):
        with mock.patch.object(listen.x3_hid, "find_devices",
                               return_value={"receiver": ["/dev/hidraw2", "/dev/hidraw4"], "cable": None}), \
             mock.patch.object(listen, "listen") as run:
            self.assertEqual(listen.main([]), 0)
        run.assert_called_once_with(["/dev/hidraw2", "/dev/hidraw4"], None)

    def test_a_missing_receiver_is_reported(self):
        with mock.patch.object(listen.x3_hid, "find_devices",
                               return_value={"receiver": [], "cable": None}), \
             mock.patch.object(listen, "listen") as run, \
             mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            self.assertEqual(listen.main([]), 1)
        run.assert_not_called()
        self.assertIn("not found", err.getvalue())


class ListenTest(unittest.TestCase):
    def run_listen(self, devices, reports):
        """Run listen() over fake fds; `reports` maps a path to its reports in order."""
        paths = {100 + i: path for i, path in enumerate(devices)}
        queues = {fd: list(reports.get(path, [])) for fd, path in paths.items()}
        by_path = {path: fd for fd, path in paths.items()}

        def fake_select(fds, _w, _x, _timeout):
            return [fd for fd in fds if queues[fd]] or [fds[0]], [], []

        def fake_read(fd, _size):
            return queues[fd].pop(0) if queues[fd] else b""

        with mock.patch.object(listen.os, "open", side_effect=lambda path, _flags: by_path[path]), \
             mock.patch.object(listen.os, "read", side_effect=fake_read), \
             mock.patch.object(listen.os, "close") as close, \
             mock.patch.object(listen.select, "select", side_effect=fake_select), \
             mock.patch.object(listen.time, "time", return_value=1.0), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            listen.listen(devices, None)
        self.assertEqual(sorted(call.args[0] for call in close.call_args_list), sorted(paths))
        return out.getvalue().splitlines()

    def test_one_candidate_prints_lines_without_a_node_path(self):
        lines = self.run_listen(["/dev/hidraw2"], {"/dev/hidraw2": [bytes.fromhex("0310400104")]})
        self.assertEqual(lines, ["1.00 power 03 10 40 01 04 state=discharging level=40"])

    def test_two_candidates_are_both_read_and_lines_carry_the_node_path(self):
        lines = self.run_listen(["/dev/hidraw2", "/dev/hidraw4"], {
            "/dev/hidraw2": [bytes.fromhex("033d400104")],
            "/dev/hidraw4": [bytes.fromhex("0310400104")],
        })
        self.assertIn("/dev/hidraw4 1.00 power 03 10 40 01 04 state=discharging level=40", lines)
        self.assertTrue(any(line.startswith("/dev/hidraw2 1.00 unknown") for line in lines), lines)
        self.assertEqual(len(lines), 2)


if __name__ == "__main__":
    unittest.main()
