# VPS Security Audit Report — TEMPLATE

> Copy this file to `private/servers/<hostname>/AUDIT_REPORT.md` and fill in your details.

**Target:** `<hostname>` (`<ip>`)
**OS:**
**Kernel:**
**Web Server:**
**Audit Date:**
**Uptime:**

---

## Executive Summary

Brief overall risk posture and top 3 issues.

**Overall Risk Posture: [HIGH / MEDIUM / LOW]**

---

## Findings

### CRITICAL

#### C1. [Title]
- **Detail:**
- **Impact:**

### HIGH

#### H1. [Title]
- **Detail:**
- **Recommendation:**

### MEDIUM

#### M1. [Title]
- **Detail:**
- **Recommendation:**

### LOW

#### L1. [Title]
- **Detail:**
- **Recommendation:**

### INFO

#### I1. [Title]
- **Detail:**

---

## Prioritized Recommendations

### Immediate (Do Today)

1.

### This Week

2.

### This Month

3.

---

## Hardening Checklist

- [ ] Install and enable fail2ban
- [ ] Enable UFW firewall (allow SSH/80/443 only)
- [ ] Disable SSH password authentication
- [ ] Disable SSH root login (after setting up key-based admin user)
- [ ] Enable `mod_headers` in Apache
- [ ] Set `ServerTokens Prod` and `ServerSignature Off`
- [ ] Add security headers (HSTS, X-Frame-Options, X-Content-Type-Options, CSP, Referrer-Policy)
- [ ] Block `.git`/`.svn` access in Apache
- [ ] Disable `mod_status` or restrict to localhost
- [ ] Add `Options -Indexes` to all virtual hosts
- [ ] Apply all pending system updates (`apt upgrade`)
- [ ] Harden sysctl network parameters (disable ICMP redirects, log martians)
- [ ] Set up dedicated admin user with sudo
- [ ] Disable X11Forwarding in SSH
- [ ] Verify certbot auto-renewal (`certbot renew --dry-run`)
- [ ] Remove cloud-init NOPASSWD sudoers rule if unused
- [ ] Consider changing SSH port
