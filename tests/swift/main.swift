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

check(ActionItems.isAction("Dewi akan eskalasi ke vendor sebelum Jumat."), "detects an Indonesian action")
check(ActionItems.isAction("Adel will send the draft by Friday."), "detects an English action")
check(!ActionItems.isAction("The team reviewed the quarterly results."), "plain discussion is not an action")
check(ActionItems.key(folder: "f", text: "Dewi, akan!") == ActionItems.key(folder: "f", text: "dewi akan"), "key ignores case and punctuation")
let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-test-\(UUID().uuidString).json")
var st = ActionItems.State(); st.done.insert("a"); ActionItems.save(st, to: tmpURL)
check(ActionItems.load(tmpURL).done == ["a"], "state round trip")
try? FileManager.default.removeItem(at: tmpURL)

var dc = Calendar(identifier: .gregorian); dc.timeZone = .current
let ref = dc.date(from: DateComponents(year: 2026, month: 10, day: 20))!
check(ActionItems.dueDate("Friday, October 23rd, 2026", reference: ref) == dc.date(from: DateComponents(year: 2026, month: 10, day: 23)), "due: English long date")
check(ActionItems.dueDate("Jumat, 23 Oktober 2026", reference: ref) == dc.date(from: DateComponents(year: 2026, month: 10, day: 23)), "due: Indonesian date")
check(ActionItems.dueDate("23 Oktober", reference: ref) == dc.date(from: DateComponents(year: 2026, month: 10, day: 23)), "due: year from reference")
check(ActionItems.dueDate("TBD", reference: ref) == nil && ActionItems.dueDate("setiap Senin", reference: ref) == nil, "due: no date")
check(ActionItems.isOverdue(due: "1 Januari 2020") && !ActionItems.isOverdue(due: "TBD"), "overdue")

check(ActionItems.dueDate("2026-10-23", reference: ref) == dc.date(from: DateComponents(year: 2026, month: 10, day: 23)), "due: ISO date")
check(ActionItems.niceDue("2026-10-23") == "23 Oct 2026" && ActionItems.niceDue("TBD") == "TBD", "nice due")

failures += gateTest()

print(failures == 0 ? "swift tests passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
