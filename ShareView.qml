import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Brands.js" as Brands
import "Config.js" as Config

// Export and import of cameras: one passphrase-encrypted file (or clipboard
// text) that another OmaCam can open. All the cryptography and checking is in
// share.py; this view only collects choices and shows results.
//
// The view is created when it opens and destroyed when it closes, so the
// passphrase, the request and any decrypted preview are gone from memory
// state as soon as the user leaves (wipe() also runs on destruction).
Column {
  id: root

  required property var ctx
  readonly property var pal: ctx.pal

  property string mode: "export"       // export · import
  property string stage: "form"        // import: form · preview · done
  property bool working: false
  property string status: ""
  property string tone: ""             // "" · ok · bad · warn
  property bool reveal: false
  property string passphrase: ""
  property string path: ""             // export destination / import source
  property bool exported: false
  property string savedPath: ""        // the path just written; empty once anything has changed
  property string appVersion: ""

  // export
  property var picked: ({})
  property bool includeLogins: true
  property bool includeSettings: false
  readonly property var checks: ctx.store.cameras.map(function(c) { return Brands.checkCamera(c) })
  readonly property int pickedCount: {
    var n = 0
    for (var i = 0; i < ctx.store.cameras.length; i++) if (picked[ctx.store.cameras[i].id] === true && checks[i].ok) n++
    return n
  }
  readonly property int customPicked: {
    var n = 0
    for (var i = 0; i < ctx.store.cameras.length; i++) if (picked[ctx.store.cameras[i].id] === true && checks[i].ok && ctx.store.cameras[i].brand === "custom") n++
    return n
  }
  readonly property bool weak: Array.from(passphrase).length < 12

  // import
  property var found: []
  property var rows: []                // [{ rec, status, existingId, selected }]
  property var preview: null           // { created, includesLogins, settings }
  property bool applySettings: false
  property bool applying: false        // shared settings are being backed up and applied
  property int skippedCount: 0         // cameras in the share that failed the check here
  readonly property int selectedCount: rows.filter(function(r) { return r.selected }).length

  spacing: 14
  focus: true
  Keys.onEscapePressed: root.back()
  Keys.onReturnPressed: root.primary()
  Keys.onEnterPressed: root.primary()

  // Return does what the highlighted button of the current step does. Past the
  // form there is no field left to type in, so the view itself takes the keys
  // (a hidden field must not answer Return by opening the file again).
  function primary() {
    if (mode === "export") { if (savedPath === "") doExport(false) }    // saved and unchanged: keep the message
    else if (stage === "form") open(false)
    else if (stage === "preview") { if (selectedCount > 0 || applySettings) doImport() }
    else ctx.closeShare()
  }
  onStageChanged: if (stage === "form") Qt.callLater(function() { passField.forceActiveFocus() }); else root.forceActiveFocus()

  ShareHelper { id: helper }

  FileView {
    path: decodeURIComponent(Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, ""))
    printErrors: false
    onLoaded: { try { root.appVersion = String(JSON.parse(text()).version || "") } catch (e) {} }
  }

  // --- lifecycle --------------------------------------------------------------
  Component.onCompleted: begin(ctx.shareMode, ctx.sharePath)
  Component.onDestruction: wipe()

  function wipe() {
    helper.cancelAll()
    passphrase = ""
    passField.text = ""
    rows = []
    preview = null
    skippedCount = 0
    applying = false
    found = []
    working = false
    reveal = false
  }

  function back() {
    if (mode === "import" && stage === "preview") { rows = []; preview = null; skippedCount = 0; stage = "form"; status = ""; tone = ""; return }
    ctx.closeShare()
  }

  function begin(newMode, source) {
    wipe()
    mode = newMode
    stage = "form"
    status = ""
    tone = ""
    exported = false
    savedPath = ""
    applySettings = false
    includeLogins = true
    includeSettings = false
    path = mode === "import" ? String(source || "") : defaultPath()
    pathField.text = path
    if (mode === "export") {
      var all = {}
      for (var i = 0; i < ctx.store.cameras.length; i++) all[ctx.store.cameras[i].id] = true
      picked = all
      newPassphrase()
      Qt.callLater(function() { passField.forceActiveFocus() })    // so Escape reaches this view
    } else {
      picked = ({})
      helper.run({ op: "find" }, function(a) { if (a.ok) root.found = a.files })
      Qt.callLater(function() { passField.forceActiveFocus() })
    }
  }

  function defaultPath() {
    var d = new Date()
    function two(n) { return (n < 10 ? "0" : "") + n }
    var stamp = d.getFullYear() + two(d.getMonth() + 1) + two(d.getDate()) + "-" + two(d.getHours()) + two(d.getMinutes()) + two(d.getSeconds())
    return "~/Downloads/omacam-cameras-" + stamp + ".omacam"
  }

  function say(text, kind) { status = text; tone = kind || "" }

  // Something that goes into the export changed: the "Saved…"/"Copied…" status is
  // stale, and the path that was just written would only say "already exists".
  function exportChanged(keepPath) {
    if (mode !== "export") return
    if (tone === "ok") say("", "")
    if (!keepPath && savedPath !== "" && path.trim() === savedPath) { path = defaultPath(); pathField.text = path }
    savedPath = ""
  }
  onPassphraseChanged: exportChanged(false)
  onPickedChanged: exportChanged(false)
  onIncludeLoginsChanged: exportChanged(false)
  onIncludeSettingsChanged: exportChanged(false)

  function explain(code) {
    switch (code) {
    case "not_found": return "That file doesn't exist."
    case "not_a_file": return "That isn't a regular file."
    case "too_large": return "That is too large to be a camera share."
    case "not_a_share": return "That doesn't look like an OmaCam camera share."
    case "unsupported": return "Made by a newer OmaCam — update the plugin."
    case "bad_passphrase_or_corrupt": return "Wrong passphrase, or the share was changed or damaged."
    case "invalid_content": return "The share opened, but what's in it isn't valid, so nothing was imported."
    case "weak_passphrase": return "Use a passphrase of at least 12 characters."
    case "exists": return "A file with that name already exists. Choose another name."
    case "invalid_path": return "Enter a full path, like ~/Downloads/cameras.omacam."
    case "cannot_write": return "Couldn't write that file. Check the folder and its permissions."
    case "cannot_read": return "Couldn't read that file."
    case "clipboard_unavailable": return "Couldn't use the clipboard (is wl-clipboard installed?)."
    case "crypto_unavailable": return "This system's OpenSSL can't be used for sharing."
    case "invalid_camera": return "One of the cameras can't be shared."
    case "no_cameras": return "Pick at least one camera."
    case "too_many": return "A share holds up to 100 cameras."
    case "timeout": return "That took too long and was stopped."
    default: return "Something went wrong."
    }
  }

  function newPassphrase() {
    helper.run({ op: "passphrase" }, function(a) {
      if (!a.ok) return
      root.passphrase = a.passphrase
      passField.text = a.passphrase
    })
  }

  function copyPassphrase() {
    if (passphrase === "") return
    helper.run({ op: "copy", text: passphrase, sensitive: true }, function(a) {
      if (a.ok) root.say("Passphrase copied. It's kept out of the clipboard history.", "ok")
      else root.say("Select the passphrase and copy it yourself.", "warn")
    })
  }

  // --- export -------------------------------------------------------------------
  function setPicked(id, value) {
    var next = {}
    for (var k in picked) next[k] = picked[k]
    next[id] = value
    picked = next
  }

  function pickAll(value) {
    var next = {}
    for (var i = 0; i < ctx.store.cameras.length; i++) next[ctx.store.cameras[i].id] = value && checks[i].ok
    picked = next
  }

  function doExport(toClipboard) {
    if (working) return
    var list = []
    for (var i = 0; i < ctx.store.cameras.length; i++) {
      var c = ctx.store.cameras[i]
      if (picked[c.id] === true && checks[i].ok) list.push({ name: c.name, brand: c.brand, host: c.host, url: c.url, user: c.user, password: c.password, variant: c.variant, enabled: c.enabled !== false })
    }
    if (list.length === 0) { say("Pick at least one camera.", "bad"); return }
    if (weak) { say("Use a passphrase of at least 12 characters.", "bad"); return }
    if (!toClipboard && path.trim() === "") { say("Enter where to save the file.", "bad"); return }
    var target = path.trim()
    working = true
    say("Encrypting…", "")
    var request = {
      op: "export", passphrase: passphrase, cameras: list, includeLogins: includeLogins,
      settings: includeSettings ? Config.sanitize(ctx.config.values, ctx.config.values) : null,
      app: appVersion, brands: Brands.brandTable(),
      dest: toClipboard ? { clipboard: true } : { file: path.trim() }
    }
    helper.run(request, function(a) {
      root.working = false
      if (!a.ok) {
        root.say(a.error === "invalid_camera" ? "“" + root.nameAt(a.index, list) + "” can't be shared. Edit it, or leave it out." : root.explain(a.error), "bad")
        return
      }
      root.exported = true
      root.savedPath = toClipboard ? "" : target
      var n = a.count + (a.count === 1 ? " camera" : " cameras")
      root.say(toClipboard
        ? "Encrypted share of " + n + " copied. Paste it into a message, and send the passphrase through a different channel."
        : "Saved " + n + " to " + a.path + ". Send the file and the passphrase through different channels.", "ok")
    })
  }

  function nameAt(index, list) {
    return list && index >= 0 && index < list.length ? list[index].name : "A camera"
  }

  // --- import -------------------------------------------------------------------
  function open(fromClipboard) {
    if (working) return
    if (passphrase === "") { say("Enter the passphrase.", "bad"); passField.forceActiveFocus(); return }
    if (!fromClipboard && path.trim() === "") { say("Choose a file, or paste from the clipboard.", "bad"); return }
    working = true
    say("Opening…", "")
    helper.run({ op: "open", passphrase: passphrase, brands: Brands.brandTable(), source: fromClipboard ? { clipboard: true } : { file: path.trim() } }, function(a) {
      root.working = false
      if (!a.ok) { root.say(a.error === "not_a_share" && fromClipboard ? "The clipboard doesn't hold an OmaCam camera share." : root.explain(a.error), "bad"); return }
      root.show(a)
    })
  }

  function show(answer) {
    var existing = {}
    for (var i = 0; i < ctx.store.cameras.length; i++) {
      var key = Brands.identity(ctx.store.cameras[i])
      if (existing[key] === undefined) existing[key] = ctx.store.cameras[i]
    }
    var seen = {}
    var list = []
    var skipped = 0
    for (var j = 0; j < answer.cameras.length; j++) {
      var rec = answer.cameras[j]
      var checked = Brands.checkCamera(rec)          // the strict check again, here in the shell
      if (!checked.ok) { skipped++; continue }
      var cam = checked.record
      cam.scope = ["local", "loopback", "linklocal"].indexOf(rec.scope) !== -1 ? rec.scope : "public"
      var web = cam.brand === "custom" && /^http:/i.test(cam.url)
      var id = Brands.identity(cam)
      var have = existing[id]
      var state = seen[id] ? "repeat" : !have ? "new" : (!answer.includesLogins || (have.user === cam.user && have.password === cam.password)) ? "same" : "login"
      seen[id] = true
      // Only plain local addresses start ticked: this computer, link-local,
      // public addresses and web (http) addresses are the importer's call.
      list.push({ rec: cam, status: state, existingId: have ? have.id : "", flag: flagOf(cam.scope, web), selected: (state === "new" && cam.scope === "local" && !web) })
    }
    skippedCount = skipped
    preview = { created: String(answer.created || ""), includesLogins: answer.includesLogins === true, settings: answer.settings || null }
    rows = list
    applySettings = false
    stage = "preview"
    say("", "")
  }

  // Warning shown next to an address that isn't a plain local rtsp one.
  function flagOf(scope, web) {
    if (scope === "public") return web ? "Public web address" : "Public address"
    if (scope === "loopback") return web ? "This computer · web address" : "This computer (loopback)"
    if (scope === "linklocal") return web ? "Link-local · web address" : "Link-local address"
    return web ? "Web address" : ""
  }

  function toggleRow(i) {
    var next = rows.slice()
    next[i] = { rec: next[i].rec, status: next[i].status, existingId: next[i].existingId, flag: next[i].flag, selected: !next[i].selected }
    rows = next
  }

  function doImport() {
    if (working || preview === null) return
    var add = []
    var logins = []
    var skipped = 0
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      if (!r.selected) continue
      var checked = Brands.checkCamera(r.rec)
      if (!checked.ok) { skipped++; continue }
      if (r.status === "new") add.push(checked.record)
      else if (r.status === "login") logins.push({ id: r.existingId, user: checked.record.user, password: checked.record.password })
    }
    ctx.store.addMany(add)
    for (var k = 0; k < logins.length; k++) ctx.store.updateLogin(logins[k].id, logins[k].user, logins[k].password)
    var parts = []
    if (add.length > 0) parts.push("Added " + add.length + (add.length === 1 ? " camera" : " cameras"))
    if (logins.length > 0) parts.push("updated " + logins.length + (logins.length === 1 ? " login" : " logins"))
    if (skipped > 0) parts.push(skipped + " skipped")
    var summary = parts.length > 0 ? parts.join(", ") + "." : "No cameras were changed."
    summary = summary.charAt(0).toUpperCase() + summary.slice(1)
    var settings = applySettings ? preview.settings : null
    rows = []
    preview = null
    skippedCount = 0
    passphrase = ""
    passField.text = ""
    stage = "done"
    if (settings !== null && ctx.config.error === "") {
      applying = true
      say(summary, "ok")
      ctx.config.replaceWithBackup(settings)      // finishes even if this view is closed meanwhile
    } else {
      say(summary + (settings !== null ? " The settings weren't applied because config.json has an error." : ""), settings !== null ? "warn" : "ok")
    }
  }

  // config.json is copied to config.json.bak before shared settings replace it
  // (Settings does both, so closing this view can't lose the change).
  Connections {
    target: root.ctx.config
    function onReplaced(ok) {
      if (!root.applying) return
      root.applying = false
      if (ok) root.say(root.status + " Settings applied; the previous ones are in config.json.bak.", "ok")
      else root.say(root.status + " The settings weren't applied: config.json couldn't be backed up first.", "warn")
    }
  }

  // --- pieces -------------------------------------------------------------------
  component T: Text {
    textFormat: Text.PlainText
    font.family: root.pal.font
    font.pixelSize: Style.font.body
    color: root.pal.fg
  }

  component SectionLabel: T {
    font.pixelSize: 10
    font.letterSpacing: 1.5
    color: root.pal.dim
  }

  component Hint: T {
    width: parent.width
    wrapMode: Text.WordWrap
    font.pixelSize: Style.font.caption + 1
    color: root.pal.dim
  }

  component Check: Rectangle {
    id: box
    property bool checked: false
    property bool allowed: true
    signal toggled()
    width: 18; height: 18
    radius: 4
    color: checked ? root.pal.accent : "transparent"
    border.width: 1
    border.color: checked ? root.pal.accent : root.pal.lineStrong
    opacity: allowed ? 1 : 0.4
    Text {
      anchors.centerIn: parent
      visible: box.checked
      text: "\u{F012C}"      // nf-md-check
      font.family: root.pal.font
      font.pixelSize: 13
      color: root.pal.bg
    }
    MouseArea { anchors.fill: parent; anchors.margins: -4; enabled: box.allowed; cursorShape: Qt.PointingHandCursor; onClicked: box.toggled() }
  }

  // --- header ---------------------------------------------------------------
  Item {
    width: parent.width
    height: 30
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: 12
      ActionButton { pal: root.pal; icon: "\u{F0141}"; text: root.mode === "import" && root.stage === "preview" ? "Back" : "Manage"; onClicked: root.back() }
      T {
        anchors.verticalCenter: parent.verticalCenter
        text: root.mode === "export" ? "Export cameras" : "Import cameras"
        font.pixelSize: Style.font.heading + 2
        font.weight: Font.Bold
      }
    }
    ActionButton { anchors { right: parent.right; verticalCenter: parent.verticalCenter } pal: root.pal; variant: "plain"; icon: "\u{F0156}"; onClicked: root.ctx.close() }
  }

  Rectangle { width: parent.width; height: 1; color: root.pal.line }

  // --- export: cameras --------------------------------------------------------
  Column {
    visible: root.mode === "export"
    width: parent.width
    spacing: 14

    Item {
      width: parent.width
      height: 18
      SectionLabel { anchors.verticalCenter: parent.verticalCenter; text: "CAMERAS" }
      Row {
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: 14
        T { text: "All"; font.pixelSize: Style.font.caption + 1; font.weight: Font.DemiBold; color: root.pal.accent; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pickAll(true) } }
        T { text: "None"; font.pixelSize: Style.font.caption + 1; font.weight: Font.DemiBold; color: root.pal.accent; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.pickAll(false) } }
      }
    }

    Rectangle {
      width: parent.width
      height: Math.max(48, camList.implicitHeight + 12)
      radius: root.pal.radius
      color: root.pal.tint(root.pal.fg, 0.03)
      border.width: 1
      border.color: root.pal.line

      T { visible: root.ctx.store.cameras.length === 0; anchors.centerIn: parent; text: "No cameras to share yet."; color: root.pal.dim }

      Column {
        id: camList
        x: 6; y: 6
        width: parent.width - 12
        Repeater {
          model: root.ctx.store.cameras
          delegate: Item {
            id: item
            required property var modelData
            required property int index
            readonly property var check: root.checks[index] || { ok: true, error: "" }
            width: camList.width
            height: item.check.ok ? 34 : 34 + reason.implicitHeight + 4
            Rectangle { anchors.fill: parent; radius: root.pal.radius; color: root.pal.tint(root.pal.fg, 0.06); visible: rowMouse.containsMouse && item.check.ok }
            MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; enabled: item.check.ok; cursorShape: Qt.PointingHandCursor; onClicked: root.setPicked(item.modelData.id, root.picked[item.modelData.id] !== true) }
            Check { x: 8; y: 8; checked: root.picked[item.modelData.id] === true && item.check.ok; allowed: item.check.ok; onToggled: root.setPicked(item.modelData.id, !checked) }
            T {
              x: 38; y: 17 - implicitHeight / 2
              width: parent.width * 0.4
              elide: Text.ElideRight
              text: item.modelData.name
              font.weight: Font.DemiBold
              opacity: item.check.ok ? 1 : 0.5
            }
            T {
              anchors { left: parent.left; leftMargin: 38 + parent.width * 0.4 + 10; right: parent.right; rightMargin: 10 }
              y: 17 - implicitHeight / 2
              elide: Text.ElideRight
              text: Brands.hostLabel(item.modelData)
              font.pixelSize: Style.font.bodySmall
              color: root.pal.dim
            }
            // Why this camera can't go into a share (so the user can fix it).
            T {
              id: reason
              visible: !item.check.ok
              x: 38; y: 32
              width: parent.width - 38 - 10
              wrapMode: Text.WordWrap
              text: "Can't be shared: " + item.check.error
              font.pixelSize: Style.font.bodySmall
              color: root.pal.warn
            }
          }
        }
      }
    }

    // --- export: options -----------------------------------------------------
    Rectangle {
      width: parent.width
      height: optionsCol.implicitHeight + 24
      radius: root.pal.radius
      color: root.pal.tint(root.pal.fg, 0.03)
      border.width: 1
      border.color: root.pal.line

      Column {
        id: optionsCol
        x: 14; y: 12
        width: parent.width - 28
        spacing: 14

        Item {
          width: parent.width
          height: Math.max(loginText.implicitHeight, loginSwitch.implicitHeight)
          Column {
            id: loginText
            anchors { left: parent.left; right: loginSwitch.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
            spacing: 3
            T { text: "Include logins (usernames and passwords)"; font.pixelSize: Style.font.title; font.weight: Font.DemiBold }
            Hint { text: root.includeLogins ? "Anyone with this file and the passphrase can watch these cameras." : "Usernames and passwords are left out. The person importing enters them afterwards." }
            Hint {
              visible: !root.includeLogins && root.customPicked > 0
              text: "In custom addresses, user:pass@ and the parameters user, usr, username, login, pwd, pass, passwd, password, token and auth are also removed. Anything else in an address, such as a login in the path, is shared as stored."
              color: root.pal.warn
            }
          }
          ToggleSwitch { id: loginSwitch; anchors { right: parent.right; verticalCenter: parent.verticalCenter } checked: root.includeLogins; onToggled: root.includeLogins = !root.includeLogins }
        }

        Rectangle { width: parent.width; height: 1; color: root.pal.line }

        Item {
          width: parent.width
          height: Math.max(settingsText.implicitHeight, settingsSwitch.implicitHeight)
          Column {
            id: settingsText
            anchors { left: parent.left; right: settingsSwitch.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
            spacing: 3
            T { text: "Include my settings"; font.pixelSize: Style.font.title; font.weight: Font.DemiBold }
            Hint { text: "Keys, timings and layout from config.json. The other person decides whether to use them." }
          }
          ToggleSwitch { id: settingsSwitch; anchors { right: parent.right; verticalCenter: parent.verticalCenter } checked: root.includeSettings; onToggled: root.includeSettings = !root.includeSettings }
        }
      }
    }
  }

  // --- file and passphrase (both directions) -----------------------------------
  Column {
    visible: root.mode === "export" || root.stage === "form"
    width: parent.width
    spacing: 14

    Column {
      width: parent.width
      spacing: 6
      SectionLabel { text: root.mode === "export" ? "SAVE TO" : "FILE" }
      TextField {
        id: pathField
        width: parent.width
        text: root.path
        placeholderText: root.mode === "import" ? "~/Downloads/omacam-cameras.omacam" : ""
        selectByMouse: true
        font.family: root.pal.font
        onTextEdited: { root.path = text; root.exportChanged(true) }
        Keys.onEscapePressed: root.back()
        Keys.onReturnPressed: root.primary()
        Keys.onEnterPressed: root.primary()
      }
      Flow {
        visible: root.mode === "import" && root.found.length > 0
        width: parent.width
        spacing: 6
        Repeater {
          model: root.found
          delegate: ActionButton {
            required property var modelData
            pal: root.pal
            text: "Found in " + (String(modelData.path).indexOf("/Downloads/") !== -1 ? "Downloads" : "your home folder") + ": " + modelData.name
            fontSize: Style.font.bodySmall
            onClicked: { root.path = modelData.path; pathField.text = modelData.path; passField.forceActiveFocus() }
          }
        }
      }
      Hint { visible: root.mode === "export"; text: "A new file is created; an existing one is never overwritten." }
    }

    Column {
      width: parent.width
      spacing: 6
      SectionLabel { text: "PASSPHRASE" }
      Row {
        width: parent.width
        spacing: 8
        TextField {
          id: passField
          width: parent.width - (newButton.visible ? newButton.width + copyButton.width + 16 : 0)
          text: root.passphrase
          // The export passphrase is shown: it has to be passed on.
          password: root.mode === "import" && !root.reveal
          rightPadding: root.mode === "import" ? 38 : 8
          selectByMouse: true
          font.family: root.pal.font
          onTextEdited: root.passphrase = text
          Keys.onEscapePressed: root.back()
          Keys.onReturnPressed: root.primary()
          Keys.onEnterPressed: root.primary()

          ActionButton {
            visible: root.mode === "import"
            anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
            pal: root.pal
            variant: "plain"
            padX: 6; padY: 2
            icon: root.reveal ? "\u{F0209}" : "\u{F0208}"   // nf-md-eye_off / eye
            onClicked: root.reveal = !root.reveal
          }
        }
        ActionButton { id: newButton; visible: root.mode === "export"; anchors.verticalCenter: parent.verticalCenter; pal: root.pal; icon: "\u{F0450}"; text: "New"; enabled: !root.working; onClicked: root.newPassphrase() }
        ActionButton { id: copyButton; visible: root.mode === "export"; anchors.verticalCenter: parent.verticalCenter; pal: root.pal; icon: "\u{F018F}"; text: "Copy"; enabled: !root.working && root.passphrase !== ""; onClicked: root.copyPassphrase() }
      }
      Hint {
        text: root.mode === "import" ? "The person who sent the file gives you this separately."
            : root.weak ? "Use at least 12 characters."
            : "Tell the person this passphrase through a different channel than the file, such as a phone call."
        color: root.mode === "export" && root.weak ? root.pal.warn : root.pal.dim
      }
    }
  }

  // --- import: preview ------------------------------------------------------------
  Column {
    visible: root.mode === "import" && root.stage === "preview"
    width: parent.width
    spacing: 12

    T {
      width: parent.width
      wrapMode: Text.WordWrap
      text: root.rows.length + (root.rows.length === 1 ? " camera" : " cameras") + " · "
        + (root.preview && root.preview.includesLogins ? "logins included" : "no passwords (enter them after importing)")
        + (root.preview && root.preview.created !== "" ? " · made " + root.preview.created.slice(0, 10) : "")
      font.pixelSize: Style.font.title
      font.weight: Font.DemiBold
    }
    Hint { text: "OmaCam will connect to exactly these addresses. Only import shares from people you trust." }
    Hint {
      visible: root.skippedCount > 0
      text: root.skippedCount + (root.skippedCount === 1 ? " camera in this share was" : " cameras in this share were") + " skipped (not valid)."
      color: root.pal.warn
    }

    Rectangle {
      width: parent.width
      height: Math.max(48, importList.implicitHeight + 12)
      radius: root.pal.radius
      color: root.pal.tint(root.pal.fg, 0.03)
      border.width: 1
      border.color: root.pal.line

      Column {
        id: importList
        x: 6; y: 6
        width: parent.width - 12
        Repeater {
          model: root.rows
          delegate: Item {
            id: line
            required property var modelData
            required property int index
            readonly property bool usable: modelData.status === "new" || modelData.status === "login"
            width: importList.width
            height: 52
            Rectangle { anchors.fill: parent; radius: root.pal.radius; color: root.pal.tint(root.pal.fg, 0.06); visible: lineMouse.containsMouse && line.usable }
            MouseArea { id: lineMouse; anchors.fill: parent; hoverEnabled: true; enabled: line.usable; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleRow(line.index) }
            Check { x: 8; anchors.verticalCenter: parent.verticalCenter; checked: line.modelData.selected; allowed: line.usable; onToggled: root.toggleRow(line.index) }
            Column {
              anchors { left: parent.left; leftMargin: 38; right: statusColumn.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
              spacing: 2
              T {
                width: parent.width
                elide: Text.ElideMiddle
                text: root.addressOf(line.modelData.rec)
                font.weight: Font.Bold
                opacity: line.usable ? 1 : 0.5
              }
              T {
                width: parent.width
                elide: Text.ElideRight
                text: line.modelData.rec.name + " · " + Brands.label(line.modelData.rec.brand).replace("Other / ", "") + (line.modelData.rec.user !== "" ? " · " + line.modelData.rec.user : "")
                font.pixelSize: Style.font.bodySmall
                color: root.pal.dim
              }
            }
            Column {
              id: statusColumn
              anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
              spacing: 2
              T {
                anchors.right: parent.right
                text: line.modelData.status === "new" ? "New" : line.modelData.status === "same" ? "Already added" : line.modelData.status === "login" ? "Already added · new login" : "Repeated in this share"
                font.pixelSize: Style.font.bodySmall
                color: line.modelData.status === "new" ? root.pal.ok : root.pal.dim
              }
              T {
                visible: line.modelData.flag !== ""
                anchors.right: parent.right
                text: line.modelData.flag
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.DemiBold
                color: root.pal.warn
              }
            }
          }
        }
      }
    }

    Item {
      visible: root.preview !== null && root.preview.settings !== null
      width: parent.width
      height: Math.max(applyText.implicitHeight, applySwitch.implicitHeight)
      Column {
        id: applyText
        anchors { left: parent.left; right: applySwitch.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
        spacing: 3
        T { text: "Also apply the shared settings"; font.pixelSize: Style.font.title; font.weight: Font.DemiBold }
        Hint { text: root.ctx.config.error !== "" ? "config.json has an error, so settings can't be replaced right now." : "Replaces keys, timings and layout. Your current config.json is kept as config.json.bak." }
      }
      ToggleSwitch {
        id: applySwitch
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        checked: root.applySettings
        interactive: root.ctx.config.error === ""
        opacity: interactive ? 1 : 0.4
        onToggled: root.applySettings = !root.applySettings
      }
    }
  }

  // What the camera will be contacted at: a custom camera's whole address
  // (a share never carries a login in it), a preset's host and port.
  // A login carried in a parameter of the address is shown as dots.
  function addressOf(rec) {
    if (rec.brand !== "custom") return rec.host
    return String(rec.url).replace(/([?&](?:user|usr|username|login|pwd|pass|passwd|password|token|auth)=)[^&#]*/gi, "$1\u2022\u2022\u2022")
  }

  // --- footer ---------------------------------------------------------------
  Rectangle { width: parent.width; height: 1; color: root.pal.line }

  Item {
    width: parent.width
    height: Math.max(32, footerText.implicitHeight)
    T {
      id: footerText
      anchors { left: parent.left; right: footerButtons.left; rightMargin: 14; verticalCenter: parent.verticalCenter }
      visible: root.status !== ""
      wrapMode: Text.WordWrap
      text: root.status
      font.pixelSize: Style.font.bodySmall
      color: root.tone === "ok" ? root.pal.ok : root.tone === "bad" ? root.pal.urgent : root.tone === "warn" ? root.pal.warn : root.pal.dim
    }
    Row {
      id: footerButtons
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      spacing: 8

      // export
      ActionButton { visible: root.mode === "export"; pal: root.pal; variant: "plain"; text: root.exported ? "Done" : "Cancel"; onClicked: root.ctx.closeShare() }
      ActionButton { visible: root.mode === "export"; pal: root.pal; icon: "\u{F018F}"; text: "Copy to clipboard"; enabled: !root.working && root.pickedCount > 0 && !root.weak; onClicked: root.doExport(true) }
      ActionButton { visible: root.mode === "export"; pal: root.pal; variant: "primary"; text: "Save file"; enabled: !root.working && root.pickedCount > 0 && !root.weak; onClicked: root.doExport(false) }

      // import
      ActionButton { visible: root.mode === "import" && root.stage === "done"; pal: root.pal; variant: "primary"; text: "Done"; onClicked: root.ctx.closeShare() }
      ActionButton { visible: root.mode === "import" && root.stage === "form"; pal: root.pal; variant: "plain"; text: "Cancel"; onClicked: root.ctx.closeShare() }
      ActionButton { visible: root.mode === "import" && root.stage === "form"; pal: root.pal; icon: "\u{F018F}"; text: "Paste from clipboard"; enabled: !root.working; onClicked: root.open(true) }
      ActionButton { visible: root.mode === "import" && root.stage === "form"; pal: root.pal; variant: "primary"; text: "Open file"; enabled: !root.working; onClicked: root.open(false) }
      ActionButton { visible: root.mode === "import" && root.stage === "preview"; pal: root.pal; variant: "primary"; text: root.selectedCount === 0 && root.applySettings ? "Apply settings" : "Import " + root.selectedCount + (root.selectedCount === 1 ? " camera" : " cameras"); enabled: !root.working && (root.selectedCount > 0 || root.applySettings); onClicked: root.doImport() }
    }
  }
}
