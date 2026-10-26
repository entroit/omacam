import QtQuick
import QtMultimedia
import qs.Commons
import qs.Ui
import "Brands.js" as Brands

// Add / edit a camera: name, brand, IP, username, password. The brand fills
// in the stream address; "Other / Custom URL" takes a full address instead.
Column {
  id: root

  required property var ctx
  readonly property var pal: ctx.pal
  property var source: null        // record being edited, null for a new one

  property string name: ""
  property string brand: "hikvision"
  property string host: ""
  property string url: ""
  property string user: "admin"
  property string password: ""
  property int variant: 0
  property string foundBrand: ""    // set when the search found a different brand
  property bool reveal: false
  property string error: ""

  readonly property bool custom: brand === "custom"
  readonly property var draft: ({ name: name, brand: brand, host: host, url: url, user: user, password: password, variant: variant })
  readonly property bool testing: finder.running
  readonly property var result: finder.result
  readonly property bool typing: nameField.activeFocus || hostField.activeFocus || urlField.activeFocus || userField.activeFocus || passField.activeFocus
  readonly property bool canTest: custom ? url.trim() !== "" : host.trim() !== ""

  spacing: 14

  function load(record) {
    source = record
    name = record ? record.name : ""
    brand = record ? record.brand : "hikvision"
    host = record ? record.host : ""
    url = record ? record.url : ""
    user = record ? record.user : "admin"
    password = record ? record.password : ""
    variant = record ? (record.variant || 0) : 0
    foundBrand = ""
    saveAfterTest = false
    reveal = false
    error = ""
    finder.cancel()
    finder.result = null
    // Typing replaces the fields' bindings, so push values in explicitly.
    nameField.text = name
    hostField.text = host
    urlField.text = url
    userField.text = user
    passField.text = password
    brandBox.value = brand
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  property bool saveAfterTest: false

  function test() {
    error = ""
    foundBrand = ""
    finder.find(draft)
  }

  function testFinished(r) {
    if (r.ok && !custom) {
      if (r.brand !== brand) {
        foundBrand = r.brand
        brand = r.brand
        brandBox.value = r.brand
      }
      variant = r.variant
    }
    if (saveAfterTest) { saveAfterTest = false; commit() }
  }

  function save() {
    if (name.trim() === "") { error = "Give the camera a name"; nameField.forceActiveFocus(); return }
    if (!canTest) { error = custom ? "Enter the stream URL" : "Enter the camera's IP address"; (custom ? urlField : hostField).forceActiveFocus(); return }
    // Not tested yet: find the stream first so the right address is saved.
    if (!custom && !(result && result.ok)) {
      saveAfterTest = true
      test()
      return
    }
    commit()
  }

  function commit() {
    var record = { name: name, brand: brand, host: host, url: url, user: user, password: password, variant: variant, enabled: source ? source.enabled : true }
    var id = source ? ctx.store.update(source.id, record) : ctx.store.add(record)
    ctx.formSaved(id)
  }

  // Switch to a custom URL pre-filled with what the brand would have used.
  function editUrl() {
    var full = Brands.streamUrl({ brand: brand, host: host, user: "", password: "", variant: variant }, "main")
    brand = "custom"
    brandBox.value = "custom"
    url = full
    urlField.text = full
    Qt.callLater(function() { urlField.forceActiveFocus() })
  }

  Keys.onEscapePressed: ctx.cancelForm()

  // Tab order: name → IP (or URL) → username → password.
  function focusNext(from, back) {
    var order = [nameField, custom ? urlField : hostField, userField, passField]
    var i = order.indexOf(from)
    order[(i + (back ? order.length - 1 : 1)) % order.length].forceActiveFocus()
  }

  StreamFinder { id: finder; onFinished: function(r) { root.testFinished(r) } }

  Shortcut {
    sequence: "Ctrl+T"
    enabled: root.visible && root.canTest && !root.testing
    onActivated: root.test()
  }

  // --- header ---------------------------------------------------------------
  Item {
    width: parent.width
    height: 30
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 12
      ActionButton { pal: root.pal; icon: "\u{F0141}"; text: "Cameras"; onClicked: root.ctx.cancelForm() }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.source ? "Edit camera" : "Add camera"
        font.family: root.pal.font
        font.pixelSize: Style.font.heading + 2
        font.weight: Font.Bold
        color: root.pal.fg
      }
    }
    ActionButton { anchors { right: parent.right; verticalCenter: parent.verticalCenter } pal: root.pal; variant: "plain"; icon: "\u{F0156}"; onClicked: root.ctx.close() }
  }

  Rectangle { width: parent.width; height: 1; color: root.pal.line }

  // --- fields ---------------------------------------------------------------
  component FieldLabel: Text {
    font.family: root.pal.font
    font.pixelSize: Style.font.body
    font.weight: Font.Medium
    color: root.pal.fg
  }

  Row {
    width: parent.width
    spacing: 12
    Column {
      width: (parent.width - parent.spacing) / 2
      spacing: 6
      FieldLabel { text: "Name" }
      TextField {
        id: nameField
        Keys.onTabPressed: root.focusNext(nameField, false)
        Keys.onBacktabPressed: root.focusNext(nameField, true)
        width: parent.width
        text: root.name
        placeholderText: "Front Door"
        onTextEdited: root.name = text
        Keys.onEscapePressed: root.ctx.cancelForm()
        Keys.onReturnPressed: root.save()
      }
    }
    Column {
      width: (parent.width - parent.spacing) / 2
      spacing: 6
      FieldLabel { text: "Brand" }
      Dropdown {
        id: brandBox
        width: parent.width
        showLabel: false
        value: root.brand
        options: Brands.options()
        onChanged: function(v) { root.brand = v; root.variant = 0; root.foundBrand = ""; finder.cancel(); finder.result = null }
      }
    }
  }

  Column {
    visible: !root.custom
    width: parent.width
    spacing: 6
    FieldLabel { text: "IP address" }
    TextField {
      id: hostField
      Keys.onTabPressed: root.focusNext(hostField, false)
      Keys.onBacktabPressed: root.focusNext(hostField, true)
      width: parent.width
      text: root.host
      placeholderText: "192.168.1.42"
      font.family: root.pal.font
      onTextEdited: { root.host = text; finder.cancel(); finder.result = null }
      Keys.onEscapePressed: root.ctx.cancelForm()
      Keys.onReturnPressed: root.save()
    }
  }

  Column {
    visible: root.custom
    width: parent.width
    spacing: 6
    FieldLabel { text: "Stream URL" }
    TextField {
      id: urlField
      Keys.onTabPressed: root.focusNext(urlField, false)
      Keys.onBacktabPressed: root.focusNext(urlField, true)
      width: parent.width
      text: root.url
      placeholderText: "rtsp://192.168.1.60:554/live"
      onTextEdited: { root.url = text; finder.cancel(); finder.result = null }
      Keys.onEscapePressed: root.ctx.cancelForm()
      Keys.onReturnPressed: root.save()
    }
    Text {
      text: "rtsp:// or http:// (MJPEG). Username and password stay separate."
      font.family: root.pal.font
      font.pixelSize: Style.font.caption + 1
      color: root.pal.dim
    }
  }

  Row {
    width: parent.width
    spacing: 12
    Column {
      width: (parent.width - parent.spacing) / 2
      spacing: 6
      FieldLabel { text: "Username" }
      TextField {
        id: userField
        Keys.onTabPressed: root.focusNext(userField, false)
        Keys.onBacktabPressed: root.focusNext(userField, true)
        width: parent.width
        text: root.user
        placeholderText: "admin"
        onTextEdited: { root.user = text; finder.cancel(); finder.result = null }
        Keys.onEscapePressed: root.ctx.cancelForm()
        Keys.onReturnPressed: root.save()
      }
    }
    Column {
      width: (parent.width - parent.spacing) / 2
      spacing: 6
      FieldLabel { text: "Password" }
      TextField {
        id: passField
        Keys.onTabPressed: root.focusNext(passField, false)
        Keys.onBacktabPressed: root.focusNext(passField, true)
        width: parent.width
        text: root.password
        password: !root.reveal
        rightPadding: 38
        onTextEdited: { root.password = text; finder.cancel(); finder.result = null }
        Keys.onEscapePressed: root.ctx.cancelForm()
        Keys.onReturnPressed: root.save()

        ActionButton {
          anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
          pal: root.pal
          variant: "plain"
          padX: 6; padY: 2
          icon: root.reveal ? "\u{F0209}" : "\u{F0208}"   // nf-md-eye_off / eye
          onClicked: root.reveal = !root.reveal
        }
      }
    }
  }

  // Generated address, masked.
  Row {
    visible: !root.custom && root.host.trim() !== ""
    width: parent.width
    spacing: 10
    Text {
      width: Math.min(implicitWidth, parent.width - editLink.width - 10)
      elide: Text.ElideMiddle
      text: Brands.displayUrl(root.draft)
      font.family: root.pal.font
      font.pixelSize: Style.font.caption + 1
      color: root.pal.dim
    }
    Text {
      id: editLink
      text: "Edit"
      font.family: root.pal.font
      font.pixelSize: Style.font.caption + 1
      font.weight: Font.DemiBold
      color: root.pal.accent
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.editUrl() }
    }
  }

  // --- test connection --------------------------------------------------------
  Rectangle {
    id: testBox
    width: parent.width
    height: Math.max(112, status.implicitHeight + 28)
    radius: root.pal.radius
    color: root.pal.tint(root.pal.fg, 0.03)
    border.width: 1
    border.color: root.pal.line

    readonly property string tone: root.testing || !root.result ? "neutral"
                                 : root.result.ok ? "ok"
                                 : root.result.kind === "offline" ? "warn" : "bad"
    readonly property color toneColor: tone === "ok" ? root.pal.ok : tone === "warn" ? root.pal.warn : tone === "bad" ? root.pal.urgent : root.pal.fg

    CameraTile {
      id: preview
      x: 12; anchors.verticalCenter: parent.verticalCenter
      width: 140; height: 79
      pal: root.pal
      pool: root.ctx.pool
      privateTag: "form"
      compact: true
      showMeta: false
      camera: root.result && root.result.ok && !root.testing ? root.draft : null
      quality: "main"
      active: root.ctx.streaming && root.visible && preview.camera !== null

      Text {
        anchors.centerIn: parent
        visible: !preview.camera
        text: root.testing ? "\u{F0450}" : "\u{F0567}"
        font.family: root.pal.font
        font.pixelSize: 24
        color: root.pal.faint
        RotationAnimation on rotation { running: root.testing; loops: Animation.Infinite; from: 0; to: 360; duration: 1100 }
        onTextChanged: rotation = 0
      }
    }

    Column {
      id: status
      anchors { left: preview.right; leftMargin: 16; right: testButton.left; rightMargin: 14; verticalCenter: parent.verticalCenter }
      spacing: 4

      Item {
        width: parent.width
        height: headline.implicitHeight
        Rectangle {
          id: toneDot
          y: Math.round(headline.font.pixelSize * 0.45)
          width: testBox.tone === "neutral" ? 0 : 8
          height: 8; radius: 4
          color: testBox.toneColor
        }
        Text {
          id: headline
          anchors { left: toneDot.right; leftMargin: toneDot.width > 0 ? 8 : 0; right: parent.right }
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
          text: root.testing ? (finder.total === 0 ? "Looking at the camera\u2026" : "Trying " + finder.tryingBrand + "\u2026")
              : !root.result ? "Not tested yet"
              : root.result.ok ? "Connected"
              : root.result.kind === "auth" ? "Wrong username or password"
              : root.result.kind === "offline" ? "Couldn't reach " + (Brands.hostLabel(root.draft) || "the camera")
              : root.custom ? "No video at this address"
              : "No video stream found"
          font.family: root.pal.font
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
          color: testBox.toneColor
        }
      }
      Text {
        width: parent.width
        visible: text !== ""
        elide: Text.ElideRight
        text: root.testing ? (finder.total > 0 ? "address " + finder.step + " of " + finder.total : "")
            : root.result && root.result.ok ? [root.result.width > 0 ? root.result.width + "\u00d7" + root.result.height : "", root.result.fps > 0 ? root.result.fps + " fps" : "", root.result.codec, root.foundBrand !== "" ? "found as " + Brands.label(root.foundBrand) : ""].filter(function(s) { return s !== "" }).join(" \u00b7 ")
            : ""
        font.family: root.pal.font
        font.pixelSize: Style.font.bodySmall
        color: root.pal.fg
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        maximumLineCount: 4
        elide: Text.ElideRight
        text: root.testing ? "Finding the camera's stream address."
            : !root.result ? "Check the camera answers before saving."
            : root.result.ok ? "Live preview \u2014 this is what you'll see in the bar."
            : root.result.kind === "auth" ? "The camera rejected the login. Check the username and password."
            : root.result.kind === "offline" ? "Check the camera is on, on the same network, and the IP is right."
            : root.custom ? "Check the stream URL, or pick the camera's brand instead."
            : "Turn on RTSP in the camera's settings, or paste its address with Other / Custom URL."
        font.family: root.pal.font
        font.pixelSize: Style.font.caption + 1
        lineHeight: 1.15
        color: root.pal.dim
      }
    }

    ActionButton {
      id: testButton
      anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
      pal: root.pal
      icon: "\u{F0450}"
      text: root.result ? "Test again" : "Test connection"
      hint: "^T"
      enabled: root.canTest && !root.testing
      onClicked: root.test()
    }
  }

  // --- footer ---------------------------------------------------------------
  Rectangle { width: parent.width; height: 1; color: root.pal.line }

  Item {
    width: parent.width
    height: 32
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.error !== ""
      text: root.error
      font.family: root.pal.font
      font.pixelSize: Style.font.bodySmall
      color: root.pal.urgent
    }
    Row {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      spacing: 8
      ActionButton { pal: root.pal; variant: "plain"; text: "Cancel"; onClicked: root.ctx.cancelForm() }
      ActionButton { pal: root.pal; variant: "primary"; text: root.saveAfterTest ? "Finding stream\u2026" : (root.source ? "Save changes" : "Save camera"); hint: "↵"; onClicked: root.save() }
    }
  }
}
