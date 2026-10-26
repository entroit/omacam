import QtQuick

// "[esc] close" style keyboard hint.
Row {
  id: root

  required property var pal
  property string keys: ""
  property string label: ""
  property color keyColor: pal.fg
  property color labelColor: pal.dim

  spacing: 5

  Rectangle {
    width: keyText.implicitWidth + 10
    height: 20
    radius: root.pal.radius
    color: Qt.rgba(0, 0, 0, 0.2)
    border.width: 1
    border.color: root.pal.line
    Text {
      id: keyText
      anchors.centerIn: parent
      text: root.keys
      font.family: root.pal.font
      font.pixelSize: 10
      color: root.keyColor
    }
  }
  Text {
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    font.family: root.pal.font
    font.pixelSize: 10
    color: root.labelColor
    rightPadding: 6
  }
}
