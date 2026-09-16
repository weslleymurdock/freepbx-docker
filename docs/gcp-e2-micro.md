# GCP e2-micro profile

This profile targets a single Google Cloud `e2-micro` instance with 1 vCPU and 1 GiB RAM. It packages FreePBX/Asterisk, Apache/PHP, MariaDB, MongoDB, Postfix, cron, logrotate and Fail2ban into one container instead of running separate database and Fail2ban containers.

## Resource strategy

- Docker Compose limits the container to `1.0` CPU and `1g` memory.
- MariaDB uses a 64 MiB InnoDB buffer pool, low connection/cache limits and disables Performance Schema.
- PHP uses a 96 MiB memory limit and a small OPcache.
- MongoDB uses a 128 MiB WiredTiger cache and disables diagnostic data collection.
- Asterisk is compiled with `make -j1` to avoid build-time memory spikes on the target machine.
- Host networking avoids a large RTP port publishing table and lets SIP/RTP use the host network directly.

MongoDB is included because it is a requested runtime dependency; its cache is deliberately constrained for this profile. The combined workload is still extremely tight for a 1 GiB machine and should be validated under the expected call/session load before production use.

## Runtime configuration

Set `MYSQL_ROOT_PASSWORD` and `FREEPBX_DB_PASSWORD` before starting the profile. The entrypoint initializes the bundled MariaDB databases `asterisk` and `asteriskcdrdb` and creates the `freepbxuser` account when both values are supplied.

The FreePBX installation step remains explicit, matching the existing project workflow; this profile does not silently run `php install` during container startup.

## Validation policy

This branch intentionally does not run Docker builds. Validation is limited to repository/configuration inspection and consistency checks in the pull request. Build and runtime validation should be performed on an actual GCP e2-micro before merging.
