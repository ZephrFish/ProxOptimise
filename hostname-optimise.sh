#!/usr/bin/env bash
###############################################################################
# hostname-optimise.sh — Unified Proxmox VE Host Performance Optimiser
#
# Merges and supersedes all prior optimisation scripts.
# Auto-detects hardware (CPU vendor, RAM, NVMe/SATA). Safe to re-run.
#
# Usage:
#   ./hostname-optimise.sh              # dry-run (default)
#   ./hostname-optimise.sh --apply      # apply all optimisations
#   ./hostname-optimise.sh --revert     # restore from backup
#   ./hostname-optimise.sh --status     # show current tuning state
###############################################################################
set -euo pipefail

# ─── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

LOG_FILE="/var/log/proxmox-optimise.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/proxmox-optimise.log"

log()  { echo -e "${GREEN}[+]${NC} $1"; echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; echo "[$(date '+%F %T')] WARN: $1" >> "$LOG_FILE"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1" >&2; echo "[$(date '+%F %T')] ERROR: $1" >> "$LOG_FILE"; }
skip() { echo -e "${GREEN}[=]${NC} $1 (already optimal)"; }
hdr()  { printf "\n${CYAN}══════════════════════════════════════════${NC}\n"; printf "${CYAN} %s${NC}\n" "$*"; printf "${CYAN}══════════════════════════════════════════${NC}\n"; }

[[ $EUID -eq 0 ]] || { err "Must run as root"; exit 1; }

MODE="${1:---dry-run}"
CHANGES=0
REBOOT_NEEDED=0

# ─── Hardware Detection ─────────────────────────────────────────────────────
HOSTNAME=$(hostname)
KERNEL=$(uname -r)
CPU_MODEL=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2}')
CPU_COUNT=$(nproc)
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/{gsub(/ /,"",$2); print $2}')
RAM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
RAM_MB=$((RAM_TOTAL_KB / 1024))
RAM_TOTAL="${RAM_MB}MB ($((RAM_MB / 1024))GB)"

IS_INTEL=false; [[ "$CPU_VENDOR" == *"Intel"* ]] && IS_INTEL=true
IS_AMD=false;   [[ "$CPU_VENDOR" == *"AMD"* ]]   && IS_AMD=true
HAS_NVME=false; ls /sys/block/nvme* &>/dev/null  && HAS_NVME=true

# Dynamic calculations
LAST_CPU=$((CPU_COUNT - 1))
ISOL_RANGE="1-${LAST_CPU}"                       # tickless range
MIN_FREE_KB=$((RAM_TOTAL_KB / 500))              # ~0.2% of RAM
[[ $MIN_FREE_KB -lt 131072 ]] && MIN_FREE_KB=131072
ZRAM_SIZE_MB=$((RAM_MB / 8))                     # ~12.5% of RAM

# ─── File Paths ─────────────────────────────────────────────────────────────
BACKUP_DIR="/root/.proxmox-optimise-backup"
SYSCTL_CONF="/etc/sysctl.d/99-proxmox-optimize.conf"
BRIDGE_CONF="/etc/sysctl.d/99-bridge-nf.conf"
UDEV_CONF="/etc/udev/rules.d/60-block-performance.rules"
LIMITS_CONF="/etc/security/limits.d/99-proxmox-optimize.conf"
SYSTEMD_LIMITS="/etc/systemd/system.conf.d/99-pve-performance.conf"
KVM_MODPROBE="/etc/modprobe.d/kvm-performance.conf"
MODULES_CONF="/etc/modules-load.d/proxmox-optimize.conf"
CPU_SERVICE="/etc/systemd/system/cpu-performance.service"
KSM_SERVICE="/etc/systemd/system/ksm-tune.service"
JOURNAL_CONF="/etc/systemd/journald.conf.d/performance.conf"
COMPACT_CRON="/etc/cron.d/proxmox-memory-compact"

