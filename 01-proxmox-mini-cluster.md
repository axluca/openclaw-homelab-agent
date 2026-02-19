# Building a Mini PC Proxmox Cluster: From Single Node to Four-Node Homelab

*How I went from one aging Proxmox box to a proper four-node cluster using affordable mini PCs — and what I learned the hard way.*

---

I had a single Proxmox node sitting under my desk for over a year. It ran fine. One box, one brain, one point of failure. Every time I wanted to work on the hypervisor itself — update packages, test a config change, migrate a VM — I had to shut everything down or just hold my breath.

The fix was obvious: build a cluster. But I didn't want rack servers, noise, or a power bill. I wanted something quiet, efficient, and small enough to live in a closet. Mini PCs turned out to be the answer.

## The Hardware

I bought three identical mini PCs — the kind sold by a half-dozen manufacturers under names like Beelink, Minisforum, or TRIGKEY. The specs that mattered:

- **Intel N-series or 12th-gen Core i5** — full VT-x and VT-d support (you'll want this for PCI passthrough later)
- **16 GB DDR4 RAM** — dual-channel, soldered in most models; check before you buy
- **Fast NVMe SSD** — I spec'd one node at 1 TB and the other two at 256 GB

The 1 TB unit becomes your "shock absorber": migration staging, ISOs, snapshots, local VM disks when you need fast temporary storage. The 256 GB units are compute nodes. That asymmetry is intentional.

**Pricing** at the time of writing: roughly €140–180 per unit at 16 GB/256 GB, plus €40 more for the 1 TB model. Total cluster hardware: under €600.

Combined with an existing Proxmox node (my original box, `pve-1`), I ended up with a four-node cluster: `pve-1`, `pve-2`, `pve-3`, and `pve-4`.

## Proxmox Install: Get This Right First

Install the same Proxmox version across every node before forming the cluster. I used **Proxmox VE 9.1** (kernel 6.17 PVE). Setting it up from the ISO is straightforward, but a few things catch people off guard:

**Set a static IP and a proper hostname during install.** You cannot change the IP without re-joining the cluster later. Write these down before you touch the installer:

| Node | IP | Hostname |
|------|-----|----------|
| pve-1 | 192.168.1.101 | pve-1|
| pve-2 | 192.168.1.102 | pve-2 |
| pve-3 | 192.168.1.103 | pve-3 |

**After install, immediately:**

```bash
apt update && apt dist-upgrade -y
reboot
```

Then add the no-subscription repo and disable the enterprise/Ceph repos:

```bash
# /etc/apt/sources.list.d/ — rename enterprise sources to .disabled
mv /etc/apt/sources.list.d/pve-enterprise.list \
   /etc/apt/sources.list.d/pve-enterprise.list.disabled
mv /etc/apt/sources.list.d/ceph.list \
   /etc/apt/sources.list.d/ceph.list.disabled

# Add community repo
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list

apt update && apt dist-upgrade -y
```

Repeat on all nodes. Make sure `timedatectl` shows the same NTP status everywhere. Time drift causes bizarre cluster issues.

## Network Consistency Is Non-Negotiable

Before you form the cluster, verify that every node has:

- **Same bridge name:** `vmbr0` on all nodes, same physical NIC underneath
- **Same MTU** (default 1500 unless you've changed it everywhere)
- **Proper hostname resolution:** every node's `/etc/hosts` must resolve all other node hostnames to their LAN IPs

`/etc/hosts` on each node should look like:

```
127.0.0.1       localhost
192.168.1.101   pve-1
192.168.1.102   pve-2
192.168.1.103   pve-3
192.168.1.104   pve-4
```

This sounds obvious. It will bite you if you skip it. Migration between nodes that can't resolve each other's hostnames fails silently at the worst possible moment.

## Forming the Cluster

On the node you designate as cluster creator (I used `pve-1`):

```bash
pvecm create homelab-pve
```

Then on each other node:

```bash
pvecm add 192.168.1.101
```

Verify cluster health after each join:

```bash
pvecm status
```

Look for `Quorum information — Quorum providers: corosync_votequorum`. All nodes should show `online`. Watch the quorum vote count — a 4-node cluster needs 3 votes to operate, so losing two nodes simultaneously will cause a split-brain situation. Plan accordingly.

**Watch out:** joining an existing Proxmox node that already has containers and VMs will **wipe `/etc/pve`** on that node during the join. The containers still exist on disk — their configs don't. I lost my LXC 100, VM 101, and LXC 203 configs this way when I added `pve-4`. Lesson: export VMA backups of everything before adding any non-fresh node to a cluster.

## NFS Shared Storage: The Synology NFS Trap

I use an old Synology as NFS backup storage that I already have. Getting the NFS export right took two attempts. You could use other products or even a cloud service, but I do recommend having backup in place!

**NAS NFS settings that work with Proxmox:**

1. Enable NFS service (for Synology): Control Panel → File Services → NFS → Enable NFS service
2. Create shared folder, then: **Edit shared folder → NFS Permissions**
   - IP: add each node **individually** (not as a subnet — Proxmox NFS checks don't always match subnet rules)
   - Privilege: Read/Write
   - Squash: **No mapping** (required so Proxmox can write backup files as root)
   - Security: `sys`
   - Enable asynchronous: ON

On the Proxmox side, add the NFS storage in Datacenter → Storage:

- **ID:** `nas-backups`
- **NAS Server:** `192.168.1.150`
- **Export:** `/volume1/Proxmox_Backups`
- **Content:** Backup, Disk image, ISO image, Container template

Test immediately:

```bash
pvesm list nas-backups
```

If it hangs, it's usually the NAS (Synology in my case) NFS allowed IP list. If it fails with a permissions error, it's the squash setting.

## BIOS Hacks for VT-x and VT-d

Mini PCs explecially the old and chip ones ship with VT-x (hardware virtualization) enabled but VT-d (IOMMU for PCI passthrough) often disabled. Check per node:

```bash
cat /proc/cpuinfo | grep -E 'vmx|svm'     # VT-x
dmesg | grep -E 'IOMMU|DMAR|VT-d'          # VT-d
```

On `pve-2`, VT-x was disabled in the BIOS (it was listed under "Advanced → CPU Configuration → Intel Virtualization Technology"). On `pve-3`, VT-d required digging through a "Chipset" submenu. Every BIOS is slightly different — look for "Virtualization Technology for Directed I/O" or "VT-d" specifically.

Without VT-d, Proxmox will still create VMs (nested KVM works), but PCI passthrough of GPUs, USB controllers, or NVMe drives won't work.

## What Actually Runs on This Cluster

Once the cluster was stable, I migrated all VMs from `pve-4`:

- **VM 101 — Ubuntu 24.04:** runs my AI agent (OpenClaw, more on this in a future article)
- **VM 102 — Debian 12 / FreePBX 17:** handles phone calls, SIP trunk, Asterisk
- **LXC 100 — nginx-proxy**
- **LXC 203 — Portainer CE**

Live migration between nodes works at ~200 MB/s, limited by the gigabit LAN switch and cables (chose cat 6 ot 7 if you want to maximize the speed) between the mini PCs. VMs migrate without downtime in about from seconds to few minutes depending on RAM and VM sizes.

## The Node Count Rationale

Four nodes feels right for a home setup:

- Three nodes lose one and still have quorum (2/3 votes remain)
- Four nodes lose one and still have quorum (3/4 votes) — more resilient
- Four nodes is still dead quiet and cheap to run (~30–45W idle total)

Three mini PCs at 16 GB gives you 48 GB total RAM across new nodes — enough to run 15–20 light VMs or a handful of heavier ones. Add the existing node and you're at a comfortable 64+ GB across the cluster.

## Key Lessons

**Buy identical hardware across nodes.** Different mini PC generations mean different CPU feature sets, which blocks some migration scenarios.

**Never add a running production node to a cluster without full backups.** The cluster join wipes configs. This is documented. I read it. Did it anyway. Don't.

**Storage first, workloads second.** Get NFS verified and tested before migrating anything to it. A single failed backup job teaches this better than any tutorial.

**Check name resolution before everything else.** Half the mysterious Proxmox errors I've seen trace back to hostname resolution failures. `/etc/hosts` is your friend.

---

*In the next article, I'll cover how I connected this cluster to a self-hosted Headscale VPN so every node, VM, and device — including phones and laptops — lives on a single private mesh network accessible from anywhere.*

---

*GitHub: [axluca/openclaw-homelab-agent](https://github.com/axluca/openclaw-homelab-agent)*

**Tags:** homelab, proxmox, self-hosted, mini-pc, virtualization, linux, infrastructure

---

## Header Image Prompt

> A cinematic close-up of three identical small form-factor mini PCs stacked neatly on a wooden desk, glowing blue LEDs, connected by a thin ethernet switch. Soft ambient light, dark moody background, cable management visible. Style: high-end tech product photography, shallow depth of field, 16:9, ultra-detailed.
