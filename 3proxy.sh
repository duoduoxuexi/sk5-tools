#!/usr/bin/env bash
# Ubuntu 20.04: official tagged source; Ubuntu >=22.04: official apt LTS.
# Only 3proxy-owned files/services are changed. No firewall or x-ui edits.
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PROXY_PASS PROXY_USER

readonly SOURCE_VERSION=0.9.9.0
readonly SOURCE_SHA256=5af253fa734f61af6d5fe3790022130a14caf25bfce24a6aefd415797d351dd3
readonly CONFIG=/etc/3proxy/3proxy.cfg
readonly UNIT=/etc/systemd/system/3proxy.service
readonly SOURCE_BIN=/usr/local/bin/3proxy
readonly REPO=/etc/apt/sources.list.d/3proxy.sources
TMPDIR_PRIVATE='' BACKUP='' ROLLBACK=0 OLD_ACTIVE=0 OLD_ENABLED=0
PROXY_IP='' PROXY_PORT='' PROXY_USER='' PROXY_PASS=''
MODE='' BINARY='' LISTEN_IP='' TEST_HOST='' OLD_PID=0

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
ask() { IFS= read -r -p "$1" "$2" </dev/tty || die '输入已取消。'; }
confirm() { local answer; ask "$1 [输入 yes 确认]: " answer; [[ "$answer" == yes ]]; }

cleanup() {
    local code=$?
    trap - EXIT ERR INT TERM
    unset PROXY_PASS
    if (( ROLLBACK )); then
        say '安装未完成，正在恢复安装前的 3proxy 配置/服务状态（不涉及 x-ui）。' >&2
        systemctl stop 3proxy.service >/dev/null 2>&1 || true
        local entry path
        for entry in cfg unit binary; do
            case "$entry" in
                cfg) path=$CONFIG ;; unit) path=$UNIT ;; binary) path=$SOURCE_BIN ;;
            esac
            if [[ -f "$BACKUP/$entry" ]]; then
                cp -a -- "$BACKUP/$entry" "$path" || true
            elif [[ -f "$BACKUP/$entry.absent" ]]; then
                rm -f -- "$path" || true
            fi
        done
        systemctl daemon-reload >/dev/null 2>&1 || true
        if (( OLD_ENABLED )); then
            systemctl enable 3proxy.service >/dev/null 2>&1 || true
        else
            systemctl disable 3proxy.service >/dev/null 2>&1 || true
        fi
        if (( OLD_ACTIVE )); then
            systemctl start 3proxy.service >/dev/null 2>&1 || true
        fi
        say "备份保留在：$BACKUP；失败的依赖安装不做全局修复/卸载。" >&2
    fi
    if [[ -n "$TMPDIR_PRIVATE" && "$TMPDIR_PRIVATE" == /tmp/3proxy-installer.* ]]; then
        rm -rf -- "$TMPDIR_PRIVATE"
    fi
    exit "$code"
}

