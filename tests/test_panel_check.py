import importlib.machinery
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("panel_check", str(ROOT / "tools" / "panel-check"))
spec = importlib.util.spec_from_loader("panel_check", loader)
panel_check = importlib.util.module_from_spec(spec)
loader.exec_module(panel_check)

GREY = (100, 100, 100)
BACKGROUND = (20, 20, 20)


def canvas(width, height, color=BACKGROUND):
    return bytearray(color * (width * height))


def put(buf, width, x, y, color=GREY):
    i = (y * width + x) * 3
    buf[i:i + 3] = bytes(color)


def draw_control(buf, width, x, y, w, h, missing=()):
    for xx in range(x, x + w):
        if "top" not in missing:
            put(buf, width, xx, y)
        if "bottom" not in missing:
            put(buf, width, xx, y + h - 1)
    for yy in range(y, y + h):
        if "left" not in missing:
            put(buf, width, x, yy)
        if "right" not in missing:
            put(buf, width, x + w - 1, yy)


def draw_rounded_control(buf, width, x, y, w, h, radius):
    for xx in range(x + radius, x + w - radius):
        put(buf, width, xx, y)
        put(buf, width, xx, y + h - 1)
    for yy in range(y + radius, y + h - radius):
        put(buf, width, x, yy)
        put(buf, width, x + w - 1, yy)


def flatten(rows):
    return [control for row in rows for control in row]


