#!/bin/bash
# Experimental KVM Reinstall Script (Part of OsMutation)
# Original Author: Lloyd@nodeseek.com
# Updated Fork: https://github.com/Wangbaofushuai/OsMutation
# WARNING: Experimental! A fresh system will be installed and all old data will be wiped.
# License: GPLv3

set -o pipefail

REPO="${OSMUTATION_REPO:-Wangbaofushuai/OsMutation}"
os_selected=""
download_link=""

function print_help(){
    echo -ne "\e[1;32m"
    cat <<- EOF

		 ██████╗ ███████╗███╗   ███╗██╗   ██╗████████╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗
		██╔═══██╗██╔════╝████╗ ████║██║   ██║╚══██╔══╝██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║
		██║   ██║███████╗██╔████╔██║██║   ██║   ██║   ███████║   ██║   ██║██║   ██║██╔██╗ ██║
		██║   ██║╚════██║██║╚██╔╝██║██║   ██║   ██║   ██╔══██║   ██║   ██║██║   ██║██║╚██╗██║
		╚██████╔╝███████║██║ ╚═╝ ██║╚██████╔╝   ██║   ██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║
		 ╚═════╝ ╚══════╝╚═╝     ╚═╝ ╚═════╝    ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

		OsMutationKvm (Experimental) - Reinstall KVM VPS
		[warning] A fresh system will be installed and all old data will be wiped!
		Repo: https://github.com/${REPO}
	EOF
    echo -ne "\e[m"
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

function read_lxc_template(){
    local arch manifest_json release_json last_lxc_version image_list os_list total_count os_index
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
        *)             arch="amd64" ;;
    esac

    manifest_json=$(curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/images.json" 2>/dev/null || true)
    if [[ -n "$manifest_json" ]]; then
        image_list=$(printf '%s\n' "$manifest_json" | grep "\"arch\": \"${arch}\"" | sed -nE 's/.*"url": *"([^"]+)".*/\1/p')
        os_list=$(printf '%s\n' "$manifest_json" | grep "\"arch\": \"${arch}\"" | sed -nE 's/.*"name": *"([^"]+)".*/\1/p')
    fi

    if [[ -z "$image_list" ]]; then
        release_json=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)
        last_lxc_version=$(printf '%s\n' "$release_json" | grep '"tag_name":' | grep "LXC" | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)
        if [[ -n "$last_lxc_version" ]]; then
            image_list=$(printf '%s\n' "$release_json" | grep '"browser_download_url":' | sed -E 's/.*"([^"]+)".*/\1/' | grep -E '\.tar\.(xz|gz)$' | grep -- "-${arch}\.tar\." | sort -V)
            os_list=$(printf '%s\n' "$image_list" | sed -E 's|.*/||; s/\.tar\.(xz|gz)$//')
        fi
    fi

    if [[ -z "$image_list" ]]; then
        echo -e "\e[1;31mError: Failed to fetch template list.\e[m"
        exit 1
    fi

    total_count=$(printf '%s\n' "$os_list" | wc -l)
    printf '%s\n' "$os_list" | nl -w 3 -s '  '

    while true; do
        echo -ne "\e[1;33mplease select os (1-${total_count}): \e[m"
        read -r os_index < /dev/tty
        if [[ "$os_index" =~ ^[0-9]+$ ]] && (( os_index >= 1 && os_index <= total_count )); then
            break
        fi
        echo -e "\e[1;31mInvalid selection.\e[m"
    done

    os_selected=$(printf '%s\n' "$os_list" | sed -n "${os_index}p")
    download_link=$(printf '%s\n' "$image_list" | sed -n "${os_index}p")
    echo -e "\e[1;32mSelected OS: ${os_selected}\e[m"
}

function download_rootfs(){
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

    curl -fSL "$download_link" | tar -C /oldroot -xJ --numeric-owner --delay-directory-restore \
        --anchored --exclude="./dev" --exclude="./proc" --exclude="./run" --exclude="./sys" \
        --exclude="dev" --exclude="proc" --exclude="run" --exclude="sys"
}