valid_ipv4() {
    local ip=$1 octet; local -a parts
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$ip"
    for octet in "${parts[@]}"; do
        [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
    # Reject unspecified, loopback, multicast and reserved destination ranges.
    (( 10#${parts[0]} > 0 && 10#${parts[0]} < 224 && 10#${parts[0]} != 127 ))
}
valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}
valid_user() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]]; }
valid_password() {
    # Deliberately exclude config metacharacters: $, quotes, backslash, colon,
    # whitespace, # and control bytes. SOCKS5 auth fields are at most 255 bytes.
    [[ ${#1} -ge 1 && ${#1} -le 255 && "$1" =~ ^[A-Za-z0-9_@%+=.!~-]+$ ]]
}
detect_os() {
    [[ -r /etc/os-release ]] || die '找不到 /etc/os-release。'
    local ID='' VERSION_ID=''
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "$ID" == ubuntu ]] || die '此脚本只支持 Ubuntu。'
    if [[ "$VERSION_ID" == 20.04 ]]; then
        MODE=source
    elif [[ "$VERSION_ID" =~ ^[0-9]+\.[0-9]+$ ]] &&
         dpkg --compare-versions "$VERSION_ID" ge 22.04; then
        MODE=apt
    else
        die "Ubuntu $VERSION_ID 不在支持范围（20.04 或 22.04+）。"
    fi
    say "检测到 Ubuntu $VERSION_ID；安装方式：$MODE。"
}

port_check() {
    local permitted_pid=${1:-0} rows line conflict=0
    # Check IPv4 AND IPv6, TCP listeners AND bound UDP sockets. Never kill owners.
    rows=$(ss -H -lntup "sport = :$PROXY_PORT") || die '无法检查端口占用。'
    [[ -n "$rows" ]] || return 0
    while IFS= read -r line; do
        if [[ "$permitted_pid" != 0 && "$line" == *"pid=$permitted_pid,"* ]]; then
            # If a different process also owns the socket, do not ignore it.
            local owners
            owners=$(grep -oE 'pid=[0-9]+' <<< "$line" | sort -u)
            [[ "$owners" == "pid=$permitted_pid" ]] && continue
        fi
        printf '%s\n' "$line" >&2
        conflict=1
    done <<< "$rows"
    (( conflict == 0 )) || die "端口 $PROXY_PORT 被其他进程占用；请选择其他端口。不会停止 Xray/x-ui。"
}

apt_install_safe() {
    local package version status plan
    local -a frozen=()
    # Freeze every already-installed libc6 / OpenSSL runtime (including multiarch).
    # New libc6/libssl runtime installations are also rejected in the dry run.
    while IFS=$'\t' read -r package version status; do
        if [[ "$status" == installed && "$package" =~ ^(libc6(:|$|-)|libssl[0-9]) ]]; then
            frozen+=("$package=$version")
        fi
    done < <(dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' 'libc6*' 'libssl*' 2>/dev/null || true)
    plan="$TMPDIR_PRIVATE/apt-plan"
    if ! apt-get -s --no-remove install "$@" "${frozen[@]}" >"$plan" 2>&1; then
        die '依赖预检查失败。未升级 libc6/libssl；请检查 apt 软件源/依赖（不运行全局修复）。'
    fi
    if grep -Eq '^Inst (libc6(:|[[:space:]]|-)|libssl[0-9])' "$plan"; then
        die 'apt 计划更改 libc6/libssl 运行库，已中止。需要与现有运行库匹配的构建依赖，不能强行升级。'
    fi
    # List-only needrestart: do not automatically restart unrelated services.
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
        apt-get --no-remove install -y "$@" "${frozen[@]}"
}

prepare_repository() {
    local file
    # Only retire the old installer's dedicated repo files, not mixed/global lists.
    for file in "$REPO" /etc/apt/sources.list.d/3proxy.list; do
        [[ -e "$file" ]] || continue
        [[ -f "$file" && ! -L "$file" ]] || die "软件源不是普通文件：$file"
        grep -qE 'https?://3proxy\.org/repo/deb/?([[:space:]]|$)' "$file" ||
            die "发现非预期的软件源文件：$file；未修改。"
        if [[ "$file" == *.list ]]; then
            if grep -Ev '^[[:space:]]*(#.*)?$|^[[:space:]]*deb(-src)?[[:space:]].*https?://3proxy\.org/repo/deb/?([[:space:]]|$)' "$file" | grep -q .; then
                die "软件源混有其他仓库：$file；未修改。"
            fi
        else
            [[ $(grep -c '^Types:' "$file") == 1 && $(grep -c '^URIs:' "$file") == 1 ]] ||
                die "软件源包含多个段落：$file；未修改。"
            grep -Eq '^URIs:[[:space:]]+https://3proxy\.org/repo/deb/?[[:space:]]*$' "$file" ||
                die "软件源混有其他地址：$file；未修改。"
        fi
        cp -a -- "$file" "$BACKUP/$(basename "$file")"
        mv -- "$file" "$file.disabled.$(basename "$BACKUP")"
    done
    # Detect duplicates instead of rewriting arbitrary administrator-owned files.
    if grep -El 'https?://3proxy\.org/repo/deb' /etc/apt/sources.list \
          /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null |
          grep -q .; then
        die '其他 apt 文件中仍有 3proxy 仓库；请去掉重复条目后重试。其他软件源未被改动。'
    fi
    if [[ "$MODE" == apt ]]; then
        local arch
        arch=$(dpkg --print-architecture)
        case "$arch" in amd64|arm64|armhf) ;; *) die "官方 LTS apt 不支持架构 $arch。" ;; esac
        install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
        curl -q -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 \
            https://3proxy.org/repo/3proxy-release-key.asc -o "$TMPDIR_PRIVATE/3proxy.asc"
        local fingerprint
        fingerprint=$(gpg --batch --homedir "$TMPDIR_PRIVATE" --show-keys --with-colons \
            "$TMPDIR_PRIVATE/3proxy.asc" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
        [[ "$fingerprint" == FC12214499FCC7BA1CFF6CDC0312384E3A73940B ]] ||
            die '官方仓库签名密钥指纹不匹配。'
        install -m 0644 "$TMPDIR_PRIVATE/3proxy.asc" /usr/share/keyrings/3proxy.asc
        cat >"$TMPDIR_PRIVATE/repo" <<EOF
Types: deb
URIs: https://3proxy.org/repo/deb
Suites: lts
Components: main
Architectures: $arch
Signed-By: /usr/share/keyrings/3proxy.asc
EOF
        install -m 0644 "$TMPDIR_PRIVATE/repo" "$REPO"
    fi
}

snapshot() {
    local path entry
    install -d -m 0700 /var/backups/3proxy-installer
    BACKUP=$(mktemp -d /var/backups/3proxy-installer/run.XXXXXXXX)
    for entry in cfg unit binary; do
        case "$entry" in cfg) path=$CONFIG ;; unit) path=$UNIT ;; binary) path=$SOURCE_BIN ;; esac
        [[ ! -L "$path" ]] || die "为避免误覆盖，不处理符号链接：$path"
        if [[ -e "$path" ]]; then
            [[ -f "$path" ]] || die "不是普通文件：$path"
            cp -a -- "$path" "$BACKUP/$entry"
        else
            : >"$BACKUP/$entry.absent"
        fi
    done
}

