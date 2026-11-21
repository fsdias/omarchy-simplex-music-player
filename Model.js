.pragma library

// Pure helpers for the Simplex Music Player panel. Nothing here touches QML, so the
// test script can load this file in node.

var MAX_TRACKS = 20000
var MAX_TEXT = 300

// "~/Music" -> "/home/me/Music"; anything else is returned trimmed.
function expandHome(path, home) {
  var p = String(path || "").trim()
  if (p === "~") return home
  if (p.indexOf("~/") === 0) return String(home).replace(/\/+$/, "") + p.slice(1)
  return p
}

// "/home/me/Music" -> "~/Music", for display.
function tildify(path, home) {
  var h = String(home || "").replace(/\/+$/, "")
  var p = String(path || "")
  if (h && (p === h || p.indexOf(h + "/") === 0)) return "~" + p.slice(h.length)
  return p
}

function clip(text) {
  var s = String(text === undefined || text === null ? "" : text)
  return s.length > MAX_TEXT ? s.slice(0, MAX_TEXT - 1) + "…" : s
}

function basename(path) {
  var s = String(path)
  var i = s.lastIndexOf("/")
  return i >= 0 ? s.slice(i + 1) : s
}

function stripExtension(name) {
  return String(name).replace(/\.mp3$/i, "")
}

// True for a path that one line of a list (find output, the M3U queue) can
// hold unambiguously: absolute, no control characters, no "." or ".." parts.
function cleanPath(path) {
  var p = String(path || "")
  if (p.charAt(0) !== "/") return false
  if (/[\x00-\x1f\x7f]/.test(p)) return false
  return !/(^|\/)\.\.?(\/|$)/.test(p) && p.indexOf("//") < 0
}

// Output of `find <root> -type f -iname '*.mp3'` -> sorted track objects:
// { path, name, folder } where folder is relative to root ("" at the top).
// Only paths inside root count, so a line cut out of a file name that holds a
// newline can never point the queue at a file outside the chosen folder.
function parseFileList(text, root) {
  var base = String(root || "").replace(/\/+$/, "")
  if (!cleanPath(base + "/")) return []
  var lines = String(text || "").split("\n")
  var tracks = []
  var seen = ({})
  for (var i = 0; i < lines.length && tracks.length < MAX_TRACKS; i++) {
    var path = lines[i]
    if (path.indexOf(base + "/") !== 0 || !cleanPath(path)) continue
    if (!/\.mp3$/i.test(path)) continue
    if (seen[path]) continue
    seen[path] = true
    var rel = path.slice(base.length + 1)
    var cut = rel.lastIndexOf("/")
    tracks.push({
      path: path,
      name: clip(stripExtension(basename(path))),
      folder: clip(cut >= 0 ? rel.slice(0, cut) : "")
    })
  }
  tracks.sort(function(a, b) {
    var fa = a.folder.toLowerCase(), fb = b.folder.toLowerCase()
    if (fa !== fb) return fa < fb ? -1 : 1
    var na = a.name.toLowerCase(), nb = b.name.toLowerCase()
    if (na !== nb) return na < nb ? -1 : 1
    return a.path < b.path ? -1 : (a.path > b.path ? 1 : 0)
  })
  return tracks
}

// Indices into tracks whose name or folder contains every word of query.
function filterTracks(tracks, query) {
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function(w) { return w.length > 0 })
  var out = []
  for (var i = 0; i < tracks.length; i++) {
    if (words.length === 0) { out.push(i); continue }
    var hay = (tracks[i].name + " " + tracks[i].folder).toLowerCase()
    var ok = true
    for (var w = 0; w < words.length; w++) {
      if (hay.indexOf(words[w]) < 0) { ok = false; break }
    }
    if (ok) out.push(i)
  }
  return out
}

function indexOfPath(tracks, path) {
  if (!path) return -1
  for (var i = 0; i < tracks.length; i++) if (tracks[i].path === path) return i
  return -1
}

// The order mpv plays tracks in, as indices into tracks, starting at start.
// In order: start to the end, then (with repeat) around from the top, so a
// looping playlist keeps the folder order. Shuffled: start, then all the
// others at random. rand() returns [0, 1) and is passed in for testing.
function playOrder(count, start, shuffle, repeat, rand) {
  if (count <= 0 || start < 0 || start >= count) return []
  var rest = []
  var i
  if (shuffle) {
    for (i = 0; i < count; i++) if (i !== start) rest.push(i)
    for (i = rest.length - 1; i > 0; i--) {
      var j = Math.floor(rand() * (i + 1))
      var t = rest[i]; rest[i] = rest[j]; rest[j] = t
    }
  } else {
    for (i = start + 1; i < count; i++) rest.push(i)
    if (repeat) for (i = 0; i < start; i++) rest.push(i)
  }
  return [start].concat(rest)
}

