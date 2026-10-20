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

print(failures == 0 ? "swift tests passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
