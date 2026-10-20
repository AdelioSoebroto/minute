"""End-to-end mock of a multi-person online meeting, using macOS text-to-speech voices.

Three speakers (you plus two others, in mixed Bahasa Indonesia and English) are rendered with `say`, laid on a timeline, and written as
two tracks like the app does (mic.caf = you, system.caf = everyone else). The real pipeline then transcribes it and writes the minutes.
Run: python3 tests/mock_meeting.py [folder-to-create-in]   (default: a temporary folder; nothing in your library is touched)
"""
import subprocess, sys, tempfile, wave, re, json
from pathlib import Path

PIPE = Path.home() / ".mom/bin/mom"
SCRIPT = [
    ("me",  "Damayanti", "Selamat pagi semuanya, kita mulai rapat soal rencana peluncuran fitur pembayaran baru."),
    ("oth", "Samantha",  "Good morning. The payment API integration is finished, but the vendor sandbox is still timing out."),
    ("me",  "Damayanti", "Baik. Dewi, tolong eskalasi ke vendor hari ini ya."),
    ("oth", "Samantha",  "Understood, I will escalate this afternoon."),
    ("oth", "Daniel",     "From my side, the marketing campaign needs approval from finance before Friday, October 23rd."),
    ("me",  "Damayanti", "Oke, saya follow up ke finance besok pagi."),
    ("oth", "Daniel",     "Great, thanks."),
    ("me",  "Damayanti", "Sip. Kalau begitu rapat kita sudahi, terima kasih semuanya."),
]
EXPECT = [r"API", r"sandbox|timing out|timeout", r"vendor", r"finance", r"23|Jumat|Friday"]

def render(voice, text, tmp, i):
    aiff, wav = tmp / f"{i}.aiff", tmp / f"{i}.wav"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(aiff), "-ar", "16000", "-ac", "1", "-sample_fmt", "s16", str(wav)], check=True)
    with wave.open(str(wav)) as w: return w.readframes(w.getnframes())

def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.mkdtemp())
    folder = root / "2026-10-21_1030_mock"; folder.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp())
    gap = b"\x00\x00" * int(16000 * 0.9)
    me, oth = bytearray(), bytearray()
    for i, (who, voice, text) in enumerate(SCRIPT):
        pcm = render(voice, text, tmp, i)
        (me if who == "me" else oth).extend(pcm); (oth if who == "me" else me).extend(b"\x00\x00" * (len(pcm) // 2))
        me.extend(gap); oth.extend(gap)
    for name, data in (("mic", me), ("system", oth)):
        wav = tmp / f"{name}.wav"
        with wave.open(str(wav), "wb") as w: w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(data))
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a", "pcm_f32le", str(folder / f"{name}.caf")], check=True)
    (folder / "mode.txt").write_text("Online\n")
    print("Mock meeting written to", folder)
    for args in ([str(folder), "--transcript-only"], ["--draft", str(folder)]):
        r = subprocess.run([str(PIPE)] + args, capture_output=True, text=True)
        if r.returncode: print(r.stdout[-400:], r.stderr[-400:]); sys.exit(1)
    print("\n--- transcript ---\n" + (folder / "transcript.md").read_text())
    data = json.loads((folder / "MoM.json").read_text())
    print("--- minutes ---\nAgenda:", data["agenda"])
    for t in data["topics"]: print(" -", t)
    blob = " ".join(data["topics"] + [data["agenda"]])
    hits = [(p, bool(re.search(p, blob, re.I))) for p in EXPECT]
    for p, ok in hits: print(("ok   " if ok else "MISS ") + p)
    print(f"\n{sum(ok for _, ok in hits)}/{len(hits)} expected facts found")

if __name__ == "__main__":
    main()