###############################################################################
# Helper Functions
###############################################################################
backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local encoded; encoded=$(echo "$src" | sed 's|/|%%|g')
    [[ -f "$BACKUP_DIR/$encoded" ]] || cp "$src" "$BACKUP_DIR/$encoded"
}

write_file() {
    local dest="$1" content="$2"
    if [[ "$MODE" == "--apply" ]]; then
        backup_file "$dest"
        mkdir -p "$(dirname "$dest")"
        echo "$content" > "$dest"
        log "Wrote $dest"
    else
        info "Would write $dest"
    fi
    CHANGES=$((CHANGES + 1))
}

run_cmd() {
    local desc="$1"; shift
    if [[ "$MODE" == "--apply" ]]; then
        "$@" 2>/dev/null && log "$desc" || warn "Failed: $desc"
    else
        info "Would: $desc"
    fi
    CHANGES=$((CHANGES + 1))
}

sysfs_write() {
    local path="$1" value="$2" desc="$3"
    [[ -f "$path" ]] || return 0
    local current; current=$(cat "$path" 2>/dev/null || true)
    if [[ "$current" == "$value" ]]; then
        skip "$desc = $value"
        return 0
    fi
    if [[ "$MODE" == "--apply" ]]; then
        echo "$value" > "$path" 2>/dev/null && log "$desc: $value" || warn "Failed: $desc"
    else
        info "Would set $desc: $current -> $value"
    fi
    CHANGES=$((CHANGES + 1))
}

service_disable() {
    local svc="$1" desc="$2"
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        if [[ "$MODE" == "--apply" ]]; then
            systemctl disable --now "$svc" 2>/dev/null && log "Disabled $svc ($desc)" || true
        else
            info "Would disable: $svc ($desc)"
        fi
        CHANGES=$((CHANGES + 1))
    fi
}

