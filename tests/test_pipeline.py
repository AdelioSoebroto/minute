"""Unit tests for the pure parts of the pipeline. Run: python3 tests/test_pipeline.py"""
import importlib.machinery, importlib.util, json, tempfile, unittest
from pathlib import Path

l = importlib.machinery.SourceFileLoader("mom", str(Path(__file__).parent.parent / "pipeline" / "mom"))
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("mom", l)); l.exec_module(m)

class Tidy(unittest.TestCase):
    def test_spacing_and_punctuation(self):
        self.assertEqual(m.tidy_text("  pada renewal  SSL ,terdapat issue  "), "Pada renewal SSL, terdapat issue.")
    def test_keeps_terminal_punctuation(self):
        self.assertEqual(m.tidy_text("Is it done?"), "Is it done?")
    def test_names_dedupe_and_case(self):
        self.assertEqual(m.tidy_names(["adelio  ferhan", "ADELIO FERHAN", "Ivan Saputra ", ""]), ["Adelio Ferhan", "Ivan Saputra"])
    def test_field_without_sentence_rules(self):
        self.assertEqual(m.tidy_text("operational - update ssl", sentence=False), "operational - update ssl")

class Echo(unittest.TestCase):
    def test_drops_mic_echo_of_meeting_audio(self):
        segs = [(10.0, "Others", "We will submit the change request today"), (10.8, "Me", "we will submit the change request today"), (30.0, "Me", "Thanks, noted")]
        out = m.drop_echo(segs)
        self.assertEqual([x[2] for x in out], ["We will submit the change request today", "Thanks, noted"])
    def test_keeps_all_when_single_track(self):
        segs = [(1.0, "Speaker", "hello"), (5.0, "Speaker", "hello")]
        self.assertEqual(m.drop_echo(segs), segs)

class Loops(unittest.TestCase):
    def test_collapses_repetition_keeps_rest(self):
        self.assertEqual(m.collapse_loops("Hi in the chat in the chat in the chat in the chat. Hello everyone."), "Hi in the chat in the chat. Hello everyone.")
    def test_plain_text_untouched(self):
        self.assertEqual(m.collapse_loops("no loop here at all"), "no loop here at all")

class WeekdayDates(unittest.TestCase):
    def test_corrects_wrong_friday_and_saturday(self):
        import datetime
        d0 = datetime.date(2026, 10, 20)   # Tuesday
        self.assertEqual(m.fix_weekday_dates("paling lambat hari Jumat, 21 Oktober 2026", d0), "paling lambat hari Jumat, 23 Oktober 2026")
        self.assertEqual(m.fix_weekday_dates("pada Sabtu (22 Oktober 2026)", d0), "pada Sabtu (24 Oktober 2026)")
    def test_keeps_consistent_dates(self):
        import datetime
        self.assertEqual(m.fix_weekday_dates("Rabu, 21 Oktober 2026", datetime.date(2026, 10, 20)), "Rabu, 21 Oktober 2026")

class Dates(unittest.TestCase):
    def test_ordinals(self):
        self.assertEqual(m.nice_date(2026, 10, 19), "October 19th, 2026")
        self.assertEqual(m.nice_date(2026, 10, 21), "October 21st, 2026")
        self.assertEqual(m.nice_date(2026, 10, 22), "October 22nd, 2026")
        self.assertEqual(m.nice_date(2026, 10, 11), "October 11th, 2026")

class Segments(unittest.TestCase):
    def test_prepare_collects_device_change_segments_in_order(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            for n in ("mic.caf", "mic_2.caf", "system.caf", "mic_10.caf"): (d / n).write_bytes(b"x" * 5000)
            (d / "mode.txt").write_text("Online\n")
            _, tracks = m.prepare(d)
            lab = dict(tracks)
            self.assertEqual([p.name for p in lab["Me"]], ["mic.caf", "mic_2.caf", "mic_10.caf"])
            self.assertIn("Others", lab)

if __name__ == "__main__":
    unittest.main()
