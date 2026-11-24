import QtQuick

// Stands in for Quickshell's SystemClock, following the stock clock plugin's
// lead (plugins/panels/clock/WallClock.qml). SystemClock schedules its next
// tick from local wall time; in the hour repeated when daylight saving ends
// that resolves to the first pass through the hour, so the delay comes out
// negative and the timer floods the log with warnings. Epoch milliseconds
// never repeat, so every delay here stays within one step.
Timer {
  id: root

  // Milliseconds between ticks: 1000 to show seconds, 60000 for minutes.
  property int step: 60000
  property date date: new Date()

  function arm() {
    interval = root.step - Date.now() % root.step
    restart()
  }

  onStepChanged: arm()
  onTriggered: {
    date = new Date()
    arm()
  }
  Component.onCompleted: arm()
}