###############################################################################
# --revert
###############################################################################
if [[ "$MODE" == "--revert" ]]; then
    hdr "Reverting Proxmox Optimisations"
    [[ -d "$BACKUP_DIR" ]] || { err "No backup at $BACKUP_DIR"; exit 1; }

    for f in "$BACKUP_DIR"/*; do
        target=$(basename "$f" | sed 's|%%|/|g')
        cp "$f" "$target" && log "Restored $target"
    done

    # Remove files we created that had no prior backup
    for created in "$SYSCTL_CONF" "$BRIDGE_CONF" "$UDEV_CONF" "$LIMITS_CONF" \
                   "$SYSTEMD_LIMITS" "$KVM_MODPROBE" "$MODULES_CONF" \
                   "$CPU_SERVICE" "$KSM_SERVICE" "$JOURNAL_CONF" "$COMPACT_CRON"; do
        encoded=$(echo "$created" | sed 's|/|%%|g')
        if [[ ! -f "$BACKUP_DIR/$encoded" && -f "$created" ]]; then
            rm -f "$created"
            log "Removed $created"
        fi
    done

    sysctl --system &>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log "Revert complete. Reboot recommended."
    exit 0
fi

###############################################################################
# --status
###############################################################################
if [[ "$MODE" == "--status" ]]; then
    hdr "Tuning Status — ${HOSTNAME}"
    echo ""
    printf "  %-18s %s\n" "Host:"       "$HOSTNAME"
    printf "  %-18s %s\n" "PVE:"        "$(pveversion 2>/dev/null || echo 'N/A')"
    printf "  %-18s %s\n" "Kernel:"     "$KERNEL"
    printf "  %-18s %s\n" "CPU:"        "$CPU_MODEL (${CPU_COUNT} threads)"
    printf "  %-18s %s\n" "RAM:"        "$RAM_TOTAL"
    printf "  %-18s %s\n" "Governor:"   "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
    printf "  %-18s %s\n" "THP:"        "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo 'N/A')"
    printf "  %-18s %s\n" "KSM:"        "run=$(cat /sys/kernel/mm/ksm/run 2>/dev/null), sharing=$(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo 0) pages"
    printf "  %-18s %s\n" "Swappiness:" "$(sysctl -n vm.swappiness 2>/dev/null)"
    printf "  %-18s %s\n" "TCP CC:"     "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf "  %-18s %s\n" "Conntrack:"  "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'N/A')"
    printf "  %-18s %s\n" "Boot args:"  "$(cat /proc/cmdline)"
    echo ""
    if $HAS_NVME; then
        echo "  NVMe devices:"
        for dev in /sys/block/nvme*; do
            d=$(basename "$dev")
            printf "    %-12s scheduler=%-6s nr_requests=%-5s read_ahead=%sKB\n" \
                "$d:" "$(cat "$dev/queue/scheduler" 2>/dev/null)" \
                "$(cat "$dev/queue/nr_requests" 2>/dev/null)" \
                "$(cat "$dev/queue/read_ahead_kb" 2>/dev/null)"
        done
    fi
    echo ""
    echo "  Hugepages:"
    grep -i huge /proc/meminfo 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Swap:"
    swapon --show 2>/dev/null | sed 's/^/    /'
    echo ""
    printf "  %-18s %s\n" "Running VMs:" "$(qm list 2>/dev/null | grep -c running || echo 0)"
    printf "  %-18s %s\n" "Running CTs:" "$(pct list 2>/dev/null | grep -c running || echo 0)"
    echo ""
    exit 0
fi

###############################################################################
# Main Optimisation Flow
###############################################################################
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Proxmox VE Performance Optimisation               ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Host:   %-43s ║\n" "$HOSTNAME"
printf "║  Kernel: %-43s ║\n" "$KERNEL"
printf "║  CPU:    %-43s ║\n" "$CPU_MODEL"
printf "║  Cores:  %-43s ║\n" "${CPU_COUNT} ($(lscpu | awk -F: '/Socket/{gsub(/ /,"",$2);print $2}')S/$(lscpu | awk -F: '/Core\(s\) per socket/{gsub(/ /,"",$2);print $2}')C/$(lscpu | awk -F: '/Thread\(s\) per core/{gsub(/ /,"",$2);print $2}')T)"
printf "║  RAM:    %-43s ║\n" "$RAM_TOTAL"
printf "║  Mode:   %-43s ║\n" "$MODE"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

if [[ "$MODE" == "--dry-run" ]]; then
    warn "DRY-RUN — no changes will be made. Use --apply to apply."
    echo ""
fi

###############################################################################
# 1. KERNEL BOOT PARAMETERS
###############################################################################
hdr "1. KERNEL BOOT PARAMETERS"

GRUB_FILE="/etc/default/grub"
CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | head -1 | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//;s/"$//')

DESIRED_PARAMS=(
    "quiet"
    "iommu=pt"
    "mitigations=off"
    "nowatchdog"
    "nmi_watchdog=0"
    "transparent_hugepage=madvise"
    "nohz_full=${ISOL_RANGE}"
    "rcu_nocbs=${ISOL_RANGE}"
)

if $IS_INTEL; then
    DESIRED_PARAMS+=(
        "intel_iommu=on"
        "intel_pstate=active"
        "processor.max_cstate=1"
        "intel_idle.max_cstate=0"
    )
fi

if $IS_AMD; then
    DESIRED_PARAMS+=(
        "amd_iommu=on"
        "amd_pstate=active"
        "processor.max_cstate=1"
    )
fi

NEEDS_UPDATE=false
for param in "${DESIRED_PARAMS[@]}"; do
    key="${param%%=*}"
    if ! echo "$CURRENT_CMDLINE" | grep -q "$key"; then
        NEEDS_UPDATE=true
        info "  Missing: $param"
    else
        skip "  $key"
    fi
done

if $NEEDS_UPDATE; then
    if [[ "$MODE" == "--apply" ]]; then
        backup_file "$GRUB_FILE"
        NEW="$CURRENT_CMDLINE"
        for param in "${DESIRED_PARAMS[@]}"; do
            key="${param%%=*}"
            NEW=$(echo "$NEW" | sed "s/\b${key}=[^ ]*//g" | xargs)
            NEW="$NEW $param"
        done
        NEW=$(echo "$NEW" | xargs)
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW}\"|" "$GRUB_FILE"
        update-grub 2>/dev/null
        log "GRUB updated → $NEW"
        REBOOT_NEEDED=1
    fi
    CHANGES=$((CHANGES + 1))