class EdgeScanTest(unittest.TestCase):
    def test_grey_matches_the_issue_appendix(self):
        self.assertTrue(panel_check.grey((100, 103, 107)))
        self.assertFalse(panel_check.grey((69, 69, 69)))
        self.assertFalse(panel_check.grey((141, 141, 141)))
        self.assertFalse(panel_check.grey((100, 110, 100)))

    def test_a_button_with_all_edges_is_measured_once(self):
        width, height = 120, 80
        buf = canvas(width, height)
        draw_control(buf, width, 10, 8, 50, 30)
        rows = panel_check.analyze_controls(bytes(buf), width, height)
        controls = flatten(rows)
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(controls), 1)
        control = controls[0]
        self.assertEqual((control["x"], control["y"], control["width"]), (10, 8, 50))
        self.assertEqual(control["edges"], {"left": True, "right": True, "top": True, "bottom": True})

    def test_rounded_corners_estimate_columns_without_overriding_the_exact_probe(self):
        width, height = 120, 80
        buf = canvas(width, height)
        draw_rounded_control(buf, width, 10, 8, 50, 30, 3)
        rows = panel_check.analyze_controls(bytes(buf), width, height)
        controls = flatten(rows)
        self.assertEqual(len(controls), 1)
        self.assertEqual((controls[0]["x"], controls[0]["width"]), (10, 50))
        self.assertEqual(controls[0]["edges"], {"left": False, "right": False, "top": True, "bottom": True})

    def test_a_button_with_the_left_edge_missing_is_still_reported(self):
        width, height = 120, 80
        buf = canvas(width, height)
        draw_control(buf, width, 10, 8, 50, 30, missing=("left",))
        rows = panel_check.analyze_controls(bytes(buf), width, height)
        controls = flatten(rows)
        self.assertEqual(len(controls), 1)
        self.assertEqual(controls[0]["edges"], {"left": False, "right": True, "top": True, "bottom": True})

    def test_a_neighbor_four_pixels_away_does_not_satisfy_a_missing_left_edge(self):
        width, height = 180, 90
        buf = canvas(width, height)
        draw_control(buf, width, 10, 8, 50, 30)
        draw_control(buf, width, 63, 8, 50, 30, missing=("left",))
        rows = panel_check.analyze_controls(bytes(buf), width, height)
        self.assertEqual([len(row) for row in rows], [2])
        second = rows[0][1]
        self.assertEqual((second["x"], second["width"]), (63, 50))
        self.assertEqual(second["edges"], {"left": False, "right": True, "top": True, "bottom": True})

    def test_the_frame_border_does_not_satisfy_a_missing_left_edge(self):
        width, height = 180, 100
        button_x = 20
        for margin in (8, 12):
            with self.subTest(margin=margin):
                buf = canvas(width, height)
                frame_x = button_x - margin
                frame_y = 4
                frame_width = 140
                frame_height = 80
                draw_control(buf, width, frame_x, frame_y, frame_width, frame_height)
                draw_control(buf, width, button_x, 20, 50, 30, missing=("left",))
                region = (frame_x + 4, frame_y + 4,
                          frame_x + frame_width - 4, frame_y + frame_height - 4)
                rows = panel_check.analyze_controls(bytes(buf), width, height, region)
                controls = flatten(rows)
                self.assertEqual(len(controls), 1)
                self.assertEqual((controls[0]["x"], controls[0]["width"]), (button_x, 50))
                self.assertFalse(controls[0]["edges"]["left"])
                self.assertTrue(controls[0]["edges"]["right"])

    def test_a_control_cut_by_the_region_bottom_has_no_missing_edge(self):
        width, height = 120, 80
        region = (0, 0, width, 30)
        buf = canvas(width, height)
        # Side edges run down to the region bottom; the clip hides the bottom.
        draw_control(buf, width, 10, 20, 50, 10, missing=("bottom",))
        rows = panel_check.analyze_controls(bytes(buf), width, height, region)
        controls = flatten(rows)
        self.assertEqual(len(controls), 1)
        self.assertTrue(controls[0]["cut"])
        self.assertEqual(panel_check.missing_edges(rows), [])
        result = {"frame": {"x": 0, "y": 0, "width": width, "height": 30}, "rows": rows}
        self.assertIn("cut", panel_check.format_report("x3", result).splitlines()[-1])

    def test_a_cut_control_still_reports_a_missing_side_edge(self):
        width, height = 120, 80
        region = (0, 0, width, 30)
        buf = canvas(width, height)
        draw_control(buf, width, 10, 20, 50, 10, missing=("bottom", "left"))
        rows = panel_check.analyze_controls(bytes(buf), width, height, region)
        self.assertEqual(panel_check.missing_edges(rows), [(1, 1, "left")])

    def test_horizontal_runs_group_into_rows_by_their_top_edge(self):
        width, height = 180, 120
        buf = canvas(width, height)
        draw_control(buf, width, 10, 8, 45, 28)
        draw_control(buf, width, 70, 8, 45, 28)
        draw_control(buf, width, 10, 60, 45, 28)
        rows = panel_check.analyze_controls(bytes(buf), width, height)
        self.assertEqual([len(row) for row in rows], [2, 1])
        self.assertEqual([[control["x"] for control in row] for row in rows], [[10, 70], [10]])

    def test_a_separator_line_is_not_a_button(self):
        width, height = 160, 80
        buf = canvas(width, height)
        for x in range(10, 150):
            put(buf, width, x, 10)
        self.assertEqual(panel_check.analyze_controls(bytes(buf), width, height), [])

    def test_frame_from_difference_finds_the_changed_rectangle(self):
        width, height = 160, 100
        before = canvas(width, height)
        after = canvas(width, height)
        for y in range(20, 70):
            for x in range(30, 120):
                i = (y * width + x) * 3
                after[i:i + 3] = bytes((35, 35, 40))
        frame = panel_check.frame_from_difference(bytes(before), bytes(after), width, height)
        self.assertIsNotNone(frame)
        self.assertLessEqual(abs(frame["x"] - 30), 1)
        self.assertLessEqual(abs(frame["y"] - 20), 1)
        self.assertLessEqual(abs(frame["width"] - 90), 2)
        self.assertLessEqual(abs(frame["height"] - 50), 2)


if __name__ == "__main__":
    unittest.main()
