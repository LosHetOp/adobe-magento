# Magento Native

Disposable Magento security-research lab on **Debian 12, AMD64 or ARM64**.
Magento, PHP, Composer, and nginx run natively. Only MySQL and OpenSearch use
stock Docker images: no Magento image builds, Compose, or systemd.

## Run

In a fresh sandbox, as root, from this repository:

```bash
bash setup.sh
```

Requires a Docker CLI and a running **local Linux Docker engine**, internet access,
roughly 8 GB RAM and 15 GB free disk. Published Docker ports must be reachable from
the script at localhost; a remote engine or sibling-container Docker socket alone
is insufficient. The script does not install Docker.

Installs PHP 8.5 and nginx 1.30 from signed APT repositories, downloads checksummed
Composer 2.10.0, and pulls MySQL 8.4 and OpenSearch 3.1.0. No MariaDB APT repository,
native database, or Java installation. PHP/nginx APT access is still required.
OpenSearch mmap is disabled, avoiding a host `vm.max_map_count` change.

It fetches pinned public Magento **2.4.9** source and Composer dependencies and
applies latest applicable Adobe registry patches/hotfixes before installing Magento.
No Adobe credentials, platform-check bypasses, or fake search service.
Developer mode generates code/static assets on demand; first requests may be slower.

Require exit code 0. Final JSON contains URLs, generated credentials, and verified
security level. On failure, inspect logs rather than treating the lab as ready.

- Storefront: http://localhost:8888/
- Admin: http://localhost:8888/admin_local/
- Source: `/opt/magento-native/app/`
- Credentials: `/opt/magento-native/credentials.json`
- Logs: `/opt/magento-native/logs/`
- Per-stage timings: `/opt/magento-native/timings.tsv`
- Patch receipt: `/opt/magento-native/security/receipt.json`
- MySQL: `127.0.0.1:13306`, container `magento-native-db`
- OpenSearch: `127.0.0.1:19200`, container `magento-native-search`

PHP-FPM uses a private Unix socket. Ports 8080 and 9000 are untouched.
A background loop runs Magento cron each minute. For current infrastructure logs:

```bash
docker logs magento-native-db
docker logs magento-native-search
```

Failures retain processes, containers, and logs for diagnosis. Discard the sandbox
when finished; reruns against the same runtime directory/container names are refused.
If the Docker daemon outlives the sandbox, also remove this lab's containers and volumes:

```bash
docker rm -fv magento-native-db magento-native-search
```

This changes host packages and repositories: **do not run on a workstation or production
server**. Package-managed service startup is temporarily blocked; the prior policy is restored.

## Report-specific modules

Agents may create modules under `app/code/Local/` using researcher-provided routes.
Preserve services, permissions, and parameters; do not invent commercial implementations.
Make files readable by `www-data`, then:

```bash
cd /opt/magento-native/app
runuser -u www-data -- php8.5 bin/magento module:enable Local_YourModule
runuser -u www-data -- php8.5 bin/magento setup:upgrade --no-interaction
runuser -u www-data -- php8.5 bin/magento cache:flush
```

For async reports, inspect `queue:consumers:list` and run the relevant consumer with
a timeout or as a logged background process. Verify execution, not just queue acceptance.
Report findings as Open Source behavior with a report-derived fixture, not verified
Commerce/B2B behavior. Commercial DI/plugins may differ. Never weaken authorization
or remove patches to force reproduction.

## Scope

Patch verification includes Adobe SHA-256 checksums, zero-fuzz application, a full
reverse-chain check, and patched-file hashes. Unsupported patches fail visibly.
New Magento base versions are not installed automatically. Registry coverage does
not guarantee zero vulnerabilities or audit every dependency.

Uses the GitHub source distribution, without paid Commerce/B2B modules or Composer
extras such as Inventory/PageBuilder. Local HTTP, disabled admin 2FA when present,
file-backed cache/sessions, and database-backed queues are intentional lab conveniences.
No production hardening, upgrade/reset workflow, tests, or CI.

Requirements: https://experienceleague.adobe.com/en/docs/commerce-operations/installation-guide/system-requirements