fi

###############################################################################
# 2. SYSCTL TUNING
###############################################################################
hdr "2. SYSCTL TUNING"

SYSCTL_CONTENT="# ═══════════════════════════════════════════════════
# Proxmox Performance Tuning — generated by hostname-optimise.sh
# Host: ${HOSTNAME} | RAM: ${RAM_TOTAL} | CPUs: ${CPU_COUNT}
# ═══════════════════════════════════════════════════

# --- Memory ---
vm.swappiness = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
vm.overcommit_memory = 1
vm.oom_kill_allocating_task = 1
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.zone_reclaim_mode = 0
vm.max_map_count = 262144
vm.watermark_boost_factor = 0
vm.compaction_proactiveness = 20

# --- Hugepages ---
# Static hugepages disabled — THP madvise handles QEMU automatically.
# To use static hugepages, VMs must be configured with hugepages=1024.
# vm.nr_hugepages = 0

# --- Network: Core ---
net.core.default_qdisc = fq
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 2097152
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# --- Network: TCP ---
net.ipv4.ip_forward = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.ip_local_port_range = 1024 65535

# --- Network: Conntrack ---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# --- Network: IPv6 ---
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# --- File descriptors / inotify ---
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.aio-max-nr = 1048576

# --- Kernel ---
kernel.pid_max = 4194304
kernel.sched_autogroup_enabled = 0
kernel.sched_migration_cost_ns = 5000000
kernel.numa_balancing = 0
kernel.nmi_watchdog = 0
kernel.watchdog = 0"

write_file "$SYSCTL_CONF" "$SYSCTL_CONTENT"

# Clean up any old conflicting sysctl files
for old in /etc/sysctl.d/99-proxmox-optimizations.conf \
           /etc/sysctl.d/99-proxmox-performance.conf; do
    if [[ -f "$old" && "$old" != "$SYSCTL_CONF" ]]; then
        if [[ "$MODE" == "--apply" ]]; then
            backup_file "$old"
            rm -f "$old"
            log "Removed stale config: $old"
        else
            info "Would remove stale: $old"
        fi
    fi
done

# Load required modules & apply
if [[ "$MODE" == "--apply" ]]; then
    modprobe tcp_bbr      2>/dev/null || warn "tcp_bbr not available"
    modprobe nf_conntrack 2>/dev/null || true
    sysctl --system > /dev/null 2>&1
    log "Sysctl applied"
fi

###############################################################################
# 3. NVMe / BLOCK I/O TUNING
###############################################################################
hdr "3. NVMe / BLOCK I/O TUNING"

# NVMe devices
for dev in /sys/block/nvme*; do
    [[ -d "$dev" ]] || continue
    devname=$(basename "$dev")
    sysfs_write "$dev/queue/scheduler"      "none" "$devname scheduler"
    # Use current nr_requests — kernel already caps at controller max (typically 1023 for NVMe)
    max_nr=$(cat "$dev/queue/nr_requests" 2>/dev/null || echo 1023)
    sysfs_write "$dev/queue/nr_requests"    "$max_nr" "$devname nr_requests"
    sysfs_write "$dev/queue/read_ahead_kb"  "64"   "$devname read_ahead_kb"
    sysfs_write "$dev/queue/rq_affinity"    "2"    "$devname rq_affinity"
    sysfs_write "$dev/queue/add_random"     "0"    "$devname add_random"
done

