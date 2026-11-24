import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Pomodoro settings panel: timer lengths, auto-start behaviour, and the
// focus reward that lifts the site-blocker DNS blocklist. Every write goes
// through the host widget, which persists it to shell.json inline settings.
//
// The host widget owns the timer state and the daily count; this panel only
// reads them (through `hostWidget`) and sends edits back.
Panel {
  id: root
  moduleName: "larper.pomodoro"
  ipcTarget: "larper.pomodoro"
  manageIpc: false

  // The bar tracks the widget mounted in its slot — Pomodoro.qml — not this
  // nested panel, so everything the bar identifies a panel by must be that
  // widget.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Guarded so the panel renders before the bar is injected (the
  // bar-widget contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dimForeground: Qt.darker(contentForeground, 1.5)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Timer settings and live state, read off the host widget so the clamping
  // and defaults live in exactly one place.
  readonly property int workMinutes: hostWidget ? hostWidget.workMinutes : 30
  readonly property int breakMinutes: hostWidget ? hostWidget.breakMinutes : 5
  readonly property int longBreakMinutes: hostWidget ? hostWidget.longBreakMinutes : 15
  readonly property int sessionsBeforeLong: hostWidget ? hostWidget.sessionsBeforeLong : 4
  readonly property bool autoStartBreaks: hostWidget ? hostWidget.autoStartBreaks : true
  readonly property bool autoStartFocus: hostWidget ? hostWidget.autoStartFocus : false
  readonly property int rewardSessions: hostWidget ? hostWidget.rewardSessions : 4
  readonly property int rewardMinutes: hostWidget ? hostWidget.rewardMinutes : 120
  readonly property int dailyLimitMinutes: hostWidget ? hostWidget.dailyLimitMinutes : 180
  readonly property string screenUsedText: hostWidget ? hostWidget.screenUsedText : ""

  readonly property bool timerRunning: hostWidget ? hostWidget.running : false
  readonly property bool timerIdle: hostWidget ? hostWidget.idle : true
  readonly property string phaseLabel: hostWidget ? hostWidget.phaseLabel : ""
  readonly property string clockText: hostWidget ? hostWidget.clockText : "--:--"
  readonly property int dailyCompleted: hostWidget ? hostWidget.dailyCompleted : 0
  readonly property bool unblocked: hostWidget ? hostWidget.unblocked : false
  readonly property string unblockedRemainingText: hostWidget ? hostWidget.unblockedRemainingText : ""
  readonly property string minutesLabel: hostWidget ? hostWidget.minutesLabel : "2 hours"

  readonly property int sessionsUntilReward: rewardSessions - (dailyCompleted % rewardSessions)

  // Two-step confirmation for the destructive "reset today's count" action.
  property bool confirmReset: false

  readonly property string rewardSummaryText: unblocked
    ? "Sites unblocked · restores in " + unblockedRemainingText
    : (dailyCompleted > 0
      ? dailyCompleted + " of " + rewardSessions + " focus sessions today · " + sessionsUntilReward + " more to unblock sites"
      : "Complete " + rewardSessions + " focus sessions in a day to unblock sites")

  function persist(values) {
    if (hostWidget && typeof hostWidget.persistSettings === "function") hostWidget.persistSettings(values)
  }

  function run(method) {
    if (hostWidget && typeof hostWidget[method] === "function") hostWidget[method]()
  }

  // Restore blocking before the reward window ends.
  function endRewardNow() {
    resumeProc.command = ["sudo", "-n", "/usr/local/bin/site-blocker", "resume"]
    resumeProc.running = true
  }

  Process {
    id: resumeProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code, status) {
      if (code !== 0 && root.hostWidget)
        root.hostWidget.notify("Could not restore blocking",
          "site-blocker resume failed (exit " + code + ").")
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchor under the widget rather than the middle of the bar, so the
    // popup follows wherever the widget is placed.
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    // A settings form, not a cursor-driven list: spinboxes and toggles take
    // focus and keys directly (arrows step the focused field, Tab walks the
    // controls), so only Escape is handled here.
    content: Item {
      id: content
      implicitHeight: settingsColumn.implicitHeight
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

        // Scroll the capped card instead of drawing past the screen edge.
        Flickable {
          id: settingsScroll
          anchors.fill: parent
          contentWidth: width
          contentHeight: settingsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height

        Column {
          id: settingsColumn
          width: Math.max(settingsScroll.width, 300)
          spacing: Style.space(14)
  
          // ---- hero: phase · clock · reward progress ----
          Item {
            width: parent.width
            implicitHeight: Math.max(heroGlyph.height, heroLabels.implicitHeight)
  
            Text {
              id: heroGlyph
              textFormat: Text.PlainText
              text: "\uf252"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
  
            Column {
              id: heroLabels
              anchors.left: heroGlyph.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
  
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.phaseLabel + " · " + root.clockText
                  + (root.timerRunning ? "" : (root.timerIdle ? " (idle)" : " (paused)"))
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }
  
              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.rewardSummaryText
                color: root.unblocked ? Commons.Color.accent : root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
  
          // ---- timer controls ----
          Row {
            spacing: Style.space(8)
  
            Button {
              bordered: true
              text: root.timerRunning ? "Pause" : (root.timerIdle ? "Start" : "Resume")
              onClicked: root.run("toggle")
            }
  
            Button {
              bordered: true
              text: "Reset phase"
              onClicked: root.run("resetPhase")
            }
  
            Button {
              bordered: true
              text: "Skip phase"
              onClicked: root.run("skipPhase")
            }
          }
  
          PanelSeparator { foreground: root.contentForeground }
  
          // ---- timer lengths ----
          PanelSectionHeader { text: "Timer"; foreground: root.contentForeground }
  
          Grid {
            columns: 2
            spacing: Style.space(16)
            width: parent.width
  
            NumberField {
              label: "Focus length (min)"
              from: 30
              to: 180
              stepSize: 5
              value: root.workMinutes
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function(v) { root.persist({ workMinutes: v }) }
            }
  
            NumberField {
              label: "Break length (min)"
              from: 1
              to: 15
              stepSize: 1
              value: root.breakMinutes
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function(v) { root.persist({ breakMinutes: v }) }
            }
  
            NumberField {
              label: "Long break (min)"
              from: 1
              to: 15
              stepSize: 5
              value: root.longBreakMinutes
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function(v) { root.persist({ longBreakMinutes: v }) }
            }
  
            NumberField {
              label: "Long break after"
              from: 1
              to: 12
              stepSize: 1
              value: root.sessionsBeforeLong
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function(v) { root.persist({ sessionsBeforeLong: v }) }
            }
          }
  
          Toggle {
            width: parent.width
            label: "Auto-start breaks"
            description: "Begin each break as soon as a focus session ends."
            checked: root.autoStartBreaks
            foreground: root.contentForeground
            onClicked: root.persist({ autoStartBreaks: !checked })
          }
  
          Toggle {
            width: parent.width
            label: "Auto-start focus"
            description: "Begin the next focus session when a break ends."
            checked: root.autoStartFocus
            foreground: root.contentForeground
            onClicked: root.persist({ autoStartFocus: !checked })
          }
  
          PanelSeparator { foreground: root.contentForeground }
  
          // ---- site-blocker reward ----
          PanelSectionHeader { text: "Focus reward"; foreground: root.contentForeground }
  
          Grid {
            columns: 2
            spacing: Style.space(16)
            width: parent.width
  
            NumberField {
              label: "Sessions to unblock"
              from: 2
              to: 20
              stepSize: 1
              value: root.rewardSessions
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function(v) { root.persist({ rewardSessions: v }) }
            }
  
            NumberField {
              label: "Unblock duration (min)"
              from: 5
              to: 480
              stepSize: 15
              value: root.rewardMinutes
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function(v) { root.persist({ rewardMinutes: v }) }
            }
          }
  
          Row {
            width: parent.width
            spacing: Style.space(8)
  
            Text {
              textFormat: Text.PlainText
              width: parent.width - endButton.width - parent.spacing
              wrapMode: Text.WordWrap
              text: root.rewardSummaryText
              color: root.unblocked ? Commons.Color.accent : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }
  
            PanelActionButton {
              id: endButton
              visible: root.unblocked
              iconText: "\uf00d"
              tooltipText: "Restore site blocking now"
              foreground: root.contentForeground
              onClicked: root.endRewardNow()
            }
          }
  
          // Clearing the count is a deliberate action, so the first click only
          // arms the button and a second click within a few seconds applies it.
          Button {
            visible: root.dailyCompleted > 0
            bordered: true
            text: root.confirmReset
              ? "Click again to reset (" + root.dailyCompleted + " today)"
              : "Reset today's count"
            onClicked: {
              if (root.confirmReset) {
                root.confirmReset = false
                root.run("resetDaily")
              } else {
                root.confirmReset = true
                resetConfirmTimer.restart()
              }
            }
          }
  
          Timer {
            id: resetConfirmTimer
            interval: 4000
            onTriggered: root.confirmReset = false
          }
  
          // ---- daily screen-time limit ----
          PanelSectionHeader {
            text: "Screen time · today " + root.screenUsedText
            foreground: root.contentForeground
          }
  
          Row {
            width: parent.width
  
            NumberField {
              label: "Daily limit (min)"
              from: 5
              to: 360
              stepSize: 15
              value: root.dailyLimitMinutes
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onModified: function(v) { root.persist({ dailyLimitMinutes: v }) }
            }
          }
  
        }
        }
    }
  }
}
