#!/bin/bash
# Reinstall Any OpenVZ/LXC VPS with Small Disk (<1GiB) to Alpine/Debian/Ubuntu/CentOS/Rocky/AlmaLinux
# Original Author: Lloyd@nodeseek.com
# Updated Fork: https://github.com/Wangbaofushuai/OsMutation
# WARNING: A fresh system will be installed and all old data will be wiped.
# License: GPLv3; Partly based on https://gist.github.com/trimsj/c1fefd650b5f49ceb8f3efc1b6a1404d

set -o pipefail

REPO="${OSMUTATION_REPO:-Wangbaofushuai/OsMutation}"
LEGACY_OPENVZ_REPO="${OSMUTATION_LEGACY_REPO:-LloydAsp/OsMutation}"
LEGACY_OPENVZ_TAG="v0.0.1"

# Global state
cttype=""
os_selected=""
download_link=""
expected_size=""
NEW_ROOT_PASS=""

# CLI options
CLI_OS=""
CLI_SSH_PORT=""
CLI_YES=0
CLI_FORCE=0
CLI_LIST=0
CLI_REBOOT=""
ORIG_ARGS=("$@")

# Populated via /tmp/osmutation_env in post_install
NET_DEV=""
NET_IP4=""
NET_GW4=""
NET_IP6=""
NET_GW6=""
SSH_PORT=""

function print_usage(){
    cat <<- EOF
Usage: $0 [OPTIONS]

OsMutationTight - Small Disk (<1GiB) OpenVZ/LXC Reinstall Script

Options:
  --list                List available OS images for current architecture and exit
  --os <name>           Select OS non-interactively (exact or partial match, e.g. alpine-3.24)
  -p, --password <pwd>  Set a new root password for the reinstalled system
  --ssh-port <port>     Override SSH port for the reinstalled system
  -y, --yes             Skip final reinstall confirmation prompt
  --force               Bypass OpenVZ old-kernel cgroup v2 warning prompt
  --reboot              Automatically reboot after reinstallation succeeds
  --no-reboot           Do not reboot after reinstallation
  -h, --help            Show this help message and exit
EOF
}

function parse_args(){
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --list)
                CLI_LIST=1
                shift
                ;;
            --os)
                [ "$#" -lt 2 ] && { echo "Error: --os requires an argument."; exit 1; }
                CLI_OS="$2"
                shift 2
                ;;
            -p|--password)
                [ "$#" -lt 2 ] && { echo "Error: $1 requires an argument."; exit 1; }
                NEW_ROOT_PASS="$2"
                shift 2
                ;;
            --ssh-port)
                [ "$#" -lt 2 ] && { echo "Error: --ssh-port requires an argument."; exit 1; }
                local port_arg="$2"
                if ! [[ "$port_arg" =~ ^[0-9]+$ ]] || (( port_arg < 1 || port_arg > 65535 )); then
                    echo "Error: Invalid SSH port '${port_arg}'."
                    exit 1
                fi
                CLI_SSH_PORT="$port_arg"
                shift 2
                ;;
            -y|--yes)
                CLI_YES=1
                shift
                ;;
            --force)
                CLI_FORCE=1
                shift
                ;;
            --reboot)
                CLI_REBOOT="yes"
                shift
                ;;
            --no-reboot)
                CLI_REBOOT="no"
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                echo "Error: Unknown option '$1'"
                print_usage
                exit 1
                ;;
        esac
    done
}

function print_help(){
    echo -ne "\e[1;32m"
    cat <<- EOF

		 ██████╗ ███████╗███╗   ███╗██╗   ██╗████████╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗
		██╔═══██╗██╔════╝████╗ ████║██║   ██║╚══██╔══╝██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║
		██║   ██║███████╗██╔████╔██║██║   ██║   ██║   ███████║   ██║   ██║██║   ██║██╔██╗ ██║
		██║   ██║╚════██║██║╚██╔╝██║██║   ██║   ██║   ██╔══██║   ██║   ██║██║   ██║██║╚██╗██║
		╚██████╔╝███████║██║ ╚═╝ ██║╚██████╔╝   ██║   ██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║
		 ╚═════╝ ╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

		OsMutationTight - For Small Disk (<1GiB) OpenVZ/LXC VPS
		[warning] A fresh system will be installed and all old data will be wiped!
		Repo: https://github.com/${REPO}
	EOF
    echo -ne "\e[m"
}

function check_root(){
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "\e[1;31mError: Please run this script as root.\e[m"
        exit 1
    fi
}

function detect_arch(){
    case "$(uname -m)" in
        aarch64|arm64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "amd64" ;;
    esac
}

function detect_alpine_arch(){
    case "$(uname -m)" in
        aarch64|arm64) echo "aarch64" ;;
        *)             echo "x86_64" ;;
    esac
}

function detect_cgroup_version(){
    if [ -f /sys/fs/cgroup/cgroup.controllers ] || grep -q ' /sys/fs/cgroup cgroup2 ' /proc/mounts 2>/dev/null; then
        echo "v2"
    else
        echo "v1"
    fi
}

function detect_x86_64_level(){
    if [[ "$(detect_arch)" != "amd64" ]] || [ ! -r /proc/cpuinfo ]; then
        echo "n/a"
        return 0
    fi
    local flags
    flags=$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
    local has_v2=1 has_v3=1 f
    for f in cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; do
        if ! printf ' %s ' "$flags" | grep -q " ${f} "; then
            has_v2=0
            break
        fi
    done
    if (( has_v2 == 0 )); then
        echo "x86-64-v1"
        return 0
    fi
    for f in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do
        if ! printf ' %s ' "$flags" | grep -q " ${f} "; then
            has_v3=0
            break
        fi
    done
    if (( has_v3 == 1 )); then
        echo "x86-64-v3"
    else
        echo "x86-64-v2"
    fi
}

function detect_ram_mb(){
    awk '/^MemTotal:/{printf "%d", int($2 / 1024); exit}' /proc/meminfo 2>/dev/null || echo "0"
}

function has_ipv4_default_route(){
    if command -v ip >/dev/null 2>&1; then
        ip -4 route show default 2>/dev/null | grep -q default
        return $?
    fi
    awk '$2 == "00000000" { found=1 } END { exit !found }' /proc/net/route 2>/dev/null
}

function has_ipv6_default_route(){
    if command -v ip >/dev/null 2>&1; then
        ip -6 route show default 2>/dev/null | grep -q default
        return $?
    fi
    [ -f /proc/net/ipv6_route ] && awk '$1 == "00000000000000000000000000000000" && $2 == "00" { found=1 } END { exit !found }' /proc/net/ipv6_route 2>/dev/null
}

function ensure_network_dns(){
    local ok=0
    if command -v curl >/dev/null 2>&1; then
        curl -fsSLI --max-time 6 "https://raw.githubusercontent.com" >/dev/null 2>&1 && ok=1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --spider --timeout=6 "https://raw.githubusercontent.com" >/dev/null 2>&1 && ok=1
    else
        (exec 3<>/dev/tcp/raw.githubusercontent.com/443) >/dev/null 2>&1 && ok=1
    fi

    if (( ok == 0 )); then
        if ! has_ipv4_default_route && has_ipv6_default_route; then
            echo -e "\e[1;33mIPv6-only environment detected without NAT64 DNS, adding 2a00:1098:2c::1 ...\e[m"
            echo "nameserver 2a00:1098:2c::1" > /etc/resolv.conf
        fi
    fi
}

