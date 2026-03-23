# Glossary

Terms used throughout the linux-security docs and scripts. Focused on what these mean in practice for server operators, not textbook definitions.

---

## A

**ACME** — Automated Certificate Management Environment. The protocol Let's Encrypt uses to issue and renew TLS certificates. Certbot speaks ACME. Renewal failures are usually ACME errors: port 80 blocked, rate limits, or DNS misconfiguration.

**AIDE** — Advanced Intrusion Detection Environment. Takes a cryptographic snapshot of critical filesystem paths and compares against it on each run. If a binary or config file changes unexpectedly, AIDE catches it. Set up by `core/07-aide-setup.sh`.

**AppArmor** — Linux kernel security module that restricts what programs can do based on per-process profiles. Pre-installed on Ubuntu. Checked by `core/audit/apparmor-check.sh`. Complements, does not replace, traditional DAC permissions.

**auditd** — The Linux audit daemon. Records system calls — file access, privilege changes, network connections — to `/var/log/audit/audit.log`. Useful post-incident for reconstructing what happened. Configured by `core/05-auditd-setup.sh`.

**authorized_keys** — File at `~/.ssh/authorized_keys` listing the public keys allowed to authenticate as that user. If a public key is in this file, the holder of the matching private key can log in without a password.

---

## C

**certbot** — The standard CLI for obtaining and renewing Let's Encrypt TLS certificates. On Ubuntu, installed via snap (`/snap/bin/certbot`); on Debian 12, via apt. Auto-renewal runs via a systemd timer.

**cipher suite** — The combination of algorithms used for a TLS connection: key exchange, authentication, bulk encryption, and MAC. Modern servers should only offer ECDHE key exchange, AES-GCM or ChaCha20-Poly1305 encryption, and SHA-256+ MACs.

**CSP (Content Security Policy)** — HTTP response header that tells browsers which sources are allowed to load scripts, styles, fonts, and other resources. Also controls framing (`frame-ancestors`). Set per-server by `web/01-apache-hardening.sh` from `CSP_FRAME_ANCESTORS` in `config.web.env`.

**Certificate Transparency (CT)** — Public logs where every issued TLS certificate must be recorded. You can monitor CT logs to detect certificates issued for your domains without your knowledge — a signal of a compromised CA or a phishing setup.

---

## E

**ECDSA** — Elliptic Curve Digital Signature Algorithm. Used for SSH host keys and TLS certificates. ECDSA keys are smaller and faster than RSA at equivalent security levels. Let's Encrypt issues ECDSA certificates by default.

---

## F

**fail2ban** — Reads log files and temporarily bans IPs that show brute-force patterns (repeated auth failures, scanner patterns). Implemented as iptables rules. The linux-security scripts configure jails for SSH and Apache.

**fail2ban jail** — A named fail2ban policy: which log to watch, what pattern to match, how many failures trigger a ban, how long the ban lasts. `sshd` and `apache-auth` are the main jails configured here. The `recidive` jail escalates bans for repeat offenders.

---

## G

**GoAccess** — Fast terminal and web-based log analyser for Apache/Nginx access logs. Used here to generate daily HTML traffic reports from Apache access logs. Set up by `web/02-log-monitoring-setup.sh`.

---

## H

**HSTS (HTTP Strict Transport Security)** — HTTP response header that tells browsers to only connect to this domain over HTTPS, for a specified duration. The `preload` directive submits the domain to browser-maintained lists, enforcing HTTPS even on first visit. Set by `web/01-apache-hardening.sh`.

---

## I

**ICMP redirect** — A network packet type that tells a host to change its routing table. Attackers on the same network can use ICMP redirects for traffic interception. The sysctl hardening in `core/01-immediate-hardening.sh` disables acceptance of ICMP redirects.

**iptables** — The underlying Linux packet filtering framework. UFW and fail2ban both write iptables rules — UFW for the firewall policy, fail2ban for temporary IP bans. You generally manage both through their respective tools rather than iptables directly.

---

## K

**KexAlgorithm** — Key Exchange Algorithm. The cryptographic method used to establish a shared session key at the start of an SSH connection. Weak algorithms like `diffie-hellman-group1-sha1` should be disabled; `curve25519-sha256` and `ecdh-sha2-nistp256` are current standards.

---

## L

