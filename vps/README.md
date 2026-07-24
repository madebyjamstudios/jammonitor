# JamMonitor VPS Tailscale Watchdog

This watchdog is the local, second-line recovery layer for the Debian OMR VPS.
The existing `tailscaled.service` remains responsible for normal process crash
recovery through systemd. The watchdog observes the supervisor and a bounded
LocalAPI request every 15 seconds.

It can request exactly one supervised restart in any of these cases:

1. `tailscaled.service` remains inactive for three consecutive observations.
2. The service is active but `/run/tailscale/tailscaled.sock` is absent or is
   not a Unix socket for three consecutive observations.
3. `tailscale status --json --peers=false` times out for three consecutive
   observations while the service is active.

The recovery episode remains latched until five supported, schema-valid
LocalAPI responses arrive. A failed restart is also latched. This prevents an
outage from becoming a restart storm.

The following conditions are observable but never authorize a restart:

- `NeedsLogin`, including an expired node key
- `NeedsMachineAuth`
- a stopped or starting backend
- control-plane or TUN degradation
- health warnings
- a command failure that is not a proven timeout
- malformed or future status schemas
- peer or ACL failures

An explicitly disabled or masked `tailscaled.service` is also an
operator-authoritative state and is never restarted. Only an inactive or
failed unit whose `UnitFileState` remains `enabled` or `enabled-runtime` is
eligible. Activating, reloading, deactivating, static, and otherwise unmanaged
units are not eligible.

An optional critical-peer probe can strengthen the meaning of delivered
connectivity. A peer failure changes `connected` and health reporting but
never authorizes a daemon restart.

## Files and runtime state

The installation owns only:

```text
/usr/local/libexec/jammonitor-tailscale-watchdog
/etc/systemd/system/jammonitor-tailscale-watchdog.service
/etc/systemd/system/jammonitor-tailscale-watchdog.timer
/usr/share/doc/jammonitor-tailscale-watchdog/README.md
```

Runtime state is private and reboot-volatile:

```text
/run/jammonitor-tailscale-watchdog/status.json
/run/jammonitor-tailscale-watchdog/memory
/run/jammonitor-tailscale-watchdog/maintenance-until
/run/jammonitor-tailscale-watchdog/watchdog.lock
```

The published JSON is mode `0600` and has a fixed allowlist. Raw LocalAPI JSON,
command stderr, health text, AuthURL values, node keys, and peer identities are
never published or logged.

Each run holds a nonblocking kernel `flock` on the persistent `watchdog.lock`
inode. The inode is never unlinked during normal or signal cleanup. The kernel
releases the held file-description lock on every exit, including `SIGKILL`, so
stale PID text and PID reuse cannot suppress later timer runs and concurrent
starts cannot lock different replacement inodes.

Because systemd can recover a short process crash entirely between 15-second
samples, `status.json` also publishes systemd's numeric `NRestarts`, the
current `ExecMainStartTimestampMonotonic`, and a derived process-generation
uptime when those properties are available. A changed generation or restart
count prevents a fast crash from being presented as uninterrupted local
process uptime. These fields are observational only and do not change the
recovery state machine.

Schema 2 defines `connected` as local tailnet data-plane readiness:

- `BackendState` is `Running`
- at least one valid Tailscale IPv4 or IPv6 address is present
- `TUN` is true
- `Self.InEngine` is true
- the critical peer is reachable when one is configured

`Self.Online=false` means the control plane is offline. It makes
`healthy=false`, `degraded=true`, and reports `reason=control_offline`, but it
does not erase `connected=true` or reset `connectivity_uptime_seconds` while
the local data plane remains ready. A health warning has the same
connected-uptime behavior. A missing TUN, inactive engine, missing tailnet
address, process-generation change, unknown observation, or configured
critical-peer failure breaks the connected interval.

To require one critical peer, create exactly one validated hostname or
Tailscale IP in the optional configuration file:

```bash
sudo install -d -m 0755 -o root -g root /etc/jammonitor
printf '%s\n' '100.104.78.42' |
  sudo tee /etc/jammonitor/tailscale-critical-peer >/dev/null
sudo chown root:root /etc/jammonitor/tailscale-critical-peer
sudo chmod 0644 /etc/jammonitor/tailscale-critical-peer
```

The peer identity and command output are never included in the snapshot or
journal. An invalid configuration fails closed for `connected` and is reported
only as the fixed `critical_peer_invalid` reason.

## Verified local installation

Run the manifest generator only after the last payload edit:

```bash
cd /path/to/jammonitor
./vps/generate-vps-manifest.sh
(cd vps && shasum -a 256 -c vps-files.sha256)
MANIFEST_SHA256="$(shasum -a 256 vps/vps-files.sha256 | awk '{print $1}')"
INSTALLER_SHA256="$(shasum -a 256 vps/install-tailscale-watchdog.sh | awk '{print $1}')"
printf 'manifest=%s\ninstaller=%s\n' \
  "$MANIFEST_SHA256" "$INSTALLER_SHA256"
```