function read_virt_tech(){
    cttype=$(virt-what 2>/dev/null | sed -n 1p)
    if [[ -z "$cttype" ]]; then
        if grep -qa "container=lxc" /proc/1/environ 2>/dev/null; then
            cttype="lxc"
        elif [ -f /proc/user_beancounters ]; then
            cttype="openvz"
        fi
    fi

    if [[ "$cttype" == "lxc" || "$cttype" == "openvz" ]]; then
        echo -e "\e[1;33mYour container type: ${cttype} (arch: $(detect_arch), kernel: $(uname -r), cgroup: $(detect_cgroup_version), cpu: $(detect_x86_64_level), ram: $(detect_ram_mb) MiB)\e[m"
    else
        while [[ "$cttype" != 'lxc' && "$cttype" != 'openvz' ]]; do
            echo -ne "\e[1;33mplease input container type (lxc/openvz): \e[m"
            read -r cttype < /dev/tty
        done
    fi
}

function install(){
    if [ -n "$(command -v apt-get)" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Languages=none update
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Languages=none install -y "$@"
    elif [ -n "$(command -v dnf)" ]; then
        dnf makecache -q || true
        dnf install -y "$@"
    elif [ -n "$(command -v yum)" ]; then
        yum install -y "$@"
    elif [ -n "$(command -v apk)" ]; then
        apk add --no-cache "$@"
    else
        echo "Error: Not Supported OS"
        exit 1
    fi
}

function is_old_openvz_kernel(){
    local kver k_major k_minor
    kver=$(uname -r)
    k_major=$(echo "$kver" | awk -F. '{print $1}')
    k_minor=$(echo "$kver" | awk -F. '{print $2}')
    if [[ "$k_major" =~ ^[0-9]+$ && "$k_minor" =~ ^[0-9]+$ ]]; then
        if (( k_major < 4 || (k_major == 4 && k_minor < 15) )); then
            return 0
        fi
    fi
    return 1
}

function check_openvz_kernel_compat(){
    local target="$1"
    local cg_ver cpu_lvl ram_mb ver=""
    cg_ver=$(detect_cgroup_version)
    cpu_lvl=$(detect_x86_64_level)
    ram_mb=$(detect_ram_mb)

    # 1. Hard cgroup v1 incompatibility: systemd >= 258 removed cgroup v1 completely
    local cgroup_fatal=0
    if [[ "$cg_ver" == "v1" ]]; then
        if [[ "$target" =~ ^ubuntu-([0-9]+)\. ]]; then
            ver="${BASH_REMATCH[1]}"
            (( ver >= 26 )) && cgroup_fatal=1
        elif echo "$target" | grep -qiE 'ubuntu-resolute'; then
            cgroup_fatal=1
        elif [[ "$target" =~ ^debian-([0-9]+)- ]]; then
            ver="${BASH_REMATCH[1]}"
            (( ver >= 14 )) && cgroup_fatal=1
        elif echo "$target" | grep -qiE 'debian-(forky|duke|sid)'; then
            cgroup_fatal=1
        elif [[ "$target" =~ ^(centos|rockylinux|almalinux)-([0-9]+) ]]; then
            ver="${BASH_REMATCH[2]}"
            (( ver >= 11 )) && cgroup_fatal=1
        fi
    fi

    if (( cgroup_fatal == 1 )); then
        echo -e "\e[1;31m========================================================================\e[m"
        echo -e "\e[1;31m[BLOCKED] cgroup v1 Incompatibility — Container WILL NOT BOOT!\e[m"
        echo -e "\e[1;33mDetected host environment: ${cttype}, kernel $(uname -r), cgroup v1 (legacy).\e[m"
        echo -e "\e[1;33mSelected OS '${target}' ships systemd >= 258, which REMOVED cgroup v1 support.\e[m"
        echo -e "\e[1;33mPID 1 will immediately exit on boot and leave your VPS permanently Offline!\e[m"
        echo -e "\e[1;32mCompatible choices for cgroup v1: Alpine 3.x, Debian 12/13, Ubuntu 22.04/24.04.\e[m"
        echo -e "\e[1;31m========================================================================\e[m"
        if (( CLI_FORCE == 1 )); then
            echo -e "\e[1;33m--force specified, proceeding despite cgroup v1 hard incompatibility.\e[m"
        elif (( CLI_YES == 1 )); then
            echo -e "\e[1;31mAborting in non-interactive mode (--yes). Pass --force to override this safety block.\e[m"
            return 1
        else
            local confirm=""
            echo -ne "\e[1;33mForce continue anyway? (type 'FORCE' to override, or Enter to pick another OS): \e[m"
            read -r confirm < /dev/tty
            if [[ "$confirm" != "FORCE" ]]; then
                return 1
            fi
        fi
    fi

    # 2. CPU x86-64 ISA level check (EL 10 requires x86-64-v3 / AVX2; EL 9 requires x86-64-v2)
    local isa_fatal=0 isa_req=""
    if [[ "$cpu_lvl" == "x86-64-v1" || "$cpu_lvl" == "x86-64-v2" ]]; then
        if [[ "$target" =~ ^(centos|rockylinux|almalinux)-([0-9]+) ]]; then
            ver="${BASH_REMATCH[2]}"
            if (( ver >= 10 )) && [[ "$cpu_lvl" != "x86-64-v3" ]]; then
                isa_fatal=1
                isa_req="x86-64-v3 (AVX2/BMI2/FMA)"
            elif (( ver == 9 )) && [[ "$cpu_lvl" == "x86-64-v1" ]]; then
                isa_fatal=1
                isa_req="x86-64-v2 (SSE4.2/POPCNT)"
            fi
        fi
    fi

    if (( isa_fatal == 1 )); then
        echo -e "\e[1;31m========================================================================\e[m"
        echo -e "\e[1;31m[BLOCKED] CPU Architecture ISA Too Old — Binaries Will Crash (SIGILL)!\e[m"
        echo -e "\e[1;33mDetected CPU level: ${cpu_lvl}. Selected OS '${target}' requires ${isa_req}.\e[m"
        echo -e "\e[1;32mRecommended for this CPU: Alpine 3.x, Debian 12/13, Ubuntu 22.04/24.04.\e[m"
        echo -e "\e[1;31m========================================================================\e[m"
        if (( CLI_FORCE == 1 )); then
            echo -e "\e[1;33m--force specified, proceeding despite CPU ISA mismatch.\e[m"
        elif (( CLI_YES == 1 )); then
            echo -e "\e[1;31mAborting in non-interactive mode (--yes). Pass --force to override this safety block.\e[m"
            return 1
        else
            local confirm=""
            echo -ne "\e[1;33mForce continue anyway? (type 'FORCE' to override, or Enter to pick another OS): \e[m"
            read -r confirm < /dev/tty
            if [[ "$confirm" != "FORCE" ]]; then
                return 1
            fi
        fi
    fi

    # 3. Old OpenVZ 7 kernel (< 4.15, e.g. 3.10.x) check
    if [[ "$cttype" == "openvz" ]] && is_old_openvz_kernel; then
        local risky=0
        if [[ "$target" =~ ^debian-([0-9]+)- ]]; then
            ver="${BASH_REMATCH[1]}"
            (( ver >= 13 )) && risky=1
        elif echo "$target" | grep -qiE 'debian-(trixie|forky|duke|sid)'; then
            risky=1
        elif [[ "$target" =~ ^ubuntu-([0-9]+)\. ]]; then
            ver="${BASH_REMATCH[1]}"
            (( ver >= 24 )) && risky=1
        elif echo "$target" | grep -qiE 'ubuntu-(noble|resolute)'; then
            risky=1
        elif [[ "$target" =~ ^(centos|rockylinux|almalinux)-([0-9]+) ]]; then
            ver="${BASH_REMATCH[2]}"
            (( ver >= 10 )) && risky=1
        fi

        if (( risky == 1 )); then
            echo -e "\e[1;31m========================================================================\e[m"
            echo -e "\e[1;31m[WARNING] OpenVZ 7 Old Kernel Compatibility Risk!\e[m"
            echo -e "\e[1;33mDetected old OpenVZ kernel: $(uname -r) (< 4.15).\e[m"
            echo -e "\e[1;33mSelected OS '${target}' ships newer systemd/glibc that may fail on 3.10.x kernels.\e[m"
            echo -e "\e[1;32mRecommended for OpenVZ 7: Alpine 3.x, Debian 12 (bookworm), Ubuntu 22.04, or [0] Legacy v0.0.1.\e[m"
            echo -e "\e[1;31m========================================================================\e[m"
            if (( CLI_FORCE == 1 )); then
                echo -e "\e[1;33m--force specified, proceeding despite OpenVZ 7 old-kernel risk.\e[m"
            elif (( CLI_YES == 1 )); then
                echo -e "\e[1;31mAborting in non-interactive mode (--yes). Pass --force to override.\e[m"
                return 1
            else
                local confirm=""
                echo -ne "\e[1;33mContinue anyway? (y/N): \e[m"
                read -r confirm < /dev/tty
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    return 1
                fi
            fi
        fi
    fi

    # 4. Low-RAM advisory (<= 192 MiB) for heavier distros
    if [[ "$ram_mb" =~ ^[0-9]+$ ]] && (( ram_mb > 0 && ram_mb <= 192 )); then
        if [[ "$target" == ubuntu-* || "$target" == centos-* || "$target" == rockylinux-* || "$target" == almalinux-* ]]; then
            echo -e "\e[1;33m[NOTICE] Low RAM detected (${ram_mb} MiB). '${target}' runs heavier background services and may OOM.\e[m"
            echo -e "\e[1;32mFor <=192 MiB VPS, Alpine 3.x or Debian 12/13 is strongly recommended.\e[m"
            if (( CLI_YES == 0 && CLI_FORCE == 0 )); then
                local confirm=""
                echo -ne "\e[1;33mContinue with '${target}' on ${ram_mb} MiB RAM? (y/N): \e[m"
                read -r confirm < /dev/tty
                if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    return 1
                fi
            fi
        fi
    fi

    return 0
}

function check_password_compat(){
    if [[ -n "$NEW_ROOT_PASS" ]]; then
        return 0
    fi

    local root_hash=""
    if [ -f /etc/shadow ]; then
        root_hash=$(awk -F: '$1=="root"{print $2; exit}' /etc/shadow)
    fi

    local has_ssh_keys=0
    [ -s /root/.ssh/authorized_keys ] && has_ssh_keys=1

    local need_new_pass=0
    local reason=""
    if [[ "$os_selected" == alpine-* && "$root_hash" == \$y\$* ]]; then
        need_new_pass=1
        reason="Current system uses yescrypt (\$y\$) password hash (Debian/Ubuntu default), which Alpine Linux (musl) CANNOT verify!"
    elif [[ -z "$root_hash" || "$root_hash" == "!"* || "$root_hash" == "*"* ]]; then
        if (( has_ssh_keys == 0 )); then
            need_new_pass=1
            reason="Current root password is locked/empty and no /root/.ssh/authorized_keys was found!"
        fi
    fi

    if (( need_new_pass == 1 )); then
        echo -e "\e[1;31m========================================================================\e[m"
        echo -e "\e[1;31m[WARNING] Root Password Compatibility Notice!\e[m"
        echo -e "\e[1;33m${reason}\e[m"
        if (( has_ssh_keys == 1 )); then
            echo -e "\e[1;32mDetected /root/.ssh/authorized_keys (SSH key login will still work).\e[m"
        else
            echo -e "\e[1;31mWithout setting a compatible root password now, you WILL be locked out of SSH!\e[m"
        fi
        echo -e "\e[1;31m========================================================================\e[m"

        if (( CLI_YES == 1 )); then
            if (( has_ssh_keys == 1 )); then
                echo -e "\e[1;33mNon-interactive mode (--yes): relying on preserved /root/.ssh/authorized_keys.\e[m"
                return 0
            fi
            echo -e "\e[1;31mError: Non-interactive mode (--yes) requires --password <pwd> for this migration to avoid SSH lockout.\e[m"
            exit 1
        fi

        local p1="" p2=""
        while true; do
            if (( has_ssh_keys == 1 )); then
                echo -ne "\e[1;33mEnter new root password (or press Enter to rely on SSH keys only): \e[m"
            else
                echo -ne "\e[1;33mEnter new root password: \e[m"
            fi
            read -rs p1 < /dev/tty
            echo ""
            if [[ -z "$p1" ]]; then
                if (( has_ssh_keys == 1 )); then
                    echo -e "\e[1;32mSkipping password reset; SSH key login will be preserved.\e[m"
                    return 0
                fi
                echo -e "\e[1;31mPassword cannot be empty.\e[m"
                continue
            fi
            echo -ne "\e[1;33mConfirm new root password: \e[m"
            read -rs p2 < /dev/tty
            echo ""
            if [[ "$p1" == "$p2" ]]; then
                NEW_ROOT_PASS="$p1"
                echo -e "\e[1;32mNew root password recorded and will be applied after installation.\e[m"
                return 0
            fi
            echo -e "\e[1;31mPasswords do not match. Please try again.\e[m"
        done
    fi
}

function read_legacy_openvz_template(){
    echo -e "\e[1;33mLoading legacy OpenVZ 7 templates (${LEGACY_OPENVZ_REPO}@${LEGACY_OPENVZ_TAG})...\e[m"
    local release_json image_list os_list total_count os_index
    release_json=$(curl -fsSL "https://api.github.com/repos/${LEGACY_OPENVZ_REPO}/releases/tags/${LEGACY_OPENVZ_TAG}" 2>/dev/null || true)

    if [[ -n "$release_json" ]]; then
        image_list=$(printf '%s\n' "$release_json" | grep '"browser_download_url":' | sed -E 's/.*"([^"]+)".*/\1/' | grep -E '\.tar\.(gz|xz)$' | sort -V)
    fi

    if [[ -z "$image_list" ]]; then
        os_list=$(curl -fsSL "https://github.com/${LEGACY_OPENVZ_REPO}/releases/expanded_assets/${LEGACY_OPENVZ_TAG}" 2>/dev/null | \
            sed -nE '/\.tar\.gz/s/.*>([^<>]+)\.tar\.gz.*/\1/p' | sort -V)
        if [[ -z "$os_list" ]]; then
            echo -e "\e[1;31mError: Failed to fetch legacy OpenVZ template list.\e[m"
            return 1
        fi
        image_list=$(printf '%s\n' "$os_list" | sed "s|^|https://github.com/${LEGACY_OPENVZ_REPO}/releases/download/${LEGACY_OPENVZ_TAG}/|; s|$|.tar.gz|")
    else
        os_list=$(printf '%s\n' "$image_list" | sed -E 's|.*/||; s/\.tar\.(xz|gz)$//')
    fi

    total_count=$(printf '%s\n' "$os_list" | wc -l)
    printf '%s\n' "$os_list" | nl -w 3 -s '  '

    while true; do
        echo -ne "\e[1;33mplease select legacy OpenVZ os (1-${total_count}, or b to go back): \e[m"
        read -r os_index < /dev/tty
        if [[ "$os_index" == "b" || "$os_index" == "B" ]]; then
            return 1
        fi
        if [[ "$os_index" =~ ^[0-9]+$ ]] && (( os_index >= 1 && os_index <= total_count )); then
            break
        fi
        echo -e "\e[1;31mInvalid selection. Please enter a number between 1 and ${total_count}.\e[m"
    done

    os_selected=$(printf '%s\n' "$os_list" | sed -n "${os_index}p")
    download_link=$(printf '%s\n' "$image_list" | sed -n "${os_index}p")
    expected_size=""
    return 0
}

function fetch_template_catalog(){
    local arch="$1"
    local manifest_json release_json last_lxc_version
    CATALOG_OS=""
    CATALOG_URLS=""
    CATALOG_SIZES=""

    # 1. Prefer raw images.json manifest (no GitHub API rate limit, auto-updated weekly)
    manifest_json=$(curl -fsSL --max-time 15 "https://raw.githubusercontent.com/${REPO}/main/images.json" 2>/dev/null || true)
    if [[ -n "$manifest_json" ]]; then
        last_lxc_version=$(printf '%s\n' "$manifest_json" | sed -nE 's/.*"tag": *"([^"]+)".*/\1/p' | head -n 1)
        local arch_lines
        arch_lines=$(printf '%s\n' "$manifest_json" | grep "\"arch\": \"${arch}\"")
        if [[ -n "$arch_lines" ]]; then
            CATALOG_OS=$(printf '%s\n' "$arch_lines" | sed -nE 's/.*"name": *"([^"]+)".*/\1/p')
            CATALOG_URLS=$(printf '%s\n' "$arch_lines" | sed -nE 's/.*"url": *"([^"]+)".*/\1/p')
            CATALOG_SIZES=$(printf '%s\n' "$arch_lines" | sed -nE 's/.*"size": *([0-9]+).*/\1/p')
            echo -e "\e[1;32mImage source: Manifest (${REPO}@${last_lxc_version:-latest})\e[m"
            return 0
        fi
    fi

    # 2. Fallback to GitHub Releases API
    release_json=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)
    last_lxc_version=$(printf '%s\n' "$release_json" | grep '"tag_name":' | grep "LXC" | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)
    if [[ -n "$last_lxc_version" ]]; then
        CATALOG_URLS=$(printf '%s\n' "$release_json" | grep '"browser_download_url":' | sed -E 's/.*"([^"]+)".*/\1/' | grep -E '\.tar\.(xz|gz)$' | grep -- "-${arch}\.tar\." | sort -V)
        if [[ -n "$CATALOG_URLS" ]]; then
            CATALOG_OS=$(printf '%s\n' "$CATALOG_URLS" | sed -E 's|.*/||; s/\.tar\.(xz|gz)$//')
            echo -e "\e[1;32mImage source: GitHub Release (${REPO}@${last_lxc_version})\e[m"
            return 0
        fi
    fi

    # 3. Fallback direct to LinuxContainers (auto-tracks Alpine, Debian stable/oldstable, Ubuntu LTS, EL >= 9)
    echo -e "\e[1;33mGitHub Release unavailable, falling back to https://images.linuxcontainers.org ...\e[m"
    local server="https://images.linuxcontainers.org"
    local deb_pairs="" ub_pairs="" entries suite rel_txt c v
    for suite in oldstable stable; do
        rel_txt=$(curl -fsSL --max-time 10 "https://deb.debian.org/debian/dists/${suite}/Release" 2>/dev/null || true)
        c=$(printf '%s\n' "$rel_txt" | awk '/^Codename:/{print tolower($2); exit}')
        v=$(printf '%s\n' "$rel_txt" | awk '/^Version:/{split($2,a,"."); print a[1]; exit}')
        [[ -n "$c" && -n "$v" ]] && deb_pairs="${deb_pairs} ${c}=${v}"
    done
    [ -z "$deb_pairs" ] && deb_pairs="bookworm=12 trixie=13"

    ub_pairs=$(curl -fsSL --max-time 10 "https://changelogs.ubuntu.com/meta-release-lts" 2>/dev/null | awk '
        /^Dist:/{d=tolower($2)}
        /^Version:/{split($2,a,"."); v=a[1]"."a[2]}
        /^Supported:/{if($2=="1" && d!="" && v!="") printf "%s=%s ", d, v; d=""; v=""}
    ')
    [ -z "$ub_pairs" ] && ub_pairs="jammy=22.04 noble=24.04 resolute=26.04"

    entries=$(curl -fsSL --max-time 20 "${server}/meta/1.0/index-system" | awk -F';' -v arch="$arch" -v deb="$deb_pairs" -v ub="$ub_pairs" '
        BEGIN {
            n = split(deb, da, " ");
            for (i = 1; i <= n; i++) { split(da[i], kv, "="); if (kv[1] != "") dmap[kv[1]] = kv[2]; }
            m = split(ub, ua, " ");
            for (i = 1; i <= m; i++) { split(ua[i], kv, "="); if (kv[1] != "") umap[kv[1]] = kv[2]; }
        }
        $4 == "default" && $3 == arch {
            distro = tolower($1); rel = $2; rel_l = tolower(rel); path = $NF;
            if (distro == "alpine" && rel ~ /^[0-9]+\.[0-9]+$/) {
                print "alpine-" rel "-" arch ";" path;
            } else if (distro == "debian" && (rel_l in dmap)) {
                print "debian-" dmap[rel_l] "-" rel_l "-" arch ";" path;
            } else if (distro == "ubuntu" && (rel_l in umap)) {
                print "ubuntu-" umap[rel_l] "-" rel_l "-" arch ";" path;
            } else if (distro == "centos" && rel_l ~ /^[0-9]+-stream$/) {
                split(rel_l, ca, "-");
                if (ca[1] + 0 >= 9) print "centos-" rel_l "-" arch ";" path;
            } else if ((distro == "rockylinux" || distro == "almalinux") && rel ~ /^[0-9]+$/ && (rel + 0 >= 9)) {
                print distro "-" rel "-" arch ";" path;
            }
        }
    ' | sort -uV)

    if [[ -z "$entries" ]]; then
        echo -e "\e[1;31mError: Failed to fetch template list from both GitHub and LinuxContainers.\e[m"
        exit 1
    fi
    CATALOG_OS=$(printf '%s\n' "$entries" | cut -d';' -f1)
    CATALOG_URLS=$(printf '%s\n' "$entries" | cut -d';' -f2 | sed -E "s|^/*|${server}/|; s|/*$|/rootfs.tar.xz|")
}

function list_templates_and_exit(){
    local arch
    arch=$(detect_arch)
    fetch_template_catalog "$arch"
    echo ""
    echo "Available OS templates (arch: ${arch}):"
    local total i name sz sz_mb
    total=$(printf '%s\n' "$CATALOG_OS" | wc -l)
    for (( i=1; i<=total; i++ )); do
        name=$(printf '%s\n' "$CATALOG_OS" | sed -n "${i}p")
        sz=$(printf '%s\n' "$CATALOG_SIZES" | sed -n "${i}p")
        if [[ "$sz" =~ ^[0-9]+$ ]]; then
            sz_mb=$(( (sz + 1048575) / 1048576 ))
            printf "  %2d  %-28s (%d MiB)\n" "$i" "$name" "$sz_mb"
        else
            printf "  %2d  %s\n" "$i" "$name"
        fi
    done
    exit 0
}

function read_unified_template(){
    local arch total_count os_index
    arch=$(detect_arch)
    fetch_template_catalog "$arch"
    total_count=$(printf '%s\n' "$CATALOG_OS" | wc -l)

    if [[ -n "$CLI_OS" ]]; then
        local matched_idx=""
        matched_idx=$(printf '%s\n' "$CATALOG_OS" | awk -v target="$CLI_OS" 'tolower($0) == tolower(target) { print NR; exit }')
        if [[ -z "$matched_idx" ]]; then
            local matches match_count
            matches=$(printf '%s\n' "$CATALOG_OS" | awk -v target="$CLI_OS" 'index(tolower($0), tolower(target)) > 0 { print NR }')
            match_count=$(printf '%s\n' "$matches" | grep -c '^[0-9]' || true)
            if (( match_count == 1 )); then
                matched_idx="$matches"
            elif (( match_count > 1 )); then
                echo -e "\e[1;31mError: --os '${CLI_OS}' matched multiple templates:\e[m"
                printf '%s\n' "$CATALOG_OS" | grep -i "$CLI_OS"
                exit 1
            else
                echo -e "\e[1;31mError: --os '${CLI_OS}' not found. Run '$0 --list' to see available OS names.\e[m"
                exit 1
            fi
        fi

        os_selected=$(printf '%s\n' "$CATALOG_OS" | sed -n "${matched_idx}p")
        download_link=$(printf '%s\n' "$CATALOG_URLS" | sed -n "${matched_idx}p")
        expected_size=$(printf '%s\n' "$CATALOG_SIZES" | sed -n "${matched_idx}p")
        if ! check_openvz_kernel_compat "$os_selected"; then
            echo -e "\e[1;31mAborted due to OpenVZ kernel compatibility check.\e[m"
            exit 1
        fi
        echo -e "\e[1;32mSelected OS: ${os_selected}\e[m"
        echo -e "\e[1;32mDownload URL: ${download_link}\e[m"
        return 0
    fi

    while true; do
        echo ""
        local i name sz sz_mb
        for (( i=1; i<=total_count; i++ )); do
            name=$(printf '%s\n' "$CATALOG_OS" | sed -n "${i}p")
            sz=$(printf '%s\n' "$CATALOG_SIZES" | sed -n "${i}p")
            if [[ "$sz" =~ ^[0-9]+$ ]]; then
                sz_mb=$(( (sz + 1048575) / 1048576 ))
                printf "  %2d  %-28s (%d MiB)\n" "$i" "$name" "$sz_mb"
            else
                printf "  %2d  %s\n" "$i" "$name"
            fi
        done
        if [[ "$cttype" == "openvz" ]]; then
            echo -e "   0  \e[1;36m[Legacy] OpenVZ 7 archive templates (${LEGACY_OPENVZ_TAG})\e[m"
        fi

        if [[ "$cttype" == "openvz" ]]; then
            echo -ne "\e[1;33mplease select os (0-${total_count}): \e[m"
        else
            echo -ne "\e[1;33mplease select os (1-${total_count}): \e[m"
        fi
        read -r os_index < /dev/tty

        if [[ "$cttype" == "openvz" && "$os_index" == "0" ]]; then
            if read_legacy_openvz_template; then
                break
            else
                continue
            fi
        fi

        if [[ "$os_index" =~ ^[0-9]+$ ]] && (( os_index >= 1 && os_index <= total_count )); then
            os_selected=$(printf '%s\n' "$CATALOG_OS" | sed -n "${os_index}p")
            download_link=$(printf '%s\n' "$CATALOG_URLS" | sed -n "${os_index}p")
            expected_size=$(printf '%s\n' "$CATALOG_SIZES" | sed -n "${os_index}p")
            if check_openvz_kernel_compat "$os_selected"; then
                break
            fi
        else
            echo -e "\e[1;31mInvalid selection. Please try again.\e[m"
        fi
    done

    echo -e "\e[1;32mSelected OS: ${os_selected}\e[m"
    echo -e "\e[1;32mDownload URL: ${download_link}\e[m"
}

function confirm_reinstall(){
    if (( CLI_YES == 1 )); then
        return 0
    fi
    echo ""
    echo -e "\e[1;33m==================== Reinstall Summary ====================\e[m"
    echo -e "  Container : ${cttype} (kernel: $(uname -r))"
    echo -e "  Target OS : ${os_selected}"
    if [[ "$expected_size" =~ ^[0-9]+$ ]]; then
        echo -e "  Archive   : $(( (expected_size + 1048575) / 1048576 )) MiB"
    fi
    echo -e "  Source    : ${download_link}"
    if [[ -n "$NEW_ROOT_PASS" ]]; then
        echo -e "  Password  : Will be reset to your newly specified password"
    else
        echo -e "  Password  : Preserve current root password & /root/.ssh"
    fi
    if [[ -n "$CLI_SSH_PORT" ]]; then
        echo -e "  SSH Port  : ${CLI_SSH_PORT}"
    fi
    echo -e "\e[1;31m  WARNING   : ALL DATA ON THIS VPS WILL BE PERMANENTLY WIPED!\e[m"
    echo -e "\e[1;33m===========================================================\e[m"
    local ans=""
    echo -ne "\e[1;33mType 'yes' to confirm and begin reinstallation: \e[m"
    read -r ans < /dev/tty
    if [[ "$ans" != "yes" ]]; then
        echo "Aborted by user."
        exit 0
    fi
}

function download_rootfs(){
    local tar_args=("-xJ")
    case "$download_link" in
        *.tar.xz)       tar_args=("-xJ") ;;
        *.tar.gz|*.tgz) tar_args=("-xz") ;;
        *.tar.zst)      tar_args=("--zstd" "-x") ;;
        *)              tar_args=("-xJ") ;;
    esac

    # Pre-flight range-GET check (more compatible than HEAD on S3/CDN mirrors) before wiping /oldroot
    if ! curl -fsSL -r 0-0 --max-time 15 "$download_link" -o /dev/null 2>/dev/null; then
        echo -e "\e[1;31mError: Download URL unreachable: ${download_link}. Aborting before wiping old root!\e[m"
        exit 1
    fi

    # Clear immutable bit on common system files before wiping /oldroot
    if command -v chattr >/dev/null 2>&1; then
        chattr -i /oldroot/etc/resolv.conf /oldroot/etc/hosts /oldroot/etc/hostname 2>/dev/null || true
    fi

    cd /oldroot || exit 1
    local entry base
    for entry in /oldroot/* /oldroot/.[!.]* /oldroot/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        base="${entry#/oldroot/}"
        case "$base" in
            dev|proc|sys|run|x) continue ;;
        esac
        rm -rf "$entry" 2>/dev/null || true
    done

    # Use anchored excludes so only root-level pseudo-filesystems are skipped
    if ! curl -fSL --retry 3 --retry-delay 3 "$download_link" | \
        tar -C /oldroot "${tar_args[@]}" --numeric-owner --delay-directory-restore \
            --anchored --exclude="./dev" --exclude="./proc" --exclude="./run" --exclude="./sys" \
            --exclude="dev" --exclude="proc" --exclude="run" --exclude="sys"; then
        echo -e "\e[1;31mError: Failed to extract rootfs into /oldroot!\e[m"
        exit 1
    fi
}

function migrate_configuration(){
    local dest_os_dir="$1"

    # 1. Save root password hash and SSH directory
    if [ -f /etc/shadow ] && [ -f "/${dest_os_dir}/etc/shadow" ]; then
        sed -i '/^root:/d' "/${dest_os_dir}/etc/shadow"
        grep '^root:' /etc/shadow >> "/${dest_os_dir}/etc/shadow"
    fi
    [ -d /root/.ssh ] && mkdir -p "/${dest_os_dir}/root" && cp -a /root/.ssh "/${dest_os_dir}/root/"

    local ssh_port="$CLI_SSH_PORT"
    if [[ -z "$ssh_port" ]]; then
        if [ -f /etc/ssh/sshd_config ]; then
            ssh_port=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config)
        elif [ -f /tmp/osmutation_env ]; then
            ssh_port=$(awk -F= '/^SSH_PORT=/{gsub(/"/, "", $2); print $2; exit}' /tmp/osmutation_env)
        fi
    fi

    # 2. Save hostname
    local cur_hostname
    cur_hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "vps")
    echo "$cur_hostname" > "/${dest_os_dir}/etc/hostname"
    if [ -f "/${dest_os_dir}/etc/hosts" ] && ! grep -q "$cur_hostname" "/${dest_os_dir}/etc/hosts"; then
        echo "127.0.1.1 ${cur_hostname}" >> "/${dest_os_dir}/etc/hosts"
    fi

    # 3. Save network configuration (supports eth0, onlink /32 routes, OpenVZ venet0, IPv6-only)
    local dev ipaddr_with_mask gw4 route_raw route_part gateway_line ip6_addr gw6
    dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ -z "$dev" ] && dev=$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route 2>/dev/null)
    [ -z "$dev" ] && dev=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ -z "$dev" ] && dev="eth0"

    ipaddr_with_mask=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / && /scope global/ {print $2; exit}')
    gw4=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
    route_raw=$(ip -4 route show default 2>/dev/null | head -n 1)
    route_part=$(printf '%s\n' "$route_raw" | sed -E 's/^(.*dev [^ ]+( onlink)?).*$/\1/')
    if printf '%s\n' "$route_raw" | grep -qw "onlink" && ! printf '%s\n' "$route_part" | grep -qw "onlink"; then
        route_part="${route_part} onlink"
    fi
    [ -n "$route_part" ] && gateway_line="up ip route add ${route_part}" || gateway_line=""

    ip6_addr=$(ip -6 addr show dev "$dev" 2>/dev/null | awk '/inet6 / && /scope global/ {print $2; exit}')
    gw6=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')

    mkdir -p "/${dest_os_dir}/etc/network/"
    if [ -f /etc/network/interfaces ] && grep -vE '^[[:space:]]*(#|$)' /etc/network/interfaces | grep -qE '(static|venet0|inet6)'; then
        cp -rf /etc/network/interfaces "/${dest_os_dir}/etc/network/interfaces"
        [ -d /etc/network/interfaces.d ] && cp -a /etc/network/interfaces.d "/${dest_os_dir}/etc/network/"
    elif [[ "$dev" == venet0* ]]; then
        cat > "/${dest_os_dir}/etc/network/interfaces" <<- EOF
			auto lo
			iface lo inet loopback

			auto venet0
			iface venet0 inet manual
			    up ifconfig venet0 up 2>/dev/null || ip link set venet0 up
			    up ip route add default dev venet0 2>/dev/null || true
		EOF
        if [ -n "$ipaddr_with_mask" ]; then
            local venet_ip="${ipaddr_with_mask%%/*}"
            cat >> "/${dest_os_dir}/etc/network/interfaces" <<- EOF

			auto venet0:0
			iface venet0:0 inet static
			    address ${venet_ip}/32
			EOF
        fi
        if [ -n "$ip6_addr" ]; then
            cat >> "/${dest_os_dir}/etc/network/interfaces" <<- EOF

			iface venet0 inet6 static
			    address ${ip6_addr}
			    up ip -6 route add default dev venet0 2>/dev/null || true
			EOF
        fi
    else
        cat > "/${dest_os_dir}/etc/network/interfaces" <<- EOF
			auto lo
			iface lo inet loopback

			auto ${dev}
		EOF
        if [ -n "$ipaddr_with_mask" ]; then
            cat >> "/${dest_os_dir}/etc/network/interfaces" <<- EOF
			iface ${dev} inet static
			    address ${ipaddr_with_mask}
			    ${gateway_line}
			EOF
        elif [ -z "$ip6_addr" ]; then
            cat >> "/${dest_os_dir}/etc/network/interfaces" <<- EOF
			iface ${dev} inet dhcp
			EOF
        fi
        if [ -n "$ip6_addr" ]; then
            cat >> "/${dest_os_dir}/etc/network/interfaces" <<- EOF

			iface ${dev} inet6 static
			    address ${ip6_addr}
			EOF
            if [ -n "$gw6" ]; then
                echo "    gateway ${gw6}" >> "/${dest_os_dir}/etc/network/interfaces"
            fi
        fi
    fi

    # 4. DNS configuration
    rm -f "/${dest_os_dir}/etc/resolv.conf"
    if [ -f /etc/resolv.conf ] && grep -q '^nameserver ' /etc/resolv.conf; then
        grep '^nameserver ' /etc/resolv.conf > "/${dest_os_dir}/etc/resolv.conf"
    fi
    grep -q '8.8.8.8' "/${dest_os_dir}/etc/resolv.conf" 2>/dev/null || echo "nameserver 8.8.8.8" >> "/${dest_os_dir}/etc/resolv.conf"
    grep -q '1.1.1.1' "/${dest_os_dir}/etc/resolv.conf" 2>/dev/null || echo "nameserver 1.1.1.1" >> "/${dest_os_dir}/etc/resolv.conf"
    grep -q '2001:4860:4860::8888' "/${dest_os_dir}/etc/resolv.conf" 2>/dev/null || echo "nameserver 2001:4860:4860::8888" >> "/${dest_os_dir}/etc/resolv.conf"

    # 5. Export metadata for post_install
    mkdir -p "/${dest_os_dir}/tmp"
    cat > "/${dest_os_dir}/tmp/osmutation_env" <<- EOF
		CTTYPE="${cttype:-}"
		NET_DEV="${dev}"
		NET_IP4="${ipaddr_with_mask}"
		NET_GW4="${gw4}"
		NET_IP6="${ip6_addr}"
		NET_GW6="${gw6}"
		SSH_PORT="${ssh_port}"
	EOF

    if [[ -n "$NEW_ROOT_PASS" ]]; then
        (umask 077 && printf 'root:%s\n' "$NEW_ROOT_PASS" > "/${dest_os_dir}/tmp/.osmutation_passwd")
    elif [ -f /tmp/.osmutation_passwd ] && ! [ "/${dest_os_dir}/tmp/.osmutation_passwd" -ef /tmp/.osmutation_passwd ]; then
        (umask 077 && cp -f /tmp/.osmutation_passwd "/${dest_os_dir}/tmp/.osmutation_passwd")
    fi
}

function safe_rm_x(){
    hash -r
    local m
    for m in /x/oldroot /x/sys /x/proc /x/dev/pts /x/dev; do
        if grep -q " ${m} " /proc/mounts 2>/dev/null; then
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done
    if grep -q ' /x/' /proc/mounts 2>/dev/null; then
        echo -e "\e[1;33mWarning: Active mountpoint still detected under /x/; skipping 'rm -rf /x' for safety.\e[m"
        return 0
    fi
    rm -rf /x
}

function configure_sshd(){
    local use_dropin=0
    if [ -d /etc/ssh/sshd_config.d ] && [ -f /etc/ssh/sshd_config ] && grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' /etc/ssh/sshd_config; then
        use_dropin=1
    fi

    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E 's/^[[:space:]]*PermitRootLogin[[:space:]].*/#&/' /etc/ssh/sshd_config
        sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/#&/' /etc/ssh/sshd_config
        if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
            sed -i -E 's/^[[:space:]]*Port[[:space:]].*/#&/' /etc/ssh/sshd_config
        fi
        if (( use_dropin == 0 )); then
            {
                echo ""
                echo "# Added by OsMutation"
                echo "PermitRootLogin yes"
                echo "PasswordAuthentication yes"
                if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
                    echo "Port ${SSH_PORT}"
                fi
            } >> /etc/ssh/sshd_config
        fi
    fi

    if (( use_dropin == 1 )); then
        {
            echo "# Added by OsMutation (first-match-wins)"
            echo "PermitRootLogin yes"
            echo "PasswordAuthentication yes"
            if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
                echo "Port ${SSH_PORT}"
            fi
        } > /etc/ssh/sshd_config.d/00-osmutation.conf
    fi

    command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -A >/dev/null 2>&1 || true
}

