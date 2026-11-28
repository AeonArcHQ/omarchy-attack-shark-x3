import importlib.util
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