function migrate_configuration(){
    local dest_os_dir="$1"
    if [ -f /etc/shadow ] && [ -f "/${dest_os_dir}/etc/shadow" ]; then
        sed -i '/^root:/d' "/${dest_os_dir}/etc/shadow"
        grep '^root:' /etc/shadow >> "/${dest_os_dir}/etc/shadow"
    fi
    [ -d /root/.ssh ] && mkdir -p "/${dest_os_dir}/root" && cp -a /root/.ssh "/${dest_os_dir}/root/"
    mkdir -p "/${dest_os_dir}/etc/udev/rules.d/"
    [ -f /etc/udev/rules.d/70-persistent-net.rules ] && cp -a /etc/udev/rules.d/70-persistent-net.rules "/${dest_os_dir}/etc/udev/rules.d/70-persistent-net.rules"

    local dev ipaddr_with_mask route_part gateway_line cur_hostname
    dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    [ -z "$dev" ] && dev="eth0"
    mkdir -p "/${dest_os_dir}/etc/network/"
    ipaddr_with_mask=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / && /scope global/ {print $2; exit}')
    cur_hostname=$(hostname 2>/dev/null || echo "vps")
    route_part=$(ip -4 route show default 2>/dev/null | head -n 1 | sed -E 's/^(.*dev [^ ]+( onlink)?).*$/\1/')
    [ -n "$route_part" ] && gateway_line="up ip route add ${route_part}" || gateway_line=""

    echo "$cur_hostname" > "/${dest_os_dir}/etc/hostname"
    if [ -f /etc/network/interfaces ] && grep -q static /etc/network/interfaces; then
        cp -rf /etc/network/interfaces "/${dest_os_dir}/etc/network/interfaces"
    else
        cat > "/${dest_os_dir}/etc/network/interfaces" <<- EOF
			auto lo
			iface lo inet loopback

			auto ${dev}
			iface ${dev} inet static
			    address ${ipaddr_with_mask}
			    ${gateway_line}
		EOF
    fi

    rm -f "/${dest_os_dir}/etc/resolv.conf"
    cat > "/${dest_os_dir}/etc/resolv.conf" <<- EOF
		nameserver 8.8.8.8
		nameserver 1.1.1.1
		nameserver 2001:4860:4860::8888
	EOF
}