function configure_el_networkmanager(){
    if [[ "$NET_DEV" == venet0* ]] || [[ -z "$NET_IP4" && -z "$NET_IP6" ]]; then
        return 0
    fi
    mkdir -p /etc/NetworkManager/system-connections
    local nm_file="/etc/NetworkManager/system-connections/osmutation.nmconnection"
    cat > "$nm_file" <<- EOF
		[connection]
		id=osmutation-${NET_DEV}
		type=ethernet
		interface-name=${NET_DEV}
		autoconnect=true

	EOF
    if [ -n "$NET_IP4" ]; then
        {
            echo "[ipv4]"
            echo "method=manual"
            if [ -n "$NET_GW4" ]; then
                echo "address1=${NET_IP4},${NET_GW4}"
            else
                echo "address1=${NET_IP4}"
            fi
            echo "dns=8.8.8.8;1.1.1.1;"
            echo ""
        } >> "$nm_file"
    fi
    if [ -n "$NET_IP6" ]; then
        {
            echo "[ipv6]"
            echo "method=manual"
            if [ -n "$NET_GW6" ]; then
                echo "address1=${NET_IP6},${NET_GW6}"
            else
                echo "address1=${NET_IP6}"
            fi
            echo "dns=2001:4860:4860::8888;"
            echo ""
        } >> "$nm_file"
    fi
    chmod 600 "$nm_file"
}

