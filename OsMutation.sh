#!/bin/bash
# Reinstall Any OpenVZ/LXC VPS to Alpine/Debian/Ubuntu/CentOS/Rocky/AlmaLinux
# Original Author: Lloyd@nodeseek.com
# Updated Fork: https://github.com/Wangbaofushuai/OsMutation
# WARNING: A fresh system will be installed and all old data will be wiped.
# License: GPLv3; Partly based on https://gist.github.com/trimsj/c1fefd650b5f49ceb8f3efc1b6a1404d

REPO="${OSMUTATION_REPO:-Wangbaofushuai/OsMutation}"
LEGACY_OPENVZ_REPO="${OSMUTATION_LEGACY_REPO:-LloydAsp/OsMutation}"
LEGACY_OPENVZ_TAG="v0.0.1"

function print_help(){
    echo -ne "\e[1;32m"
    cat <<- EOF

		 ██████╗ ███████╗███╗   ███╗██╗   ██╗████████╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗
		██╔═══██╗██╔════╝████╗ ████║██║   ██║╚══██╔══╝██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║
		██║   ██║███████╗██╔████╔██║██║   ██║   ██║   ███████║   ██║   ██║██║   ██║██╔██╗ ██║
		██║   ██║╚════██║██║╚██╔╝██║██║   ██║   ██║   ██╔══██║   ██║   ██║██║   ██║██║╚██╗██║
		╚██████╔╝███████║██║ ╚═╝ ██║╚██████╔╝   ██║   ██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║
		 ╚═════╝ ╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

		Reinstall Any OpenVZ/LXC VPS to Alpine/Debian/Ubuntu/CentOS/Rocky/AlmaLinux
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
        echo -e "\e[1;33mYour container type: ${cttype} (arch: $(detect_arch), kernel: $(uname -r))\e[m"
    else
        while [[ "$cttype" != 'lxc' && "$cttype" != 'openvz' && "$cttype" != 'kvm' ]]; do
            echo -ne "\e[1;33mplease input container type (lxc/openvz/kvm):\e[m"
            read -r cttype < /dev/tty
        done
    fi
}

