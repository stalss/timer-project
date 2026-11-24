import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Pomodoro focus timer for the Omarchy bar, with a settings panel and a
// site-blocker reward.
//
//   left click   start / pause
//   right click   open the settings panel
//   middle click  skip to the next phase (does not count a focus session)
//
// Optional shell.json settings on the widget entry:
//   workMinutes (30, min 30), breakMinutes (5, max 15), longBreakMinutes (15, max 15),
//   sessionsBeforeLong (4), autoStartBreaks (true), autoStartFocus (false),
//   rewardSessions (4, min 2) - focus sessions in one day that earn the reward
//   rewardMinutes (120) - how long the reward lifts site blocking
//   dailyLimitMinutes (180) - daily unlocked-time cap; max 360
//
// Completed focus sessions are counted per day in
// ~/.local/state/omarchy/pomodoro.json. Every `rewardSessions`-th session of
// the day runs `sudo -n site-blocker pause <rewardMinutes>` - passwordless
// through a sudoers rule installed alongside the site-blocker - which parks
// the DNS blocklist and schedules its own restore. The blocker leaves the
// remaining time in /var/lib/site-blocker/pause.json, which this widget
// watches so the bar and panel can show the live window.
BarWidget {
  id: root
  moduleName: "larper.pomodoro"

  // ---- settings ----

  readonly property int workMinutes: Math.max(30, Math.min(180, Math.round(Number(setting("workMinutes", 30)) || 30)))
  readonly property int breakMinutes: Math.max(1, Math.min(15, Math.round(Number(setting("breakMinutes", 5)) || 5)))
  readonly property int longBreakMinutes: Math.max(1, Math.min(15, Math.round(Number(setting("longBreakMinutes", 15)) || 15)))
  readonly property int sessionsBeforeLong: Math.max(1, Math.min(12, Math.round(Number(setting("sessionsBeforeLong", 4)) || 4)))
  readonly property bool autoStartBreaks: setting("autoStartBreaks", true) === true
  readonly property bool autoStartFocus: setting("autoStartFocus", false) === true
  readonly property int rewardSessions: Math.max(2, Math.min(20, Math.round(Number(setting("rewardSessions", 4)) || 4)))
  readonly property int rewardMinutes: Math.max(5, Math.min(480, Math.round(Number(setting("rewardMinutes", 120)) || 120)))
  readonly property int dailyLimitMinutes: Math.max(5, Math.min(360, Math.round(Number(setting("dailyLimitMinutes", 180)) || 180)))

  // ---- timer state ----

  // "focus" | "short" | "long"
  property string phase: "focus"
  property int remaining: phaseSeconds
  property bool running: false
  property double endAt: 0

  readonly property bool onBreak: phase !== "focus"
  readonly property int phaseSeconds: phase === "focus"
    ? workMinutes * 60
    : (phase === "long" ? longBreakMinutes * 60 : breakMinutes * 60)
  readonly property bool idle: !running && remaining === phaseSeconds

  readonly property string clockText: {
    var total = Math.max(0, remaining)
    var m = Math.floor(total / 60)
    var s = total % 60
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
  }
  readonly property string phaseLabel: phase === "focus"
    ? "Focus"
    : (phase === "long" ? "Long break" : "Break")

  function start() {
    if (remaining <= 0) remaining = phaseSeconds
    endAt = Date.now() + remaining * 1000
    running = true
  }

  function pause() {
    if (!running) return
    // The deadline may pass between ticks; finish instead of sitting at 00:00.
    if (endAt > 0 && Date.now() >= endAt) {
      finish()
      return
    }
    remaining = Math.max(0, Math.ceil((endAt - Date.now()) / 1000))
    running = false
  }

  function toggle() {
    if (running) pause()
    else start()
  }

  function resetPhase() {
    running = false
    remaining = Qt.binding(function() { return root.phaseSeconds })
  }

  function notify(title, body) {
    if (!root.bar) return
    root.bar.run("omarchy-notification-send -g " + Util.shellQuote("\uf252")
      + " -u normal -t 10000 " + Util.shellQuote(title) + " " + Util.shellQuote(body))
  }

  // Move to the next phase. `count` is true when a focus session actually
  // finished, which is what advances the long-break cycle and the day's
  // reward count.
  function nextPhase(count) {
    running = false
    if (phase === "focus") {
      // Use the persisted daily count so the long-break cycle survives restarts.
      if (count) recordSession()
      phase = (count && dailyCompleted % sessionsBeforeLong === 0) ? "long" : "short"
      remaining = Qt.binding(function() { return root.phaseSeconds })
      if (count) {
        notify(phase === "long" ? "Focus complete: long break" : "Focus complete: break time",
          phase === "long"
            ? "Nice work. Step away for " + longBreakMinutes + " minutes."
            : "Take " + breakMinutes + " minutes away from the screen.")
      } else {
        notify("Focus skipped", "Moving to " + (phase === "long" ? "a long break" : "a short break") + ".")
      }
      if (autoStartBreaks) start()
    } else {
      phase = "focus"
      remaining = Qt.binding(function() { return root.phaseSeconds })
      notify("Break over", "Ready for the next " + workMinutes + "-minute focus session.")
      if (autoStartFocus) start()
    }
  }

  function skipPhase() {
    nextPhase(false)
  }

  function finish() {
    remaining = 0
    running = false
    nextPhase(true)
  }

  // ---- daily focus-session count, shared across bar instances ----

  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/pomodoro.json"

  property string dayKey: ""
  property int dailyCompleted: 0

  // The blocker's reward window, published as a world-readable epoch
  // timestamp. Absent file (or a past one) means blocking is active.
  readonly property string pauseStatePath: "/var/lib/site-blocker/pause.json"
  property double unblockedUntil: 0
  property double nowMs: Date.now()
  readonly property bool unblocked: unblockedUntil > nowMs
  readonly property string unblockedRemainingText: formatClock(Math.max(0, unblockedUntil - nowMs))
  // Daily screen-time limiter state, written by ~/.local/bin/daily-screen-limit.
  readonly property string screenLimitStatePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/daily-screen-limit.json"
  property double screenUsedSeconds: 0
  readonly property string screenUsedText: {
    var mins = Math.floor(screenUsedSeconds / 60)
    return mins >= 60 ? (Math.floor(mins / 60) + "h " + (mins % 60) + "m") : (mins + "m")
  }


  readonly property string minutesLabel: rewardMinutes >= 60 && rewardMinutes % 60 === 0
    ? (rewardMinutes / 60) + " hour" + (rewardMinutes === 60 ? "" : "s")
    : rewardMinutes + " minutes"

  function formatClock(ms) {
    var total = Math.floor(ms / 1000)
    var h = Math.floor(total / 3600)
    var m = Math.floor((total % 3600) / 60)
    var s = total % 60
    var mm = (m < 10 ? "0" : "") + m
    var ss = (s < 10 ? "0" : "") + s
    return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
  }

  function dayKeyOf(date) {
    function pad(n) { return (n < 10 ? "0" : "") + n }
    return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate())
  }

  function rollDay(date) {
    var key = dayKeyOf(date)
    if (key === root.dayKey) return
    var hadKey = root.dayKey !== ""
    root.dayKey = key
    if (hadKey) {
      root.dailyCompleted = 0
      persistDaily()
    }
  }

  // FileView emits an empty read while it is (re)loading, and a plugin reload
  // can deliver that before the real content. Treating it as state would wipe
  // the day's count, so ignore anything that is not a valid JSON object.
  function loadDaily(raw) {
    var text = String(raw || "").trim()
    if (text === "") return
    var parsed = {}
    try { parsed = JSON.parse(text) } catch (e) { return }
    if (!parsed || typeof parsed !== "object") return
    var count = Number(parsed.completed)
    var key = dayKeyOf(new Date())
    root.dayKey = key
    root.dailyCompleted = parsed.date === key && Number.isFinite(count) && count > 0
      ? Math.floor(count) : 0
    if (parsed.date !== key) persistDaily()
  }

  // Clear today's count from the settings panel. An already-earned reward
  // window keeps running; only progress toward the next one is discarded.
  function resetDaily() {
    root.dayKey = dayKeyOf(new Date())
    root.dailyCompleted = 0
    persistDaily()
  }

  function persistDaily() {
    dailyFile.setText(JSON.stringify({ date: root.dayKey, completed: root.dailyCompleted }) + "\n")
  }

  // A focus session finished: count it for today, then check the reward.
  // Every `rewardSessions`-th session of the day re-earns the window, so a
  // second run of four extends the unblock from that moment.
  function recordSession() {
    rollDay(new Date())
    dailyCompleted += 1
    persistDaily()
    if (dailyCompleted > 0 && dailyCompleted % rewardSessions === 0) grantReward()
  }

  function grantReward() {
    rewardProc.command = ["sudo", "-n", "/usr/local/bin/site-blocker", "pause", String(rewardMinutes)]
    rewardProc.running = true
  }

  // Restore blocking before the reward window ends (panel button).
  function endReward() {
    resumeProc.command = ["sudo", "-n", "/usr/local/bin/site-blocker", "resume"]
    resumeProc.running = true
  }

  // ---- settings persistence ----

  // Applied locally first so the timer re-renders on the edit itself; the
  // shell.json write comes back through the bar as the same values. With no
  // writable entry the values stay session-only rather than doing nothing.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    // Enforce bounds at write time: the editable SpinBox can momentarily
    // report out-of-range values, so clamp before persisting to shell.json.
    entry.workMinutes = Math.max(30, Math.round(Number(entry.workMinutes)) || 30)
    entry.breakMinutes = Math.max(1, Math.min(15, Math.round(Number(entry.breakMinutes)) || 5))
    entry.longBreakMinutes = Math.max(1, Math.min(15, Math.round(Number(entry.longBreakMinutes)) || 15))
    entry.sessionsBeforeLong = Math.max(1, Math.min(12, Math.round(Number(entry.sessionsBeforeLong)) || 4))
    entry.rewardSessions = Math.max(2, Math.min(20, Math.round(Number(entry.rewardSessions)) || 4))
    entry.rewardMinutes = Math.max(5, Math.min(480, Math.round(Number(entry.rewardMinutes)) || 120))
    entry.dailyLimitMinutes = Math.max(5, Math.min(360, Math.round(Number(entry.dailyLimitMinutes)) || 180))

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- settings panel. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggleSettings() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // The timer label is text to read, so the open-panel dot runs under it.
  readonly property real openPanelIndicatorWidth: button.labelWidth

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  WallClock {
    id: wall
    step: 60000
    onDateChanged: root.rollDay(new Date())
  }

  // Daily count. Watched so a session finished on another monitor's bar
  // (or the day rolling over) reaches every instance.
  FileView {
    id: dailyFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadDaily(text())
    onLoadFailed: root.rollDay(new Date())
    onFileChanged: reload()
  }

  // Reward window published by the site-blocker.
  FileView {
    id: pauseFile
    path: root.pauseStatePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var until = 0
      try {
        var parsed = JSON.parse(String(text() || ""))
        var seconds = Number(parsed && parsed.until)
        if (Number.isFinite(seconds) && seconds > 0) until = seconds * 1000
      } catch (e) {}
      root.unblockedUntil = until
    }
    onLoadFailed: root.unblockedUntil = 0
    onFileChanged: reload()
  }

  // Daily unlocked-time counter published by the limiter service.
  FileView {
    id: screenLimitFile
    path: root.screenLimitStatePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var seconds = 0
      try {
        var parsed = JSON.parse(String(text() || ""))
        var value = Number(parsed && parsed.seconds)
        if (Number.isFinite(value) && value > 0) seconds = value
      } catch (e) {}
      root.screenUsedSeconds = seconds
    }
    onLoadFailed: root.screenUsedSeconds = 0
    onFileChanged: reload()
  }

  // Ticks the remaining-time readout only while a reward window is live.
  Timer {
    id: unblockTicker
    interval: 1000
    repeat: true
    running: root.unblocked
    onTriggered: root.nowMs = Date.now()
  }
  onUnblockedUntilChanged: root.nowMs = Date.now()

  // Lifting the blocklist is a privileged operation; the sudoers rule
  // installed with the site-blocker makes this exact invocation passwordless.
  Process {
    id: rewardProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code, status) {
      if (code === 0) {
        root.notify("Focus reward: sites unblocked",
          dailyCompleted + " focus sessions today. Blocking is lifted for " + root.minutesLabel + ".")
      } else {
        root.notify("Focus reward failed",
          "Could not lift site blocking (site-blocker exit " + code + "). The sudoers rule for 'site-blocker pause' is not installed.")
      }
    }
  }

  Process {
    id: resumeProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  IpcHandler {
    target: "larper.pomodoro"

    function toggle(): void { root.toggle() }
    function start(): void { root.start() }
    function pause(): void { root.pause() }
    function reset(): void { root.resetPhase() }
    function skip(): void { root.skipPhase() }
    function openSettings(): void { root.open() }
    function closeSettings(): void { root.close() }
    function resetDaily(): void { root.resetDaily() }
  }

  Timer {
    id: ticker
    interval: 250
    repeat: true
    running: root.running
    onTriggered: {
      var left = Math.ceil((root.endAt - Date.now()) / 1000)
      if (left <= 0) root.finish()
      else root.remaining = left
    }
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

  readonly property string tooltip: phaseLabel + " " + clockText
    + (running ? " (running)" : " (paused)")
    + " · " + dailyCompleted + " focus sessions today"
    + (unblocked
      ? " · sites unblocked, " + unblockedRemainingText + " left"
      : " · " + (rewardSessions - (dailyCompleted % rewardSessions)) + " more to unblock sites")
    + "\nLeft: start/pause · Right: settings · Middle: skip"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical
      ? "\uf252"
      : "\uf252 " + root.clockText
    dimmed: !root.running && !root.idle
    tooltipText: root.tooltip

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleSettings()
      else if (b === Qt.MiddleButton) root.skipPhase()
      else root.toggle()
    }
  }
}
