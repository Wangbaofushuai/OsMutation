# OsMutation

Reinstall any OpenVZ / LXC VPS to the latest **Alpine**, **Debian**, **Ubuntu LTS**, **CentOS Stream**, **Rocky Linux**, or **AlmaLinux** (`amd64` & `arm64`).

> Forked and updated from [LloydAsp/OsMutation](https://github.com/LloydAsp/OsMutation) with automated weekly container image syncing, unified OpenVZ/LXC modern templates, OpenVZ `venet0` & old-kernel compatibility protection, and bug fixes.

## Supported Systems (Auto-Synced Weekly)

Images are automatically synced weekly from [LinuxContainers](https://images.linuxcontainers.org) via GitHub Actions (`.github/workflows/sync.yml`):

- **Alpine Linux**: Latest stable releases (e.g. `3.21`, `3.22`, `3.23`, `3.24+`)
- **Debian**: `12 (Bookworm)`, `13 (Trixie)`
- **Ubuntu LTS**: `22.04 (Jammy)`, `24.04 (Noble)`, `26.04 (Resolute)`
- **CentOS Stream**: `9-Stream`, `10-Stream`
- **Rocky Linux**: `9`, `10`
- **AlmaLinux**: `9`, `10`
- **Legacy OpenVZ 7 Fallback (`Option 0`)**: Retains access to the original `LloydAsp/OsMutation@v0.0.1` OpenVZ 7 template archive for older hosts.

## Usage / 使用方法

### Standard VPS / 常规硬盘 VPS
```bash
wget -qO OsMutation.sh https://raw.githubusercontent.com/Wangbaofushuai/OsMutation/main/OsMutation.sh && chmod u+x OsMutation.sh && ./OsMutation.sh
```
or
```bash
curl -fsSLo OsMutation.sh https://raw.githubusercontent.com/Wangbaofushuai/OsMutation/main/OsMutation.sh && chmod u+x OsMutation.sh && ./OsMutation.sh
```

### Small Disk VPS (< 1 GiB) / 小硬盘 NAT 小鸡（如 128MB 内存 / 小于 1GB 硬盘）
```bash
wget -qO OsMutationTight.sh https://raw.githubusercontent.com/Wangbaofushuai/OsMutation/main/OsMutationTight.sh && chmod u+x OsMutationTight.sh && ./OsMutationTight.sh
```

## OpenVZ 7 Compatibility Notice / OpenVZ 7 兼容性说明

- **Warning**: A fresh OS will be installed and **all existing data will be wiped**. Back up important files first! Root password, `/root/.ssh`, custom SSH port, and network configuration (`eth0` / `venet0`) are preserved automatically.
- **OpenVZ 7 Old Kernel (`3.10.x`)**:
  - **Alpine 3.21 ~ 3.24** (OpenRC + musl) works reliably on OpenVZ 7 and low-RAM NAT VPS.
  - **Debian 12 (Bookworm)** and **Ubuntu 22.04 (Jammy)** generally work on OpenVZ 7.
  - **Debian 13 (Trixie)**, **Ubuntu 24.04+**, and **EL 10 (CentOS/Rocky/Alma 10)** ship newer `systemd` versions requiring **cgroup v2**, which may fail to boot on OpenVZ 7 (`3.10.x` kernel). The script will detect old OpenVZ kernels automatically and warn you before proceeding.
  - On OpenVZ, you can also enter `0` at the OS selection menu to switch to the legacy `v0.0.1` OpenVZ 7 template archive.
- OpenVZ 6 is not supported.

## What's Improved in This Fork

- **Unified Modern Templates for OpenVZ & LXC**: Both OpenVZ and LXC now access the latest auto-synced LinuxContainers images (`amd64` / `arm64`), while keeping legacy `v0.0.1` OpenVZ templates available as option `0`.
- **Upgraded GitHub Actions Workflow**: Upgraded to `softprops/action-gh-release@v2`, added `SHA256SUMS.txt` verification, expanded distro support (Alpine, Debian, Ubuntu LTS, CentOS Stream, Rocky, AlmaLinux), and automatic cleanup of old `LXC-*` releases (keeps latest 3).
- **Network & SSH Reliability**:
  - Fixed OpenVZ `venet0` IP detection (no longer depends on `brd` keyword) and preserves existing `/etc/network/interfaces`.
  - Fixed SSH `PermitRootLogin yes` and `PasswordAuthentication yes` via `/etc/ssh/sshd_config.d/00-osmutation.conf` (first-match-wins for modern OpenSSH) and preserved custom SSH ports.
  - Added NetworkManager static connection generation for CentOS Stream / Rocky / AlmaLinux.
  - Fixed IPv6-only DNS detection (no longer relies on ICMP `ping`, which is often blocked on NAT VPS).
- **Safety & Bug Fixes**:
  - Fixed `OsMutationTight.sh` typos (`cp -a cp -a`, hardcoded filename `OsMutation.sh`, missing `< /dev/tty`), upgraded temporary chroot to fetch the latest Alpine minirootfs dynamically for both `x86_64` and `aarch64`.
  - Auto-detects `.tar.xz` / `.tar.gz` / `.tar.zst` compression, validates download/extraction before wiping the old root, and strictly validates menu input ranges.

## How Does This Work

OpenVZ and LXC are container virtualization technologies where the host OS kernel is shared across containers. Replacing the operating system works by downloading the new userspace root filesystem, migrating essential credentials and network configuration, swapping root files via chroot, and installing SSH/networking services.

## Credits & License

- Original project: [LloydAsp/OsMutation](https://github.com/LloydAsp/OsMutation)
- Originally inspired by: https://gist.github.com/trimsj/c1fefd650b5f49ceb8f3efc1b6a1404d
- License: GPLv3