# SATA/SAS disks
for dev in /sys/block/sd*; do
    [[ -d "$dev" ]] || continue
    devname=$(basename "$dev")
    ROTATIONAL=$(cat "$dev/queue/rotational" 2>/dev/null || echo 1)
    if [[ "$ROTATIONAL" -eq 0 ]]; then
        sysfs_write "$dev/queue/scheduler"     "mq-deadline" "$devname scheduler"
        sysfs_write "$dev/queue/read_ahead_kb" "64"          "$devname read_ahead_kb"
        sysfs_write "$dev/queue/nr_requests"   "256"         "$devname nr_requests"
    else
        sysfs_write "$dev/queue/scheduler"     "mq-deadline" "$devname scheduler"
        sysfs_write "$dev/queue/read_ahead_kb" "256"         "$devname read_ahead_kb"
        sysfs_write "$dev/queue/nr_requests"   "128"         "$devname nr_requests"
    fi
done

# Persist via udev
UDEV_CONTENT='# Block device performance tuning for Proxmox VE
# NVMe: none scheduler, max queue depth (1023 is kernel cap for most NVMe controllers)
ACTION=="add|change", KERNEL=="nvme*n*", ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023", ATTR{queue/read_ahead_kb}="64", ATTR{queue/rq_affinity}="2", ATTR{queue/add_random}="0"
# SATA SSD: mq-deadline
ACTION=="add|change", KERNEL=="sd*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="64", ATTR{queue/nr_requests}="256"
# SATA HDD: mq-deadline with higher readahead
ACTION=="add|change", KERNEL=="sd*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="256", ATTR{queue/nr_requests}="128"'

write_file "$UDEV_CONF" "$UDEV_CONTENT"

if [[ "$MODE" == "--apply" ]]; then
    udevadm control --reload-rules 2>/dev/null || true
fi

###############################################################################
# 4. CPU PERFORMANCE
###############################################################################
hdr "4. CPU PERFORMANCE"

for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    sysfs_write "$gov" "performance" "CPU governor ($(basename $(dirname $(dirname "$gov"))))"
done

# Intel-specific
if $IS_INTEL; then
    sysfs_write /sys/devices/system/cpu/intel_pstate/no_turbo "0" "Intel Turbo Boost (0=on)"
    sysfs_write /sys/devices/system/cpu/intel_pstate/min_perf_pct "100" "Intel min_perf_pct"
fi

# AMD-specific
if $IS_AMD; then
    sysfs_write /sys/devices/system/cpu/cpufreq/boost "1" "AMD Boost"
fi

# Persist CPU governor via systemd
CPU_SVC_CONTENT="[Unit]
Description=Set CPU governor to performance — ${HOSTNAME}
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \"\$g\" 2>/dev/null; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

write_file "$CPU_SERVICE" "$CPU_SVC_CONTENT"

if [[ "$MODE" == "--apply" ]]; then
    systemctl daemon-reload
    systemctl enable cpu-performance.service --quiet 2>/dev/null || true
fi

# Disable watchdog interrupts
sysfs_write /proc/sys/kernel/nmi_watchdog "0" "NMI watchdog"
sysfs_write /proc/sys/kernel/watchdog     "0" "Kernel watchdog"

###############################################################################
# 5. TRANSPARENT HUGEPAGES
###############################################################################
hdr "5. TRANSPARENT HUGEPAGES"

sysfs_write /sys/kernel/mm/transparent_hugepage/enabled "madvise" "THP enabled"
sysfs_write /sys/kernel/mm/transparent_hugepage/defrag  "madvise" "THP defrag"

###############################################################################
# 6. KSM (Kernel Same-page Merging)
###############################################################################
hdr "6. KSM (Kernel Same-page Merging)"

sysfs_write /sys/kernel/mm/ksm/run             "1"    "KSM"
sysfs_write /sys/kernel/mm/ksm/pages_to_scan   "1000" "KSM pages_to_scan"
sysfs_write /sys/kernel/mm/ksm/sleep_millisecs "20"   "KSM sleep_millisecs"

