import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Simplex Music Player: a bar button and a panel that lists the MP3 files under one
// folder and plays them. Playback runs in a detached mpv, driven over its
// JSON IPC socket, so music keeps playing when the shell reloads plugins
// and the panel re-attaches to it on load. mpv owns the play queue, so it
// moves on to the next track by itself, and with mpv-mpris installed the
// media keys and the Media widget control it too.
Panel {
  id: root
  moduleName: "io.github.fsdias.simplex-music-player"
  ipcTarget: "io.github.fsdias.simplex-music-player"
  manageIpc: false

  // ---------------------------------------------------------------- setup
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string socketPath: runtimeDir + "/simplex-music-player.sock"
  readonly property string queuePath: runtimeDir + "/simplex-music-player.m3u"
  readonly property string folder: Model.expandHome(setting("folder", "~/Music"), home)
  readonly property string folderLabel: Model.tildify(folder, home)

  // ---------------------------------------------------------------- library
  property var tracks: []
  property bool scanned: false
  property string query: ""
  readonly property var filtered: Model.filterTracks(tracks, query)
  property int cursor: 0

  // ---------------------------------------------------------------- player
  readonly property bool connected: mpv.connected
  property bool starting: false
  property bool startFailed: false
  property int connectTries: 0
  property var pending: []
  property string playingPath: ""
  property bool idle: true
  property bool paused: false
  property real position: 0
  property real duration: 0
  property real volume: 70
  property bool shuffle: false
  property bool repeatAll: false
  property var metadata: ({})

  readonly property bool active: connected && !idle && playingPath !== ""
  readonly property bool playing: active && !paused
  readonly property int currentIndex: Model.indexOfPath(tracks, playingPath)
  readonly property string currentTitle: {
    if (!active) return ""
    var tag = Model.metadataField(metadata, "title")
    if (tag) return tag
    return currentIndex >= 0 ? tracks[currentIndex].name : Model.clip(Model.stripExtension(Model.basename(playingPath)))
  }
  readonly property string currentDetail: {
    if (!active) return ""
    var artist = Model.metadataField(metadata, "artist")
    var album = Model.metadataField(metadata, "album")
    if (artist && album) return artist + " · " + album
    if (artist || album) return artist || album
    return currentIndex >= 0 ? tracks[currentIndex].folder : ""
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------ scanning
  property bool rescanAgain: false

  function rescan() {
    if (scanProc.running) { rescanAgain = true; return }
    scanProc.command = ["find", "-L", root.folder, "-type", "f", "-iname", "*.mp3"]
    scanProc.running = true
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.rescanAgain) { root.rescanAgain = false; Qt.callLater(root.rescan); return }
        root.tracks = Model.parseFileList(text, root.folder)
        root.scanned = true
        root.cursor = Model.clampCursor(root.cursor, root.filtered.length)
      }
    }
  }

  // ------------------------------------------------------------ choosing
  // Folders picked before, newest first, kept in shell.json with the folder.
  readonly property var recentFolders: Model.recentList(setting("recentFolders", []), home)

  // Save the folder to this widget's shell.json entry; every bar copy
  // picks the new setting up from there.
  function setFolder(path) {
    var dir = Model.expandHome(path, home).replace(/\/+$/, "")
    if (!dir || dir.charAt(0) !== "/") return
    var recent = Model.addRecent(recentFolders, Model.tildify(dir, home), 5)
    root.settings = Object.assign({}, root.settings, { folder: Model.tildify(dir, home), recentFolders: recent })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function chooseFolder() {
    if (pickProc.running) return
    root.close()
    pickProc.mode = "folder"
    pickProc.command = ["zenity", "--file-selection", "--directory",
      "--title=" + strings.t("chooseFolderTitle"), "--filename=" + root.folder + "/"]
    pickProc.running = true
  }

  function chooseFiles() {
    if (pickProc.running) return
    root.close()
    pickProc.mode = "files"
    pickProc.command = ["zenity", "--file-selection", "--multiple", "--separator=\n",
      "--title=" + strings.t("chooseFilesTitle"), "--filename=" + root.folder + "/",
      "--file-filter=MP3 | *.mp3 *.MP3 *.Mp3", "--file-filter=* | *"]
    pickProc.running = true
  }

  // Play exactly the files picked, in the order picked, as their own queue.
  function playFiles(paths) {
    if (paths.length === 0) return
    queueFile.setText(paths.join("\n") + "\n")
    send(["loadlist", root.queuePath, "replace"])
    send(["set_property", "pause", false])
  }

  Process {
    id: pickProc
    property string mode: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var picked = Model.pickedPaths(text)
        if (pickProc.mode === "folder" && picked.length > 0) root.setFolder(picked[0])
        else if (pickProc.mode === "files") root.playFiles(picked.filter(function(p) { return /\.mp3$/i.test(p) }))
      }
    }
  }

  onFolderChanged: { scanned = false; tracks = []; rescan() }
  onQueryChanged: cursor = filtered.length > 0 ? 0 : -1

  // ------------------------------------------------------------ mpv link
  Socket {
    id: mpv
    path: root.socketPath
    parser: SplitParser { onRead: function(line) { root.handleMpv(line) } }
    onConnectedChanged: connected ? root.mpvAttached() : root.mpvDetached()
  }

  FileView {
    id: queueFile
    path: root.queuePath
    blockWrites: true
    preload: false
    printErrors: false
  }

  Timer {
    id: retryTimer
    interval: 100
    repeat: true
    onTriggered: {
      if (mpv.connected) { stop(); return }
      if (++root.connectTries > 50) {
        stop()
        root.starting = false
        root.startFailed = true
        root.pending = []
        return
      }
      mpv.connected = true
    }
  }

  // Ask mpv for the position twice a second while someone is looking.
  Timer {
    interval: 500
    repeat: true
    running: root.opened && root.playing
    triggeredOnStart: true
    onTriggered: root.sendNow(["get_property", "time-pos"], 100)
  }

  function sendNow(args, requestId) {
    if (!mpv.connected) return
    mpv.write(Model.mpvCommand(args, requestId))
    mpv.flush()
  }

  // Send, starting mpv first when it isn't running.
  function send(args) {
    if (mpv.connected) { sendNow(args); return }
    pending = pending.concat([args])
    ensureMpv()
  }

  function ensureMpv() {
    if (mpv.connected || starting) return
    starting = true
    startFailed = false
    connectTries = 0
    Quickshell.execDetached([
      "mpv", "--idle=yes", "--no-video", "--no-terminal", "--force-window=no",
      "--input-ipc-server=" + root.socketPath,
      "--volume=" + Math.round(root.volume),
      "--loop-playlist=" + (root.repeatAll ? "inf" : "no")
    ])
    retryTimer.restart()
  }

  function mpvAttached() {
    starting = false
    startFailed = false
    retryTimer.stop()
    var props = ["pause", "duration", "volume", "path", "idle-active", "metadata", "loop-playlist"]
    for (var i = 0; i < props.length; i++) sendNow(["observe_property", i + 1, props[i]])
    var queued = pending
    pending = []
    for (var j = 0; j < queued.length; j++) sendNow(queued[j])
    Model.broadcast({ type: "attach" })
  }

  function mpvDetached() {
    playingPath = ""
    idle = true
    paused = false
    position = 0
    duration = 0
    metadata = ({})
  }

  function handleMpv(line) {
    var msg = Model.parseMpvLine(line)
    if (!msg) return
    if (msg.request_id === 100) {
      if (msg.error === "success" && typeof msg.data === "number") position = msg.data
      return
    }
    if (msg.event !== "property-change") return
    var d = msg.data
    switch (msg.name) {
    case "pause": paused = d === true; break
    case "duration": duration = typeof d === "number" ? d : 0; break
    case "volume": if (typeof d === "number") volume = Math.min(100, d); break
    case "path": playingPath = typeof d === "string" ? d : ""; position = 0; break
    case "idle-active": idle = d === true; break
    case "metadata": metadata = d && typeof d === "object" ? d : ({}); break
    case "loop-playlist": repeatAll = d === "inf" || d === true; break
    }
  }

  function onBus(msg) {
    if (!msg) return
    if (msg.type === "attach" && !mpv.connected) mpv.connected = true
    else if (msg.type === "shuffle") shuffle = msg.value === true
  }

  Component.onCompleted: {
    Model.subscribe(onBus)
    mpv.connected = true
  }
  Component.onDestruction: Model.unsubscribe(onBus)

  // ------------------------------------------------------------ actions
  // Hand mpv a fresh queue that starts at tracks[index].
  function playIndex(index) {
    var order = Model.playOrder(tracks.length, index, shuffle, repeatAll, Math.random)
    if (order.length === 0) return
    queueFile.setText(Model.pathsFor(tracks, order))
    send(["loadlist", root.queuePath, "replace"])
    send(["set_property", "pause", false])
  }

  // Rebuild what comes after the current track, leaving it playing; used when
  // shuffle or repeat changes mid-play.
  function requeueRest() {
    if (!active || currentIndex < 0) return
    var order = Model.playOrder(tracks.length, currentIndex, shuffle, repeatAll, Math.random).slice(1)
    sendNow(["playlist-clear"])
    if (order.length === 0) return
    queueFile.setText(Model.pathsFor(tracks, order))
    sendNow(["loadlist", root.queuePath, "append"])
  }

  function playCursor() {
    if (cursor >= 0 && cursor < filtered.length) playIndex(filtered[cursor])
  }

  function togglePause() {
    if (active) sendNow(["cycle", "pause"])
    else if (filtered.length > 0) playIndex(filtered[Math.max(0, cursor)])
  }

  function next() { if (active) sendNow(["playlist-next"]) }

  function previous() {
    if (!active) return
    if (position > 3) sendNow(["seek", 0, "absolute"])
    else sendNow(["playlist-prev"])
  }

  function stop() { if (connected) sendNow(["quit"]) }

  function seek(seconds) {
    if (!active) return
    position = seconds
    sendNow(["seek", seconds, "absolute"])
  }

  function setVolume(v) {
    volume = v
    sendNow(["set_property", "volume", Math.round(v)])
  }

  function toggleShuffle() {
    shuffle = !shuffle
    Model.broadcast({ type: "shuffle", value: shuffle })
    requeueRest()
  }

  function toggleRepeat() {
    repeatAll = !repeatAll
    sendNow(["set_property", "loop-playlist", repeatAll ? "inf" : "no"])
    requeueRest()
  }

  function moveCursor(delta) {
    if (filtered.length === 0) { cursor = -1; return }
    cursor = Model.clampCursor(cursor + delta, filtered.length)
  }

  onOpenedChanged: {
    if (!opened) return
    rescan()
    var at = filtered.indexOf(currentIndex)
    cursor = at >= 0 ? at : Model.clampCursor(cursor, filtered.length)
  }

  ShellIpc {
    target: "io.github.fsdias.simplex-music-player"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function playPause() { if (!root.scanned) root.rescan(); root.togglePause() }
    function next() { root.next() }
    function previous() { root.previous() }
    function stop() { root.stop() }
    function setFolder(path: string): void { root.setFolder(path) }
    function chooseFolder(): void { root.chooseFolder() }
    function chooseFiles(): void { root.chooseFiles() }
  }

  // ------------------------------------------------------------ bar button
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.playing ? "󰝚" : "󰎈"
    tooltipText: root.active ? root.currentTitle : ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePause()
      else if (b === Qt.MiddleButton) root.next()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent ? panel.loadedContent.filterField : null
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: FocusScope {
      id: body
      property alias filterField: filterInput
      anchors.fill: parent
      implicitHeight: column.implicitHeight

      // Sees keys before the search line; what it leaves is typed there.
      Item {
        id: keyHandler
        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          var k = event.key
          if (k === Qt.Key_Escape) {
            if (filterInput.text !== "") filterInput.text = ""
            else root.close()
          } else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
            root.switchPanel((event.modifiers & Qt.ShiftModifier) || k === Qt.Key_Backtab ? -1 : 1)
          } else if (k === Qt.Key_Down) root.moveCursor(1)
          else if (k === Qt.Key_Up) root.moveCursor(-1)
          else if (k === Qt.Key_PageDown) root.moveCursor(8)
          else if (k === Qt.Key_PageUp) root.moveCursor(-8)
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.playCursor()
          else if (ctrl && k === Qt.Key_Space) root.togglePause()
          else if (ctrl && k === Qt.Key_Right) root.next()
          else if (ctrl && k === Qt.Key_Left) root.previous()
          else if (ctrl && k === Qt.Key_S) root.toggleShuffle()
          else if (ctrl && k === Qt.Key_R) root.toggleRepeat()
          else return
          event.accepted = true
        }
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Now playing ----------
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            id: heroIcon
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "󰝚"
            color: root.playing ? Commons.Color.accent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - heroIcon.width - parent.spacing
            spacing: Style.space(2)

            PlainLabel {
              width: parent.width
              text: root.active ? root.currentTitle : strings.t("nothingPlaying")
              font.pixelSize: Style.font.title
              font.bold: true
            }

            PlainLabel {
              width: parent.width
              opacity: 0.65
              font.pixelSize: Style.font.caption
              text: {
                if (root.startFailed) return strings.t("mpvFailed")
                if (root.active) return root.paused ? strings.t("paused") + (root.currentDetail ? " · " + root.currentDetail : "") : root.currentDetail
                if (!root.scanned) return strings.t("scanning")
                if (root.tracks.length === 0) return strings.t("noTracks").arg(root.folderLabel)
                return strings.tn("tracks", root.tracks.length).arg(Commons.I18n.formatNumber(root.tracks.length)).arg(root.folderLabel)
              }
            }
          }
        }

        // ---------- Seek ----------
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.active && root.duration > 0

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: Math.max(1, root.duration)
            step: 5
            value: root.position
            onReleased: function(v) { root.seek(v) }
          }

          Item {
            width: parent.width
            implicitHeight: elapsed.implicitHeight
            LayoutMirroring.enabled: false
            PlainLabel { id: elapsed; anchors.left: parent.left; opacity: 0.6; font.pixelSize: Style.font.caption; text: Model.formatTime(root.position) }
            PlainLabel { anchors.right: parent.right; opacity: 0.6; font.pixelSize: Style.font.caption; text: Model.formatTime(root.duration) }
          }
        }

        // ---------- Transport ----------
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)
          LayoutMirroring.enabled: false
          LayoutMirroring.childrenInherit: true

          Button {
            iconText: "󰒝"
            tooltipText: strings.t("shuffle")
            foreground: root.bar.foreground
            active: root.shuffle
            onClicked: root.toggleShuffle()
          }
          Button {
            iconText: "󰒮"
            foreground: root.bar.foreground
            enabled: root.active
            opacity: enabled ? 1 : 0.4
            onClicked: root.previous()
          }
          Button {
            iconText: root.playing ? "󰏤" : "󰐊"
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.panelGap
            iconSize: Style.font.iconLarge
            enabled: root.active || root.filtered.length > 0
            opacity: enabled ? 1 : 0.4
            onClicked: root.togglePause()
          }
          Button {
            iconText: "󰒭"
            foreground: root.bar.foreground
            enabled: root.active
            opacity: enabled ? 1 : 0.4
            onClicked: root.next()
          }
          Button {
            iconText: "󰓛"
            tooltipText: strings.t("stop")
            foreground: root.bar.foreground
            enabled: root.connected
            opacity: enabled ? 1 : 0.4
            onClicked: root.stop()
          }
          Button {
            iconText: "󰑖"
            tooltipText: strings.t("repeat")
            foreground: root.bar.foreground
            active: root.repeatAll
            onClicked: root.toggleRepeat()
          }
        }

        // ---------- Volume ----------
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            id: volIcon
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.volume <= 0 ? "󰝟" : (root.volume < 50 ? "󰖀" : "󰕾")
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.iconLarge
          }

          PanelSlider {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - volIcon.width - volLabel.width - parent.spacing * 2
            bar: root.bar
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.volume
            onMoved: function(v) { root.setVolume(v) }
          }

          PlainLabel {
            id: volLabel
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(34)
            horizontalAlignment: Text.AlignRight
            font.pixelSize: Style.font.bodySmall
            text: Commons.I18n.formatNumber(Math.round(root.volume))
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Folder ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(folderText.implicitHeight, folderButtons.implicitHeight)

          Text {
            id: folderIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "󰉋"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          PlainLabel {
            id: folderText
            anchors.left: folderIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.right: folderButtons.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideMiddle
            font.pixelSize: Style.font.bodySmall
            text: root.folderLabel
          }

          Row {
            id: folderButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Button {
              text: strings.t("changeFolder")
              tooltipText: strings.t("chooseFolderTitle")
              foreground: root.bar.foreground
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.chooseFolder()
            }
            Button {
              text: strings.t("openFiles")
              tooltipText: strings.t("chooseFilesTitle")
              foreground: root.bar.foreground
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.chooseFiles()
            }
            Button {
              iconText: "󰑐"
              tooltipText: strings.t("rescan")
              foreground: root.bar.foreground
              onClicked: root.rescan()
            }
          }
        }

        // Recent folders, one click to switch back.
        Flow {
          width: parent.width
          spacing: Style.space(4)
          visible: recentRepeater.count > 0

          Repeater {
            id: recentRepeater
            model: root.recentFolders.filter(function(f) { return Model.expandHome(f, root.home) !== root.folder })
            Button {
              required property string modelData
              text: Model.basename(modelData) || modelData
              tooltipText: modelData
              iconText: "󰉋"
              foreground: root.bar.foreground
              fontSize: Style.font.caption
              iconSize: Style.font.caption
              onClicked: root.setFolder(modelData)
            }
          }
        }

        // ---------- Search ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(filterInput.implicitHeight, Style.space(24))

          Text {
            id: searchIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "󰍉"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          FilterInput {
            id: filterInput
            anchors.left: searchIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            keyHandler: keyHandler
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.query = text
          }

          PlainLabel {
            anchors.fill: filterInput
            verticalAlignment: Text.AlignVCenter
            visible: filterInput.text === "" && !filterInput.preeditText
            opacity: 0.5
            font.pixelSize: Style.font.body
            text: strings.t("search")
          }
        }

        // ---------- Track list ----------
        ListView {
          id: list
          width: parent.width
          height: Math.min(contentHeight, Style.space(340))
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          model: root.filtered
          currentIndex: root.cursor
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(function() { list.positionViewAtIndex(list.currentIndex, ListView.Contain) })

          delegate: Rectangle {
            id: row
            required property int modelData
            required property int index
            readonly property var track: root.tracks[modelData] || ({ name: "", folder: "" })
            readonly property bool isCurrent: root.active && modelData === root.currentIndex
            readonly property bool hasCursor: index === root.cursor

            width: ListView.view.width
            height: rowColumn.implicitHeight + Style.space(10)
            radius: Style.spacing.labelGap
            color: hasCursor || rowMouse.containsMouse
              ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent, Commons.Color.urgent)
              : "transparent"

            Text {
              id: rowGlyph
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              textFormat: Text.PlainText
              text: row.isCurrent ? (root.paused ? "󰏤" : "󰐊") : "󰎈"
              color: row.isCurrent ? Commons.Color.accent : root.bar.foreground
              opacity: row.isCurrent ? 1 : 0.4
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            Column {
              id: rowColumn
              anchors.left: rowGlyph.right
              anchors.leftMargin: Style.space(6)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter

              PlainLabel {
                width: parent.width
                text: row.track.name
                color: row.isCurrent ? Commons.Color.accent : root.bar.foreground
                font.pixelSize: Style.font.bodySmall
                font.bold: row.isCurrent
              }
              PlainLabel {
                width: parent.width
                visible: text !== ""
                text: row.track.folder
                opacity: 0.55
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.cursor = row.index; root.playIndex(row.modelData) }
            }
          }
        }

        PlainLabel {
          width: parent.width
          visible: root.scanned && root.tracks.length > 0 && root.filtered.length === 0
          horizontalAlignment: Text.AlignHCenter
          opacity: 0.6
          font.pixelSize: Style.font.bodySmall
          text: strings.t("noMatches")
        }
      }
    }
  }

  component PlainLabel: Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.bar ? root.bar.foreground : Commons.Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
  }
}
