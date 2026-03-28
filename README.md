# ProxOptimise

Unified Proxmox VE host performance optimisation script. Auto-detects hardware (CPU vendor, RAM, NVMe/SATA) and applies comprehensive tuning across kernel parameters, sysctl, block I/O, CPU governors, memory management, networking, and services.

## Features

- **Hardware-aware** — detects Intel/AMD, core count, RAM size, NVMe/SATA and tunes accordingly
- **Safe by default** — dry-run mode shows all changes before applying
- **Reversible** — backs up every modified file; full revert with one command
- **Idempotent** — skips settings already at optimal values, safe to re-run

### What it tunes

| Area | Details |
|------|---------|
| **Kernel boot** | `iommu=pt`, `mitigations=off`, watchdog disable, tickless cores, THP madvise |
| **CPU** | Performance governor, turbo boost, Intel P-state / AMD P-state |
| **Sysctl** | Low swappiness, dirty page tuning, BBR congestion control, 64MB TCP buffers, conntrack 1M |
| **Block I/O** | NVMe: `none` scheduler, max queue depth, low readahead · SATA SSD/HDD: `mq-deadline` |
| **Memory** | THP madvise, KSM enabled, zram swap (zstd), periodic compaction cron |
| **KVM** | Nested virtualisation, APICv/AVIC, EPT/NPT, VPID |
| **Network** | Bridge netfilter bypass, IPv4/IPv6 forwarding, TCP fastopen |
| **Services** | Disables fwupd, avahi, bluetooth, apt timers, modem manager; enables irqbalance and fstrim |
| **Limits** | 1M file descriptors, unlimited memlock, systemd task limits |
| **Journald** | Volatile storage, 256M cap, rate limiting |
| **LVM** | Thin-pool autoextend (80/20), TRIM/discard enabled |

## Usage

```bash
# Preview changes (default)
./hostname-optimise.sh

# Apply all optimisations
./hostname-optimise.sh --apply

# Revert to backed-up configuration
./hostname-optimise.sh --revert

# Show current tuning state
./hostname-optimise.sh --status
```

Requires root. Backups are stored in `/root/.proxmox-optimise-backup/`.

## Requirements

- Proxmox VE (Debian-based)
- Root access
- GRUB bootloader

A reboot is required after the first `--apply` for GRUB and KVM module changes to take effect.

## License

MIT
