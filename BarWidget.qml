import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Borgmatic backup monitor for the bar. The icon sits quietly while the
// newest backup in every repository is younger than staleHours, and turns
// urgent the minute one falls behind. Left click opens the repository
// panel, right click forces a check against the remote server.
//
// Store.qml owns all IO; Panel.qml is the popup. This file is only the bar
// button plus the popout/IPC plumbing the bar host expects on the widget
// root.
BarWidget {
  id: root
  moduleName: "fr.rvier.quickborgmatic"

  // ---- popup. Shape contract for shell summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget
  //      root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("store" in target) target.store = store
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Store {
    id: store
    bar: root.bar
    settings: root.settings
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "fr.rvier.quickborgmatic"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): string { store.refresh(true); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰁯"  // nf-md-backup_restore
    active: store.anyStale
    tooltipText: store.checkFailed
      ? "Backup check failed · last checked " + store.agoText(store.lastAttemptMs)
      : (store.anyStale
        ? store.staleCount + (store.staleCount > 1 ? " backups stale" : " backup stale")
        : "Backups OK")

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) store.refresh(true)
      else root.togglePanel()
    }

    // Subtle "the check itself failed" hint: a small dim dot in the icon's
    // top-right corner. Staleness owns the loud urgent color; a network
    // hiccup shouldn't shout the same way.
    Rectangle {
      visible: store.checkFailed && !store.anyStale
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(3)
      anchors.rightMargin: Style.space(1)
      width: Style.space(5)
      height: width
      radius: width / 2
      color: Qt.darker(button.foreground, 1.55)
    }
  }
}
