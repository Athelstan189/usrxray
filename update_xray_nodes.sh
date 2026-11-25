#!/usr/bin/env bash
set -u

# All paths are relative to this script's directory.
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XRAY="$BASE/xray"
CONFIG="$BASE/config.json"
NODES="$BASE/nodes.txt"
PORTS_FILE="$BASE/ports.env"
TEST_SCRIPT="$BASE/test_ipv4_xray.py"
TEST_LOG="$BASE/test_nodes_pool.log"
RUN_LOG="$BASE/xray_run.log"
PID_FILE="$BASE/xray.pid"
PROXY_ENV="$BASE/proxy_env.sh"
# Pass/fail = can reach ChatGPT Codex backend (401/403 count as OK; timeout does not).
TEST_URL="${XRAY_PROBE_URL:-https://chatgpt.com/backend-api/codex/responses}"
TEST_POST=1

# Load ports (env overrides ports.env)
if [[ -f "$PORTS_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    # only export simple KEY=VAL lines
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" || "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        key="$(echo "$key" | sed 's/[[:space:]]//g')"
        val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')"
        case "$key" in
            XRAY_SOCKS_PORT|XRAY_HTTP_PORT)
                [[ -n "${!key:-}" ]] || export "$key=$val"
                ;;
        esac
    done < "$PORTS_FILE"
    set +a
fi
SOCKS_PORT="${XRAY_SOCKS_PORT:-32808}"
HTTP_PORT="${XRAY_HTTP_PORT:-32809}"
export XRAY_SOCKS_PORT="$SOCKS_PORT"
export XRAY_HTTP_PORT="$HTTP_PORT"

cd "$BASE" || exit 1

if [[ "${2:-}" == "--cached" ]]; then
    if [[ ! -s "$NODES" ]]; then
        echo "没有已有节点。"
        exit 1
    fi
    echo "正在尝试已有的 nodes.txt。"
else
    echo "Reading ./subscription and writing nodes.txt..."
    if ! python3 "$BASE/parse_sub.py"; then
        echo "ERROR: subscription was not applied. Xray was not restarted."
        exit 1
    fi
fi

echo "[1/6] Checking required files..."
# Fix execute bits if this is our own copy (common after cp/scp)
if [ -f "$XRAY" ] && [ ! -x "$XRAY" ]; then
    chmod +x "$XRAY" 2>/dev/null || true
fi
if [ -f "$TEST_SCRIPT" ] && [ ! -x "$TEST_SCRIPT" ]; then
    chmod +x "$TEST_SCRIPT" 2>/dev/null || true
fi
if [ ! -x "$XRAY" ]; then
    echo "ERROR: Xray binary not executable: $XRAY"
    echo "Fix with:  chmod +x \"$XRAY\""
    echo "Then rerun: bash \"$BASE/update_xray_nodes.sh\""
    exit 1
fi
if [ ! -f "$NODES" ]; then
    echo "ERROR: Missing nodes file: $NODES"
    echo "有订阅就写入 subscription（一行地址）；没有就把节点贴进 nodes.txt。"
    exit 1
fi
if [ ! -s "$NODES" ] || ! grep -qE '^(vless|ss|vmess|trojan)://' "$NODES"; then
    echo "ERROR: $NODES has no usable node URLs (vless:// / ss:// ...)."
    echo "有订阅就写入 subscription（一行地址），再运行一次。"
    exit 1
fi
if [ ! -f "$TEST_SCRIPT" ]; then
    echo "ERROR: Missing test script: $TEST_SCRIPT"
    exit 1
fi
# config.json is optional on first run; Python will create it.

echo "[2/6] Testing nodes and updating config.json if working IPv4 nodes are found..."
echo "      ports: SOCKS=$SOCKS_PORT  HTTP=$HTTP_PORT"
python3 "$TEST_SCRIPT" | tee "$TEST_LOG"
test_rc=${PIPESTATUS[0]}
if [ "$test_rc" -ne 0 ]; then
    echo "ERROR: Node test script failed with exit code $test_rc"
    exit "$test_rc"
fi

KEPT_OLD_CONFIG=0
if grep -q '^APPLIED	' "$TEST_LOG"; then
    echo "Config updated from nodes that CAN reach ChatGPT."
elif [[ "${2:-}" == "--cached" ]]; then
    echo "已有节点未通过连通性测试。"
    exit 1
elif grep -q '^NO_WORKING_NODE' "$TEST_LOG"; then
    KEPT_OLD_CONFIG=1
    echo "WARNING: No node in nodes.txt can reach ChatGPT."
    echo "         Keeping existing config.json (if any)."
    echo "         → Put a new subscription URL in ./subscription, then rerun."
    if [ ! -f "$CONFIG" ]; then
        echo "ERROR: No working node and no existing config.json — cannot start."
        exit 1
    fi
else
    KEPT_OLD_CONFIG=1
    echo "No APPLIED marker found. Keeping existing config.json (if any)."
    if [ ! -f "$CONFIG" ]; then
        echo "ERROR: No config.json produced."
        exit 1
    fi
fi

echo "[3/6] Validating config.json..."
if ! "$XRAY" run -test -config "$CONFIG"; then
    echo "ERROR: Generated/current config.json is invalid. Xray was not restarted."
    exit 1
fi

echo "[4/6] Stopping old Xray for this directory..."
if [ -f "$PID_FILE" ]; then
    old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$old_pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi
# Only kill processes started with THIS config (do not kill other users'/other copies).
if command -v pgrep >/dev/null 2>&1; then
    while read -r pid; do
        [ -n "$pid" ] || continue
        kill "$pid" 2>/dev/null || true
    done < <(pgrep -u "$USER" -f "$XRAY run -config $CONFIG" 2>/dev/null || true)
    sleep 1
fi

echo "[5/6] Starting Xray..."
env LD_LIBRARY_PATH="" nohup "$XRAY" run -config "$CONFIG" > "$RUN_LOG" 2>&1 &
echo $! > "$PID_FILE"
sleep 1.5

_port_open() {
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1$"
}
if ! _port_open "$SOCKS_PORT" || ! _port_open "$HTTP_PORT"; then
    echo "ERROR: Xray did not open ports $SOCKS_PORT/$HTTP_PORT. Last log:"
    tail -n 40 "$RUN_LOG"
    exit 1
fi

echo "[6/6] Verifying proxy against ChatGPT..."
CURL_BIN="/usr/bin/curl"
[ -x "$CURL_BIN" ] || CURL_BIN="curl"
_err="/tmp/xray_verify_err.$$"
_out="/tmp/xray_verify_out.$$"
set +e
if [[ "${TEST_POST:-1}" == "1" ]]; then
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u LD_LIBRARY_PATH \
        "$CURL_BIN" -sS -o /dev/null --max-time 25 \
        --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
        -X POST -H 'content-type: application/json' -d '{}' \
        -w "%{http_code} %{time_total}" \
        "$TEST_URL" >"$_out" 2>"$_err"
else
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u LD_LIBRARY_PATH \
        "$CURL_BIN" -sS -o /dev/null --max-time 25 \
        --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
        -w "%{http_code} %{time_total}" \
        "$TEST_URL" >"$_out" 2>"$_err"
fi
curl_rc=$?
set -u
http_line="$(cat "$_out" 2>/dev/null || true)"
http_code="${http_line%% *}"
http_time="${http_line#* }"
echo "ChatGPT probe: HTTP ${http_code:-000}, total ${http_time:-?}s  ($TEST_URL)"

# Reachable ChatGPT usually returns 401/403 without auth; treat any real HTTP status as OK.
if [[ "$curl_rc" -ne 0 || -z "$http_code" || "$http_code" == "000" ]] || ! [[ "$http_code" =~ ^[2-5][0-9][0-9]$ ]]; then
    echo "ERROR: Proxy verification failed (ChatGPT unreachable)."
    [[ -s "$_err" ]] && cat "$_err" >&2
    echo "Last log:"
    tail -n 40 "$RUN_LOG"
    rm -f "$_err" "$_out"
    exit "$((curl_rc == 0 ? 1 : curl_rc))"
fi
rm -f "$_err" "$_out"

echo "Done. Xray is running on:"
echo "  SOCKS: 127.0.0.1:$SOCKS_PORT"
echo "  HTTP : 127.0.0.1:$HTTP_PORT"
echo "  Probe: ChatGPT Codex backend (HTTP $http_code = reachable)"
if [[ "$KEPT_OLD_CONFIG" -eq 1 ]]; then
    if grep -q 'cgpt-bridge' "$CONFIG" 2>/dev/null; then
        echo
        echo "NOTE: ChatGPT is currently reachable via temporary cgpt-bridge (127.0.0.1:20808),"
        echo "      NOT via your own nodes.txt exits. ipinfo.io showing your VPS IP is expected."
        echo "      Own nodes still cannot open chatgpt.com — update nodes.txt when you can."
    else
        echo
        echo "NOTE: Kept old config; ChatGPT probe passed, but no fresh ChatGPT-capable node was selected."
    fi
fi
if [[ "${1:-}" != "--interactive" ]]; then
    echo
    echo "Enable proxy in THIS shell:"
    echo "  source \"$PROXY_ENV\""
    echo "Then test:"
    echo "  curl -s https://ipinfo.io"
fi