function install(){
    if [ -n "$(command -v apt-get)" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif [ -n "$(command -v dnf)" ]; then
        dnf makecache -q || true
        dnf install -y "$@"
    elif [ -n "$(command -v yum)" ]; then
        yum install -y "$@"
    elif [ -n "$(command -v apk)" ]; then
        apk update
        apk add "$@"
    else
        echo "Error: Not Supported OS"
        exit 1
    fi
}

function ensure_network_dns(){
    if ! curl -fsSLI --max-time 6 "https://api.github.com" >/dev/null 2>&1; then
        # Only inject NAT64 DNS when host has IPv6 connectivity but no IPv4 default route
        if ! ip -4 route show default 2>/dev/null | grep -q default && ip -6 route show default 2>/dev/null | grep -q default; then
            echo -e "\e[1;33mIPv6-only environment detected, adding NAT64 DNS...\e[m"
            echo "nameserver 2a00:1098:2c::1" > /etc/resolv.conf
        fi
    fi
}

function install_requirement(){
    if [ -n "$(command -v apk)" ]; then
        install curl sed gawk wget gzip xz tar virt-what iproute2
    elif [ -n "$(command -v apt-get)" ]; then
        install curl sed gawk wget gzip xz-utils tar virt-what iproute2 ca-certificates
    else
        install curl sed gawk wget gzip xz tar virt-what iproute ca-certificates
    fi
    ensure_network_dns
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
    if [[ "$cttype" == "openvz" ]] && is_old_openvz_kernel; then
        local risky=0
        local ver=""
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
            echo -e "\e[1;31m[WARNING] OpenVZ Old Kernel Compatibility Risk!\e[m"
            echo -e "\e[1;33mDetected OpenVZ kernel: $(uname -r) (cgroup v1 only).\e[m"
            echo -e "\e[1;33mSelected OS '${target}' ships newer systemd that requires cgroup v2.\e[m"
            echo -e "\e[1;33mReinstalling it on OpenVZ 7 will VERY LIKELY fail to boot / lose SSH!\e[m"
            echo -e "\e[1;32mRecommended for OpenVZ 7: Alpine 3.x, Debian 12 (bookworm), Ubuntu 22.04, or [0] Legacy v0.0.1.\e[m"
            echo -e "\e[1;31m========================================================================\e[m"
            local confirm
            echo -ne "\e[1;33mContinue anyway? (y/N): \e[m"
            read -r confirm < /dev/tty
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                return 1
            fi
        fi
    fi
    return 0
}

function read_legacy_openvz_template(){
    echo -e "\e[1;33mLoading legacy OpenVZ 7 templates (${LEGACY_OPENVZ_REPO}@${LEGACY_OPENVZ_TAG})...\e[m"
    local release_json image_list os_list total_count os_index
    release_json=$(curl -fsSL "https://api.github.com/repos/${LEGACY_OPENVZ_REPO}/releases/tags/${LEGACY_OPENVZ_TAG}" 2>/dev/null || true)

    if [[ -n "$release_json" ]]; then
        image_list=$(printf '%s\n' "$release_json" | grep '"browser_download_url":' | sed -E 's/.*"([^"]+)".*/\1/' | grep -E '\.tar\.(gz|xz)$' | sort -V)
    fi

    if [[ -z "$image_list" ]]; then
        os_list=$(wget -qO- "https://github.com/${LEGACY_OPENVZ_REPO}/releases/expanded_assets/${LEGACY_OPENVZ_TAG}" | \
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
    return 0
}

function read_unified_template(){
    local arch manifest_json release_json last_lxc_version image_list os_list total_count os_index
    arch=$(detect_arch)

    # 1. Prefer raw images.json manifest (no GitHub API rate limit, auto-updated weekly)
    manifest_json=$(curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/images.json" 2>/dev/null || true)
    if [[ -n "$manifest_json" ]]; then
        last_lxc_version=$(printf '%s\n' "$manifest_json" | sed -nE 's/.*"tag": *"([^"]+)".*/\1/p' | head -n 1)
        image_list=$(printf '%s\n' "$manifest_json" | grep "\"arch\": \"${arch}\"" | sed -nE 's/.*"url": *"([^"]+)".*/\1/p')
        os_list=$(printf '%s\n' "$manifest_json" | grep "\"arch\": \"${arch}\"" | sed -nE 's/.*"name": *"([^"]+)".*/\1/p')
        if [[ -n "$image_list" ]]; then
            echo -e "\e[1;32mImage source: Manifest (${REPO}@${last_lxc_version:-latest})\e[m"
        fi
    fi

    # 2. Fallback to GitHub Releases API
    if [[ -z "$image_list" ]]; then
        release_json=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)
        last_lxc_version=$(printf '%s\n' "$release_json" | grep '"tag_name":' | grep "LXC" | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)

        if [[ -n "$last_lxc_version" ]]; then
            image_list=$(printf '%s\n' "$release_json" | grep '"browser_download_url":' | sed -E 's/.*"([^"]+)".*/\1/' | grep -E '\.tar\.(xz|gz)$' | grep -- "-${arch}\.tar\." | sort -V)
            os_list=$(printf '%s\n' "$image_list" | sed -E 's|.*/||; s/\.tar\.(xz|gz)$//')
            echo -e "\e[1;32mImage source: GitHub Release (${REPO}@${last_lxc_version})\e[m"
        fi
    fi

    # 3. Fallback direct to LinuxContainers (auto-tracks Alpine, Debian stable/oldstable, Ubuntu LTS, EL >= 9)
    if [[ -z "$image_list" ]]; then
        echo -e "\e[1;33mGitHub Release unavailable, falling back to https://images.linuxcontainers.org ...\e[m"
        local server="https://images.linuxcontainers.org"
        local deb_pairs="" ub_pairs="" entries
        for suite in oldstable stable; do
            local rel_txt c v
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

        entries=$(curl -fsSL "${server}/meta/1.0/index-system" | awk -F';' -v arch="$arch" -v deb="$deb_pairs" -v ub="$ub_pairs" '
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
        os_list=$(printf '%s\n' "$entries" | cut -d';' -f1)
        image_list=$(printf '%s\n' "$entries" | cut -d';' -f2 | sed -E "s|^/*|${server}/|; s|/*$|/rootfs.tar.xz|")
    fi

    total_count=$(printf '%s\n' "$os_list" | wc -l)

    while true; do
        echo ""
        printf '%s\n' "$os_list" | nl -w 3 -s '  '
        if [[ "$cttype" == "openvz" ]]; then
            echo -e "  0  \e[1;36m[Legacy] OpenVZ 7 archive templates (${LEGACY_OPENVZ_TAG})\e[m"
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
            os_selected=$(printf '%s\n' "$os_list" | sed -n "${os_index}p")
            download_link=$(printf '%s\n' "$image_list" | sed -n "${os_index}p")
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

function download_rootfs(){
    cd / || exit 1
    rm -rf /x
    mkdir -p /x

    local tar_flag="-xJ"
    case "$download_link" in
        *.tar.xz)          tar_flag="-xJ" ;;
        *.tar.gz|*.tgz)    tar_flag="-xz" ;;
        *.tar.zst)         tar_flag="--zstd -x" ;;
        *)                 tar_flag="-xJ" ;;
    esac

    if ! curl -fsSL "$download_link" | tar -C /x ${tar_flag} --numeric-owner; then
        echo -e "\e[1;31mError: Failed to download or extract rootfs from ${download_link}\e[m"
        rm -rf /x
        exit 1
    fi

    if [ ! -d /x/etc ] || [ ! -d /x/usr ]; then
        echo -e "\e[1;31mError: Extracted rootfs appears invalid (/x/etc or /x/usr missing). Aborting!\e[m"
        rm -rf /x
        exit 1
    fi
}

