import QtQuick

// Speaker toggle for the views that can play sound. Shows "No sound" (and
// can't be pressed) when the camera's audio track turned out to be empty.
ActionButton {
  id: root

  property string sound: "unknown"   // from CameraFeed: unknown · yes · no
  property bool on: false            // currently audible
  property bool showLabel: true
  property string key: ""            // keyboard hint, e.g. "m"

  readonly property bool silent: sound === "no"

  icon: silent ? "\u{F0581}" : on ? "\u{F057E}" : "\u{F075F}"   // volume_off · volume_high · volume_mute
  text: !showLabel ? "" : silent ? "No sound" : on ? "Sound" : "Muted"
  hint: silent || !showLabel ? "" : key
  selected: on && !silent
  enabled: !silent
}