install_software() {
    say '[1/4] 准备专用软件源及依赖（不升级 libc6/libssl）...'
    # curl/iproute2 must already exist for input discovery and conflict checks.
    if [[ "$MODE" == apt ]] && ! command -v gpg >/dev/null; then
        # Disable obsolete repo first; bootstrap gpg from the OS repositories only.
        local saved_mode=$MODE
        MODE=source; prepare_repository; MODE=$saved_mode
        apt-get update
        apt_install_safe ca-certificates curl iproute2 gnupg
    fi
    prepare_repository
    apt-get update
    if [[ "$MODE" == source ]]; then
        apt_install_safe build-essential ca-certificates curl iproute2
        say "[2/4] 编译官方固定版本 $SOURCE_VERSION（不启用 TLS/PAM/PCRE 插件）..."
        curl -q -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 180 --retry 2 \
            "https://codeload.github.com/3proxy/3proxy/tar.gz/refs/tags/$SOURCE_VERSION" \
            -o "$TMPDIR_PRIVATE/source.tar.gz"
        printf '%s  %s\n' "$SOURCE_SHA256" "$TMPDIR_PRIVATE/source.tar.gz" | sha256sum -c - >/dev/null ||
            die '固定源码 SHA256 不匹配，已停止。'
        tar -xzf "$TMPDIR_PRIVATE/source.tar.gz" -C "$TMPDIR_PRIVATE" --no-same-owner
        local src="$TMPDIR_PRIVATE/3proxy-$SOURCE_VERSION" jobs
        jobs=$(getconf _NPROCESSORS_ONLN || printf 1)
        (( jobs > 2 )) && jobs=2
        # Do NOT make install: upstream install hooks create chroots/configs and
        # auto-start a service. Install just the verified binary ourselves.
        if ! make -C "$src" -f Makefile.Linux -j"$jobs" \
            OPENSSL_CHECK=false WOLFSSL_CHECK=false PCRE_CHECK=false PAM_CHECK=false \
            PLUGINS= >"$TMPDIR_PRIVATE/build.log" 2>&1; then
            install -m 0600 "$TMPDIR_PRIVATE/build.log" "$BACKUP/build.log"
            die "编译失败；不含凭据的构建日志：$BACKUP/build.log"
        fi
        [[ -x "$src/bin/3proxy" ]] || die '编译没有生成 bin/3proxy。'
        BINARY=$SOURCE_BIN
        # Actual replacement is postponed until after service stop.
    else
        say '[2/4] 安装官方 LTS 软件包...'
        # Ensure apt selects the official LTS, not an unrelated package source.
        cat >"$TMPDIR_PRIVATE/3proxy.pref" <<'EOF'
Package: 3proxy
Pin: origin "3proxy.org"
Pin-Priority: 1001
EOF
        # Scope the preference to these apt calls; no global apt pin modifications.
        apt_install_safe -o "Dir::Etc::preferences=$TMPDIR_PRIVATE/3proxy.pref" 3proxy
        local candidate
        candidate=$(dpkg-query -L 3proxy | grep -E '^/(usr/)?(s?bin)/3proxy$' | head -n 1)
        [[ -n "$candidate" && -x "$candidate" ]] || die '找不到软件包中的 3proxy 可执行文件。'
        BINARY=$candidate
    fi
}