KSM_SVC_CONTENT="[Unit]
Description=KSM tuning for Proxmox
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 1 > /sys/kernel/mm/ksm/run; echo 1000 > /sys/kernel/mm/ksm/pages_to_scan; echo 20 > /sys/kernel/mm/ksm/sleep_millisecs'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"

write_file "$KSM_SERVICE" "$KSM_SVC_CONTENT"

if [[ "$MODE" == "--apply" ]]; then
    systemctl daemon-reload
    systemctl enable ksm-tune.service --quiet 2>/dev/null || true
fi

###############################################################################
# 7. KVM MODULE TUNING
###############################################################################
hdr "7. KVM MODULE TUNING"

if $IS_INTEL; then
    KVM_CONTENT="# KVM performance tuning (Intel)
options kvm ignore_msrs=1
options kvm_intel nested=1
options kvm_intel enable_apicv=1
options kvm_intel ept=1
options kvm_intel flexpriority=1
options kvm_intel vpid=1
options kvm_intel unrestricted_guest=1"
    write_file "$KVM_MODPROBE" "$KVM_CONTENT"
    REBOOT_NEEDED=1
elif $IS_AMD; then
    KVM_CONTENT="# KVM performance tuning (AMD)
options kvm ignore_msrs=1
options kvm_amd nested=1
options kvm_amd avic=1
options kvm_amd npt=1"
    write_file "$KVM_MODPROBE" "$KVM_CONTENT"
    REBOOT_NEEDED=1
fi

###############################################################################
# 8. SYSTEM LIMITS
###############################################################################
hdr "8. SYSTEM LIMITS"

LIMITS_CONTENT="*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    nproc     unlimited
*    hard    nproc     unlimited
*    soft    memlock   unlimited
*    hard    memlock   unlimited
root soft    nofile    1048576
root hard    nofile    1048576
root soft    memlock   unlimited
root hard    memlock   unlimited"

write_file "$LIMITS_CONF" "$LIMITS_CONTENT"

SYSTEMD_LIM="[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=131072"

write_file "$SYSTEMD_LIMITS" "$SYSTEMD_LIM"

###############################################################################
# 9. KERNEL MODULES
###############################################################################
hdr "9. KERNEL MODULES"

MODULES_CONTENT="tcp_bbr
vhost_net
vhost_vsock
nf_conntrack
br_netfilter"

write_file "$MODULES_CONF" "$MODULES_CONTENT"

if [[ "$MODE" == "--apply" ]]; then
    modprobe vhost_net    2>/dev/null || true
    modprobe vhost_vsock  2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    log "Modules loaded: vhost_net, vhost_vsock, br_netfilter"
fi

###############################################################################
# 10. NETWORK BRIDGE TUNING
###############################################################################
hdr "10. NETWORK BRIDGE TUNING"

BRIDGE_CONTENT="net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0"

write_file "$BRIDGE_CONF" "$BRIDGE_CONTENT"

if [[ "$MODE" == "--apply" ]]; then
    sysctl -p "$BRIDGE_CONF" > /dev/null 2>&1 || true
fi

###############################################################################
# 11. IRQBALANCE
###############################################################################
hdr "11. IRQBALANCE"

if command -v irqbalance &>/dev/null; then
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        skip "irqbalance running"
    elif [[ "$MODE" == "--apply" ]]; then
        systemctl enable --now irqbalance 2>/dev/null || true
        log "irqbalance enabled"
        CHANGES=$((CHANGES + 1))
    else
        info "Would enable irqbalance"
        CHANGES=$((CHANGES + 1))
    fi
else
    if [[ "$MODE" == "--apply" ]]; then
        apt-get install -y irqbalance &>/dev/null && \
            systemctl enable --now irqbalance 2>/dev/null && \
            log "irqbalance installed and started" || \
            warn "irqbalance: could not install"
    else
        info "Would install and enable irqbalance"
    fi
    CHANGES=$((CHANGES + 1))
