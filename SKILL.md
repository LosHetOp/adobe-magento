---
name: magento-native
description: Install a disposable, natively hosted Magento lab on plain Debian 12 with current applicable Adobe security patches, including report-specific local route fixtures.
---

Read README.md for prerequisites. In a fresh Debian 12 sandbox,
run `bash /absolute/path/to/this/repo/setup.sh` as root. A local Linux Docker engine
is required for MySQL/OpenSearch; Magento/PHP/nginx stay native. No systemd. Allow
30 minutes initially; downloads vary. Require exit code 0 and the final JSON before
reporting success. It contains URLs, credentials, and the verified security level.

Source is at `/opt/magento-native/app`; logs and per-stage timings are under
`/opt/magento-native`. The pinned base is 2.4.9; patches refresh, base versions do not.
Never bypass patch/platform checks. Discard the sandbox afterward.

You may create local modules from researcher-provided route definitions to test public
framework behavior. Preserve route semantics, enable/upgrade the module, and verify
actual queue consumption for async findings. Follow README.md commands. Record fixtures
and patch level; do not claim commercial code access or verified B2B behavior. Newer
patches may legitimately prevent an old reproduction. Never weaken core authorization
to make a report reproduce.