deploy() {
    say '[3/4] 写入配置并启用专用 3proxy systemd 服务...'
    systemctl stop 3proxy.service >/dev/null 2>&1 || true
    port_check 0
    if [[ "$MODE" == source ]]; then
        install -m 0755 "$TMPDIR_PRIVATE/3proxy-$SOURCE_VERSION/bin/3proxy" "$TMPDIR_PRIVATE/3proxy.new"
        install -d -m 0755 /usr/local/bin
        install -m 0755 "$TMPDIR_PRIVATE/3proxy.new" "$SOURCE_BIN"
    fi
    # No daemon directive: Type=simple must track the foreground main process.
    # No traffic logging or config dumping. Credentials only in root:root 0600 cfg.
    cat >"$TMPDIR_PRIVATE/config" <<EOF
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60 15 5
maxconn 1000
users $PROXY_USER:CL:$PROXY_PASS
auth strong
allow $PROXY_USER
deny *
EOF
    if [[ "$LISTEN_IP" == 0.0.0.0 ]]; then
        printf 'socks -4 -p%s -i0.0.0.0 -Ni%s -u2\n' "$PROXY_PORT" "$PROXY_IP" >>"$TMPDIR_PRIVATE/config"
    else
        printf 'socks -4 -p%s -i%s -e%s -u2\n' "$PROXY_PORT" "$LISTEN_IP" "$LISTEN_IP" >>"$TMPDIR_PRIVATE/config"
    fi
    install -d -m 0700 /etc/3proxy
    install -o root -g root -m 0600 "$TMPDIR_PRIVATE/config" "$CONFIG"
    cat >"$TMPDIR_PRIVATE/unit" <<EOF
# Managed by 3proxy.sh (Ubuntu compatible installer)
[Unit]
Description=3proxy authenticated SOCKS5
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Group=root
ExecStart=$BINARY $CONFIG
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=on-failure
RestartSec=3s
KillMode=control-group
LimitNOFILE=65536
TasksMax=4096
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
EOF
    install -o root -g root -m 0644 "$TMPDIR_PRIVATE/unit" "$UNIT"
    systemd-analyze verify "$UNIT" >"$TMPDIR_PRIVATE/unit-check" 2>&1 || die 'systemd 单元验证失败。'
    systemctl daemon-reload
    systemctl reset-failed 3proxy.service >/dev/null 2>&1 || true
    systemctl enable 3proxy.service >/dev/null 2>&1
    systemctl restart 3proxy.service
    local pid rows ready=0
    local attempt=0
    while (( attempt++ < 15 )); do
        sleep 1
        if systemctl is-active --quiet 3proxy.service; then
            pid=$(systemctl show -p MainPID --value 3proxy.service)
            rows=$(ss -H -lntp "sport = :$PROXY_PORT")
            if [[ "$pid" =~ ^[1-9][0-9]*$ && "$rows" == *"pid=$pid,"* ]]; then
                ready=1; break
            fi
        fi
    done
    (( ready )) || die '3proxy 未成功监听；已触发恢复，不输出可能包含凭据的配置/日志。'
    sleep 2
    systemctl is-active --quiet 3proxy.service || die '3proxy 启动后退出。'
}

self_test() {
    say '[4/4] 本机 SOCKS5 认证及 TCP 出口测试...'
    local test_ip
    # Password is never in argv, the URL, stdout, journal or shell history.
    # -q avoids ~/.curlrc; explicit noproxy prevents proxy bypass via environment.
    cat >"$TMPDIR_PRIVATE/curl.conf" <<EOF
proxy = "socks5h://$TEST_HOST:$PROXY_PORT"
proxy-user = "$PROXY_USER:$PROXY_PASS"
noproxy = ""
url = "https://api.ipify.org"
connect-timeout = 10
max-time = 30
silent
fail
ipv4
EOF
    if test_ip=$(curl -q --config "$TMPDIR_PRIVATE/curl.conf" 2>/dev/null) && valid_ipv4 "$test_ip"; then
        say "本机 TCP SOCKS5 测试成功；实际出口 IP：$test_ip"
        [[ "$test_ip" == "$PROXY_IP" ]] || say '注意：实际出口与填写 IP 不同，请核对公网映射/出口路由。'
    else
        say '服务已监听，但外部 TCP 测试未通过；可能是 DNS/外网问题，需要进一步验证。'
    fi
    unset PROXY_PASS
    ROLLBACK=0
    say ''
    say "服务已启用：$PROXY_IP:$PROXY_PORT；账号：$PROXY_USER；密码为你刚才输入的值（不回显）。"
    say "配置：$CONFIG（root:root 0600）；备份：$BACKUP"
    say '状态：systemctl is-active 3proxy；监听：ss -lntp | grep 3proxy'
    say '未改动 x-ui/Xray、系统防火墙或云安全组。外部客户端请单独检查该 TCP 端口是否放行。'
    say 'SOCKS5 UDP 使用动态中继端口；本次 TCP 测试不等于 UDP 已通过。'
    [[ "$LISTEN_IP" != 0.0.0.0 ]] || say '当前公网 IP 不在本机网卡：已使用 NAT 模式。UDP 还需要一对一地址/端口映射；PAT 不能仅靠 -Ni 解决。'
}

