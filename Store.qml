import QtQuick
import Quickshell
import Quickshell.Io

// Data layer for the borgmatic backup monitor. Owns the borgmatic
// subprocess, the on-disk cache, and every timestamp computation; the
// widget and panel only read from here.
//
// The check is `borgmatic repo-list --json`: ~3s over SSH and it briefly
// takes the repo lock, so it runs on a slow timer (refreshHours) and its
// result is cached to disk. Staleness is derived from repos + nowMs +
// staleHours rather than stored, so the minute tick keeps the warning and
// every relative age honest between checks.
//
// The bar mounts one widget instance per monitor, each with its own Store.
// The cache file is the meeting point: the instance whose timer fires first
// writes it, the others converge through the watchChanges reader, and the
// cache-age guard in refresh() keeps them from each running borgmatic.
Item {
  id: root
  visible: false

  property QtObject bar: null
  property var settings: ({})

  // Matches BarWidget.setting(): one value from the widget's inline
  // shell.json entry, with a fallback for missing/null.
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property real staleHours: Number(setting("staleHours", 48))
  readonly property real refreshHours: Number(setting("refreshHours", 6))
  readonly property double staleMs: Math.max(1, staleHours) * 3600 * 1000
  readonly property double refreshMs: Math.max(1, refreshHours) * 3600 * 1000

  // Hard limits on the check. The subprocess talks to remote hosts over
  // SSH, so a stalled peer must not keep it alive forever and a hostile one
  // must not feed the shell unbounded output. The wrapper script enforces
  // all three before anything reaches this process.
  readonly property int checkTimeoutSec: 300
  readonly property int stdoutCapBytes: 8 * 1024 * 1024
  readonly property int stderrCapBytes: 64 * 1024

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/quickborgmatic"
  readonly property string cachePath: stateDir + "/status.json"

  // Extra monitoring-only borgmatic configs (repositories + passphrase, no
  // sources) live here - one file per remote machine to watch. They are
  // outside borgmatic's default config locations on purpose: the nightly
  // borgmatic run never sees them, so it can't try to `create` into a
  // repository this machine only observes.
  readonly property string monitorDir: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/quickborgmatic/monitor.d"

  // ---- state ---------------------------------------------------------------

  property var repos: []            // [{label, location, id, lastBackupMs, archiveCount}]
  property double lastCheckedMs: 0  // last successful check
  property double lastAttemptMs: 0  // last attempt, success or not
  property bool checkFailed: false
  property string errorText: ""
  readonly property bool checking: proc.running

  // Bumped once a minute; everything time-derived binds to it so an open
  // panel and the bar warning both stay truthful between checks.
  property double nowMs: Date.now()

  readonly property int staleCount: {
    var count = 0
    for (var i = 0; i < repos.length; i++)
      if (repoIsStale(repos[i])) count++
    return count
  }
  readonly property bool anyStale: staleCount > 0
  // Repositories borgmatic could not list in the last check (wrong
  // passphrase, missing repo, unreachable host...). They are rows with an
  // `error` field and no archives, so they also count as stale.
  readonly property int failedRepoCount: {
    var count = 0
    for (var i = 0; i < repos.length; i++)
      if (repos[i] && repos[i].error) count++
    return count
  }
  readonly property bool neverChecked: lastCheckedMs === 0 && repos.length === 0

  function repoIsStale(repo) {
    if (!repo) return false
    if (!(repo.lastBackupMs > 0)) return true   // repo with no archives at all
    return nowMs - repo.lastBackupMs > staleMs
  }

  // ---- borg timestamps -----------------------------------------------------

  // Borg emits local time with 6-digit fractional seconds and no timezone
  // ("2026-09-04T01:51:56.000000"); new Date(string) mis-parses that shape,
  // so read the fields out by hand as local time.
  function parseBorgTime(s) {
    var m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/.exec(String(s || ""))
    if (!m) return 0
    var ms = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).getTime()
    return isFinite(ms) ? ms : 0
  }

  // ---- the check -----------------------------------------------------------

  property bool cacheReady: false
  property bool refreshPending: false
  property bool refreshPendingForce: false

  // force skips the cache-age guard (manual refresh); a timer refresh
  // defers to data newer than the interval, including data another
  // instance or a previous shell session already fetched.
  function refresh(force) {
    if (proc.running) return
    if (!cacheReady) {
      refreshPending = true
      if (force === true) refreshPendingForce = true
      return
    }
    if (force !== true && Date.now() - lastAttemptMs < refreshMs) return
    proc.running = true
  }

  Process {
    id: proc
    running: false
    // Passing any -c disables borgmatic's default config search, so the
    // defaults that exist are re-listed explicitly before monitor.d is
    // appended. An empty monitor.d is fine (verified: borgmatic accepts an
    // empty config directory).
    //
    // $2 deadline (s), $3 stdout cap (bytes), $4 stderr cap (bytes).
    // `timeout` puts borgmatic and its borg/ssh children in one process
    // group and TERMs then KILLs the whole group at the deadline (exit 124).
    // Both streams pass through `head -c` so this process never receives
    // more than the caps: stderr is cut and the rest drained, stdout probes
    // one extra byte to tell "hit the cap" from "exactly the cap" and exits
    // 222 on overflow, which closes the pipe and stops the producer.
    command: ["bash", "-c", [
      'cfgs=()',
      'for p in /etc/borgmatic/config.yaml /etc/borgmatic.d "${XDG_CONFIG_HOME:-$HOME/.config}/borgmatic/config.yaml" "${XDG_CONFIG_HOME:-$HOME/.config}/borgmatic.d" "$1"; do',
      '  [ -e "$p" ] && cfgs+=(-c "$p")',
      'done',
      '{ timeout -k 10 "$2" borgmatic "${cfgs[@]}" repo-list --json 2>&1 >&3 \\',
      '    | { head -c "$4" >&2; cat >/dev/null; }',
      '  exit "${PIPESTATUS[0]}"',
      '} 3>&1 | { head -c "$3"; [ "$(head -c 1 | wc -c)" -eq 0 ] || exit 222; }',
      'rcs=("${PIPESTATUS[@]}")',
      '[ "${rcs[1]}" -eq 222 ] && exit 222',
      'exit "${rcs[0]}"'
    ].join("\n"), "--", root.monitorDir, String(root.checkTimeoutSec),
        String(root.stdoutCapBytes), String(root.stderrCapBytes)]

    // waitForEnd holds the exited signal until both streams have drained,
    // so the collectors' text is complete inside onExited.
    stdout: StdioCollector { id: outCollector; waitForEnd: true }
    stderr: StdioCollector { id: errCollector; waitForEnd: true }

    onExited: function(exitCode) {
      root.applyResult(exitCode, outCollector.text, errCollector.text)
    }
  }

  // Last-resort reaper in case `timeout` itself never returns: SIGKILL the
  // wrapper well after its own deadline. Normally never fires.
  Timer {
    interval: (root.checkTimeoutSec + 30) * 1000
    running: proc.running
    repeat: false
    onTriggered: {
      console.warn("quickborgmatic: check exceeded its deadline, killing it")
      proc.signal(9)
    }
  }

  function applyResult(exitCode, stdoutText, stderrText) {
    lastAttemptMs = Date.now()
    nowMs = lastAttemptMs

    // borgmatic keeps listing the other repositories when one fails and
    // still prints their JSON, so a non-zero exit is parsed too: one broken
    // repository must not hide the state of every other one. Only a
    // truncated stream (222) is never parsed.
    var parsed = null
    if (exitCode !== 222) {
      try { parsed = JSON.parse(String(stdoutText || "")) } catch (e) { parsed = null }
    }

    if (parsed && Array.isArray(parsed)) {
      var out = []
      var seen = {}
      for (var i = 0; i < parsed.length; i++) {
        var entry = parsed[i] || {}
        var repo = entry.repository || {}
        var archives = entry.archives || []
        var latest = archives.length > 0 ? archives[archives.length - 1] : null
        // A repository named by both the main config and a monitor.d file
        // comes back twice; one row per actual repository.
        var key = String(repo.id || "") !== "" ? String(repo.id) : String(repo.location || "")
        if (seen[key]) continue
        seen[key] = true
        seen[String(repo.location || "")] = true
        out.push({
          label: String(repo.label || "") !== "" ? String(repo.label) : String(repo.location || "repository"),
          location: String(repo.location || ""),
          id: String(repo.id || ""),
          lastBackupMs: latest ? parseBorgTime(latest.time || latest.start) : 0,
          archiveCount: archives.length,
          error: ""
        })
      }
      var failed = exitCode === 0 ? [] : failedRepos(stderrText)
      for (var f = 0; f < failed.length; f++) {
        if (seen[failed[f].location]) continue   // listed fine under another config
        seen[failed[f].location] = true
        out.push({
          label: failed[f].label !== "" ? failed[f].label : failed[f].location,
          location: failed[f].location,
          id: "",
          lastBackupMs: 0,
          archiveCount: 0,
          error: failed[f].error
        })
      }
      repos = out
      lastCheckedMs = lastAttemptMs
      // Every failure is attributed to a row: the rows tell the story.
      // Otherwise the exit was non-zero for a reason we could not pin on a
      // repository, so say so while still showing the fresh data.
      checkFailed = exitCode !== 0 && failed.length === 0
      errorText = checkFailed ? checkErrorText(exitCode, stderrText) : ""
    } else {
      // Keep the cached repos on failure - stale data beats no data - and
      // surface why. stderr is the only borgmatic text ever shown.
      checkFailed = true
      errorText = checkErrorText(exitCode, stderrText)
    }
    persist()
  }

  // borgmatic reports each repository it could not list as
  //   "<label>: Command 'borg list ... <repo-url>' returned non-zero exit status N."
  // with the actual borg message on the nearest preceding line. Returns
  // [{label, location, error}], one per repository.
  readonly property var commandFailedRe: /^(?:([^:'\s][^:']*): )?Command '(.*)' returned non-zero exit status (\d+)\.?$/
  readonly property var labelPrefixRe: /^[^:'\s][^:']*: /

  function failedRepos(stderrText) {
    var lines = String(stderrText || "").split("\n")
    var byLocation = {}
    var order = []
    for (var i = 0; i < lines.length; i++) {
      var m = commandFailedRe.exec(lines[i].trim())
      if (!m) continue
      var words = m[2].trim().split(/\s+/)
      var location = words[words.length - 1]
      if (!location) continue
      var message = ""
      for (var j = i - 1; j >= 0 && j >= i - 6; j--) {
        var prev = lines[j].trim().replace(labelPrefixRe, "")
        if (prev !== "" && !isNoiseLine(prev) && !commandFailedRe.test(prev)) { message = prev; break }
      }
      if (message === "") message = "borg exited with code " + m[3]
      var label = m[1] ? m[1] : ""
      var existing = byLocation[location]
      if (!existing) {
        byLocation[location] = { label: label, location: location, error: message }
        order.push(location)
      } else if (existing.label === "" && label !== "") {
        existing.label = label   // the summary repeats the line without its label
      }
    }
    var result = []
    for (var k = 0; k < order.length; k++) result.push(byLocation[order[k]])
    return result
  }

  function checkErrorText(exitCode, stderrText) {
    if (exitCode === 222)
      return "borgmatic output exceeded " + Math.round(stdoutCapBytes / 1048576) + " MiB, check aborted"
    if (exitCode === 124 || exitCode === 137)
      return "check timed out after " + Math.round(checkTimeoutSec / 60) + " min"
    return lastStderrLine(stderrText, exitCode)
  }

  // borg's remote chatter, borgmatic's help footer and its generic
  // "something failed" wrappers never say what went wrong; skipping them
  // surfaces the actual cause (e.g. "Connection closed by remote host").
  readonly property var noisePrefixes: [
    "Remote:", "Need some help?", "Error running configuration",
    "An error occurred", "Error running actions for repository"
  ]
  function isNoiseLine(line) {
    for (var i = 0; i < noisePrefixes.length; i++)
      if (line.indexOf(noisePrefixes[i]) === 0) return true
    return false
  }

  function lastStderrLine(stderrText, exitCode) {
    var lines = String(stderrText || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim().replace(labelPrefixRe, "")
      if (line !== "" && !isNoiseLine(line) && !commandFailedRe.test(line)) return line
    }
    return "borgmatic exited with code " + exitCode
  }

  // ---- cache ---------------------------------------------------------------

  property bool writeBusy: false
  property bool writeDirty: false

  function persist() {
    if (writeBusy) { writeDirty = true; return }
    writeBusy = true
    writer.path = cachePath
    writer.setText(JSON.stringify({
      version: 1,
      lastCheckedMs: lastCheckedMs,
      lastAttemptMs: lastAttemptMs,
      checkFailed: checkFailed,
      errorText: errorText,
      repos: repos
    }))
  }

  function writeDone() {
    writeBusy = false
    if (writeDirty) { writeDirty = false; persist() }
  }

  FileView {
    id: writer
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root.writeDone()
    onSaveFailed: function(error) {
      console.warn("quickborgmatic: cache write failed:", writer.path)
      root.writeDone()
    }
  }

  FileView {
    id: cacheView
    path: root.cachePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyCache(text())
    onLoadFailed: root.cacheSettled()
    onFileChanged: reload()
  }

  function applyCache(content) {
    try {
      var data = JSON.parse(String(content || ""))
      // Adopt only data at least as fresh as what this instance holds -
      // our own write echoing back and a peer's newer check both pass,
      // a stale file never regresses live state.
      if (data && typeof data === "object" && Number(data.lastAttemptMs || 0) >= lastAttemptMs) {
        repos = Array.isArray(data.repos) ? data.repos : []
        lastCheckedMs = Number(data.lastCheckedMs || 0)
        lastAttemptMs = Number(data.lastAttemptMs || 0)
        checkFailed = data.checkFailed === true
        errorText = String(data.errorText || "")
      }
    } catch (e) {
      // Corrupt cache: ignore it, the next check rewrites it.
    }
    cacheSettled()
  }

  // The refresh timer's triggeredOnStart fires before the cache has loaded;
  // without this gate every shell restart would hit the remote server even
  // when the cache is minutes old.
  function cacheSettled() {
    if (cacheReady) return
    cacheReady = true
    if (refreshPending) {
      refreshPending = false
      var force = refreshPendingForce
      refreshPendingForce = false
      refresh(force)
    }
  }

  // ---- timers --------------------------------------------------------------

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // ---- formatting ----------------------------------------------------------

  function formatAge(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  function agoText(ms) {
    if (!(ms > 0)) return "never"
    var diff = nowMs - ms
    if (diff < 60000) return "just now"
    return formatAge(diff) + " ago"
  }

  function formatAbsolute(ms) {
    return ms > 0 ? Qt.formatDateTime(new Date(ms), "ddd d MMM yyyy HH:mm") : "no archives"
  }

  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", stateDir, monitorDir])
}
