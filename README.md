# OsMutation

Reinstall any OpenVZ / LXC VPS to the latest **Alpine**, **Debian**, **Ubuntu LTS**, **CentOS Stream**, **Rocky Linux**, or **AlmaLinux** (`amd64` & `arm64`).

> Forked and modernized from [LloydAsp/OsMutation](https://github.com/LloydAsp/OsMutation) with automated weekly container image discovery, SHA256 integrity checks, cross-distro password compatibility (`yescrypt` → Alpine) protection, non-interactive CLI options, and `ShellCheck` CI.

## Supported Systems (Auto-Discovered & Synced Weekly)

Images are automatically discovered from upstream official metadata and synced weekly from [LinuxContainers](https://images.linuxcontainers.org) via GitHub Actions (`.github/workflows/sync.yml`), persisting `images.json` (which avoids GitHub's 60-day schedule auto-disable and bypasses GitHub API rate limits):

- **Alpine Linux**: All current stable releases (`3.21+`, automatically tracks `3.25`, `3.26`...)
- **Debian**: Automatically tracks official `oldstable` & `stable` releases via `deb.debian.org` (currently `12 Bookworm` & `13 Trixie`; automatically picks up `14 Forky` once released as stable)
- **Ubuntu LTS**: Automatically tracks all supported LTS releases via `changelogs.ubuntu.com/meta-release-lts` (currently `22.04`, `24.04`, `26.04`; automatically picks up `28.04+`)
- **CentOS Stream**: All major releases `>= 9` (`9-Stream`, `10-Stream`, future `11-Stream`...)
- **Rocky Linux**: All major releases `>= 9` (`9`, `10`, future `11`...)
- **AlmaLinux**: All major releases `>= 9` (`9`, `10`, future `11`...)
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

### CLI Options / 命令行参数（支持非交互重装）
Both `OsMutation.sh` and `OsMutationTight.sh` support CLI flags:

```bash
# 仅列出当前架构可用的镜像与体积（只读，不做任何修改）
./OsMutation.sh --list

# 非交互重装为 Alpine 3.24 并指定新 root 密码（自动确认并重启）
./OsMutation.sh --os alpine-3.24 --password 'YourStrongPassword' --yes --reboot

# 指定自定义 SSH 端口且重装后暂不重启
./OsMutation.sh --os debian-12 --ssh-port 2222 --no-reboot
```

| Flag | Description |
| --- | --- |
| `--list` | List available OS images for current arch and exit |
| `--os <name>` | Exact or unique partial OS name (e.g. `alpine-3.24`, `debian-12`) |
| `-p, --password <pwd>` | Set a new root password for the reinstalled system |
| `--ssh-port <port>` | Override SSH port (default: preserves existing custom port or 22) |
| `-y, --yes` | Skip final reinstall confirmation prompt |
| `--force` | Bypass OpenVZ old-kernel cgroup v2 warning prompt |
| `--reboot` / `--no-reboot` | Automatically reboot or skip reboot prompt when `sshd` check passes |
| `-h, --help` | Print CLI help |

## OpenVZ 7 Compatibility Notice / OpenVZ 7 兼容性说明

- **Warning**: A fresh OS will be installed and **all existing data will be wiped**. Back up important files first! Root password, `/root/.ssh`, custom SSH port, and network configuration (`eth0` / `venet0` / `onlink` routes / IPv6) are preserved automatically.
- **Debian/Ubuntu → Alpine Password Protection**: Debian 12/13 and Ubuntu 22.04+ store root passwords using `yescrypt` (`$y$`), which Alpine (`musl libc`) cannot verify. The script automatically detects this before wiping and prompts you to set a compatible root password (or pass `--password`), preventing SSH lockouts.
- **OpenVZ 7 Old Kernel (`3.10.x`)**:
  - **Alpine 3.x** (OpenRC + musl) works reliably on OpenVZ 7 and low-RAM NAT VPS.
  - **Debian 12 (Bookworm)** and **Ubuntu 22.04 (Jammy)** generally work on OpenVZ 7.
  - **Debian 13+**, **Ubuntu 24.04+**, and **EL 10+** ship newer `systemd` versions requiring **cgroup v2**, which may fail to boot on OpenVZ 7 (`3.10.x` kernel). The script detects old OpenVZ kernels automatically and warns before proceeding.
  - On OpenVZ, enter `0` at the OS selection menu to switch to the legacy `v0.0.1` OpenVZ 7 template archive.
- OpenVZ 6 is not supported.

## Key Engineering Improvements in This Fork

- **Safety & Anti-Brick Engineering**:
  - **Safe RootFS Replacement**: Clears immutable attributes (`chattr -i`), uses POSIX `/bin/sh` inside chroot, merges busy bind-mounted directories (such as host-mounted `/etc/hosts` or `/etc/resolv.conf`) safely without nesting `/etc/etc`, and renames core runtime directories (`bin/lib/usr`) atomically in a single `exec mv` call.
  - **Fixed `OsMutationTight.sh` Chroot Environment**: Bind-mounts `/dev`, `/dev/pts`, `/proc`, `/sys` with `trap` auto-cleanup, uses anchored `tar --exclude`, and validates chroot completion via sentinel file before running `post_install`.
  - **Integrity & Pre-Reboot Gates**: Verifies `SHA256` checksums against `images.json`, checks free disk space before extraction, requires explicit `'yes'` confirmation, and enforces `sshd` binary + `sshd -t` validation before rebooting.
- **Network & SSH Reliability**:
  - Fixes IPv6-only NAT64 DNS **before** package installation (without relying on ICMP `ping`).
  - Fixes OpenVZ `venet0` (including IPv6-only `venet0`), preserves `onlink` `/32` routes, strips Alpine-only `hostname` lines when migrating to Debian/Ubuntu, enables `networking.service`, and generates NetworkManager profiles for EL 9/10.
  - Writes `/etc/ssh/sshd_config.d/00-osmutation.conf` (first-match-wins for modern OpenSSH) and preserves custom SSH ports.
- **CI & Automated Sync**:
  - `.github/workflows/sync.yml`: Concurrency guard, upstream build-path deduplication with 45-day keep-alive refresh, per-image retry & fault tolerance, `SHA256SUMS.txt`, automatic cleanup keeping latest 3 `LXC-*` releases, and `images.json` auto-commit.
  - `.github/workflows/lint.yml`: Automatic `bash -n`, `ShellCheck`, inline Python compile, `images.json` schema validation, and CLI smoke tests on every push/PR.

## Credits & License

- Original project: [LloydAsp/OsMutation](https://github.com/LloydAsp/OsMutation)
- Originally inspired by: https://gist.github.com/trimsj/c1fefd650b5f49ceb8f3efc1b6a1404d
- License: GPLv3
