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
    def test_trusts_date_when_weekday_was_not_said(self):
        import datetime
        d0 = datetime.date(2026, 10, 20)
        self.assertEqual(m.fix_weekday_dates("pada Senin, 21 Oktober 2026", d0, {"jumat"}), "pada Rabu, 21 Oktober 2026")
        self.assertEqual(m.fix_weekday_dates("hari Jumat, 21 Oktober 2026", d0, {"jumat"}), "hari Jumat, 23 Oktober 2026")
    def test_keeps_consistent_dates(self):
        import datetime
        self.assertEqual(m.fix_weekday_dates("Rabu, 21 Oktober 2026", datetime.date(2026, 10, 20)), "Rabu, 21 Oktober 2026")

class Annotate(unittest.TestCase):
    def test_spells_out_relative_dates(self):
        import datetime
        out = m.annotate_dates("I will prepare it tomorrow. Targetnya jangan lewat Jumat, ya. Hari Sabtu malam.", datetime.date(2026, 10, 20))
        self.assertIn("tomorrow [Rabu 21 Oktober 2026]", out)
        self.assertIn("Jumat [Jumat 23 Oktober 2026]", out)
        self.assertIn("Sabtu [Sabtu 24 Oktober 2026]", out)

class NextWeek(unittest.TestCase):
    def test_weekday_depan_is_next_week(self):
        import datetime
        out = m.annotate_dates("deadline-nya Rabu depan, we meet next Friday", datetime.date(2026, 10, 20))
        self.assertIn("Rabu depan [Rabu 28 Oktober 2026]", out)
        self.assertIn("next Friday [Jumat 30 Oktober 2026]", out)

class Unsupported(unittest.TestCase):
    def test_drops_invented_weekday_date_keeps_supported(self):
        import datetime
        d0 = datetime.date(2026, 10, 20)
        tr = "mulai Kamis [Kamis 22 Oktober 2026] ya"
        out = m.drop_unsupported_dates(["yaitu hingga Minggu 25 Oktober 2026", "mulai Kamis 22 Oktober 2026"], tr, d0)
        self.assertEqual(out, ["yaitu hingga Minggu", "mulai Kamis 22 Oktober 2026"])

class MingguMeansWeek(unittest.TestCase):
    def test_minggu_as_week_is_not_sunday(self):
        import datetime
        out = m.annotate_dates("sudah empat minggu, dua minggu terakhir, laporan mingguan, minggu depan", datetime.date(2026, 10, 20))
        self.assertNotIn("Minggu 25", out)
        self.assertIn("minggu depan [week of", out)
    def test_hari_minggu_is_sunday(self):
        import datetime
        self.assertIn("hari Minggu [Minggu 25 Oktober 2026]", m.annotate_dates("hari Minggu kita libur", datetime.date(2026, 10, 20)))

class Recurring(unittest.TestCase):
    def test_recurring_weekday_gets_no_date(self):
        import datetime
        out = m.annotate_dates("laporan tiap Senin pagi, setiap Jumat, every Monday", datetime.date(2026, 10, 20))
        self.assertNotIn("[", out)

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
