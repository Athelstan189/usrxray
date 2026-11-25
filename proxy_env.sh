#!/usr/bin/env bash
# Usage: source ./proxy_env.sh
# Sets http(s)_proxy / all_proxy for the current shell to this xray instance.

_PROXY_BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! _proxy_ports="$(
    XRAY_SOCKS_PORT="${XRAY_SOCKS_PORT:-}" XRAY_HTTP_PORT="${XRAY_HTTP_PORT:-}" \
        python3 "$_PROXY_BASE/test_ipv4_xray.py" --print-ports
)"; then
    unset _PROXY_BASE _proxy_ports
    return 1
fi
read -r XRAY_SOCKS_PORT XRAY_HTTP_PORT <<< "$_proxy_ports"
unset _PROXY_BASE _proxy_ports

export http_proxy="http://127.0.0.1:${XRAY_HTTP_PORT}"
export https_proxy="$http_proxy"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export all_proxy="socks5://127.0.0.1:${XRAY_SOCKS_PORT}"
export ALL_PROXY="$all_proxy"
export no_proxy="localhost,127.0.0.1,::1,10.*,172.16.*,172.17.*,172.18.*,172.19.*,172.20.*,172.21.*,172.22.*,172.23.*,172.24.*,172.25.*,172.26.*,172.27.*,172.28.*,172.29.*,172.30.*,172.31.*,192.168.*,*.local,*.lan"
export NO_PROXY="$no_proxy"

echo "Proxy enabled -> HTTP ${XRAY_HTTP_PORT}, SOCKS ${XRAY_SOCKS_PORT}"