The manifest covers the root-executed installer as well as all four installed
files; the generator itself is not a runtime payload. Record both digests
separately from the files being transferred. Copy the reviewed `vps` directory
to a root-owned staging directory on the VPS that is not group or world
writable. The directory, manifest, and every payload file must be owned by
`root:root` and must not be group or world writable. The installer enforces
that boundary before any target mutation.
Verify the installer digest before running it:

```bash
umask 077
UPLOAD_STAGE=/home/admin/jammonitor-vps-watchdog-upload
STAGE=/root/jammonitor-vps-watchdog-stage
install -d -m 0700 "$UPLOAD_STAGE"
# Copy the reviewed vps/* files into $UPLOAD_STAGE using the operator's
# normal SCP path before continuing.
sudo install -d -m 0700 -o root -g root "$STAGE"
sudo cp -p "$UPLOAD_STAGE"/* "$STAGE"/
sudo sh -c '
  set -eu
  chown root:root "$1"/*
  chmod go-w "$1" "$1"/*
' sh "$STAGE"
# Substitute the two values recorded above.
printf '%s  %s\n' '<INSTALLER_SHA256>' \
  "$STAGE/install-tailscale-watchdog.sh" | sudo sha256sum -c -
sudo sh "$STAGE/install-tailscale-watchdog.sh" \
  --validate-source "$STAGE" \
  --manifest-sha256 '<MANIFEST_SHA256>'
sudo sh "$STAGE/install-tailscale-watchdog.sh" \
  --source-dir "$STAGE" \
  --manifest-sha256 '<MANIFEST_SHA256>'
```

Install mode has these additional preflight gates:

- `/usr/bin/tailscale`, `/usr/bin/timeout`, `/usr/bin/jq`,
  `/usr/bin/logger`, `/usr/bin/flock`, and `/usr/bin/systemctl` must be
  regular executable files. These are the absolute paths used by the
  installed watchdog.
- `tailscaled.service` must already be present. The preflight reads only its
  load state. It does not start, stop, restart, enable, or disable it.
- Each owned target must be absent or a regular file, never a symlink or
  another file type.
- No unresolved rollback evidence or recovery bundle may exist.

The installer serializes installations with
`/run/lock/jammonitor-tailscale-watchdog-install.lock`. After taking the lock,
it validates the source a second time, records exact prior hashes, modes,
owners, and timer state, then stops only the JamMonitor timer and oneshot
service. It proves both units are quiescent before changing any target.

Each file is written to a random temporary file on the target filesystem,
checked against the pinned hash and exact metadata, then atomically renamed.
The installed watchdog must be `root:root` mode `0755`; the service, timer, and
README must be `root:root` mode `0644`. The units are verified before
`daemon-reload`, and the same hashes and metadata are checked again after the
requested timer state is applied.

For a new installation the timer is enabled but left stopped by default. This
prevents the deployment itself from initiating a recovery action. Inspect the
installed state, then start it explicitly:

```bash
sudo systemd-analyze verify \
  /etc/systemd/system/jammonitor-tailscale-watchdog.service \
  /etc/systemd/system/jammonitor-tailscale-watchdog.timer
sudo systemctl cat jammonitor-tailscale-watchdog.service
sudo systemctl cat jammonitor-tailscale-watchdog.timer
sudo systemctl start jammonitor-tailscale-watchdog.timer
sudo systemctl status jammonitor-tailscale-watchdog.timer --no-pager
```

Pass `--start` only when an immediate start is intended. An upgrade preserves
both prior timer properties: a disabled timer remains disabled and an inactive
timer remains inactive. A previously active timer resumes only after all
installed files and systemd operations verify. `--start` explicitly overrides
only the prior inactive state; it does not enable a timer that was disabled
before the upgrade.

The installer never changes `tailscaled.service`, the Tailscale state file, or
authentication. The watchdog itself can request its one bounded restart only
after the configured failure threshold.

## Operation

Read only the allowlisted snapshot:

```bash
sudo jq . /run/jammonitor-tailscale-watchdog/status.json
sudo systemctl list-timers jammonitor-tailscale-watchdog.timer --all
sudo journalctl -u jammonitor-tailscale-watchdog.service --since today
```

A current `NeedsLogin` result is an operator reauthorization problem. Restarting
the daemon cannot repair an expired node key. Resolve it through the authorized
Tailscale administrative workflow, then verify that supported valid responses
rearm the watchdog.

### Runtime acceptance

After Tailscale authentication and the critical-peer file are configured,
force one observation instead of waiting for the timer, then prove the timer
and the fresh schema-2 result:

