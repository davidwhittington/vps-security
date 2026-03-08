# VPS Security Audit Report

> **Instructions:** Copy this file to `private/servers/<hostname>/AUDIT_REPORT.md` and fill in the details.
> Findings should use the severity levels: **CRITICAL**, **HIGH**, **MEDIUM**, **LOW**, **INFO**.

---

**Hostname:** `<hostname>`
**IP:** `<ip address>`
**OS:**
**Kernel:**
**Web Server:**
**Audit Date:**
**Uptime:**
**Auditor:**

---

## Executive Summary

_2–3 sentences summarizing overall risk posture and the top findings._

**Overall Risk Posture: [ CRITICAL / HIGH / MEDIUM / LOW ]**

---

## Findings

### CRITICAL

_Issues that are actively exploitable or represent immediate serious risk._

#### C1. [Title]
- **Detail:**
- **Evidence:**
- **Impact:**
- **Remediation:**

---

### HIGH

_Significant vulnerabilities that should be addressed within days._

#### H1. [Title]
- **Detail:**
- **Recommendation:**

---

### MEDIUM

_Issues that increase attack surface or risk; address within 2–4 weeks._

#### M1. [Title]
- **Detail:**
- **Recommendation:**

---

### LOW

_Minor hardening improvements; address as time allows._

#### L1. [Title]
- **Detail:**
- **Recommendation:**

---

### INFO

_Observations and confirmations of good practices — no action needed._

#### I1. [Title]
- **Detail:**

---

## Prioritized Remediation Plan

### Immediate (Today)

1.
2.
3.

### This Week

4.
5.

### This Month

6.
7.

---

## Hardening Checklist

**SSH & Access**
- [ ] SSH key-based auth only (`PasswordAuthentication no`)
- [ ] Root login disabled or key-only (`PermitRootLogin no` / `prohibit-password`)
- [ ] X11 forwarding disabled
- [ ] Non-root sudo admin user created and tested
- [ ] Root SSH login disabled after admin user confirmed

**Firewall**
- [ ] UFW active with default deny inbound
- [ ] Only required ports open (SSH port, 80, 443)
- [ ] No unexpected listening services

**Intrusion Prevention**
- [ ] fail2ban installed and running
- [ ] SSH jail active with appropriate thresholds
- [ ] Apache jails configured (if applicable)

**Apache**
- [ ] `ServerTokens Prod` set
- [ ] `ServerSignature Off` set
- [ ] `mod_headers` enabled
- [ ] Security headers applied (HSTS, X-Content-Type-Options, Referrer-Policy, CSP)
- [ ] `.git` / `.svn` access blocked
- [ ] `mod_status` disabled or localhost-only
- [ ] `Options -Indexes` on all vhosts

**System**
- [ ] All pending security updates applied
- [ ] Unattended-upgrades active
- [ ] Kernel sysctl hardened (ICMP redirects, martian logging)
- [ ] No world-writable files in web roots
- [ ] No unexpected SUID binaries

**TLS / Certificates**
- [ ] Valid cert on all vhosts
- [ ] Auto-renewal working (`certbot renew --dry-run`)
- [ ] HSTS header set with appropriate max-age

**Monitoring**
- [ ] Log monitoring in place (Logwatch or equivalent)
- [ ] fail2ban alert notifications working
- [ ] Regular update reports scheduled

---

## Notes

_Additional observations, deferred items, or context._
