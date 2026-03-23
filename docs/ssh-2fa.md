# SSH Two-Factor Authentication

Adding TOTP-based 2FA to SSH provides a second factor alongside your existing key. This guide covers setup using `libpam-google-authenticator`.

> **This is optional.** Key-based SSH authentication is already strong. 2FA makes sense when you want an additional layer for privileged accounts, have compliance requirements, or share a server with multiple operators.

---

## How It Works

With 2FA configured, SSH authentication requires two things:

1. **Your SSH private key** (what you have)
2. **A TOTP code** from an authenticator app (what you know, time-limited)

An attacker who steals your private key still cannot log in without the current 6-digit code.

---

## Prerequisites

- SSH key-based auth already working (do not attempt this with password auth only)
- An authenticator app: Google Authenticator, Authy, 1Password, or any TOTP-compatible app
- Root access to the server
- **Keep your current SSH session open throughout setup and testing**

---

## Step 1 — Install libpam-google-authenticator

```bash
apt update
apt install libpam-google-authenticator -y
```

---

## Step 2 — Configure TOTP for the User

Run this as the user whose SSH login you are securing (not as root unless root login is the account):

```bash
google-authenticator
```

Answer the prompts:

| Prompt | Recommended answer |
|---|---|
| Time-based tokens? | `y` |
| Update .google_authenticator? | `y` |
| Disallow reuse of tokens? | `y` |
| Increase window for clock skew? | `n` (unless your server clock is unreliable) |
| Enable rate limiting? | `y` |

Save the emergency scratch codes in a secure location. Scan the QR code with your authenticator app and verify a code works before proceeding.

---

## Step 3 — Configure PAM

Edit `/etc/pam.d/sshd`:

```bash
nano /etc/pam.d/sshd
```

Add this line at the top of the file (before any other `auth` lines):

```
auth required pam_google_authenticator.so
```

To make 2FA required only when the `.google_authenticator` file exists (safer for multi-user servers — users without it configured can still log in with key only):

```
auth required pam_google_authenticator.so nullok
```

Remove `nullok` once all operators have 2FA configured.

---

## Step 4 — Configure sshd

Edit `/etc/ssh/sshd_config`:

```bash
nano /etc/ssh/sshd_config
```

Set the following:

```
# Enable keyboard-interactive (required for PAM challenge)
KbdInteractiveAuthentication yes

# Require both key AND TOTP
AuthenticationMethods publickey,keyboard-interactive
```

On older OpenSSH versions (< 8.x), the setting is named `ChallengeResponseAuthentication` instead of `KbdInteractiveAuthentication`. Both work if both are present.

Also verify `UsePAM yes` is set (it should be by default on Ubuntu).

---

## Step 5 — Test Before Closing Your Session

Test config first:

```bash
sshd -t
```

Reload sshd:

```bash
systemctl reload sshd
```

**Open a new terminal** and attempt to log in with your key. You should be prompted for a verification code after key authentication succeeds:

```
Verification code:
```

Enter the 6-digit code from your authenticator app. Confirm login works before closing your existing session.

---

## Reverting

If something goes wrong while your original session is still open:

```bash
# Revert sshd_config changes
nano /etc/ssh/sshd_config
# Remove the AuthenticationMethods line, set KbdInteractiveAuthentication back to no

# Revert PAM
nano /etc/pam.d/sshd
# Remove the pam_google_authenticator.so line

systemctl reload sshd
```

---

## Per-user Setup (Multiple Operators)

Each user runs `google-authenticator` in their own home directory. The PAM module reads `~/.google_authenticator` for whichever user is authenticating. No central config needed.

For new operators added later, until they run `google-authenticator` themselves:
- With `nullok`: they can still log in with key only
- Without `nullok`: they cannot log in until their TOTP file exists

---

## Caveats

**Clock sync is required.** TOTP codes are time-based. If the server clock drifts significantly, codes will fail. Verify NTP is running:

```bash
systemctl status systemd-timesyncd
```

**Emergency access.** If you lose your authenticator device, use one of the scratch codes printed during setup, or log in from a direct console (VPS control panel) to reconfigure.

**Automation and scripts.** Any non-interactive SSH usage (rsync, scp, CI/CD deploys) will break if `AuthenticationMethods` forces TOTP for all sessions. To exempt specific keys, use `Match` blocks in `sshd_config`:

```
# Main rule: require 2FA
AuthenticationMethods publickey,keyboard-interactive

# Exempt a deploy key (identified by its fingerprint via AuthorizedKeysFile or a dedicated user)
Match User deploy
    AuthenticationMethods publickey
```

---

## Related

- [Customization Guide](customization.md) — SSH port configuration
- [RUNBOOK.md](RUNBOOK.md) — SSH key rotation procedure
- [Architecture](architecture.md) — where SSH hardening fits in the stack
