#!/bin/bash
# Reinstall Any OpenVZ/LXC VPS with Small Disk (<1GiB) to Alpine/Debian/Ubuntu/CentOS/Rocky/AlmaLinux
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
        while [[ "$cttype" != 'lxc' && "$cttype" != 'openvz' ]]; do
            echo -ne "\e[1;33mplease input container type (lxc/openvz): \e[m"
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
    local tar_flag="-xJ"
    case "$download_link" in
        *.tar.xz)          tar_flag="-xJ" ;;
        *.tar.gz|*.tgz)    tar_flag="-xz" ;;
        *.tar.zst)         tar_flag="--zstd -x" ;;
        *)                 tar_flag="-xJ" ;;
    esac

    # Pre-flight check that download URL is reachable before wiping /oldroot
    if ! curl -fsSLI "$download_link" >/dev/null 2>&1; then
        echo -e "\e[1;31mError: Download URL unreachable: ${download_link}. Aborting before wiping old root!\e[m"
        exit 1
    fi

    cd /oldroot || exit 1
    rm -rf $(ls -A /oldroot | grep -vE '^(dev|proc|sys|run|x)$')

    if ! curl -fsSL "$download_link" | tar -C /oldroot ${tar_flag} --numeric-owner --delay-directory-restore --exclude="dev" --exclude="proc" --exclude="run" --exclude="sys"; then
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

    local ssh_port=""
    if [ -f /etc/ssh/sshd_config ]; then
        ssh_port=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config)
    elif [ -f /tmp/osmutation_env ]; then
        ssh_port=$(awk -F= '/^SSH_PORT=/{gsub(/"/, "", $2); print $2; exit}' /tmp/osmutation_env)
    fi

    # 2. Save hostname
    local cur_hostname
    cur_hostname=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "vps")
    echo "$cur_hostname" > "/${dest_os_dir}/etc/hostname"
    if [ -f "/${dest_os_dir}/etc/hosts" ] && ! grep -q "$cur_hostname" "/${dest_os_dir}/etc/hosts"; then
        echo "127.0.1.1 ${cur_hostname}" >> "/${dest_os_dir}/etc/hosts"
    fi

    # 3. Save network configuration (supports both eth0 and OpenVZ venet0)
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

    mkdir -p "/${dest_os_dir}/etc/network/"
    if [ -f /etc/network/interfaces ] && grep -qE '(static|venet0|inet6)' /etc/network/interfaces; then
        cp -rf /etc/network/interfaces "/${dest_os_dir}/etc/network/interfaces"
        [ -d /etc/network/interfaces.d ] && cp -a /etc/network/interfaces.d "/${dest_os_dir}/etc/network/"
    elif [[ "$dev" == venet0* ]]; then
        local venet_ip="${ipaddr_with_mask%%/*}"
        cat > "/${dest_os_dir}/etc/network/interfaces" <<- EOF
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
        else
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
}

function chroot_run(){
    if [ -f /x/etc/alpine-release ] || grep -qi alpine /x/etc/issue 2>/dev/null; then
        chroot "/x/" /bin/sh -c "[ -x /bin/bash ] || apk add --no-cache bash"
    fi
    chroot "/x/" /bin/bash -c "$*"
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
    local reboot_ans=""
    while [[ "$reboot_ans" != 'yes' && "$reboot_ans" != 'no' ]]; do
        echo -ne "\e[1;33mreboot now? (yes/no): \e[m"
        read -r reboot_ans < /dev/tty
    done

    if [[ "$reboot_ans" == 'yes' ]]; then
        reboot -f
    fi
}

function install_requirement(){
    if [ -n "$(command -v apk)" ]; then
        install curl sed gawk wget gzip xz tar virt-what iproute2 ca-certificates
    elif [ -n "$(command -v apt-get)" ]; then
        install curl sed gawk wget gzip xz-utils tar virt-what iproute2 ca-certificates
    else
        install curl sed gawk wget gzip xz tar virt-what iproute ca-certificates
    fi
}

function main(){
    print_help
    echo -e '\e[1;32minstall requirement...\e[m'
    install_requirement
    read_virt_tech
    read_unified_template

    echo -e '\e[1;32mdownloading template...\e[m'
    download_rootfs

    echo -e '\e[1;32mmigrating configuration...\e[m'
    migrate_configuration oldroot
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

function make_temp_os(){
    check_root
    # IPv6-only NAT64 fallback only when IPv4 default route is absent
    if ! ip -4 route show default 2>/dev/null | grep -q default && ip -6 route show default 2>/dev/null | grep -q default; then
        fetch_url "https://api.github.com" >/dev/null 2>&1 || echo "nameserver 2a00:1098:2c::1" > /etc/resolv.conf
    fi

    local alpine_arch minirootfs_file temp_os_url
    alpine_arch=$(detect_alpine_arch)
    minirootfs_file=$(fetch_url "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${alpine_arch}/latest-releases.yaml" 2>/dev/null | awk '/file: alpine-minirootfs-.*\.tar\.gz/{print $2; exit}')

    if [[ -n "$minirootfs_file" ]]; then
        temp_os_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${alpine_arch}/${minirootfs_file}"
    else
        temp_os_url="https://github.com/${LEGACY_OPENVZ_REPO}/releases/download/utils/alpine-3.18-chroot.tar.gz"
    fi

    echo -e "\e[1;32mPreparing temporary Alpine chroot from ${temp_os_url} ...\e[m"
    rm -rf /x
    mkdir -p /x
    if ! fetch_url "$temp_os_url" | tar -C /x -xz; then
        echo -e "\e[1;31mError: Failed to prepare temporary Alpine chroot.\e[m"
        rm -rf /x
        exit 1
    fi

    # Backup current configuration into temporary Alpine chroot
    migrate_configuration x

    local script_self
    script_self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    cp "$script_self" /x/OsMutationTight.sh
    chmod +x /x/OsMutationTight.sh

    mkdir -p /x/oldroot
    mount --bind / /x/oldroot
    chroot_run env main=1 /OsMutationTight.sh
    umount /x/oldroot

    echo -e '\e[1;32mpost processing...\e[m'
    post_install
}

if [ -z "$main" ]; then
    make_temp_os 2>&1 | tee reinstall.log
    exit 0
fi

main