**Let's Encrypt** — Free, automated Certificate Authority that issues 90-day TLS certificates via the ACME protocol. All domains in the linux-security stack use Let's Encrypt certificates managed by certbot.

**Logwatch** — Summarises system log files (auth, Apache, mail, etc.) into a daily digest email. Useful for spotting recurring patterns that aren't critical enough to trigger fail2ban but indicate background noise. Configured by `web/02-log-monitoring-setup.sh`.

---

## M

**MAC (Message Authentication Code)** — Cryptographic checksum that proves a message wasn't tampered with in transit. In SSH, the MAC algorithm covers the encrypted payload. Weak MACs like `hmac-md5` or `hmac-sha1` should not be used.

**martian packets** — Packets with source or destination addresses that should not appear on a public network (e.g., loopback addresses arriving on a public interface). The sysctl hardening enables logging of martian packets, which can indicate spoofing or misconfiguration.

**ModSecurity** — Open-source Web Application Firewall (WAF) module for Apache. Inspects HTTP requests and responses against a ruleset. Configured here with the OWASP Core Rule Set. Set up by `web/05-modsecurity-setup.sh`.

**msmtp** — Lightweight SMTP client used to relay outgoing email from the server. Configured with your SMTP relay credentials in `config.env`. Used by scripts that send email reports and alerts.

---

## O

**OCSP stapling** — TLS optimization where the server fetches and caches the certificate revocation status from the CA, then sends it to clients during the handshake. Reduces latency and improves privacy vs. clients making direct OCSP requests. Configured by `web/07-apache-tls-hardening.sh`.

**OWASP CRS (Core Rule Set)** — The standard open-source ruleset for ModSecurity. Covers common attacks: SQL injection, XSS, path traversal, protocol violations, and more. Used with ModSecurity in the web-server profile.

---

## P

**PAM (Pluggable Authentication Modules)** — Linux authentication framework. SSH, sudo, login, and other services delegate authentication decisions to PAM. PAM modules are stacked — each can require, sufficient, or optionally contribute to the result. Used for SSH 2FA configuration.

**PermitRootLogin** — sshd_config directive controlling whether root can log in directly over SSH. Set to `no` after a non-root admin user is configured. Intermediate value `prohibit-password` blocks password auth for root but allows key-based access.

---

## R

**recidive jail** — fail2ban jail that monitors fail2ban's own log. IPs that get banned repeatedly across other jails get escalated to a longer ban (typically 1 week). Set up by `core/06-fail2ban-recidive.sh`.

**rkhunter** — Rootkit Hunter. Scans for known rootkits, backdoors, and suspicious local files. Supplements AIDE (AIDE detects unauthorized changes; rkhunter specifically knows rootkit signatures). Configured by `core/04-rkhunter-setup.sh`.

---

## S

**SNI (Server Name Indication)** — TLS extension that lets a client specify which hostname it is connecting to during the handshake. Allows multiple domains with separate TLS certificates to be served from a single IP address. Required for modern virtual hosting.

**sysctl** — Interface for reading and writing kernel parameters at runtime. The linux-security scripts write hardening values (ICMP redirect blocking, martian logging, TCP SYN cookies) to `/etc/sysctl.d/` so they persist across reboots.

---

## T

**TOTP (Time-based One-Time Password)** — 2FA method where a short-lived code (usually 6 digits, 30-second window) is generated by an authenticator app using a shared secret and the current time. Used in SSH 2FA setup with `libpam-google-authenticator`. Defined by RFC 6238.

---

## U

**UFW (Uncomplicated Firewall)** — User-friendly front end for iptables on Ubuntu/Debian. The linux-security baseline configures UFW with a deny-all inbound policy and explicit allow rules for SSH, HTTP, and HTTPS. Managed by `core/01-immediate-hardening.sh`.

**unattended-upgrades** — Ubuntu/Debian package that automatically installs security updates. Configured to apply security patches on a schedule without manual intervention. Checked by `web/audit/unattended-upgrades-check.sh`.

---

## W

**WAF (Web Application Firewall)** — Inspects HTTP traffic at the application layer and blocks requests that match known attack patterns. ModSecurity with the OWASP CRS is the WAF used in the web-server profile. Operates differently from a network firewall — it understands HTTP semantics.

---

## Related

- [Customization Guide](customization.md) — config.env and config.web.env variables
- [Architecture](architecture.md) — how all these components fit together
- [Security Baseline](security/README.md) — what controls are required and why
