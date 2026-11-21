// Unit tests for Model.js. Run from the repository root with:
//   node --test
// Model.js is a QML JavaScript library (".pragma library"), so this loads it
// into a fresh context with that line removed.
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library.*$/m, "")
const M = vm.createContext({})
vm.runInContext(source, M)
// Arrays made inside the context fail deepEqual's prototype check; copy them out.
const plain = v => JSON.parse(JSON.stringify(v))

test("expandHome and tildify round-trip", () => {
  assert.equal(M.expandHome("~/Music", "/home/me"), "/home/me/Music")
  assert.equal(M.expandHome("~", "/home/me"), "/home/me")
  assert.equal(M.expandHome("  /srv/music ", "/home/me"), "/srv/music")
  assert.equal(M.tildify("/home/me/Music", "/home/me"), "~/Music")
  assert.equal(M.tildify("/home/meow/Music", "/home/me"), "/home/meow/Music")
})

test("clip caps long text", () => {
  const s = M.clip("x".repeat(1000))
  assert.equal(s.length, M.MAX_TEXT)
  assert.ok(s.endsWith("…"))
  assert.equal(M.clip(null), "")
})

test("parseFileList keeps absolute .mp3 paths, dedupes and sorts by folder then name", () => {
  const text = [
    "/m/b/Zeta.mp3", "/m/a/beta.MP3", "/m/Top.mp3", "relative.mp3",
    "/m/a/notes.txt", "/m/a/beta.MP3", "", "/m/a/Alpha.mp3"
  ].join("\n")
  const t = M.parseFileList(text, "/m/")
  assert.deepEqual(plain(t.map(x => x.path)), ["/m/Top.mp3", "/m/a/Alpha.mp3", "/m/a/beta.MP3", "/m/b/Zeta.mp3"])
  assert.equal(t[0].folder, "")
  assert.equal(t[1].name, "Alpha")
  assert.equal(t[2].name, "beta")
  assert.equal(t[3].folder, "b")
})

test("filterTracks matches every word in name or folder, case-insensitively", () => {
  const t = M.parseFileList("/m/Jazz/So What.mp3\n/m/Rock/What Else.mp3\n/m/Jazz/Blue.mp3", "/m")
  assert.equal(M.filterTracks(t, "").length, 3)
  const hits = M.filterTracks(t, "jazz WHAT").map(i => t[i].name)
  assert.deepEqual(plain(hits), ["So What"])
})

test("playOrder in order, with repeat wrap-around, and shuffled", () => {
  assert.deepEqual(plain(M.playOrder(5, 2, false, false)), [2, 3, 4])
  assert.deepEqual(plain(M.playOrder(5, 2, false, true)), [2, 3, 4, 0, 1])
  const s = M.playOrder(5, 2, true, false, () => 0)
  assert.equal(s[0], 2)
  assert.deepEqual(plain([...s].sort()), [0, 1, 2, 3, 4])
  assert.deepEqual(plain(M.playOrder(0, 0, false, false)), [])
  assert.deepEqual(plain(M.playOrder(3, 3, false, false)), [])
})

test("pathsFor writes an m3u body", () => {
  const t = [{ path: "/a.mp3" }, { path: "/b.mp3" }]
  assert.equal(M.pathsFor(t, [1, 0]), "/b.mp3\n/a.mp3\n")
})

test("formatTime", () => {
  assert.equal(M.formatTime(75.4), "1:15")
  assert.equal(M.formatTime(3725), "1:02:05")
  assert.equal(M.formatTime(-3), "0:00")
  assert.equal(M.formatTime("junk"), "0:00")
})

test("clampCursor", () => {
  assert.equal(M.clampCursor(5, 0), -1)
  assert.equal(M.clampCursor(9, 3), 2)
  assert.equal(M.clampCursor(-4, 3), 0)
})

test("mpvCommand JSON-quotes awkward file names", () => {
  const name = '/m/"quoted"; $(rm -rf ~)\nnext.mp3'
  const line = M.mpvCommand(["loadfile", name], 7)
  assert.ok(line.endsWith("\n"))
  assert.equal(line.split("\n").length, 2)
  assert.deepEqual(plain(JSON.parse(line)), { command: ["loadfile", name], request_id: 7 })
})