function migrate_configuration(){
    # 1. Save root password hash and SSH authorized keys
    if [ -f /etc/shadow ] && [ -f /x/etc/shadow ]; then
        sed -i '/^root:/d' /x/etc/shadow
        grep '^root:' /etc/shadow >> /x/etc/shadow
    fi
    [ -d /root/.ssh ] && mkdir -p /x/root && cp -a /root/.ssh /x/root/

    # Detect existing custom SSH port (if any)
    local ssh_port=""
    if [ -f /etc/ssh/sshd_config ]; then
        ssh_port=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config)
    fi

    # 2. Save hostname
    local cur_hostname
    cur_hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "vps")
    echo "$cur_hostname" > /x/etc/hostname
    if [ -f /x/etc/hosts ] && ! grep -q "$cur_hostname" /x/etc/hosts; then
        echo "127.0.1.1 ${cur_hostname}" >> /x/etc/hosts
    fi

    # 3. Detect current network configuration (supports both eth0 and OpenVZ venet0)
    local dev ipaddr_with_mask gw4 route_part gateway_line ip6_addr gw6
    dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ -z "$dev" ] && dev=$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route 2>/dev/null)
    [ -z "$dev" ] && dev=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ -z "$dev" ] && dev="eth0"

    ipaddr_with_mask=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / && /scope global/ {print $2; exit}')
    gw4=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
    route_part=$(ip -4 route show default 2>/dev/null | head -n 1 | sed -E 's/^(.*dev [^ ]+).*$/\1/')
    [ -n "$route_part" ] && gateway_line="up ip route add ${route_part}" || gateway_line=""

    ip6_addr=$(ip -6 addr show dev "$dev" 2>/dev/null | awk '/inet6 / && /scope global/ {print $2; exit}')
    gw6=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')

    mkdir -p /x/etc/network/
    # Preserve existing /etc/network/interfaces when it already configures static or OpenVZ venet0
    if [ -f /etc/network/interfaces ] && grep -qE '(static|venet0|inet6)' /etc/network/interfaces; then
        cp -rf /etc/network/interfaces /x/etc/network/interfaces
        [ -d /etc/network/interfaces.d ] && cp -a /etc/network/interfaces.d /x/etc/network/
    elif [[ "$dev" == venet0* ]]; then
        local venet_ip="${ipaddr_with_mask%%/*}"
        cat > /x/etc/network/interfaces <<- EOF
			auto lo
			iface lo inet loopback

			auto venet0
			iface venet0 inet manual
			    up ifconfig venet0 up 2>/dev/null || ip link set venet0 up
			    up ip route add default dev venet0 2>/dev/null || true

			auto venet0:0
			iface venet0:0 inet static
			    address ${venet_ip}/32
		EOF
        if [ -n "$ip6_addr" ]; then
            cat >> /x/etc/network/interfaces <<- EOF

			iface venet0 inet6 static
			    address ${ip6_addr}
			    up ip -6 route add default dev venet0 2>/dev/null || true
			EOF
        fi
    else
        cat > /x/etc/network/interfaces <<- EOF
			auto lo
			iface lo inet loopback

			auto ${dev}
		EOF
        if [ -n "$ipaddr_with_mask" ]; then
            cat >> /x/etc/network/interfaces <<- EOF
			iface ${dev} inet static
			    address ${ipaddr_with_mask}
			    ${gateway_line}
			EOF
        else
            cat >> /x/etc/network/interfaces <<- EOF
			iface ${dev} inet dhcp
			EOF
        fi
        if [ -n "$ip6_addr" ]; then
            cat >> /x/etc/network/interfaces <<- EOF

			iface ${dev} inet6 static
			    address ${ip6_addr}
			EOF
            if [ -n "$gw6" ]; then
                echo "    gateway ${gw6}" >> /x/etc/network/interfaces
            fi
        fi
    fi

    # 4. Save DNS configuration (preserve valid nameservers + fallback public DNS)
    rm -f /x/etc/resolv.conf
    if [ -f /etc/resolv.conf ] && grep -q '^nameserver ' /etc/resolv.conf; then
        grep '^nameserver ' /etc/resolv.conf > /x/etc/resolv.conf
    fi
    grep -q '8.8.8.8' /x/etc/resolv.conf 2>/dev/null || echo "nameserver 8.8.8.8" >> /x/etc/resolv.conf
    grep -q '1.1.1.1' /x/etc/resolv.conf 2>/dev/null || echo "nameserver 1.1.1.1" >> /x/etc/resolv.conf
    grep -q '2001:4860:4860::8888' /x/etc/resolv.conf 2>/dev/null || echo "nameserver 2001:4860:4860::8888" >> /x/etc/resolv.conf

    # 5. Export metadata for post_install (used by NetworkManager/SSH config)
    mkdir -p /x/tmp
    cat > /x/tmp/osmutation_env <<- EOF
		CTTYPE="${cttype}"
		NET_DEV="${dev}"
		NET_IP4="${ipaddr_with_mask}"
		NET_GW4="${gw4}"
		NET_IP6="${ip6_addr}"
		NET_GW6="${gw6}"
		SSH_PORT="${ssh_port}"
	EOF
}

