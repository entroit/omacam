import QtQuick
import QtMultimedia
import qs.Commons
import "Config.js" as Config
import "Brands.js" as Brands

// One camera, large, with the other cameras stacked on the right. Clicking a
// side feed swaps it in.
Column {
  id: root

  required property var ctx
  readonly property var pal: ctx.pal
  readonly property var cams: ctx.store.enabledCameras
  readonly property int index: {
    for (var i = 0; i < cams.length; i++) if (cams[i].id === ctx.focusId) return i
    return -1
  }
  readonly property var camera: index >= 0 ? cams[index] : null
  readonly property var others: cams.filter(function(c) { return c.id !== root.ctx.focusId })
  readonly property int railWidth: 296

  spacing: 12

  // The enlarged camera may play sound; it takes the sound when it opens.
  Component.onCompleted: ctx.claimSound("enlarged")
  Component.onDestruction: ctx.releaseSound("enlarged")

  // --- header ---------------------------------------------------------------
  Item {
    width: parent.width
    height: 30

    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 12
      ActionButton { pal: root.pal; icon: "\u{F0141}"; text: "All cameras"; onClicked: root.ctx.view = "grid" }   // nf-md-chevron_left
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.camera ? root.camera.name : ""
        font.family: root.pal.font
        font.pixelSize: Style.font.heading + 2
        font.weight: Font.Bold
        color: root.pal.fg
      }
    }

    ActionButton {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      pal: root.pal
      variant: "plain"
      icon: "\u{F0156}"   // nf-md-close
      onClicked: root.ctx.close()
    }
  }

  // --- body -----------------------------------------------------------------
  Row {
    width: parent.width
    spacing: 14

    Column {
      id: main
      width: parent.width - (root.others.length > 0 ? root.railWidth + parent.spacing : 0)
      spacing: 12

      CameraTile {
        id: big
        pal: root.pal
        pool: root.ctx.pool
        camera: root.camera
        width: parent.width
        height: Math.round(width * 9 / 16)
        quality: "main"
        active: root.ctx.streaming && root.ctx.view === "camera"
        fillMode: VideoOutput.PreserveAspectFit
        showBadge: false
        showMeta: false
        showName: false
        onDoubleClicked: root.ctx.openFullscreen(root.ctx.focusId)

        Row {
          anchors.centerIn: parent
          anchors.verticalCenterOffset: 84
          spacing: 8
          visible: !big.feed.live && big.feed.status !== "connecting" && big.feed.status !== "idle"
          ActionButton { pal: root.pal; text: "Retry"; onClicked: big.feed.retry() }
          ActionButton { pal: root.pal; icon: "\u{F03EB}"; text: "Edit camera"; onClicked: root.ctx.openForm(root.camera, "camera") }
        }
      }

      Item {
        width: parent.width
        height: 32

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6
          ActionButton { pal: root.pal; icon: "\u{F0141}"; enabled: root.cams.length > 1; onClicked: root.ctx.step(-1) }
          ActionButton { pal: root.pal; icon: "\u{F0142}"; enabled: root.cams.length > 1; onClicked: root.ctx.step(1) }  // nf-md-chevron_right
          Text {
            anchors.verticalCenter: parent.verticalCenter
            leftPadding: 6
            text: (root.index + 1) + " / " + root.cams.length
            font.family: root.pal.font
            font.pixelSize: Style.font.bodySmall
            color: root.pal.dim
          }
        }

        Row {
          anchors { right: parent.right; verticalCenter: parent.verticalCenter }
          spacing: 6
          SoundButton {
            pal: root.pal
            sound: root.ctx.sound.soundOf(root.ctx.focusId)
            on: root.ctx.soundOn(root.ctx.focusId, "enlarged")
            key: Config.label(root.ctx.config.keys.enlarged.sound)
            onClicked: root.ctx.toggleSound(root.ctx.focusId, "enlarged")
          }
          ActionButton { pal: root.pal; icon: "\u{F03EB}"; text: "Edit camera"; onClicked: root.ctx.openForm(root.camera, "camera") }   // nf-md-pencil
          ActionButton {
            pal: root.pal
            icon: "\u{F0403}"        // nf-md-pin
            text: root.ctx.isPinned(root.ctx.focusId) ? "Pinned" : "Pin"
            hint: root.ctx.isPinned(root.ctx.focusId) ? "" : "keep on desktop"
            selected: root.ctx.isPinned(root.ctx.focusId)
            onClicked: root.ctx.togglePin(root.ctx.focusId)
          }
          ActionButton { pal: root.pal; variant: "primary"; icon: "\u{F0293}"; text: "Fullscreen"; hint: Config.label(root.ctx.config.keys.enlarged.fullscreen); onClicked: root.ctx.openFullscreen(root.ctx.focusId) }  // nf-md-fullscreen
        }
      }
    }

    // --- side feeds ---------------------------------------------------------
    Column {
      visible: root.others.length > 0
      width: root.railWidth
      spacing: 8

      Item {
        width: parent.width
        height: 18
        Text { text: "OTHER CAMERAS"; font.family: root.pal.font; font.pixelSize: 10; font.letterSpacing: 1.5; color: root.pal.dim; anchors.verticalCenter: parent.verticalCenter }
        Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "click to swap"; font.family: root.pal.font; font.pixelSize: 10; color: root.pal.faint }
      }

      Flickable {
        width: parent.width
        height: main.height - 26
        contentHeight: rail.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: rail
          width: parent.width
          spacing: 8

          Repeater {
            model: root.others
            delegate: Rectangle {
              id: row
              required property var modelData
              width: rail.width
              height: 76
              radius: root.pal.radius
              color: rowMouse.containsMouse ? root.pal.tint(root.pal.fg, 0.07) : root.pal.tint(root.pal.fg, 0.03)
              border.width: 1
              border.color: rowMouse.containsMouse ? root.pal.tint(root.pal.accent, 0.6) : root.pal.line

              // The dropdown's stream of this camera, handed over.
              Rectangle {
                id: thumb
                readonly property alias feed: thumbFeed
                x: 8; anchors.verticalCenter: parent.verticalCenter
                width: 104; height: 60
                radius: root.pal.radius
                color: root.pal.sunken
                clip: true
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
                  visible: !thumb.feed.live && thumb.feed.snapshot === ""
                  text: thumb.feed.status === "connecting" ? "\u{F0450}" : "\u{F0BDB}"
                  font.family: root.pal.font
                  font.pixelSize: 18
                  color: root.pal.faint
                }
              }
              Column {
                anchors { left: thumb.right; leftMargin: 12; right: dot.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                spacing: 3
                Text { width: parent.width; elide: Text.ElideRight; text: row.modelData.name; font.family: root.pal.font; font.pixelSize: Style.font.subtitle; font.weight: Font.DemiBold; color: root.pal.fg }
                Text {
                  width: parent.width
                  visible: text !== ""
                  elide: Text.ElideRight
                  text: thumb.feed.live ? ""
                      : thumb.feed.status === "connecting" ? "connecting…"
                      : thumb.feed.status === "auth" ? "wrong password"
                      : thumb.feed.status === "idle" ? "" : "offline"
                  font.family: root.pal.font
                  font.pixelSize: Style.font.caption + 1
                  color: thumb.feed.live || thumb.feed.status === "connecting" ? root.pal.dim : root.pal.urgent
                }
              }
              Rectangle {
                id: dot
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                width: 7; height: 7; radius: 3.5
                visible: !thumb.feed.live
                color: thumb.feed.status === "connecting" ? root.pal.warn : root.pal.urgent
              }
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.ctx.focusId = row.modelData.id
              }
            }
          }
        }
      }
    }
  }
}
