import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// The borgmatic popup: every configured repository with its last backup
// date and relative age, stale ones in the urgent color, plus a failure
// banner when the check itself couldn't reach the server and a footer
// telling when the data was fetched.
//
// BarWidget.qml owns the bar icon and hands this panel the button to
// anchor against plus the shared Store.
Panel {
  id: root
  moduleName: "fr.rvier.quickborgmatic"
  ipcTarget: "fr.rvier.quickborgmatic"
  manageIpc: false

  property var anchorItem: null
  property var store: null

  // The bar tracks the widget mounted in its slot - BarWidget.qml - not this
  // nested panel, so everything the bar identifies a panel by must be that
  // widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Guarded so the widget renders before the bar is injected.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var repoModel: store ? store.repos : []
  readonly property int staleCount: store ? store.staleCount : 0
  readonly property int failedCount: store ? store.failedRepoCount : 0

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function refreshNow() {
    if (store) store.refresh(true)
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function heroMeta() {
    if (!store) return ""
    if (store.checking) return "Checking…"
    if (store.neverChecked) return "No data yet"
    var parts = []
    if (staleCount - failedCount > 0) parts.push((staleCount - failedCount) + " stale")
    if (failedCount > 0) parts.push(failedCount + " unchecked")
    return parts.length > 0 ? parts.join(" · ") : "All fresh"
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(440))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentY + dy * Style.space(56),
                                                     Math.max(0, panelFlick.contentHeight - panelFlick.height)))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            title: "Backups"
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰁯"
                color: root.staleCount > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Check failure ----------
          // Whole check failed (no fresh data) or some repositories could
          // not be listed (their rows carry the borg message).
          BorderSurface {
            visible: !!root.store && (root.store.checkFailed || root.failedCount > 0)
            width: parent.width
            implicitHeight: failureColumn.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Column {
              id: failureColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: {
                  if (!root.store) return ""
                  if (!root.store.checkFailed)
                    return root.failedCount + " of " + root.repoModel.length + " repositories could not be checked"
                  if (root.store.lastCheckedMs > 0)
                    return "Last check failed · showing data from " + root.store.agoText(root.store.lastCheckedMs)
                  return "Backup check failed"
                }
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                wrapMode: Text.WordWrap
              }

              Text {
                textFormat: Text.PlainText
                visible: text !== ""
                width: parent.width
                text: root.store ? root.store.errorText : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }
            }
          }

          // ---------- Loading / empty ----------
          Text {
            visible: !!root.store && root.store.neverChecked
            width: parent.width
            topPadding: Style.space(16)
            bottomPadding: Style.space(8)
            text: root.store && root.store.checking
              ? "Checking backups…"
              : "No backup data yet.\nPress r or the Refresh button to check now."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !!root.store && !root.store.neverChecked && root.repoModel.length === 0
            width: parent.width
            topPadding: Style.space(16)
            bottomPadding: Style.space(8)
            text: "No repositories configured."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          // ---------- Repositories ----------
          PanelSeparator {
            visible: repoSection.visible
            foreground: root.foreground
          }

          Column {
            id: repoSection
            visible: root.repoModel.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "REPOSITORIES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.repoModel

              RepoRow {
                required property var modelData
                width: repoSection.width
                repo: modelData
              }
            }
          }

          // ---------- Footer ----------
          PanelSeparator {
            foreground: root.foreground
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(checkedLabel.implicitHeight, refreshButton.implicitHeight)

            Text {
              id: checkedLabel
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: {
                if (!root.store) return ""
                if (root.store.checking) return "Checking…"
                if (root.store.lastCheckedMs > 0) return "Checked " + root.store.agoText(root.store.lastCheckedMs)
                return "Never checked"
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Button {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Refresh"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.refreshNow()
            }
          }
        }
      }
    }
  }

  // One repository: state dot, label over dimmed location on the left,
  // relative age over absolute date on the right. Urgent color the moment
  // the newest archive is older than staleHours - or when there is none.
  component RepoRow: Item {
    id: row

    property var repo: null

    readonly property bool stale: root.store ? root.store.repoIsStale(repo) : false
    readonly property double lastMs: repo ? Number(repo.lastBackupMs || 0) : 0
    readonly property string error: repo ? String(repo.error || "") : ""

    implicitHeight: Math.max(leftColumn.implicitHeight, rightColumn.implicitHeight)

    Text {
      id: stateDot
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "●"
      color: row.stale ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Column {
      id: leftColumn
      anchors.left: stateDot.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rightColumn.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: row.repo ? String(row.repo.label || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== "" && text !== (row.repo ? String(row.repo.label || "") : "")
        width: parent.width
        text: row.repo ? String(row.repo.location || "") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    Column {
      id: rightColumn
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: row.error !== "" ? "check failed" : (root.store ? root.store.agoText(row.lastMs) : "")
        color: row.stale ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // Absolute date, or the borg error for a repository that could not
      // be listed (bounded so a long message never squeezes the label out).
      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        width: Math.min(implicitWidth, row.width * 0.55)
        text: row.error !== "" ? row.error : (root.store ? root.store.formatAbsolute(row.lastMs) : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
      }
    }
  }
}