function post_install(){
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    local root_partition root_partition_type target_disk os_id="" arch
    root_partition=$(df / | awk 'NR==2 {print $1}')
    root_partition_type=$(df -T / | awk 'NR==2 {print $2}')
    target_disk=$(printf '%s\n' "$root_partition" | sed -E 's/p?[0-9]+$//')
    echo "${root_partition} / ${root_partition_type} defaults 0 1" > /etc/fstab
    mkdir -p /boot/grub

    [ -f /etc/os-release ] && os_id=$(awk -F= '/^ID=/{gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release)
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
        *)             arch="amd64" ;;
    esac

    if [[ "$os_id" == "alpine" ]] || [ -f /etc/alpine-release ]; then
        install openssh bash ifupdown-ng grub grub-bios linux-lts
        rc-update add sshd default
        rc-update add mdev sysinit || true
        rc-update add devfs sysinit || true
        rc-update add networking default
        [ -f /etc/init.d/networking ] && sed -i 's/--auto/-a/' /etc/init.d/networking
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet rootfstype=ext4 modules=sd-mod,usb-storage,ext4"' >> /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg
    elif [[ "$os_id" == "debian" ]]; then
        install openssh-server ifupdown fdisk "linux-image-${arch}" grub-pc
        systemctl enable ssh networking.service 2>/dev/null || true
        systemctl disable systemd-networkd.service 2>/dev/null || true
        grub-install "$target_disk"
        update-grub
    elif [[ "$os_id" == "ubuntu" ]]; then
        install openssh-server ifupdown fdisk linux-image-generic grub-pc
        systemctl enable ssh networking.service 2>/dev/null || true
        systemctl disable systemd-networkd.service 2>/dev/null || true
        grub-install "$target_disk"
        update-grub
    elif [[ "$os_id" == "centos" || "$os_id" == "rocky" || "$os_id" == "almalinux" ]]; then
        install openssh-server NetworkManager kernel grub2-pc
        systemctl enable sshd NetworkManager 2>/dev/null || true
        grub2-install "$target_disk"
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi

    if [ -d /etc/ssh/sshd_config.d ]; then
        printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-osmutation.conf
    fi
    [ -f /etc/ssh/sshd_config ] && echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -A >/dev/null 2>&1 || true
    rm -rf /x
    sync
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

function clean_old_system(){
    pkill -9 -f systemd 2>/dev/null || true
    while true; do
        local mnt
        mnt=$(mount | tac | awk '/oldroot/ {print $3; exit}')
        [ -z "$mnt" ] && break
        umount "$mnt" 2>/dev/null || break
    done
}

function main(){
    print_help
    echo -e '\e[1;32minstall requirement...\e[m'
    install_requirement

    read_lxc_template

    echo -e '\e[1;32mClean old system\e[m'
    clean_old_system

    echo -e '\e[1;32mdownloading template...\e[m'
    download_rootfs

    echo -e '\e[1;32mmigrating configuration\e[m'
    migrate_configuration oldroot
}

function make_temp_os(){
    if ! ip -4 route show default 2>/dev/null | grep -q default && ip -6 route show default 2>/dev/null | grep -q default; then
        curl -fsSLI --max-time 6 "https://raw.githubusercontent.com" >/dev/null 2>&1 || echo "nameserver 2a00:1098:2c::1" > /etc/resolv.conf
    fi

    local temp_os_url script_self
    temp_os_url='https://github.com/LloydAsp/templates/releases/download/v1.0.0/alpine-takeover.tar.gz'
    mkdir -p /x
    mount -t tmpfs tmpfs /x -o size=150M
    if [ -n "$(command -v curl)" ]; then
        curl -fsSL "$temp_os_url" | tar -C /x -xz
    elif [ -n "$(command -v wget)" ]; then
        wget -qO- "$temp_os_url" | tar -C /x -xz
    else
        install curl
        curl -fsSL "$temp_os_url" | tar -C /x -xz
    fi

    mv /x/takeover/* /x

    migrate_configuration x

    script_self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    cp "$script_self" /x/OsMutationKvm.sh
    cp "$script_self" /OsMutationKvm.sh

    cd /x || exit 1
    curl -fsSLo takeover.sh "https://raw.githubusercontent.com/${REPO}/main/takeover.sh"
    chmod u+x takeover.sh
    ./takeover.sh

    /busybox chroot . apk add bash
    /busybox chroot . env main=1 /OsMutationKvm.sh

    echo -e '\e[1;32mpost processing...\e[m'
    /busybox cp /OsMutationKvm.sh /oldroot
    /busybox chroot /oldroot apk add bash >/dev/null 2>&1 || true
    /busybox chroot /oldroot env postinstall=1 /OsMutationKvm.sh

    local reboot_ans=""
    while [[ "$reboot_ans" != 'yes' && "$reboot_ans" != 'no' ]]; do
        echo -ne "\e[1;33mreboot now? (yes/no): \e[m"
        read -r reboot_ans < /dev/tty
    done

    if [[ "$reboot_ans" == 'yes' ]]; then
        reboot -f
    fi
}

if [ -n "${main:-}" ]; then
    main
    exit 0
fi

if [ -n "${postinstall:-}" ]; then
    post_install 2>&1 | tee /run/osmutation-kvm.log
    exit 0
fi

make_temp_os 2>&1 | tee /run/osmutation-kvm.log