fi

###############################################################################
# 12. DISABLE UNNECESSARY SERVICES
###############################################################################
hdr "12. DISABLE UNNECESSARY SERVICES"

service_disable "fwupd.service"            "Firmware update daemon"
service_disable "fwupd-refresh.timer"      "Firmware update refresh"
service_disable "ModemManager.service"     "Modem manager"
service_disable "avahi-daemon.service"     "mDNS / Avahi"
service_disable "bluetooth.service"        "Bluetooth"
service_disable "apt-daily.timer"          "Auto apt update"
service_disable "apt-daily-upgrade.timer"  "Auto apt upgrade"
service_disable "man-db.timer"             "Man page indexing"
service_disable "e2scrub_all.timer"        "ext4 scrub"
service_disable "unattended-upgrades.service" "Unattended upgrades"

###############################################################################
# 13. LVM THIN-POOL & TRIM
###############################################################################
hdr "13. LVM THIN-POOL & TRIM"

LVM_CONF="/etc/lvm/lvm.conf"
if [[ -f "$LVM_CONF" ]]; then
    if [[ "$MODE" == "--apply" ]]; then
        backup_file "$LVM_CONF"
        if grep -q "thin_pool_autoextend_threshold" "$LVM_CONF"; then
            sed -i 's/.*thin_pool_autoextend_threshold.*/\tthin_pool_autoextend_threshold = 80/' "$LVM_CONF"
            sed -i 's/.*thin_pool_autoextend_percent.*/\tthin_pool_autoextend_percent = 20/' "$LVM_CONF"
            log "LVM thin-pool autoextend: 80% threshold, 20% growth"
        fi
        if grep -q "issue_discards = 0" "$LVM_CONF"; then
            sed -i 's/issue_discards = 0/issue_discards = 1/' "$LVM_CONF"
            log "LVM issue_discards enabled"
        fi
    else
        info "Would configure LVM thin-pool autoextend + discards"
    fi
    CHANGES=$((CHANGES + 1))
fi

if systemctl is-enabled --quiet fstrim.timer 2>/dev/null; then
    skip "fstrim.timer"
else
    run_cmd "Enable weekly fstrim" systemctl enable --now fstrim.timer
fi

###############################################################################
# 14. JOURNALD TUNING
###############################################################################
hdr "14. JOURNALD TUNING"

JOURNAL_CONTENT="[Journal]
Storage=volatile
Compress=yes
SystemMaxUse=256M
RuntimeMaxUse=256M
RateLimitIntervalSec=30s
RateLimitBurst=10000"

write_file "$JOURNAL_CONF" "$JOURNAL_CONTENT"

if [[ "$MODE" == "--apply" ]]; then
    systemctl restart systemd-journald 2>/dev/null || true
fi

###############################################################################
# 15. ZRAM SWAP
###############################################################################
hdr "15. ZRAM SWAP"

if [[ "$MODE" == "--apply" ]]; then
    command -v zramctl &>/dev/null || apt-get install -y zram-tools 2>/dev/null || warn "Could not install zram-tools"
    modprobe zram 2>/dev/null || true

    if ! swapon --show | grep -q zram; then
        if [[ -e /sys/block/zram0 ]]; then
            echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        fi
        echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null \
            || echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        echo "${ZRAM_SIZE_MB}M" > /sys/block/zram0/disksize 2>/dev/null || true
        mkswap /dev/zram0 &>/dev/null || true
        swapon -p 100 /dev/zram0 2>/dev/null || true
        log "zram0: ${ZRAM_SIZE_MB}MB (zstd) at priority 100"
    else
        skip "zram swap already active"
    fi

    # Lower priority of disk-backed swap
    for SWAP_DEV in $(swapon --show=NAME,TYPE --noheadings | awk '/partition|file/{print $1}'); do
        [[ "$SWAP_DEV" == *zram* ]] && continue
        swapoff "$SWAP_DEV" 2>/dev/null && swapon -p 10 "$SWAP_DEV" 2>/dev/null || true
        log "Deprioritised disk swap: $SWAP_DEV → priority 10"
    done