function post_install(){
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    hash -r
    # shellcheck disable=SC1091
    [ -f /tmp/osmutation_env ] && source /tmp/osmutation_env

    local os_id=""
    if [ -f /etc/os-release ]; then
        os_id=$(awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release)
    fi

    if [[ "$os_id" == "alpine" ]] || [ -f /etc/alpine-release ]; then
        if ! install openssh bash ifupdown-ng; then
            echo -e "\e[1;33mRetrying apk fix --no-cache (low-memory trigger recovery)...\e[m"
            apk fix --no-cache || true
            command -v sshd >/dev/null 2>&1 || apk add --no-cache openssh || true
        fi
        rc-update add sshd default
        rc-update add networking default
        rc-update add mdev sysinit || true
        rc-update add devfs sysinit || true
        if [ -f /etc/init.d/networking ]; then
            sed -i 's/--auto/-a/' /etc/init.d/networking
        fi
    elif [[ "$os_id" == "debian" || "$os_id" == "ubuntu" ]] || [ -f /etc/debian_version ]; then
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Languages=none update
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Languages=none install -y --no-install-recommends openssh-server
        DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Languages=none install -y ifupdown
        apt-get clean 2>/dev/null || true
        if [ -f /etc/network/interfaces ]; then
            sed -i -E '/^[[:space:]]*hostname[[:space:]]+/d' /etc/network/interfaces
        fi
        systemctl disable ssh.socket 2>/dev/null || true
        rm -f /etc/systemd/system/sockets.target.wants/ssh.socket /etc/systemd/system/ssh.service.requires/ssh.socket 2>/dev/null || true
        systemctl enable ssh.service 2>/dev/null || systemctl enable sshd.service 2>/dev/null || true
        systemctl enable networking.service 2>/dev/null || true
        systemctl disable systemd-networkd.service 2>/dev/null || true
        systemctl disable systemd-networkd.socket 2>/dev/null || true
        systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
        systemctl disable systemd-network-generator.service 2>/dev/null || true
        systemctl disable systemd-networkd-resolve-hook.socket 2>/dev/null || true
        systemctl disable systemd-networkd-varlink.socket 2>/dev/null || true
        systemctl disable netplan-configure.service 2>/dev/null || true
        rm -f /etc/netplan/*.yaml 2>/dev/null || true
    elif [[ "$os_id" == "centos" || "$os_id" == "rocky" || "$os_id" == "almalinux" || "$os_id" == "rhel" ]] || [ -f /etc/redhat-release ]; then
        install openssh-server NetworkManager
        systemctl disable sshd.socket 2>/dev/null || true
        systemctl enable sshd.service 2>/dev/null || systemctl enable sshd 2>/dev/null || true
        systemctl enable NetworkManager 2>/dev/null || true
        configure_el_networkmanager
    else
        echo -e "\e[1;33mWarning: Unknown OS ID '${os_id}', attempting generic openssh install...\e[m"
        install openssh-server || install openssh || true
    fi

    if [ -f /tmp/.osmutation_passwd ]; then
        if chpasswd -c sha512 < /tmp/.osmutation_passwd 2>/dev/null \
            || chpasswd -c SHA512 < /tmp/.osmutation_passwd 2>/dev/null \
            || chpasswd < /tmp/.osmutation_passwd; then
            echo -e "\e[1;32mNew root password applied successfully.\e[m"
        else
            echo -e "\e[1;31mWARNING: Failed to apply new root password via chpasswd! Please run 'passwd root' manually before rebooting!\e[m"
        fi
        rm -f /tmp/.osmutation_passwd
    fi

    configure_sshd
    rm -f /tmp/osmutation_env
    safe_rm_x
    sync

    local ssh_ok=1
    if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
        ssh_ok=0
        echo -e "\e[1;31m========================================================================\e[m"
        echo -e "\e[1;31m[CRITICAL] sshd binary NOT FOUND! Package installation may have failed!\e[m"
        echo -e "\e[1;31mDO NOT REBOOT YET! Install openssh-server manually in this shell first.\e[m"
        echo -e "\e[1;31m========================================================================\e[m"
    else
        mkdir -p /run/sshd 2>/dev/null || true
        if ! sshd -t 2>/dev/null; then
            ssh_ok=0
            echo -e "\e[1;31m[CRITICAL] 'sshd -t' config test FAILED! Check /etc/ssh/sshd_config before rebooting!\e[m"
        fi
    fi

    if (( ssh_ok == 1 )); then
        echo -e "\e[1;32mReinstallation complete & sshd verified OK!\e[m"
        if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
            echo -e "\e[1;32mActive SSH port: ${SSH_PORT}\e[m"
        fi
    fi

    local reboot_ans="$CLI_REBOOT"
    if (( ssh_ok == 0 )); then
        reboot_ans=""
    fi

    while [[ "$reboot_ans" != 'yes' && "$reboot_ans" != 'no' ]]; do
        echo -ne "\e[1;33mreboot now? (yes/no): \e[m"
        read -r reboot_ans < /dev/tty
    done

    if [[ "$reboot_ans" == 'yes' ]]; then
        reboot -f
    fi
}

function install_requirement(){
    ensure_network_dns

    local missing=()
    local xz_pkg="xz" ip_pkg="iproute2"
    if [ -n "$(command -v apt-get)" ]; then
        xz_pkg="xz-utils"
    elif [ -n "$(command -v dnf)" ] || [ -n "$(command -v yum)" ]; then
        ip_pkg="iproute"
    fi

    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v sed >/dev/null 2>&1 || missing+=("sed")
    command -v awk >/dev/null 2>&1 || missing+=("gawk")
    command -v gzip >/dev/null 2>&1 || missing+=("gzip")
    command -v xz >/dev/null 2>&1 || missing+=("$xz_pkg")
    (tar --version 2>/dev/null | grep -qi 'GNU tar') || missing+=("tar")
    command -v virt-what >/dev/null 2>&1 || missing+=("virt-what")
    command -v ip >/dev/null 2>&1 || missing+=("$ip_pkg")
    if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/pki/tls/certs/ca-bundle.crt ]; then
        missing+=("ca-certificates")
    fi

    if [ "${#missing[@]}" -eq 0 ]; then
        echo -e "\e[1;32mAll requirements already installed, skipping package manager update.\e[m"
    else
        echo -e "\e[1;32mInstalling missing packages: ${missing[*]}\e[m"
        install "${missing[@]}"
    fi
    ensure_network_dns
}

function main(){
    parse_args "$@"
    print_help
    echo -e '\e[1;32minstall requirement...\e[m'
    install_requirement
    read_virt_tech
    read_unified_template
    check_password_compat
    confirm_reinstall

    echo -e '\e[1;32mdownloading template...\e[m'
    download_rootfs

    echo -e '\e[1;32mmigrating configuration...\e[m'
    migrate_configuration oldroot

    touch /tmp/.osmutation_replaced
}

function fetch_url(){
    local url="$1"
    if [ -n "$(command -v curl)" ]; then
        curl -fsSL "$url"
    elif [ -n "$(command -v wget)" ]; then
        wget -qO- "$url"
    else
        install curl
        curl -fsSL "$url"
    fi
}

CHROOT_MOUNTS_ACTIVE=0
function cleanup_chroot_mounts(){
    if (( CHROOT_MOUNTS_ACTIVE == 0 )); then
        return 0
    fi
    hash -r
    local m
    for m in /x/oldroot /x/sys /x/proc /x/dev/pts /x/dev; do
        if grep -q " ${m} " /proc/mounts 2>/dev/null || mountpoint -q "$m" 2>/dev/null; then
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done
    CHROOT_MOUNTS_ACTIVE=0
}

function make_temp_os(){
    parse_args "$@"
    if (( CLI_LIST == 1 )); then
        list_templates_and_exit
    fi

    check_root
    ensure_network_dns

    local alpine_arch minirootfs_file temp_os_url
    alpine_arch=$(detect_alpine_arch)
    minirootfs_file=$(fetch_url "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${alpine_arch}/latest-releases.yaml" 2>/dev/null | awk '/file: alpine-minirootfs-.*\.tar\.gz/{print $2; exit}')

    if [[ -n "$minirootfs_file" ]]; then
        temp_os_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${alpine_arch}/${minirootfs_file}"
    else
        temp_os_url="https://github.com/${LEGACY_OPENVZ_REPO}/releases/download/utils/alpine-3.18-chroot.tar.gz"
    fi

    echo -e "\e[1;32mPreparing temporary Alpine chroot from ${temp_os_url} ...\e[m"
    safe_rm_x
    mkdir -p /x
    if ! fetch_url "$temp_os_url" | tar -C /x -xz; then
        echo -e "\e[1;31mError: Failed to prepare temporary Alpine chroot.\e[m"
        safe_rm_x
        exit 1
    fi

    # Backup current configuration into temporary Alpine chroot
    migrate_configuration x

    local script_self
    script_self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ -f "$script_self" ]; then
        cp "$script_self" /x/OsMutationTight.sh
    else
        fetch_url "https://raw.githubusercontent.com/${REPO}/main/OsMutationTight.sh" > /x/OsMutationTight.sh
    fi
    chmod +x /x/OsMutationTight.sh

    # Mount essential pseudo-filesystems so /dev/tty, /dev/null, /dev/urandom, /proc work inside chroot
    mkdir -p /x/oldroot /x/dev /x/dev/pts /x/proc /x/sys
    trap cleanup_chroot_mounts EXIT INT TERM
    CHROOT_MOUNTS_ACTIVE=1
    mount --bind /dev /x/dev
    [ -d /dev/pts ] && mount --bind /dev/pts /x/dev/pts 2>/dev/null || true
    mount --bind /proc /x/proc
    mount --bind /sys /x/sys
    mount --bind / /x/oldroot

    # Install bash inside temporary Alpine chroot, then invoke main=1 with forwarded CLI arguments
    if ! chroot /x /bin/sh -c "[ -x /bin/bash ] || apk add --no-cache bash"; then
        echo -e "\e[1;31mError: Failed to install bash in temporary Alpine chroot.\e[m"
        cleanup_chroot_mounts
        safe_rm_x
        exit 1
    fi

    local chroot_rc=0
    chroot /x /usr/bin/env main=1 /bin/bash /OsMutationTight.sh "${ORIG_ARGS[@]}" || chroot_rc=$?

    local replaced=0
    [ -f /x/tmp/.osmutation_replaced ] && replaced=1
    cleanup_chroot_mounts
    trap - EXIT INT TERM

    if (( chroot_rc != 0 || replaced == 0 )); then
        if (( replaced == 0 )); then
            safe_rm_x
        fi
        exit "$chroot_rc"
    fi

    echo -e '\e[1;32mpost processing...\e[m'
    post_install
}

function is_readonly_cli_invocation(){
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --os|-p|--password|--ssh-port)
                shift 2 2>/dev/null || break
                ;;
            -h|--help|--list)
                return 0
                ;;
            *)
                shift
                ;;
        esac
    done
    return 1
}

if [ -z "${main:-}" ]; then
    if is_readonly_cli_invocation "$@"; then
        make_temp_os "$@"
        exit $?
    fi
    LOG_FILE="/run/osmutation.log"
    [ -w /run ] || LOG_FILE="/tmp/osmutation.log"
    make_temp_os "$@" 2>&1 | tee "$LOG_FILE"
    exit $?
fi

main "$@"
