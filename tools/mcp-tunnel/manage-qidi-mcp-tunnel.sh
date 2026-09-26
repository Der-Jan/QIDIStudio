#!/usr/bin/env bash
set -uo pipefail
action=""
while (($#)); do
  case "$1" in
    --action) action="${2:-}"; shift 2 ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done
unit=qidi-studio-mcp-tunnel.service
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/qidi-studio-mcp-tunnel"
unit_file="$config_dir/systemd/user/$unit"
profile="$config_dir/tunnel-client/qidi-studio.yaml"
id=""
if [[ -f "$profile" ]]; then
  id="$(sed -n 's/^[[:space:]]*tunnel_id:[[:space:]]*//p' "$profile" | head -n1 | tr -d '\"')"
fi
running=0
systemctl --user is-active --quiet "$unit" && running=1
credential=0
if [[ -n "$id" ]] && command -v secret-tool >/dev/null; then
  secret-tool lookup application QIDIStudio tunnel-id "$id" >/dev/null 2>&1 && credential=1
fi
configured=0; [[ -f "$unit_file" && -x "$(dirname -- "$0")/tunnel-client" && -n "$id" ]] && configured=1
healthy=0
if ((running)); then
  curl --silent --fail --max-time 2 http://127.0.0.1:8080/readyz >/dev/null 2>&1 && healthy=1
fi
case "$action" in
  status)
    printf '{"configured":%s,"healthy":%s,"heartbeat_fresh":%s,"credentials_configured":%s,"task_state":"%s","tunnel_id":"%s","heartbeat_age_seconds":null,"local_mcp_url":"http://127.0.0.1:8765/mcp"}\n' \
      "$([[ $configured == 1 ]] && echo true || echo false)" "$([[ $healthy == 1 ]] && echo true || echo false)" \
      "$([[ $running == 1 ]] && echo true || echo false)" "$([[ $credential == 1 ]] && echo true || echo false)" \
      "$([[ $running == 1 ]] && echo Running || echo Stopped)" "$id"
    ;;
  start) systemctl --user start "$unit" ;;
  stop) systemctl --user stop "$unit" ;;
  restart) systemctl --user restart "$unit" ;;
  doctor)
    client="$(dirname -- "$0")/tunnel-client"
    export CONTROL_PLANE_API_KEY="$(secret-tool lookup application QIDIStudio tunnel-id "$id")"
    "$client" doctor --profile qidi-studio --explain
    ;;
  open-ui) xdg-open http://127.0.0.1:8080/ui >/dev/null 2>&1 & ;;
  logs) xdg-open "$state_dir" >/dev/null 2>&1 & ;;
  *) echo "Usage: $0 --action status|start|stop|restart|doctor|open-ui|logs" >&2; exit 2 ;;
esac