```bash
set -eu
sudo systemctl is-enabled --quiet tailscaled.service
sudo systemctl is-active --quiet tailscaled.service
sudo systemctl start jammonitor-tailscale-watchdog.timer
sudo systemctl start jammonitor-tailscale-watchdog.service
sudo systemctl is-enabled --quiet jammonitor-tailscale-watchdog.timer
sudo systemctl is-active --quiet jammonitor-tailscale-watchdog.timer
[ "$(sudo systemctl show jammonitor-tailscale-watchdog.service \
  --property=Result --value)" = 'success' ]

STATUS=/run/jammonitor-tailscale-watchdog/status.json
NOW_EPOCH="$(date +%s)"
sudo jq -e --argjson now "$NOW_EPOCH" '
  .schema == 2 and
  (.observed_at | type) == "number" and
  ($now - .observed_at) >= 0 and
  ($now - .observed_at) <= 45 and
  .status == "running" and
  .healthy == true and
  .connected == true and
  .control_online == true and
  .localapi_valid == true and
  .service_active == true and
  .peer_configured == true and
  .peer_reachable == true and
  (.process_started_monotonic_usec | type) == "number" and
  .process_started_monotonic_usec > 0 and
  (.process_uptime_seconds | type) == "number" and
  .process_uptime_seconds >= 0
' "$STATUS" >/dev/null
sudo systemctl list-timers jammonitor-tailscale-watchdog.timer --all
sudo journalctl -u jammonitor-tailscale-watchdog.service \
  --since today --no-pager
```

This acceptance intentionally fails when no critical peer is configured,
when the peer is unreachable, or when only stale status remains.

### Bounded maintenance marker

Before an intentional transient stop or other `tailscaled.service` maintenance
action, create a marker containing the creation and expiry Unix epochs. The
expiry must be later than creation and the interval must not exceed one hour:

```bash
sudo install -d -m 0700 -o root -g root \
  /run/jammonitor-tailscale-watchdog
NOW_EPOCH="$(date +%s)"
case "$NOW_EPOCH" in ""|*[!0-9]*) exit 1 ;; esac
printf '%s %s\n' "$NOW_EPOCH" "$((NOW_EPOCH + 600))" |
  sudo tee /run/jammonitor-tailscale-watchdog/maintenance-until >/dev/null
sudo chmod 0600 \
  /run/jammonitor-tailscale-watchdog/maintenance-until
```

Remove the marker after maintenance. If the operator process crashes, the
absolute expiry prevents indefinite suppression. An invalid, expired, future
created, or more-than-one-hour marker fails open for recovery and is reported
as a bounded `maintenance_state` enum in `status.json`. Invalid marker content
is retained for operator diagnosis but is never copied into status or logs.

## Failure injection

Perform crash and LocalAPI-hang tests only with a separate working SSH path,
such as the public Lightsail SSH endpoint. Never inject a Tailscale failure
from a Tailscale-only session.

Before a test, confirm the normal systemd recovery policy and record the
current watchdog counters. A process crash should ordinarily be repaired by
`tailscaled.service` before the watchdog threshold. A controlled missing
socket or LocalAPI hang should result in one watchdog restart request, followed
by a latch until five valid responses. Peer, control-plane, authentication,
health, and generic CLI failures must not request a restart. Do not weaken the
production thresholds to make a test pass.

## Disable, uninstall, and rollback

Disable only the JamMonitor watchdog without affecting Tailscale:

```bash
sudo systemctl disable --now jammonitor-tailscale-watchdog.timer
sudo systemctl stop jammonitor-tailscale-watchdog.service
```

To uninstall, first disable the timer as above, then remove only the four owned
installation paths:

```bash
sudo rm -f /usr/local/libexec/jammonitor-tailscale-watchdog
sudo rm -f /etc/systemd/system/jammonitor-tailscale-watchdog.service
sudo rm -f /etc/systemd/system/jammonitor-tailscale-watchdog.timer
sudo rm -f /usr/share/doc/jammonitor-tailscale-watchdog/README.md
sudo rmdir /usr/share/doc/jammonitor-tailscale-watchdog 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl reset-failed jammonitor-tailscale-watchdog.service
sudo rm -rf /run/jammonitor-tailscale-watchdog
```

These commands do not remove, restart, disconnect, or reconfigure Tailscale.
For rollback to an earlier reviewed watchdog, rerun that version's installer
with its separately recorded manifest and installer digests.

An installation failure first quiesces both JamMonitor units, restores all
four prior files atomically, verifies every old hash, mode, and owner, reloads
systemd, then restores and verifies the prior timer enabled and active states.
It never reactivates the timer before every file restore and the reload have
succeeded.

If any restore, verification, reload, or state restoration is incomplete, the
installer fails safe: it keeps the JamMonitor timer and service stopped,
disables the timer, preserves the private recovery bundle, writes
`/var/lib/jammonitor-tailscale-watchdog/INSTALL-ROLLBACK-INCOMPLETE`, prints
both paths conspicuously, and returns nonzero. The bundle includes each prior
file, exact metadata, and `prior-timer-state`. Future installation attempts are
blocked while that evidence or an orphaned `transaction.*` bundle exists.

Do not delete incomplete evidence as a retry tactic. Maintain a separate,
working public SSH session, inspect the evidence and bundle, compare every
owned path, repair the failed restore, run `systemctl daemon-reload`, and leave
the watchdog stopped until the old or new payload is internally consistent.
Only then restore the recorded timer state and remove the reviewed evidence
and bundle.
