// Logic tests for the app's pure code. Run: ./build.sh test
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) { if !ok { failures += 1; print("FAIL \(name)") } }

let raw = "# Transcript\n\n[00:00:04] Me: Selamat pagi: semuanya.\n[00:01:15] Others: Siap, nanti saya follow up.\n[00:10:00] Budi: Oke.\n"
let lines = TLine.parse(raw)
check(lines.count == 3, "parses three lines")
check(lines[0].who == "Me" && lines[0].speaker == "You", "Me is shown as You")
check(lines[0].text == "Selamat pagi: semuanya.", "text keeps colons after the speaker")
check(lines[1].seconds == 75, "seconds from timestamp")
check(lines[2].seconds == 600 && lines[2].speaker == "Budi", "named speaker")
check(TLine.serialize(lines) == raw, "round trip is lossless")

var edited = lines
edited[1].text = "   "
check(!TLine.serialize(edited).contains("Others"), "empty lines are dropped when saving")
edited = lines; edited[2].who = "Budi Santoso"
check(TLine.serialize(edited).contains("[00:10:00] Budi Santoso: Oke."), "speaker rename is saved")
check(TLine.parse("no timestamps here\nat all").isEmpty, "ignores non-transcript lines")
check(TLine.parse("[bad] Me: x").first?.seconds == 0, "bad timestamp is zero")

let jl = TLine.parse("[00:00:01] Me: Selamat pagi semuanya.\n[00:00:09] Others: Vendor sandbox masih timeout.\n[00:00:20] Me: Dewi tolong eskalasi ke vendor hari ini.\n[00:00:30] Others: Siap.")
check(TLine.bestMatch(for: "Dewi to escalate the vendor sandbox timeout today", in: jl) != nil, "finds a matching line")
check(TLine.bestMatch(for: "Dewi eskalasi vendor", in: jl) == 2, "picks the line with the rarer shared words")
check(TLine.bestMatch(for: "completely unrelated budget", in: jl) == nil, "no match when nothing fits")
check(TLine.srt(jl).hasPrefix("1\n00:00:01,000 --> 00:00:09,000\nYou: Selamat"), "srt first cue")
let md = ShareText.markdown(agenda: "Rapat A", date: "21 Oct", time: "10:00", internalNames: ["Adel"], unit: "IT", externalNames: [], company: "", topics: ["Satu", "Dua"])
check(md.contains("# Rapat A") && md.contains("1. Satu") && md.contains("**Internal (IT):** Adel"), "markdown has agenda, topics, participants")
check(!ShareText.plain(md).contains("**"), "plain text has no markdown marks")

print(failures == 0 ? "swift tests passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
