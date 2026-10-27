# code-server for Ubuntu 26.04 LTS

A single-file, non-interactive installer for [Coder's code-server](https://github.com/coder/code-server): VS Code in a browser, HTTPS, generated password, systemd, and safe version switching.

> [!WARNING]
> **The service runs as `root`, intentionally.** The integrated terminal and extensions can administer the entire host. If an attacker compromises the browser session, a password, or an extension, they may gain full control of the server. **Do not expose port 15001 (or any configured port) to the open Internet without network restrictions.** Prefer a private VPN or trusted-source firewall rules. This is an independent project, not an official Coder installer.

## Requirements

- Fresh **Ubuntu 26.04 LTS** server with systemd and `amd64` or `arm64` architecture.
- Root access (`sudo`) and outbound HTTPS access to GitHub Releases, the GitHub API, and Ubuntu package mirrors.
- For public-IP auto-detection, outbound access to at least one IP detection endpoint. Otherwise use `--server-ip`.
- Sufficient storage for the code-server release archive and extracted binaries, as well as your projects.

The installer installs only required system packages. It does **not** run `apt upgrade`, migrate old projects, install Docker, or configure a reverse proxy.

## Quick installation

Download the installer from **this repository**, inspect it, then execute it:

```bash
curl -fsSLo install-code-server.sh \
  https://raw.githubusercontent.com/iMagicKey/code-server/main/install-code-server.sh
less install-code-server.sh
sudo bash install-code-server.sh
```

Or install from a clone:

```bash
git clone https://github.com/iMagicKey/code-server.git
cd code-server
sudo bash install-code-server.sh
```

The default configuration needs **no input**:

- Runs as **root**, listens on `0.0.0.0:15001` over HTTPS.
- Creates `/srv/code-server` (versioned application), `/srv/workspaces` (project files), `/var/lib/code-server` (user data and extensions), and `/etc/code-server` (configuration).
- Determines IPv4 automatically and creates a self-signed TLS certificate with the IP in its SAN.
- Generates a random web-login password, stores the original in `/root/code-server-credentials.txt` (`0600`), and configures an Argon2id hash for authentication.
- Installs the **latest stable upstream release** for AMD64/ARM64, checking the SHA-256 digest published with that release.
- Disables code-server telemetry and update polling. **Third-party extensions and executed tools may still send their own telemetry.**
- Enables `code-server.service` and a daily `code-server-cert-renew.timer`.
- Adds a UFW rule for the selected port **only if UFW is already active**, unless `--no-ufw` is given or loopback binding is selected. It does not enable UFW or modify cloud-provider firewalls.

At the end, the installer displays the URL, password, and certificate SHA-256 fingerprint. Browsers will warn about the self-signed certificate until it is trusted; verifying the fingerprint out of band is recommended. Reissuing a certificate changes its fingerprint.

## Custom installation options

Options apply to **fresh installations only**, and can be combined:

| Option | Default | Meaning |
|---|---|---|
| `--port NUMBER` | `15001` | HTTPS port, 1024–65535 |
| `--bind-host IPV4` | `0.0.0.0` | Interface to listen on; `127.0.0.1` for SSH/VPN proxy access |
| `--workspace-dir PATH` | `/srv/workspaces` | Absolute projects directory, independent of the app installation |
| `--server-ip IPV4` | Auto-detected | Address to include in the TLS certificate and connection URL; useful for NAT/private networks |
| `--version X.Y.Z` | Latest stable | Install a particular stable code-server release |
| `--no-ufw` | Not set | Never add a UFW allow rule |
| `--help` | — | Print available options without installing |

Example: change the port and workspace directory, with an explicitly supplied IP:

```bash
sudo bash install-code-server.sh \
  --port 18443 \
  --workspace-dir /srv/projects \
  --server-ip 192.0.2.10 \
  --no-ufw
```

Replace `192.0.2.10` (a documentation-only address) with your real server IP.

Example: only listen on localhost (ideal behind an SSH tunnel or secure reverse proxy):

```bash
sudo bash install-code-server.sh \
  --bind-host 127.0.0.1 \
  --no-ufw
```

When bound to `127.0.0.1`, the installer uses that IP in the self-signed certificate unless `--server-ip` is explicitly set.

**Note:** The installer only supports IPv4 for its bind and automatic certificate workflow. The workspace path must use an absolute path containing only letters, digits, `_`, `-`, `.`, and `/`, with no `..` path components or spaces, and cannot overlap application, state, or configuration directories. Configurations for TLS-terminating proxies or public domain certificates require separate setup.

### Re-running the installer

Running the installer again **without flags** refreshes the installed management utility, preserves passwords, TLS certificates (unless renewal is required), application settings, existing projects, and the currently active code-server version. It will not change existing port, bind host, or project directory. To prevent silent misconfiguration, custom install flags are rejected after the first installation. For deliberate reconfiguration, edit the root-owned `/etc/code-server/config.yaml`, `/etc/code-server/manager.env`, and (if needed) the systemd unit, then reload systemd and restart the service; keep these files consistent.

## Administration

```bash
sudo code-server-manager status                  # Version, bind address, health, TLS
sudo code-server-manager check                   # Compare with the latest stable version
sudo code-server-manager update                  # Upgrade to the latest stable version
sudo code-server-manager update --version 4.143.1 # Install a specific stable version
sudo code-server-manager rollback                # Switch to previous installed version
sudo code-server-manager renew-cert              # Renew if IP changed or cert expires soon

sudo systemctl status code-server
sudo journalctl -u code-server -n 100 --no-pager
sudo systemctl status code-server-cert-renew.timer
```

### How updating works

The manager fetches upstream release metadata, validates version and URL, downloads the archive, compares its SHA-256 digest to the upstream release asset metadata, extracts the version into an isolated directory, and atomically switches `/srv/code-server/current`. Then it restarts the service and checks the local HTTPS `/healthz` endpoint. If activation fails, it attempts to restore the previous version automatically.

Previous versions remain in `/srv/code-server/versions` to allow rollback. `code-server-manager rollback` manually switches to the previously activated version. **An executable rollback cannot reverse changes already made to user data by a newer release**; make backups before major updates.

The upstream GitHub Release API and archive source must be trusted. A hash downloaded from the *same* upstream account detects transit or archive corruption but does not protect against compromise of that release account.

## File structure

```text
/srv/
├── code-server/
│   ├── current -> versions/<active>
│   ├── previous -> versions/<previous>
│   ├── versions/
│   └── ssl/
│       ├── cert.pem
│       └── key.pem
└── workspaces/                    # All projects; no migration or sample data

/var/lib/code-server/
├── user-data/
└── extensions/

/etc/code-server/
├── config.yaml                    # Argon2id hash, bind, SSL configuration
├── manager.env                    # Root-owned manager settings
└── public-ip                      # Last certificate IP

/root/code-server-credentials.txt  # Web password, root-only
/usr/local/sbin/code-server-manager
```

The installer never recursively clears or changes the ownership of the projects directory. All code-server processes and their extensions run as root in this configuration.

## TLS, firewall, and privacy

- **Self-signed TLS** encrypts the connection but does not independently establish the server's identity. Restrict access by firewall/VPN and validate the fingerprint.
- Certificates are checked daily and regenerated if their SAN IP changes or they have fewer than 30 days left; the certificate is valid for up to 825 days.
- By default, the program listens on all IPv4 interfaces. To avoid opening a public admin endpoint, use `--bind-host 127.0.0.1` and a VPN, tunnel, or properly configured TLS reverse proxy.
- The web password alone should not be treated as a complete defence of a root administrative interface. Never use this root-mode deployment in an untrusted multi-user environment.
- No backup is configured. Back up `/srv/workspaces`, `/var/lib/code-server`, `/etc/code-server`, and the TLS keys to secure off-host storage.
- Disabling telemetry here affects code-server and VS Code preferences, not third-party software and extensions.

## Development / contribution

Files in this repository:

```text
install-code-server.sh         # Standalone installer, includes embedded manager
code-server-manager            # Standalone readable manager source
README.md                      # Setup and operations guide
.github/workflows/validate.yml # CI: syntax and repository tests
tests/validate.sh              # Local tests
tools/sync-manager.sh          # Copies manager source into installer
```

To change the manager, edit `code-server-manager`, then run:

```bash
./tools/sync-manager.sh
./tests/validate.sh
```

The installer embeds the manager so that downloading **just one file** is enough for a new server. Validate on a disposable Ubuntu 26.04 VM before production use. Local tests do not deploy a real code-server instance.

## License and attribution

This project is independent of Coder and downloads [coder/code-server](https://github.com/coder/code-server) from official releases. The installer and management scripts in this repository are licensed under the [MIT License](LICENSE), Copyright (c) 2026 iMagicKey. The upstream code-server project and its bundled dependencies retain their own respective licenses. This repository is not affiliated with Coder.
