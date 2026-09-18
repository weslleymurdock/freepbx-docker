# GCP e2-micro image

This directory contains the Docker image and runtime configuration for deploying FreePBX/Asterisk on a small Google Cloud VM, with the target profile of a Compute Engine **e2-micro** instance (1 vCPU, 1 GB RAM).

## Context

The main project is a conventional Docker Compose deployment in which FreePBX, MariaDB and Fail2ban are separate services. The GCP image is a constrained deployment variant created for environments where running multiple containers on a 1 GB VM is undesirable.

The GCP variant therefore packages the following services into one container:

- Asterisk 21.10.2
- FreePBX 17 source bundle, installed after the container is deployed
- Apache 2.4
- PHP 8.2
- MariaDB
- MongoDB 8
- Fail2ban
- Cron
- Postfix

The image is based on `debian:bookworm-slim` and uses low-memory MariaDB, MongoDB and PHP configuration.

## Important: build is not the FreePBX installation

The image build compiles Asterisk and places the FreePBX installer under `/usr/local/src/freepbx`. It intentionally does **not** run the FreePBX installer during `docker build`.

This separation is required because the FreePBX installation writes runtime configuration and application files such as:

- `/etc/freepbx.conf`
- `/var/www/html`
- `/var/lib/asterisk`
- FreePBX database tables

The container must therefore be running with its persistent volumes and initialized MariaDB before the installation is executed.

After the container starts, use the GCP deployment helper:

```bash
sudo bash gcp-run.sh --install-freepbx
```

The helper waits for MariaDB, verifies that `/usr/local/src/freepbx/install` exists, checks whether FreePBX is already installed, and then runs the installer against the **local MariaDB instance** at `127.0.0.1`.

After installation it runs:

```text
fwconsole chown
fwconsole reload
fwconsole restart
```

Do not run the installation command against a Docker service name such as `db`: the GCP image uses `network_mode: host` / a single-container deployment, so there is no separate `db` container or Compose DNS entry.

## Image runtime

The image starts its services through `source/gcp/entrypoint.sh`:

1. Ensure the `asterisk` runtime user exists.
2. Prepare runtime directories and permissions.
3. Configure the low-memory MariaDB/PHP settings.
4. Initialize and start MariaDB.
5. Initialize MongoDB.
6. Start Postfix, cron and Fail2ban when available.
7. Start the packaged Asterisk helper from `/usr/local/src/freepbx/start_asterisk`.
8. Keep Apache in the foreground.

The FreePBX installation is intentionally a post-deployment operation. Before installation, Apache may only expose an empty/default document root; that is not evidence that FreePBX has been installed.

## Persistent data

The GCP Compose definition persists:

```text
/var/lib/mysql
/var/lib/mongodb
/var/lib/asterisk
/etc/asterisk
/var/log/asterisk
```

The FreePBX application files under `/var/www/html` are part of the container filesystem and are produced by the FreePBX installation. Recreating the container without preserving the installed application layer requires running the post-install operation again.

## Network model

The GCP deployment is designed for a host-network or host-oriented deployment because SIP/RTP and Fail2ban require direct access to the host networking stack.

Required traffic normally includes:

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | FreePBX HTTP |
| 443 | TCP | FreePBX HTTPS |
| 5060 | UDP | SIP/PJSIP |
| 5160 | UDP | Asterisk SIP |
| RTP range | UDP | RTP media |

The GCP helper configures the Google Cloud firewall rules when the `gcloud` CLI is available and configures the host iptables RTP rules.

## Deployment

The GCP deployment helper supports a single-run deployment flow as well as a manual FreePBX installation fallback.

### Full deployment

For a standard deployment, run:

```bash
sudo bash gcp-run.sh
```

The helper prepares the firewall/network configuration, creates the Docker network and volumes, installs the systemd service, pulls the configured image and starts the container. It then:

1. Checks Asterisk readiness until it responds to CLI requests, using a bounded retry window configured internally by the script.
2. Verifies that MariaDB is ready with the configured root password.
4. Runs the FreePBX installer.
5. Runs `fwconsole chown`, `fwconsole reload` and `fwconsole restart`.

This means a new deployment no longer requires a second invocation of `gcp-run.sh` just to install FreePBX.

### Full deployment with a custom RTP range

Use:

```bash
sudo bash gcp-run.sh --rtp 10000-20000
```

This performs the same full deployment and FreePBX installation flow while using the specified RTP UDP range for the firewall configuration.

The `--rtp` option applies to the full deployment flow; it is not a standalone command for changing the RTP range of an already-running deployment.

### Manual FreePBX installation

If the automatic installation needs to be retried after a failed or interrupted deployment, run:

```bash
sudo bash gcp-run.sh --install-freepbx
```

This mode does not redeploy the container. It waits for the services, verifies Asterisk and MariaDB readiness, verifies the FreePBX installer and then performs the installation if necessary.

The installation is idempotent with respect to `/etc/freepbx.conf`: when that file already exists, the helper reports that FreePBX is already installed and does not run the installer again.

### Cleanup

To run the existing cleanup flow:

```bash
sudo bash gcp-run.sh --clean-all
```

This does not deploy or install FreePBX.

### Command summary

| Command | Full deploy | Custom RTP | Installs FreePBX |
|---|---:|---:|---:|
| `./gcp-run.sh` | Yes | No | Yes |
| `./gcp-run.sh --rtp 10000-20000` | Yes | Yes | Yes |
| `./gcp-run.sh --install-freepbx` | No | No | Yes, if needed |
| `./gcp-run.sh --clean-all` | No | No | No |

## Low-memory target

The target environment is an e2-micro with 1 GB RAM. The image therefore uses conservative settings for MariaDB, MongoDB and PHP, and Asterisk is compiled with `make -j1`.

This profile is intentionally an MVP deployment target. FreePBX/Asterisk workload, enabled modules, concurrent calls, RTP load, MongoDB usage and Fail2ban activity can increase memory consumption substantially.

## Relation to the main project

The conventional multi-container deployment remains documented in the repository root `README.md`. This README documents only the GCP single-container variant and its post-install lifecycle.