function pathsFor(tracks, order) {
  var lines = []
  for (var i = 0; i < order.length; i++) lines.push(tracks[order[i]].path)
  return lines.join("\n") + "\n"
}

// 75.4 -> "1:15", 3725 -> "1:02:05".
function formatTime(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var r = s % 60
  var rr = (r < 10 ? "0" : "") + r
  if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + rr
  return m + ":" + rr
}

function clampCursor(cursor, count) {
  if (count <= 0) return -1
  return Math.max(0, Math.min(count - 1, cursor))
}

// One JSON IPC line for mpv. JSON.stringify handles quoting, so file names
// never reach a shell or mpv's own command parser.
function mpvCommand(args, requestId) {
  var msg = { command: args }
  if (requestId !== undefined) msg.request_id = requestId
  return JSON.stringify(msg) + "\n"
}

function parseMpvLine(line) {
  var s = String(line || "").trim()
  if (!s || s.charAt(0) !== "{" || s.length > 1000000) return null
  try {
    var obj = JSON.parse(s)
    return obj && typeof obj === "object" ? obj : null
  } catch (e) {
    return null
  }
}

// mpv's metadata keys vary in case between tag formats.
function metadataField(meta, key) {
  if (!meta || typeof meta !== "object") return ""
  var want = String(key).toLowerCase()
  for (var k in meta) {
    if (String(k).toLowerCase() === want && typeof meta[k] === "string") return clip(meta[k])
  }
  return ""
}

// One bar per monitor means one copy of the panel per monitor. This library
// is shared by all of them, so it carries word between them: "attach" when
// one starts mpv, "shuffle" when one toggles it.
var _listeners = []

function subscribe(fn) { if (_listeners.indexOf(fn) < 0) _listeners.push(fn) }

function unsubscribe(fn) {
  var i = _listeners.indexOf(fn)
  if (i >= 0) _listeners.splice(i, 1)
}

function broadcast(msg) {
  var copy = _listeners.slice()
  for (var i = 0; i < copy.length; i++) {
    try { copy[i](msg) } catch (e) { unsubscribe(copy[i]) }
  }
}

// zenity's output (one path per line) -> absolute paths, at most 2000.
function pickedPaths(text) {
  var out = []
  var lines = String(text || "").replace(/\n+$/, "").split("\n")
  for (var i = 0; i < lines.length && out.length < 2000; i++) {
    var p = lines[i].replace(/\r$/, "")
    if (p) out.push(p)
  }
  return out
}

function parentOf(path) {
  var s = String(path)
  return s.slice(0, s.lastIndexOf("/") + 1)
}

// The folder picker returns one path. Anything else (a name holding a newline
// splits into several lines) is refused.
function pickedFolder(text) {
  var picked = pickedPaths(text)
  return picked.length === 1 && cleanPath(picked[0]) ? picked[0] : ""
}

// The files picker returns paths from one folder, one per line. A file name
// holding a newline would split into lines that look like other paths, so the
// whole pick is refused unless every line is a clean path in the same folder.
function pickedFiles(text) {
  var picked = pickedPaths(text)
  if (picked.length === 0) return []
  var dir = parentOf(picked[0])
  for (var i = 0; i < picked.length; i++) {
    if (!cleanPath(picked[i]) || parentOf(picked[i]) !== dir) return []
  }
  return picked.filter(function(p) { return /\.mp3$/i.test(p) })
}

// The stored recent-folder list, cleaned: strings only, no duplicates, at most 5.
function recentList(value, home) {
  var out = []
  if (!Array.isArray(value)) return out
  for (var i = 0; i < value.length && out.length < 5; i++) {
    var f = value[i]
    if (typeof f !== "string" || !f) continue
    var full = expandHome(f, home)
    if (full.charAt(0) !== "/") continue
    var dup = false
    for (var j = 0; j < out.length; j++) if (expandHome(out[j], home) === full) dup = true
    if (!dup) out.push(clip(f))
  }
  return out
}

// Put folder at the front of list, dropping its older copy, keep max.
function addRecent(list, folder, max) {
  var out = [folder]
  for (var i = 0; i < list.length && out.length < max; i++) if (list[i] !== folder) out.push(list[i])
  return out
}
