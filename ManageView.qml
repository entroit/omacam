import QtQuick
import qs.Commons
import qs.Ui
import "Brands.js" as Brands
import "Shared.js" as Shared

// Every camera in one list: drag to reorder (the order sets the 1-9 keys and
// the dropdown order), hide/show, edit, delete with an inline confirmation.
Column {
  id: root

  required property var ctx
  readonly property var pal: ctx.pal
  readonly property var cams: ctx.store.cameras
  property string confirmId: ""
  readonly property int rowHeight: 62

  // Full-stream resolution, looked up once per camera in the background
  // (or already known from an enlarged / fullscreen / pinned view).
  property int resolutionsKnown: 0
  function resolutionOf(id) {
    resolutionsKnown   // re-evaluate when a lookup finishes
    return Shared.mainResolution[id] || ""
  }

  property var lookupQueue: []
  function lookupNext() {
    while (lookupQueue.length > 0) {
      var cam = lookupQueue.shift()
      if (Shared.mainResolution[cam.id] || cam.enabled === false) continue
      lookup.cameraId = cam.id
      lookup.probe(Brands.streamUrl(cam, "main"))
      return
    }
  }
  Probe {
    id: lookup
    property string cameraId: ""
    onFinished: function(r) {
      if (r.ok && r.width > 0) { Shared.mainResolution[cameraId] = r.width + "\u00d7" + r.height; root.resolutionsKnown++ }
      root.lookupNext()
    }
  }
  Component.onCompleted: { lookupQueue = cams.slice(); lookupNext() }

  spacing: 10

  // --- header ---------------------------------------------------------------
  Item {
    width: parent.width
    height: 32
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 12
      ActionButton { pal: root.pal; icon: "\u{F0141}"; text: "Cameras"; onClicked: root.ctx.view = "grid" }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Manage cameras"
        font.family: root.pal.font
        font.pixelSize: Style.font.heading + 2
        font.weight: Font.Bold
        color: root.pal.fg
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.cams.length
        font.family: root.pal.font
        font.pixelSize: Style.font.bodySmall
        color: root.pal.dim
      }
    }
    Row {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      spacing: 6
      ActionButton { pal: root.pal; variant: "primary"; icon: "\u{F0415}"; text: "Add camera"; onClicked: root.ctx.openForm(null, "manage") }
      ActionButton { pal: root.pal; variant: "plain"; icon: "\u{F0156}"; onClicked: root.ctx.close() }
    }
  }

  // --- column labels ----------------------------------------------------------
  Item {
    width: parent.width
    height: 22
    component ColLabel: Text {
      anchors.verticalCenter: parent.verticalCenter
      font.family: root.pal.font
      font.pixelSize: 10
      font.letterSpacing: 1.5
      color: root.pal.dim
    }
    ColLabel { x: 30; text: "KEY" }
    ColLabel { x: 160; text: "CAMERA" }
    ColLabel { x: parent.width - 330; text: "BRAND" }
    ColLabel { x: parent.width - 190; text: "STATUS" }
  }

  Rectangle { width: parent.width; height: 1; color: root.pal.line }

  // --- rows -------------------------------------------------------------------
  Column {
    id: list
    width: parent.width

    Repeater {
      model: root.cams
      delegate: Item {
        id: row
        required property var modelData
        required property int index
        readonly property bool confirming: root.confirmId === modelData.id
        readonly property bool hidden: modelData.enabled === false
        property real dragOffset: 0
        property bool dragging: false

        width: list.width
        height: root.rowHeight
        z: dragging ? 10 : 0

        Rectangle {
          id: card
          width: parent.width
          height: parent.height
          y: row.dragOffset
          radius: root.pal.radius
          color: row.confirming ? root.pal.tint(root.pal.urgent, 0.10)
               : row.dragging ? root.pal.raised
               : rowHover.hovered ? root.pal.tint(root.pal.fg, 0.05) : "transparent"
          border.width: row.dragging ? 1 : 0
          border.color: root.pal.lineStrong

          Rectangle {
            visible: row.confirming
            width: 3; height: parent.height
            color: root.pal.urgent
          }

          HoverHandler { id: rowHover }

          // Drag handle
          Text {
            id: handle
            x: 8; anchors.verticalCenter: parent.verticalCenter
            text: "\u{F01DD}"   // nf-md-drag_vertical
            font.family: root.pal.font
            font.pixelSize: 16
            color: handleMouse.containsMouse || row.dragging ? root.pal.fg : root.pal.faint
            MouseArea {
              id: handleMouse
              anchors.fill: parent
              anchors.margins: -6
              hoverEnabled: true
              cursorShape: row.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
              property real startY: 0
              onPressed: function(m) { startY = mapToItem(list, m.x, m.y).y; row.dragging = true }
              onPositionChanged: function(m) {
                if (!row.dragging) return
                var y = mapToItem(list, m.x, m.y).y
                row.dragOffset = Math.max(-row.index * root.rowHeight, Math.min((root.cams.length - 1 - row.index) * root.rowHeight, y - startY))
              }
              onReleased: {
                var target = Math.max(0, Math.min(root.cams.length - 1, row.index + Math.round(row.dragOffset / root.rowHeight)))
                row.dragging = false
                row.dragOffset = 0
                if (target !== row.index) root.ctx.store.move(row.index, target)
              }
            }
          }

          // Key number
          Rectangle {
            x: 30; anchors.verticalCenter: parent.verticalCenter
            width: 22; height: 22
            radius: root.pal.radius
            color: "transparent"
            border.width: 1
            border.color: root.pal.line
            Text {
              anchors.centerIn: parent
              text: row.hidden ? "–" : root.ctx.keyFor(row.modelData.id)
              font.family: root.pal.font
              font.pixelSize: 11
              color: root.pal.fg
            }
          }

          // The dropdown's stream of this camera, handed over.
          Rectangle {
            id: thumb
            readonly property alias feed: thumbFeed
            x: 64; anchors.verticalCenter: parent.verticalCenter
            width: 78; height: 44
            radius: root.pal.radius
            color: root.pal.sunken
            clip: true
            opacity: row.hidden ? 0.4 : 1
            CameraFeed {
              id: thumbFeed
              anchors.fill: parent
              pool: root.ctx.pool
              camera: row.modelData
              active: root.ctx.streaming
              showStatus: false
            }
            Text {
              anchors.centerIn: parent
              visible: !thumb.feed.live && (row.hidden || thumb.feed.snapshot === "")
              text: row.hidden ? "\u{F0209}" : thumb.feed.status === "connecting" ? "\u{F0450}" : "\u{F0BDB}"
              font.family: root.pal.font
              font.pixelSize: 16
              color: root.pal.faint
            }
          }

          // Normal content
          Column {
            visible: !row.confirming
            x: 160; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 330 - 160 - 12
            spacing: 3
            Text { width: parent.width; elide: Text.ElideRight; text: row.modelData.name; font.family: root.pal.font; font.pixelSize: Style.font.title; font.weight: Font.DemiBold; color: row.hidden ? root.pal.dim : root.pal.fg }
            Text {
              width: parent.width
              elide: Text.ElideRight
              text: row.modelData.brand === "custom" ? Brands.displayUrl(row.modelData) : [Brands.hostLabel(row.modelData), row.modelData.user].filter(function(s) { return s !== "" }).join(" · ")
              font.family: root.pal.font
              font.pixelSize: Style.font.caption + 1
              color: root.pal.dim
            }
          }
          Text {
            visible: !row.confirming
            x: parent.width - 330; anchors.verticalCenter: parent.verticalCenter
            width: 130
            elide: Text.ElideRight
            text: Brands.label(row.modelData.brand).replace("Other / ", "")
            font.family: root.pal.font
            font.pixelSize: Style.font.bodySmall
            color: root.pal.fg
          }
          Column {
            visible: !row.confirming
            x: parent.width - 190; anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Row {
              spacing: 6
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 7; height: 7; radius: 3.5
                color: row.hidden ? root.pal.faint : thumb.feed.live ? root.pal.ok : thumb.feed.status === "connecting" ? root.pal.warn : root.pal.urgent
              }
              Text {
                text: row.hidden ? "Hidden" : thumb.feed.live ? "Live" : thumb.feed.status === "connecting" ? "Connecting" : thumb.feed.status === "auth" ? "Wrong password" : "Offline"
                font.family: root.pal.font
                font.pixelSize: Style.font.bodySmall
                color: row.hidden ? root.pal.dim : thumb.feed.live ? root.pal.ok : thumb.feed.status === "connecting" ? root.pal.warn : root.pal.urgent
              }
            }
            Text {
              leftPadding: 13
              visible: text !== ""
              text: root.resolutionOf(row.modelData.id)
              font.family: root.pal.font
              font.pixelSize: Style.font.caption + 1
              color: root.pal.dim
            }
          }
          Row {
            visible: !row.confirming
            anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
            spacing: 2
            ActionButton { pal: root.pal; variant: "plain"; icon: row.hidden ? "\u{F0209}" : "\u{F0208}"; onClicked: root.ctx.store.setEnabled(row.modelData.id, row.hidden) }
            ActionButton { pal: root.pal; variant: "plain"; icon: "\u{F03EB}"; onClicked: root.ctx.openForm(row.modelData, "manage") }
            ActionButton { pal: root.pal; variant: "plain"; icon: "\u{F0A7A}"; onClicked: root.confirmId = row.modelData.id }   // nf-md-trash_can_outline
          }

          // Delete confirmation
          Column {
            visible: row.confirming
            x: 160; anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            Text { text: "Delete “" + row.modelData.name + "”?"; font.family: root.pal.font; font.pixelSize: Style.font.title; font.weight: Font.DemiBold; color: root.pal.fg }
            Text { text: "It's removed from OmaCam only. Nothing on the camera changes."; font.family: root.pal.font; font.pixelSize: Style.font.caption + 1; color: root.pal.dim }
          }
          Row {
            visible: row.confirming
            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
            spacing: 8
            ActionButton { pal: root.pal; text: "Cancel"; onClicked: root.confirmId = "" }
            ActionButton { pal: root.pal; variant: "danger"; text: "Delete"; onClicked: { root.ctx.unpin(row.modelData.id); root.ctx.store.remove(row.modelData.id); root.confirmId = "" } }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width; height: 1
          color: root.pal.line
          visible: !row.dragging
        }
      }
    }
  }

  // --- connection settings ----------------------------------------------------
  Item { width: parent.width; height: 6 }

  Text {
    text: "CONNECTION"
    font.family: root.pal.font
    font.pixelSize: 10
    font.letterSpacing: 1.5
    color: root.pal.dim
  }

  Rectangle {
    width: parent.width
    height: settingsCol.implicitHeight + 24
    radius: root.pal.radius
    color: root.pal.tint(root.pal.fg, 0.03)
    border.width: 1
    border.color: root.pal.line

    Column {
      id: settingsCol
      x: 14; y: 12
      width: parent.width - 28
      spacing: 14

      // Always connected
      Item {
        width: parent.width
        height: Math.max(alwaysText.implicitHeight, alwaysSwitch.implicitHeight)
        Column {
          id: alwaysText
          anchors { left: parent.left; right: alwaysSwitch.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
          spacing: 3
          Text { text: "Keep cameras connected all the time"; font.family: root.pal.font; font.pixelSize: Style.font.title; font.weight: Font.DemiBold; color: root.pal.fg }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Cameras open live instantly, with no time limit. Uses about 2% of one CPU core in the background."
            font.family: root.pal.font
            font.pixelSize: Style.font.caption + 1
            color: root.pal.dim
          }
        }
        ToggleSwitch {
          id: alwaysSwitch
          anchors { right: parent.right; verticalCenter: parent.verticalCenter }
          checked: root.ctx.alwaysConnected
          onToggled: root.ctx.config.set("connection.alwaysConnected", !root.ctx.alwaysConnected)
        }
      }

      Rectangle { visible: !root.ctx.alwaysConnected; width: parent.width; height: 1; color: root.pal.line }

      // Grace period after closing (only relevant when not always connected)
      Item {
        visible: !root.ctx.alwaysConnected
        width: parent.width
        height: Math.max(graceText.implicitHeight, graceButtons.implicitHeight)
        Column {
          id: graceText
          anchors { left: parent.left; right: graceButtons.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
          spacing: 3
          Text { text: "Otherwise, stay connected after closing"; font.family: root.pal.font; font.pixelSize: Style.font.title; font.weight: Font.DemiBold; color: root.pal.fg }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Reopening within this time is instant. Off disconnects right away."
            font.family: root.pal.font
            font.pixelSize: Style.font.caption + 1
            color: root.pal.dim
          }
        }
        Row {
          id: graceButtons
          anchors { right: parent.right; verticalCenter: parent.verticalCenter }
          spacing: 4
          Repeater {
            model: [{ s: 0, t: "Off" }, { s: 60, t: "1 min" }, { s: 180, t: "3 min" }, { s: 600, t: "10 min" }, { s: 1800, t: "30 min" }]
            delegate: ActionButton {
              required property var modelData
              pal: root.pal
              text: modelData.t
              selected: root.ctx.keepWarmSeconds === modelData.s
              onClicked: root.ctx.config.set("connection.keepConnectedSeconds", modelData.s)
            }
          }
        }
      }
    }
  }

  // --- footer -----------------------------------------------------------------
  Item {
    width: parent.width
    height: 26
    Text {
      anchors.verticalCenter: parent.verticalCenter
      // A config.json that isn't valid JSON is ignored until it's fixed.
      text: root.ctx.config.error !== ""
        ? "config.json has an error, using the last good settings: " + root.ctx.config.error
        : "Drag to reorder — the order here is the order in the dropdown and the 1-9 keys."
      font.family: root.pal.font
      font.pixelSize: Style.font.caption + 1
      color: root.ctx.config.error !== "" ? root.pal.warn : root.pal.dim
    }
    Text {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      text: "~/.config/omacam/"
      font.family: root.pal.font
      font.pixelSize: Style.font.caption + 1
      color: root.pal.faint
    }
  }
}
