import QtQuick
import QtMultimedia
import qs.Commons
import "Config.js" as Config

// Dropdown home: every camera as a small live tile (two per row by default).
Column {
  id: root

  required property var ctx
  readonly property var pal: ctx.pal
  readonly property var cams: ctx.store.enabledCameras
  readonly property var cfg: ctx.config
  readonly property int columns: Math.max(1, Math.round(Number(cfg.dropdown.columns) || 2))
  property int liveCount: 0
  property int cursor: -1

  spacing: 12

  function recount() {
    var n = 0
    for (var i = 0; i < tiles.count; i++) {
      var t = tiles.itemAt(i)
      if (t && t.feed.live) n++
    }
    liveCount = n
  }

  Timer { interval: 1000; repeat: true; running: root.visible; onTriggered: root.recount() }

  // --- header ---------------------------------------------------------------
  Item {
    width: parent.width
    height: 30

    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 10
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Cameras"
        font.family: root.pal.font
        font.pixelSize: Style.font.heading
        font.weight: Font.Bold
        color: root.pal.fg
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.cams.length > 0 && root.liveCount < root.cams.length
        text: root.liveCount + " of " + root.cams.length + " live"
        font.family: root.pal.font
        font.pixelSize: Style.font.bodySmall
        color: root.pal.dim
      }
    }

    Row {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      spacing: 4
      ActionButton { pal: root.pal; variant: "plain"; icon: "\u{F0415}"; onClicked: root.ctx.openForm(null, "grid") }                          // nf-md-plus
      ActionButton { pal: root.pal; variant: "plain"; icon: "\u{F0493}"; visible: root.ctx.store.cameras.length > 0; onClicked: root.ctx.view = "manage" } // nf-md-cog
    }
  }

  // --- empty state ----------------------------------------------------------
  Column {
    visible: root.ctx.store.loaded && root.cams.length === 0
    width: parent.width
    spacing: 12
    topPadding: 18
    bottomPadding: 18

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: 60; height: 60
      radius: Math.max(root.pal.radius, 10)
      color: root.pal.raised
      border.width: 1
      border.color: root.pal.line
      Text {
        anchors.centerIn: parent
        text: "\u{F0567}"
        font.family: root.pal.font
        font.pixelSize: 26
        color: root.pal.accent
      }
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.ctx.store.cameras.length > 0 ? "All cameras are hidden" : "No cameras yet"
      font.family: root.pal.font
      font.pixelSize: Style.font.heading + 2
      font.weight: Font.Bold
      color: root.pal.fg
    }
    Text {
      width: parent.width - 40
      anchors.horizontalCenter: parent.horizontalCenter
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: root.ctx.store.cameras.length > 0
        ? "Show them again from Manage cameras."
        : "Add an IP camera with its address, username and password. It will show up here, one click from the bar."
      font.family: root.pal.font
      font.pixelSize: Style.font.body
      lineHeight: 1.3
      color: root.pal.dim
    }
    ActionButton {
      anchors.horizontalCenter: parent.horizontalCenter
      pal: root.pal
      variant: "primary"
      icon: root.ctx.store.cameras.length > 0 ? "\u{F0493}" : "\u{F0415}"
      text: root.ctx.store.cameras.length > 0 ? "Manage cameras" : "Add your first camera"
      onClicked: root.ctx.store.cameras.length > 0 ? root.ctx.view = "manage" : root.ctx.openForm(null, "grid")
    }
  }

  // --- tiles ----------------------------------------------------------------
  Flow {
    id: flow
    visible: root.cams.length > 0
    width: parent.width
    spacing: 10
    readonly property real tileW: (width - spacing * (root.columns - 1)) / root.columns

    Repeater {
      id: tiles
      model: root.cams
      delegate: CameraTile {
        required property var modelData
        required property int index
        pal: root.pal
        pool: root.ctx.pool
        camera: modelData
        number: index + 1
        showNumber: root.cfg.dropdown.showNumbers && root.cfg.keys.cameraNumbers && index < 9   // 1-9 (or the numpad) open it
        fillMode: VideoOutput.PreserveAspectFit   // whole picture, never cropped
        width: flow.tileW
        height: Math.round(width * 9 / 16)
        active: root.ctx.streaming   // keep running behind other views so going back is instant
        shown: root.ctx.opened && root.ctx.view === "grid"
        selected: root.cursor === index
        onClicked: root.ctx.cameraAction(root.cfg.dropdown.click, modelData.id)
        onDoubleClicked: root.ctx.cameraAction(root.cfg.dropdown.doubleClick, modelData.id)
      }
    }
  }

  // --- footer ---------------------------------------------------------------
  Rectangle { visible: root.cams.length > 0; width: parent.width; height: 1; color: root.pal.line }

  Item {
    visible: root.cams.length > 0
    width: parent.width
    height: 30

    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 6
      Repeater {
        model: [["click", root.cfg.dropdown.click], ["dbl", root.cfg.dropdown.doubleClick], [root.cfg.keys.cameraNumbers ? "1-9" : "", "open"], [Config.label(root.cfg.keys.dropdown.close), "close"]]
          .filter(function(h) { return h[0] !== "" && h[1] !== "none" })
        delegate: Row {
          required property var modelData
          spacing: 5
          Rectangle {
            width: keyText.implicitWidth + 10; height: 20
            radius: root.pal.radius
            color: "transparent"
            border.width: 1
            border.color: root.pal.line
            Text { id: keyText; anchors.centerIn: parent; text: modelData[0]; font.family: root.pal.font; font.pixelSize: 10; color: root.pal.fg }
          }
          Text { anchors.verticalCenter: parent.verticalCenter; text: modelData[1]; font.family: root.pal.font; font.pixelSize: 10; color: root.pal.dim; rightPadding: 4 }
        }
      }
    }

    ActionButton {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      visible: root.cams.length > 1
      pal: root.pal
      variant: "primary"
      icon: "\u{F0570}"
      text: "View all"
      onClicked: root.ctx.openWall()
    }
  }
}
