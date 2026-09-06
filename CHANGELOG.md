# Changelog

## [0.1.0] - 2026-09-06

### Added
- Initial release: borgmatic backup freshness monitor for Omarchy shell (Quickshell bar-widget plugin)
- Bar icon that turns urgent when the newest backup in any repository is older than the stale threshold (default 48 h)
- Popup panel listing every configured repository with its last backup date and relative age, stale repositories highlighted
- Failure banner when the check itself can't reach the server, keeping the last cached data visible
- Status cache in `~/.local/state/quickborgmatic/status.json` so status shows instantly after a shell restart
- Monitoring-only YAML config, one file per remote machine (see `example-monitor.yaml`)
