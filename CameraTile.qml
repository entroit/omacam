import QtQuick
import QtMultimedia
import qs.Commons

// A camera picture with its name, live badge and meta line. Used for the
// dropdown grid, the camera wall, the fullscreen strip and the side feeds.
Rectangle {
  id: root

  required property var pal
  property var pool: null
  property var camera: null
  property int number: 0
  property string quality: "sub"
  property bool active: true
  property bool shown: true
  property string privateTag: ""
  property bool selected: false
  property bool showNumber: false
  property bool showBadge: true
  property bool showMeta: true
  property bool showName: true
  property bool compact: false
  property bool showStatus: !compact
  property int fillMode: VideoOutput.PreserveAspectCrop
  default property alias overlay: overlayHolder.data

  readonly property alias feed: feed
  readonly property bool hot: mouse.containsMouse

  signal clicked()
  signal doubleClicked()

  radius: pal.radius
  color: pal.sunken
  clip: true
  border.width: selected || hot ? (selected ? 2 : 1) : 1
  border.color: selected ? pal.accent : (hot ? pal.tint(pal.accent, 0.6) : pal.line)

  CameraFeed {
    id: feed
    anchors.fill: parent
    anchors.margins: root.border.width
    pool: root.pool
    camera: root.camera
    quality: root.quality
    active: root.active
    shown: root.shown
    privateTag: root.privateTag
    fillMode: root.fillMode
    showStatus: root.showStatus
  }

  // Scrims keep labels readable on bright pictures.
  Rectangle {
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: Math.min(parent.height * 0.4, 56)
    visible: !root.compact
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.55) }
      GradientStop { position: 1; color: "transparent" }
    }
  }
  Rectangle {
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: Math.min(parent.height * 0.45, 64)
    visible: root.compact && root.showMeta
    gradient: Gradient {
      GradientStop { position: 0; color: "transparent" }
      GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.6) }
    }
  }

  // Top row: number · name ............ status (only when not live)
  Row {
    visible: !root.compact && root.showName
    anchors { left: parent.left; top: parent.top; margins: 10 }
    spacing: 7

    Rectangle {
      visible: root.showNumber && root.number > 0
      width: 20; height: 20
      radius: root.pal.radius
      color: root.selected ? root.pal.accent : Qt.rgba(0, 0, 0, 0.45)
      border.width: 1
      border.color: root.selected ? root.pal.accent : Qt.rgba(1, 1, 1, 0.18)
      Text {
        anchors.centerIn: parent
        text: root.number
        font.family: root.pal.font
        font.pixelSize: 11
        font.weight: Font.Bold
        color: root.selected ? root.pal.bg : "#ffffff"
      }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, root.width - (root.showNumber ? 48 : 20) - (root.showBadge ? 96 : 0))
      elide: Text.ElideRight
      text: root.camera ? root.camera.name : ""
      font.family: root.pal.font
      font.pixelSize: Style.font.subtitle
      font.weight: Font.DemiBold
      color: feed.live ? "#ffffff" : root.pal.fg
      style: Text.Raised
      styleColor: Qt.rgba(0, 0, 0, feed.live ? 0.5 : 0)
    }
  }

  Row {
    visible: !root.compact && root.showBadge && !feed.live && feed.status !== "idle"
    anchors { right: parent.right; top: parent.top; margins: 11 }
    spacing: 5
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: 6; height: 6; radius: 3
      color: feed.status === "connecting" ? root.pal.warn : root.pal.urgent
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: feed.status === "connecting" ? "CONNECTING" : feed.status === "auth" ? "WRONG PASSWORD" : "OFFLINE"
      font.family: root.pal.font
      font.pixelSize: 10
      font.letterSpacing: 1
      color: root.pal.fg
    }
  }

  // Bottom: the compact strip label (cameras stamp their own time).
  Text {
    visible: root.showMeta && root.compact
    anchors { left: parent.left; bottom: parent.bottom; leftMargin: root.compact ? 8 : 10; bottomMargin: root.compact ? 6 : 8 }
    width: parent.width - 20
    elide: Text.ElideRight
    text: root.camera ? root.camera.name : ""
    font.family: root.pal.font
    font.pixelSize: 11
    font.weight: Font.DemiBold
    color: "#ffffff"
    opacity: root.compact && !feed.live ? 0.6 : 1
  }

  Rectangle {
    visible: root.compact && root.showNumber && root.number > 0
    anchors { left: parent.left; top: parent.top; margins: 6 }
    width: 18; height: 18
    radius: root.pal.radius
    color: root.selected ? root.pal.accent : Qt.rgba(0, 0, 0, 0.5)
    Text {
      anchors.centerIn: parent
      text: root.number
      font.family: root.pal.font
      font.pixelSize: 10
      font.weight: Font.Bold
      color: root.selected ? root.pal.bg : "#ffffff"
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: clickTimer.restart()
    onDoubleClicked: { clickTimer.stop(); root.doubleClicked() }
  }

  // Delay single clicks briefly so a double click doesn't also enlarge.
  Timer {
    id: clickTimer
    interval: 220
    onTriggered: root.clicked()
  }

  Item {
    id: overlayHolder
    anchors.fill: parent
  }
}
