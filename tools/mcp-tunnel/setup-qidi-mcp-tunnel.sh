#!/usr/bin/env bash
set -euo pipefail
umask 077

id=""
reuse=0
for arg in "$@"; do
  case "$arg" in
    --tunnel-id) expect_id=1 ;;
    --from-environment) from_environment=1 ;;
    --reuse-existing-credential) reuse=1 ;;
    *) if [[ "${expect_id:-0}" == 1 ]]; then id="$arg"; expect_id=0; else echo "Unexpected argument: $arg" >&2; exit 2; fi ;;
  esac
done
[[ -n "$id" && "$id" =~ ^tunnel_[A-Za-z0-9_-]+$ ]] || { echo "A valid --tunnel-id tunnel_... is required" >&2; exit 2; }
[[ "${from_environment:-0}" != 1 || "$reuse" != 1 ]] || { echo "Cannot replace and reuse the key at once" >&2; exit 2; }
command -v secret-tool >/dev/null || { echo "Install secret-tool (libsecret-tools) to use the desktop keyring" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemd user services are required" >&2; exit 1; }

client="$(cd -- "$(dirname -- "$0")" && pwd)/tunnel-client"
[[ -x "$client" ]] || { echo "Missing executable Linux tunnel-client: $client" >&2; exit 1; }
cloudflared="$(dirname -- "$client")/cloudflared"
[[ -x "$cloudflared" ]] || { echo "Missing bundled cloudflared companion: $cloudflared" >&2; exit 1; }
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/tunnel-client"
app_config="${XDG_CONFIG_HOME:-$HOME/.config}/QIDIStudio-MCP"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/qidi-studio-mcp-tunnel"
mkdir -p "$config_dir" "$app_config" "$state_dir" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
chmod 700 "$config_dir"
chmod 700 "$app_config" "$state_dir"

if [[ "${from_environment:-0}" == 1 ]]; then
  key="${QIDI_MCP_RUNTIME_API_KEY:-}"
  [[ ${#key} -ge 8 ]] || { echo "QIDI_MCP_RUNTIME_API_KEY was missing or too short" >&2; exit 1; }
  printf %s "$key" | secret-tool store --label="QIDI Studio MCP tunnel API key" application QIDIStudio tunnel-id "$id" >/dev/null
  unset key QIDI_MCP_RUNTIME_API_KEY
elif [[ "$reuse" == 1 ]]; then
  secret-tool lookup application QIDIStudio tunnel-id "$id" >/dev/null || { echo "No keyring credential found for $id" >&2; exit 1; }
else
  echo "Use --from-environment or --reuse-existing-credential" >&2; exit 2
fi

export CONTROL_PLANE_API_KEY="$(secret-tool lookup application QIDIStudio tunnel-id "$id")"
[[ -n "$CONTROL_PLANE_API_KEY" ]] || { echo "Could not read the key from the desktop keyring" >&2; exit 1; }
"$client" init --force --sample sample_mcp_remote_no_auth --profile qidi-studio --tunnel-id "$id" --mcp-server-url http://127.0.0.1:8765/mcp
"$client" doctor --profile qidi-studio --explain
unset CONTROL_PLANE_API_KEY

cat > "$app_config/run-tunnel.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export XDG_CONFIG_HOME='${XDG_CONFIG_HOME:-$HOME/.config}'
export CONTROL_PLANE_API_KEY="\$(secret-tool lookup application QIDIStudio tunnel-id '$id')"
exec '$client' run --profile qidi-studio
EOF
chmod 700 "$app_config/run-tunnel.sh"

unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
cat > "$unit_dir/qidi-studio-mcp-tunnel.service" <<EOF
[Unit]
Description=QIDI Studio OpenAI MCP tunnel
After=default.target

[Service]
Type=simple
ExecStart=/bin/bash $app_config/run-tunnel.sh
Restart=always
RestartSec=5
StandardOutput=append:$state_dir/tunnel.log
StandardError=append:$state_dir/tunnel.log

[Install]
WantedBy=default.target
EOF
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/qidi-studio-mcp-tunnel"
chmod 700 "${XDG_STATE_HOME:-$HOME/.local/state}/qidi-studio-mcp-tunnel"
systemctl --user daemon-reload
systemctl --user enable --now qidi-studio-mcp-tunnel.service
echo "Configured and started QIDI Studio MCP tunnel for $id."
