#!/usr/bin/env bash
# Usage: source ./proxy_env.sh
# Sets http(s)_proxy / all_proxy for the current shell to this xray instance.

_PROXY_BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_PORTS_FILE="${_PROXY_BASE}/ports.env"

XRAY_SOCKS_PORT="${XRAY_SOCKS_PORT:-}"
XRAY_HTTP_PORT="${XRAY_HTTP_PORT:-}"
if [[ -f "$_PORTS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" != *=* ]] && continue
        key="${line%%=*}"; val="${line#*=}"
        key="${key// /}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val#\"}"; val="${val%\"}"
        val="${val#\'}"; val="${val%\'}"
        case "$key" in
            XRAY_SOCKS_PORT) [[ -z "$XRAY_SOCKS_PORT" ]] && XRAY_SOCKS_PORT="$val" ;;
            XRAY_HTTP_PORT)  [[ -z "$XRAY_HTTP_PORT"  ]] && XRAY_HTTP_PORT="$val"  ;;
        esac
    done < "$_PORTS_FILE"
fi
XRAY_SOCKS_PORT="${XRAY_SOCKS_PORT:-32808}"
XRAY_HTTP_PORT="${XRAY_HTTP_PORT:-32809}"

export http_proxy="http://127.0.0.1:${XRAY_HTTP_PORT}"
export https_proxy="$http_proxy"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export all_proxy="socks5://127.0.0.1:${XRAY_SOCKS_PORT}"
export ALL_PROXY="$all_proxy"
export no_proxy="localhost,127.0.0.1,::1,10.*,172.16.*,172.17.*,172.18.*,172.19.*,172.20.*,172.21.*,172.22.*,172.23.*,172.24.*,172.25.*,172.26.*,172.27.*,172.28.*,172.29.*,172.30.*,172.31.*,192.168.*,*.local,*.lan"
export NO_PROXY="$no_proxy"

echo "Proxy enabled -> HTTP ${XRAY_HTTP_PORT}, SOCKS ${XRAY_SOCKS_PORT}"
unset _PROXY_BASE _PORTS_FILE line key val