test("parseMpvLine rejects non-objects and bad JSON", () => {
  assert.equal(M.parseMpvLine(""), null)
  assert.equal(M.parseMpvLine("[1]"), null)
  assert.equal(M.parseMpvLine("{oops"), null)
  assert.equal(M.parseMpvLine('{"event":"idle"}').event, "idle")
})

test("metadataField ignores key case and non-strings, and clips", () => {
  const meta = { TITLE: "Song", Artist: 42, album: "y".repeat(500) }
  assert.equal(M.metadataField(meta, "title"), "Song")
  assert.equal(M.metadataField(meta, "artist"), "")
  assert.equal(M.metadataField(meta, "album").length, M.MAX_TEXT)
  assert.equal(M.metadataField(null, "title"), "")
})

test("markup-shaped tags pass through unchanged as plain strings", () => {
  // The panel renders them with Text.PlainText; the model must not alter them.
  const tag = '<img src="https://example.invalid/tracker">'
  assert.equal(M.metadataField({ title: tag }, "title"), tag)
  const t = M.parseFileList("/m/<img src=x>.mp3", "/m")
  assert.equal(t[0].name, "<img src=x>")
})

test("broadcast reaches subscribers and drops ones that throw", () => {
  const got = []
  const ok = m => got.push(m.type)
  const bad = () => { throw new Error("gone") }
  M.subscribe(ok); M.subscribe(ok); M.subscribe(bad)
  M.broadcast({ type: "attach" })
  M.broadcast({ type: "shuffle" })
  assert.deepEqual(got, ["attach", "shuffle"])
  M.unsubscribe(ok)
})

test("pickedFiles keeps a clean pick from one folder, .mp3 only", () => {
  assert.deepEqual(plain(M.pickedFiles("/d/a.mp3\r\n/d/b c.MP3\n/d/notes.txt\n")), ["/d/a.mp3", "/d/b c.MP3"])
  assert.deepEqual(plain(M.pickedFiles("")), [])
})

test("pickedFiles refuses a pick split by a newline in a file name", () => {
  // "/d/x\n/home/me/secret.mp3" as one file name reaches us as two lines.
  assert.deepEqual(plain(M.pickedFiles("/d/x\n/home/me/secret.mp3\n/d/a.mp3\n")), [])
  assert.deepEqual(plain(M.pickedFiles("/d/a.mp3\nrel.mp3\n")), [])
  assert.deepEqual(plain(M.pickedFiles("/d/../etc/a.mp3\n")), [])
})

test("pickedFolder takes exactly one clean path", () => {
  assert.equal(M.pickedFolder("/home/me/Music\n"), "/home/me/Music")
  assert.equal(M.pickedFolder("/home/me/evil\n/etc\n"), "")
  assert.equal(M.pickedFolder("Music\n"), "")
})

test("parseFileList drops lines outside the folder and odd paths", () => {
  // A name like "x\n/home/me/secret.mp3" inside /m arrives as two lines.
  const text = "/m/x\n/home/me/secret.mp3\n/m/ok.mp3\n/m/../etc/a.mp3\n/mx/b.mp3\n/m/t\tab.mp3"
  assert.deepEqual(plain(M.parseFileList(text, "/m").map(x => x.path)), ["/m/ok.mp3"])
  assert.deepEqual(plain(M.parseFileList("/m/a.mp3", "relative")), [])
})

test("recentList cleans stored folders; addRecent moves to front", () => {
  const r = M.recentList(["~/Music", "/home/me/Music", 5, "", "rel", "/x", "/y", "/z", "/w", "/v"], "/home/me")
  assert.deepEqual(plain(r), ["~/Music", "/x", "/y", "/z", "/w"])
  assert.deepEqual(plain(M.recentList("nope", "/home/me")), [])
  assert.deepEqual(plain(M.addRecent(["/a", "/b", "/c"], "/b", 3)), ["/b", "/a", "/c"])
  assert.deepEqual(plain(M.addRecent(["/a", "/b", "/c"], "/d", 3)), ["/d", "/a", "/b"])
})