else
    info "Would configure zram swap (${ZRAM_SIZE_MB}MB, zstd compression)"
fi
CHANGES=$((CHANGES + 1))

###############################################################################
# 16. MEMORY COMPACTION CRON
###############################################################################
hdr "16. MEMORY COMPACTION CRON"

CRON_CONTENT="# Compact memory every 6 hours to reduce fragmentation for hugepages
0 */6 * * * root echo 1 > /proc/sys/vm/compact_memory 2>/dev/null; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null"

write_file "$COMPACT_CRON" "$CRON_CONTENT"

if [[ "$MODE" == "--apply" ]]; then
    chmod 644 "$COMPACT_CRON"
fi

###############################################################################
# FINALISE
###############################################################################
if [[ "$MODE" == "--apply" ]]; then
    systemctl daemon-reload 2>/dev/null || true
fi

###############################################################################
# SUMMARY
###############################################################################
hdr "SUMMARY — ${HOSTNAME}"

echo ""
printf "  %-24s %s\n" "GRUB kernel params:" "iommu=pt, mitigations=off, nowatchdog, tickless ${ISOL_RANGE}"
$IS_INTEL && printf "  %-24s %s\n" "" "intel_pstate=active, C-state capped"
$IS_AMD   && printf "  %-24s %s\n" "" "amd_pstate=active, C-state capped"
printf "  %-24s %s\n" "Sysctl:" "swappiness=1, dirty=15/5, BBR, buffers=64MB, THP=madvise"
printf "  %-24s %s\n" "Block I/O:" "NVMe: none/max-depth/64KB | SATA: mq-deadline"
printf "  %-24s %s\n" "CPU:" "governor=performance, turbo=on, watchdog=off"
if $IS_INTEL; then
    printf "  %-24s %s\n" "KVM:" "nested, apicv, ept, vpid, unrestricted_guest"
elif $IS_AMD; then
    printf "  %-24s %s\n" "KVM:" "nested, avic, npt"
fi
printf "  %-24s %s\n" "Memory:" "KSM=on, THP=madvise, zram=${ZRAM_SIZE_MB}MB"
printf "  %-24s %s\n" "Network:" "bridge-nf=off, conntrack=1M, fastopen=3"
printf "  %-24s %s\n" "LVM:" "autoextend=80/20, TRIM=on, fstrim=weekly"
printf "  %-24s %s\n" "Services:" "irqbalance=on, fwupd/apt-timers/avahi=off"
printf "  %-24s %s\n" "Journald:" "volatile, 256M"
printf "  %-24s %s\n" "Limits:" "nofile=1M, memlock=unlimited"
echo ""

if [[ "$MODE" == "--apply" ]]; then
    echo -e "${GREEN}${CHANGES} optimisations applied.${NC}"
    echo ""
    echo "  Backup:   $BACKUP_DIR"
    echo "  Log:      $LOG_FILE"
    echo "  Revert:   $0 --revert"
    echo "  Status:   $0 --status"
    echo ""

    # Status snapshot
    info "Swap:"
    swapon --show
    echo ""

    if [[ $REBOOT_NEEDED -eq 1 ]]; then
        warn "REBOOT REQUIRED for GRUB and KVM module changes."
        warn "After reboot, verify with: cat /proc/cmdline"
    fi
else
    echo -e "${YELLOW}${CHANGES} changes identified (dry run).${NC}"
    echo ""
    echo "  To apply:  $0 --apply"
    echo "  To revert: $0 --revert"
    echo "  Status:    $0 --status"
    echo ""
fi

echo ""
info "Optimisation complete for ${HOSTNAME}."
