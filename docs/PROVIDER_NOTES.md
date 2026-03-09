# Provider Notes

Known quirks, gotchas, and configuration differences across common VPS providers.

---

## Status

| Item | Detail |
|---|---|
| Applies to | vps-security deployments on major VPS providers |
| Last updated | 2026-03-09 |

---

## DigitalOcean

**Tested on:** Ubuntu 24.04 Droplets

### Cloud-Init / Sudoers

DigitalOcean provisions Droplets with a cloud-init NOPASSWD sudoers rule for the default user. `03-setup-admin-user.sh` removes this automatically. Verify after running:

```bash
ls /etc/sudoers.d/
cat /etc/sudoers.d/90-cloud-init-users  # should be removed or overwritten
```

### UFW and DigitalOcean Firewall

If you use DigitalOcean's Cloud Firewall (external firewall in the control panel), note that UFW still runs on the Droplet itself. Both layers are active. This is fine — defense in depth. Just ensure your Cloud Firewall allows SSH, 80, 443 before enabling UFW or you may lock yourself out.

### Private Networking

If you use DigitalOcean's private network (VPC), ensure UFW rules account for it:

```bash
# Allow traffic on private interface (eth1 typically)
ufw allow in on eth1
```

### Snapshots vs. Backups

DigitalOcean automated backups are weekly. Consider this when setting `DISK_WARN_PCT` — backup snapshots may temporarily increase disk usage.

### Floating IPs

If using a Floating IP, `hostname -f` may return the Droplet's original hostname, not the Floating IP. This affects banners and cert checks. Set `HOSTNAME` explicitly in `config.env` if needed:

```bash
HOSTNAME=server1.example.com
```

---

## Hetzner Cloud

**Tested on:** Ubuntu 24.04 CX series

### SSH Root Access Default

Hetzner enables root SSH login with a password by default. `01-immediate-hardening.sh` disables password auth and root login — this is the right behavior, but ensure you have key-based access before running it.

### Hetzner Firewall

Like DigitalOcean, Hetzner has an optional cloud-level firewall. Same advice applies: set it before running UFW hardening, or connect via their console.

### IPv6

Hetzner assigns IPv6 by default. Ensure UFW IPv6 rules are enabled:

```bash
# Check /etc/default/ufw
grep IPV6 /etc/default/ufw
# Should be: IPV6=yes
```

If UFW IPv6 is disabled, connections on IPv6 are unfiltered.

### NTP

Hetzner uses their own NTP servers. `timedatectl` usually shows correct sync, but if you see time drift:

```bash
timedatectl status
# If not synchronized:
systemctl restart systemd-timesyncd
```

---

## Vultr

**Tested on:** Ubuntu 24.04 Cloud Compute**

### Root Login

Vultr deploys with root access via SSH password. Disable before anything else:

```bash
bash scripts/audit/preflight-check.sh  # verifies SSH key present
bash scripts/hardening/01-immediate-hardening.sh
```

### Serial Console

Vultr provides a browser-based serial console (SOS console) in the control panel. If you get locked out of SSH, use this to recover. You'll need the root password you set at deployment.

### Block Storage

If you've attached Vultr Block Storage volumes, they appear as separate block devices and are not automatically included in disk alerts. Verify `df -h` shows your mount points, then adjust `disk-usage-check.sh` if needed.

### DDoS Protection

Vultr has optional DDoS protection at the network level. If enabled, it may interfere with `mod_evasive` false-positive detection during load tests.

---

## Linode / Akamai Cloud

**Tested on:** Ubuntu 24.04 Nanode, Linode 2GB**

### Lish Console

Linode's equivalent of a serial console. Accessible via the web panel or SSH to a regional Lish gateway. Keep Lish access details in your password manager in case of SSH lockout.

### Private IP Addresses

Linode's private network uses 192.168.128.0/17. If your Linode has a private IP:

```bash
# Allow private network traffic (for internal services)
ufw allow in on eth0 from 192.168.128.0/17
```

Adjust if you don't need it.

### Longview Monitoring

If using Linode Longview agent, it runs as a system process and will appear in `services-check.sh` baseline. Update the baseline after installing Longview:

```bash
bash scripts/audit/services-check.sh --update
```

---

## AWS EC2 / Lightsail

**Notes (not fully tested)**

### Security Groups

AWS Security Groups are your external firewall. UFW is still useful for process-level filtering and defense in depth. Ensure Security Groups allow SSH, 80, 443 before running `01-immediate-hardening.sh`.

### Default User

EC2 Ubuntu AMIs use `ubuntu` as the default user, not `root`. The user has passwordless sudo. `03-setup-admin-user.sh` targets this pattern — set `ADMIN_USER=ubuntu` in `config.env`.

### Instance Metadata Service (IMDS)

AWS IMDS v1 is accessible at 169.254.169.254 from within the instance. If not needed, restrict it:

```bash
# Block IMDS access from web processes (Apache runs as www-data)
ufw deny out from any to 169.254.169.254
```

Or configure IMDSv2 (token-required) in the EC2 console.

### SSM Session Manager

If using AWS SSM for console access instead of SSH, the SSM agent runs as a service. Add it to your baseline:

```bash
bash scripts/audit/services-check.sh --update
```

---

## OVH / OVHcloud

**Notes (community-contributed)**

### Anti-DDoS VAC

OVH's VAC system may block certain types of traffic automatically. This can interfere with legitimate rate-limiting tests.

### Rescue Mode

OVH provides rescue mode boot via the control panel. If locked out, boot into rescue, mount your disk, and fix the issue.

### OVH Monitoring Pings

OVH sends ICMP monitoring pings from their infrastructure. If you block ICMP with UFW, OVH may flag the instance as down. Allow ICMP or add an exemption rule.

---

## General Notes (All Providers)

### Console Access is Critical

Before hardening SSH, confirm you have out-of-band console access (browser console, Lish, SOS console, etc.) in case you get locked out. This is why `preflight-check.sh` verifies SSH keys first.

### Provider DNS TTL

If you're moving IPs or setting up new DNS records, note that TTL changes take time to propagate. Don't rely on DNS during an active incident.

### Kernel Versions

Some providers run custom kernels. rkhunter may flag kernel module differences. After installing rkhunter, run `rkhunter --propupd` to set a clean baseline:

```bash
rkhunter --propupd
```

### Cloud-Init Logs

```bash
# If provisioning behaves unexpectedly
cat /var/log/cloud-init.log
cat /var/log/cloud-init-output.log
```

---

## Related

- [RUNBOOK.md](RUNBOOK.md) — operational procedures
- [docs/customization.md](customization.md) — per-script config options
- [CONTRIBUTING.md](../CONTRIBUTING.md) — adding provider-specific notes