main() {
    [[ $EUID == 0 ]] || die '请使用 root 或 sudo bash 3proxy.sh 运行。'
    [[ $# == 0 ]] || die '不接受命令行凭据或参数；请交互运行。'
    [[ -t 0 && -t 1 ]] || die '请在交互终端运行下载后的文件，不要使用 curl | bash 或日志重定向。'
    local command
    for command in curl ip ss dpkg dpkg-query apt-get systemctl systemd-analyze flock; do
        command -v "$command" >/dev/null || die "缺少 $command；请先安装对应的 Ubuntu 系统工具。"
    done
    [[ -d /run/systemd/system ]] || die '当前系统没有运行 systemd。'
    exec 9>/run/lock/3proxy-installer.lock
    flock -n 9 || die '另一个 3proxy 安装程序正在运行。'
    TMPDIR_PRIVATE=$(mktemp -d /tmp/3proxy-installer.XXXXXXXX)
    trap cleanup EXIT
    trap 'say "安装中止（步骤出错）；不显示命令、配置或凭据。" >&2' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    say '=== 3proxy SOCKS5 Ubuntu 安装/配置 ==='
    detect_os
    # Existing drop-ins could override ExecStart/User/Environment, so do not guess.
    local drops
    drops=$(systemctl show -p DropInPaths --value 3proxy.service)
    [[ -z "$drops" ]] || die '3proxy 存在额外 systemd drop-in，需先核对；未自动覆盖。'
    [[ $(systemctl is-enabled 3proxy.service 2>/dev/null || true) != masked ]] ||
        die '3proxy 服务被 masked；请先核对，脚本不会自动解除屏蔽。'
    systemctl is-active --quiet 3proxy.service && OLD_ACTIVE=1
    systemctl is-enabled --quiet 3proxy.service && OLD_ENABLED=1
    OLD_PID=$(systemctl show -p MainPID --value 3proxy.service)
    OLD_PID=${OLD_PID:-0}
    if [[ -e "$CONFIG" || -e "$UNIT" ]] || (( OLD_ACTIVE )); then
        confirm '发现已有 3proxy，将备份并替换它的配置/服务（不修改 x-ui）。继续？' || die '已取消。'
    fi
    local auto_ip=''
    auto_ip=$(curl -q -4 -fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)
    valid_ipv4 "$auto_ip" || auto_ip=''
    ask "公网 IPv4 [${auto_ip:-请手动输入}]: " PROXY_IP
    PROXY_IP=${PROXY_IP:-$auto_ip}
    valid_ipv4 "$PROXY_IP" || die 'IPv4 格式/范围无效（不接受前导零、回环或组播）。'
    ask 'SOCKS5 端口 [25000]: ' PROXY_PORT
    PROXY_PORT=${PROXY_PORT:-25000}
    valid_port "$PROXY_PORT" || die '端口应为 1–65535。'
    PROXY_PORT=$((10#$PROXY_PORT))
    port_check "$OLD_PID"
    ask '用户名 [admin，仅字母/数字/下划线/点/横线]: ' PROXY_USER
    PROXY_USER=${PROXY_USER:-admin}
    valid_user "$PROXY_USER" || die '用户名格式无效；长度 1–64，首字符须字母/数字/下划线。'
    ask '密码（可见输入；建议至少12位；允许字母数字及 _@%+=.!~-）: ' PROXY_PASS
    valid_password "$PROXY_PASS" || die '密码不能为空，最长255字节，只允许提示中的字符。'
    if (( ${#PROXY_PASS} < 12 )); then
        confirm '密码不足12位，仍要使用？' || die '已取消，请重新运行并使用较长密码。'
    fi
    if ip -4 -o addr show | awk '{sub(/\/.*/, "", $4); print $4}' | grep -Fxq "$PROXY_IP"; then
        LISTEN_IP=$PROXY_IP; TEST_HOST=$PROXY_IP
    else
        say '公网 IPv4 不在本机网卡上，将按 NAT 使用 0.0.0.0 监听、由系统选择出口。'
        confirm '确认填写的是映射到本机的公网 IP？' || die '请核对公网地址后重试。'
        LISTEN_IP=0.0.0.0; TEST_HOST=127.0.0.1
    fi
    snapshot
    ROLLBACK=1
    install_software
    deploy
    self_test
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