function chroot_run(){
    if [ -f /x/etc/alpine-release ] || grep -qi alpine /x/etc/issue 2>/dev/null; then
        chroot "/x/" /bin/sh -c "[ -x /bin/bash ] || apk add --no-cache bash"
    fi
    chroot "/x/" /bin/bash -c "$*"
}

function replace_os(){
    mkdir -p /x/oldroot
    mount --bind / /x/oldroot
    chroot_run 'cd /oldroot; ' \
        'rm -rf $(ls -A /oldroot | grep -vE "^(dev|proc|sys|run|x)$"); ' \
        'cd /; ' \
        'mv -f $(ls -A / | grep -vE "^(dev|proc|sys|run|oldroot)$") /oldroot'
    umount /x/oldroot
}

function configure_sshd(){
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E 's/^[[:space:]]*PermitRootLogin[[:space:]].*/#&/' /etc/ssh/sshd_config
        sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/#&/' /etc/ssh/sshd_config
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

    if [ -d /etc/ssh/sshd_config.d ]; then
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
    # Configure static IPv4/IPv6 for CentOS/Rocky/AlmaLinux when using non-venet0 interfaces
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
    [ -f /tmp/osmutation_env ] && source /tmp/osmutation_env

    local os_id=""
    if [ -f /etc/os-release ]; then
        os_id=$(awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release)
    fi

    if [[ "$os_id" == "alpine" ]] || [ -f /etc/alpine-release ]; then
        install openssh bash ifupdown-ng
        rc-update add sshd default
        rc-update add networking default
        rc-update add mdev sysinit || true
        rc-update add devfs sysinit || true
        if [ -f /etc/init.d/networking ]; then
            sed -i 's/--auto/-a/' /etc/init.d/networking
        fi
    elif [[ "$os_id" == "debian" || "$os_id" == "ubuntu" ]] || [ -f /etc/debian_version ]; then
        install openssh-server ifupdown
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
        systemctl disable systemd-networkd.service 2>/dev/null || true
        systemctl disable systemd-networkd.socket 2>/dev/null || true
        systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
        rm -f /etc/netplan/*.yaml 2>/dev/null || true
    elif [[ "$os_id" == "centos" || "$os_id" == "rocky" || "$os_id" == "almalinux" || "$os_id" == "rhel" ]] || [ -f /etc/redhat-release ]; then
        install openssh-server NetworkManager
        systemctl enable sshd 2>/dev/null || true
        systemctl enable NetworkManager 2>/dev/null || true
        configure_el_networkmanager
    else
        echo -e "\e[1;33mWarning: Unknown OS ID '${os_id}', attempting generic openssh install...\e[m"
        install openssh-server || install openssh || true
    fi

    configure_sshd
    rm -rf /x /tmp/osmutation_env
    sync

    echo -e "\e[1;32mReinstallation complete! Root password and SSH keys have been preserved.\e[m"
    if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
        echo -e "\e[1;32mPreserved custom SSH port: ${SSH_PORT}\e[m"
    fi

    local reboot_ans=""
    while [[ "$reboot_ans" != 'yes' && "$reboot_ans" != 'no' ]]; do
        echo -ne "\e[1;33mreboot now? (yes/no): \e[m"
        read -r reboot_ans < /dev/tty
    done

    if [[ "$reboot_ans" == 'yes' ]]; then
        reboot -f
    fi
}

function main(){
    check_root
    print_help
    echo -e '\e[1;32minstall requirement...\e[m'
    install_requirement
    read_virt_tech

    if [[ "$cttype" == 'openvz' || "$cttype" == 'lxc' ]]; then
        read_unified_template
    elif [[ "$cttype" == 'kvm' ]]; then
        curl -fsSLo OsMutationKvm.sh "https://raw.githubusercontent.com/${REPO}/main/OsMutationKvm.sh"
        chmod u+x OsMutationKvm.sh
        ./OsMutationKvm.sh
        exit 0
    fi

    echo -e '\e[1;32mdownloading template...\e[m'
    download_rootfs
    echo -e '\e[1;32mmigrating configuration...\e[m'
    migrate_configuration
    echo -e '\e[1;32mreplacing old files...\e[m'
    replace_os
    echo -e '\e[1;32mpost processing...\e[m'
    post_install
}

main 2>&1 | tee reinstall.log
