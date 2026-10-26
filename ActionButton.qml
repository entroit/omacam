import QtQuick
import qs.Commons

// Compact button used across OmaCam: optional Nerd Font icon, label and a
// trailing key hint. Variants: "ghost" (outlined), "primary" (accent fill),
// "danger" (urgent fill), "plain" (no chrome until hovered).
Rectangle {
  id: root

  required property var pal
  property string icon: ""
  property string text: ""
  property string hint: ""
  property string variant: "ghost"
  property bool selected: false
  property real fontSize: Style.font.body
  property int padX: text === "" ? 7 : 11
  property int padY: 6
  property string tooltip: ""
  // Sits on top of video: use an opaque base so it stays readable.
  property bool solid: false

  signal clicked()

  readonly property bool hot: mouse.containsMouse
  readonly property color fill: variant === "primary" ? pal.accent
                              : variant === "danger" ? pal.urgent
                              : selected ? (solid ? pal.tint(pal.bg, 0.92) : pal.tint(pal.accent, 0.18))
                              : solid ? (hot ? pal.raised : pal.tint(pal.bg, 0.84))
                              : hot ? pal.tint(pal.fg, 0.09)
                              : variant === "plain" ? "transparent"
                              : pal.tint(pal.fg, 0.04)
  readonly property color ink: variant === "primary" || variant === "danger" ? pal.bg
                             : selected ? pal.accent
                             : pal.fg

  implicitWidth: row.implicitWidth + padX * 2
  implicitHeight: Math.max(row.implicitHeight + padY * 2, 28)
  radius: pal.radius
  color: fill
  opacity: enabled ? (hot && (variant === "primary" || variant === "danger") ? 0.88 : 1) : 0.4
  border.width: variant === "ghost" || selected ? 1 : 0
  border.color: selected ? pal.tint(pal.accent, 0.7) : (hot ? pal.lineStrong : pal.line)

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 7

    Text {
      visible: root.icon !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.icon
      font.family: root.pal.font
      font.pixelSize: root.fontSize + 2
      color: root.ink
    }
    Text {
      visible: root.text !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.text
      font.family: root.pal.font
      font.pixelSize: root.fontSize
      font.weight: Font.DemiBold
      color: root.ink
    }
    Text {
      visible: root.hint !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: root.hint
      font.family: root.pal.font
      font.pixelSize: root.fontSize - 2
      color: root.ink
      opacity: 0.55
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
