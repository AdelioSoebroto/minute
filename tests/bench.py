"""Accuracy benchmark for the minutes writer. Runs the real local model on fixed transcripts and checks that the facts that must be in the
minutes are there (and that names which were never said are not). Run: python3 tests/bench.py   (needs Ollama and the model; ~1 min per case)
Use it before and after changing a prompt, a model or a pass: the score tells you whether the minutes got better or worse."""
import importlib.machinery, importlib.util, json, re, sys, tempfile
from pathlib import Path

l = importlib.machinery.SourceFileLoader("mom", str(Path(__file__).parent.parent / "pipeline" / "mom"))
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("mom", l)); l.exec_module(m)

CASES = [
    {"name": "formal change request (Bahasa)", "folder": "2026-10-20_1000_bench",
     "transcript": """[00:00:03] Me: Selamat pagi Pak Rudi, terima kasih sudah bergabung. Kita bahas renewal sertifikat SSL untuk aplikasi LBA ya.
[00:00:14] Others: Pagi Pak Adelio. Betul, sertifikat yang lama akan expired minggu ini, jadi perlu diganti secepatnya.
[00:00:31] Me: Baik. Kapan remediasinya bisa dilakukan?
[00:00:38] Others: Kami dari iCode bisa melakukan remediasi pada hari Selasa, 27 Oktober 2026 pukul 22.00 sampai 05.00. Saya sendiri yang menjadi PIC-nya, nama saya Rudi Hartono.
[00:00:57] Me: Oke, saya akan submit standard change request hari ini supaya approval-nya keluar sebelum Selasa.
[00:01:08] Others: Siap. Kami juga siapkan rollback plan kalau ada kendala saat penggantian.""",
     "must": [r"SSL", r"27 Oktober", r"Rudi", r"22[.:]00", r"change request", r"rollback"], "must_not": [r"Ivan Saputra", r"Kiki"], "min_topics": 3},
    {"name": "slang planning (Jaksel mix)", "folder": "2026-10-20_1100_bench",
     "transcript": """[00:00:05] Me: Jadi gini guys, campaign Teazzi buat bulan depan udah mepet banget nih, gue butuh materi dari tim kreatif.
[00:00:19] Others: Gue sih bisa kelarin visual-nya besok, tapi copy-nya nunggu Siti dulu.
[00:00:30] Others: Iya, nanti gue kirim copy-nya besok sore ke lo ya, Dim. Tapi budget-nya udah di-acc belum sama finance?
[00:00:42] Me: Belum, gue follow up ke finance hari ini. Kalau udah acc, kita langsung gas produksi.""",
     "must": [r"Teazzi", r"Siti", r"21 Oktober|besok", r"finance", r"copy"], "must_not": [r"Rudi"], "min_topics": 2},
    {"name": "English standup", "folder": "2026-10-21_0930_bench",
     "transcript": """[00:00:04] Me: Morning everyone. Dewi, where are we on the payment API?
[00:00:10] Others: Morning. The integration is done but there is a blocker: the vendor sandbox keeps timing out, so I cannot finish testing.
[00:00:24] Me: Okay, please raise it with the vendor today. We still need to deploy on Friday, October 23rd.
[00:00:33] Others: Understood, I will escalate to them this afternoon and update the channel before five.""",
     "must": [r"Dewi", r"API", r"sandbox|timing out|timeout", r"Friday|October 23|23 Oktober|Jumat", r"vendor"], "must_not": [], "min_topics": 2},
    {"name": "talk without decisions", "folder": "2026-10-22_1400_bench",
     "transcript": """[00:00:02] Me: Selamat siang semuanya. Hari ini saya akan berbagi tentang bagaimana membangun kebiasaan kerja yang konsisten.
[00:00:20] Me: Pertama, mulai dari hal kecil. Lima menit sehari lebih baik daripada dua jam sekali seminggu.
[00:00:40] Me: Kedua, catat progres kamu setiap hari supaya kelihatan kemajuannya. Ketiga, cari teman yang bisa saling mengingatkan.
[00:01:00] Me: Sekian dari saya, terima kasih.""",
     "must": [r"kecil|lima menit", r"catat|progres", r"teman|saling"], "must_not": [], "min_topics": 3},
]

def run_case(c):
    d = Path(tempfile.mkdtemp()) / c["folder"]; d.mkdir(parents=True)
    data = m.make_mom(c["transcript"], d)
    blob = "\n".join([data.get("agenda", ""), *data.get("topics", []), *data.get("telkomsel_names", []), *data.get("third_party_names", []), data.get("third_party_company", "")])
    hits = [(p, bool(re.search(p, blob, re.I))) for p in c["must"]]
    bad = [p for p in c["must_not"] if re.search(p, blob, re.I)]
    enough = len(data.get("topics", [])) >= c["min_topics"]
    return hits, bad, enough, data

if __name__ == "__main__":
    m.ensure_ollama()
    total = got = 0
    for c in CASES:
        hits, bad, enough, data = run_case(c)
        pts = sum(1 for _, ok in hits if ok) + (1 if enough else 0) + (1 if not bad else 0)
        mx = len(hits) + 2; total += mx; got += pts
        print(f"\n{c['name']}: {pts}/{mx}")
        for p, ok in hits: print(("  ok   " if ok else "  MISS ") + p)
        print(("  ok   " if enough else "  MISS ") + f">= {c['min_topics']} topics (got {len(data.get('topics', []))})")
        print(("  ok   no invented names" if not bad else "  BAD  invented: " + ", ".join(bad)))
        if "-v" in sys.argv: print(json.dumps(data, ensure_ascii=False, indent=1))
    print(f"\nScore: {got}/{total} = {got * 100 // total}%")
    m.unload()
