#!/bin/zsh
set -euo pipefail

mode="${1:-run}"
script_dir="${0:A:h}"
package_dir="${script_dir:h}"
app_name="SecondSightMac"
bundle_path="${package_dir}/${app_name}.app"
binary_path="${bundle_path}/Contents/MacOS/${app_name}"

pkill -x "$app_name" >/dev/null 2>&1 || true
"${script_dir}/build-app.sh" >/dev/null

open_app() {
  /usr/bin/open -n "$bundle_path"
}

case "$mode" in
  run)
    open_app
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$app_name" >/dev/null
    print "$app_name is running"
    ;;
  --debug|debug)
    lldb -- "$binary_path"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == '$app_name'"
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "study.secondsight.mac"'
    ;;
  *)
    print -u2 "usage: $0 [run|--verify|--debug|--logs|--telemetry]"
    exit 2
    ;;
esac
