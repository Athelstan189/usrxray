#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mode=""
if [[ -t 0 && -t 1 ]]; then
    mode="--interactive"
fi

updater="$BASE/update_xray_nodes.sh"
# A working proxy is enough. Retest nodes.txt only when that connection fails.
if ! bash "$updater" "$mode" --live && ! bash "$updater" "$mode" --cached; then
    subscription="$BASE/subscription"
    if ! grep -qsE '^[[:space:]]*[^#[:space:]]' "$subscription"; then
        if [[ -z "$mode" ]]; then
            echo "缺少订阅链接，请在交互式终端运行 ./run.sh，或预先填写 subscription。" >&2
            exit 1
        fi

        while true; do
            printf '请粘贴订阅链接并按回车（输入不会显示）：' >&2
            if ! IFS= read -rs link; then
                printf '\n未收到订阅链接。\n' >&2
                exit 1
            fi
            printf '\n' >&2
            if [[ "$link" =~ ^https?://[^/[:space:]]+[^[:space:]]*$ ]]; then
                break
            fi
            echo "请输入有效的 HTTP 或 HTTPS 订阅链接。" >&2
        done

        (
            umask 077
            pending="$(mktemp "$BASE/.subscription.XXXXXX")"
            trap '[[ ! -e "$pending" ]] || rm -- "$pending"' EXIT
            printf '%s\n' "$link" > "$pending"
            mv -T -- "$pending" "$subscription"
        )
        unset link
    fi
    echo "已有节点未能启动代理，正在更新订阅后重试。"
    bash "$updater" "$mode"
fi

[[ -n "$mode" ]] || exit 0
echo "进入代理终端，输入 exit 返回原来的终端。"
# Read the user's Bash settings before applying this instance's proxy.
exec bash --rcfile <(
    printf '%s\n' '[[ ! -r ~/.bashrc ]] || source ~/.bashrc'
    printf 'source %q || exit 1\n' "$BASE/proxy_env.sh"
    printf '%s\n' 'command curl -fsS --max-time 8 https://ipinfo.io || echo "出口 IP 查询失败，仍可使用代理。" >&2' 'printf "\n"'
) -i
