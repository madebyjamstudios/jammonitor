# JamMonitor VPS Tailscale Watchdog

This watchdog is the local, second-line recovery layer for the Debian OMR VPS.
The existing `tailscaled.service` remains responsible for normal process crash
recovery through systemd. The watchdog observes the supervisor and a bounded
LocalAPI request every 15 seconds.
It has no metrics database or hosted backend. Supabase and Convex are not used
and neither CLI nor either service's credentials belong on this VPS.

The LocalAPI command runs in a child with a 64 KiB output-file limit. An
attempt to exceed that limit is a command failure and never restart evidence.
A schema-valid response must contain `Health` as an array of no more than 100
strings, with each string having length no more than 512. Missing, null,
scalar, non-string, oversized, or over-count `Health` data is a schema error
and can never default to an empty healthy array.

It can request a bounded supervised restart episode in any of these cases:

1. `tailscaled.service` remains inactive for three consecutive observations.
2. The service is active but `/run/tailscale/tailscaled.sock` is absent or is
   not a Unix socket for three consecutive observations.
3. GNU `timeout` returns exactly 124 for
   `tailscale status --json --peers=false` in three consecutive observations
   while the service is active.

The first attempt occurs at the configured failure threshold. If the same
proven failure remains, attempt two is allowed only after a 60-second monotonic
cooldown and attempt three only after a further 300-second cooldown. Three
attempts exhaust automatic recovery. Five supported, schema-valid LocalAPI
responses reset the episode. A failed restart spends its attempt and observes
the same cooldowns, preventing both permanent one-shot stranding and a restart
storm.

Before invoking `systemctl restart`, the watchdog uses GNU
`/usr/bin/mv -T -f` to atomically replace its private memory file with the
recovery latch, attempt count, next monotonic deadline, and incremented
recovery count. A crash or `SIGKILL` during the restart therefore spends that
attempt, and the next timer run must honor the cooldown and cap. Invalid or
legacy spent retry state fails closed to exhausted recovery. If the state
commit fails, the watchdog does not restart Tailscale, exits unsuccessfully,
leaves a private continuity-break sentinel, and reports only the fixed
`watchdog_error`, `state_persistence_failed`, and
`restart_suppressed_state_persistence_failed` status enums.

This latch is durable across watchdog invocations only within the same boot.
Its `/run` directory is intentionally volatile. Reboot clears the latch and
memory, then the 120-second boot grace suppresses recovery while the host
settles. Do not claim that this recovery state survives power loss or reboot.
The VPS installer's separate transaction bundles under `/var/lib` are the
persistent recovery evidence for file deployment.

The following conditions are observable but never authorize a restart:

- `NeedsLogin`, including an expired node key
- `NeedsMachineAuth`
- a stopped or starting backend
- control-plane or TUN degradation
- health warnings
- a command failure that is not a proven timeout
- malformed or future status schemas
- peer or ACL failures

GNU `timeout` reserves 124 for its own deadline. Exit 137 or 143 is ambiguous
with OOM termination, an external signal, or a terminated wrapper, so the VPS
watchdog reports it as a generic command error and never counts it toward
recovery. A timeout or signal while querying `systemctl show` is likewise
observable but never restart-eligible.

An explicitly disabled or masked `tailscaled.service` is also an
operator-authoritative state and is never restarted. Only an inactive or
failed unit whose `UnitFileState` is exactly the persistent value `enabled` is
eligible. `enabled-runtime` does not survive reboot and is therefore never
healthy or eligible, just like disabled, masked, static, activating, reloading,
deactivating, and otherwise unmanaged states. An otherwise connected active
daemon in one of those states is reported as degraded and remains point-in-time
observable, but it is not considered reboot-durable.

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
never published or logged. The systemd unit also sets `LimitCORE=0`, so a
watchdog process or bounded child cannot persist those private runtime bytes in
a core dump.

Each run holds a nonblocking kernel `flock` on the persistent `watchdog.lock`
inode. The inode is never unlinked during normal or signal cleanup. The kernel
releases the held file-description lock on every exit, including `SIGKILL`, so
stale PID text and PID reuse cannot suppress later timer runs and concurrent
starts cannot lock different replacement inodes.

Because systemd can recover a short process crash entirely between 15-second
samples, `status.json` publishes systemd's numeric `NRestarts`, current
`ExecMainStartTimestampMonotonic`, and derived process uptime when those
properties are available. `NRestarts` is diagnostic only. It neither defines
the process generation nor resets connectivity uptime.
The process-start value must be positive and no later than the current
monotonic clock. A missing, zero, malformed, or future process generation can
leave point-in-time `connected=true`, but forces `running_degraded`,
`reason=process_generation_unknown`, `healthy=false`, and a new connectivity
evidence interval.

Continuity is bound to the exact positive
`ExecMainStartTimestampMonotonic`, exact normalized critical-peer contract,
and successfully persisted observation chain. Connectivity uptime resets when
the current or previous process-start value is missing or zero, the value
changes, the peer contract changes, the persisted continuity-break sentinel
exists, monotonic time regresses, there is no prior persisted observation, the
gap from that observation reaches 30 seconds, or `connected` is not true.
This deliberately refuses to bridge a known-generation to unknown-generation
to same-known-generation sequence, an unpersisted sample, a peer replacement,
or a missed timer interval.

Schema 3 defines `connected` as local tailnet data-plane readiness and removes
the legacy `in_engine` field:

- `BackendState` is `Running`
- at least one canonical IPv4 address in `100.64.0.0/10` or structurally valid
  full or compressed IPv6 address in `fd7a:115c:a1e0::/48` is present
- `TUN` is true
- the critical peer is reachable when one is configured

The critical-peer check uses
`tailscale ping --tsmp --c=1 --timeout=3s --until-direct=false`. TSMP traverses
WireGuard without depending on either host's OS ICMP policy, and
`--until-direct=false` accepts a working DERP path instead of misclassifying
relayed connectivity as down. This proves the Tailscale peer data path, not a
specific application on the peer. Use a separate application-level check when
that stronger claim is required. See the
[v1.98.9 ping contract](https://github.com/tailscale/tailscale/blob/v1.98.9/cmd/tailscale/cli/ping.go#L31-L58).
A critical-peer literal equal to any local `Self.TailscaleIPs` value is an
invalid configuration: it reports `peer_reachable=false`, breaks
`connected`, and never invokes `tailscale ping`.

`Self.InEngine` is intentionally not a local-readiness signal. Tailscale
v1.98.9 uses that shared status field for entries in the peer map that are
currently tracked by the WireGuard engine; the self-status builder does not set
it. A healthy local node therefore normally reports `Self.InEngine=false`.
JamMonitor neither requires nor republishes that peer-only field. See the
[v1.98.9 status definition](https://github.com/tailscale/tailscale/blob/v1.98.9/ipn/ipnstate/ipnstate.go#L309-L319),
[engine peer population](https://github.com/tailscale/tailscale/blob/v1.98.9/wgengine/userspace.go#L1297-L1314),
and [self-status population](https://github.com/tailscale/tailscale/blob/v1.98.9/ipn/ipnlocal/local.go#L1396-L1429).

`Self.Online=false` means the control plane is offline. It makes
`healthy=false`, `degraded=true`, and reports `reason=control_offline`, but it
does not erase `connected=true` or reset `connectivity_uptime_seconds` while
the local data plane remains ready. A health warning has the same
connected-uptime behavior. A missing TUN, missing tailnet address,
process-generation change, unknown observation, or configured critical-peer
failure breaks the connected interval.

The VPS may report
`Some peers are advertising routes but --accept-routes is false` while its
intentionally configured `--accept-routes=false` policy is working. Do not
enable route acceptance merely to clear this advisory. JamMonitor surfaces it
as `status=running_warning`, `health_warning=true`, `healthy=false`, and
`degraded=true`, while preserving `connected=true` when the local readiness
and critical-peer delivery checks still succeed. That example is not a blanket
allowlist. Acceptance requires an operator to inspect the exact raw `Health`
array from an adjacent private LocalAPI query and approve its digest. A
warning count or fixed `health_warning` enum alone is insufficient.

To require one critical peer, create exactly one Tailscale IP literal in the
optional configuration file. Hostnames are deliberately refused because an
alias for the local node could make a self-ping look like proof of remote
delivery:

```bash
sudo install -d -m 0755 -o root -g root /etc/jammonitor
ROUTER_TAILSCALE_IP='<ROUTER_TAILSCALE_IP>'
printf '%s\n' "$ROUTER_TAILSCALE_IP" |
  sudo tee /etc/jammonitor/tailscale-critical-peer >/dev/null
sudo chown root:root /etc/jammonitor/tailscale-critical-peer
sudo chmod 0644 /etc/jammonitor/tailscale-critical-peer
```

The peer identity and command output are never included in the snapshot or
journal. An invalid configuration fails closed for `connected` and is reported
only as the fixed `critical_peer_invalid` reason. An existing peer contract
must be a `root:root`, mode `0644`, single-link regular file with exactly one
bounded IP line. The watchdog joins its device, inode, size, content, and
metadata before and after TSMP and once more immediately before publication.
An atomic operator replacement during either window invalidates the sample,
breaks connectivity continuity, and never authorizes a restart.

The watchdog does not run `tailscale up`, change authentication, or configure
the host firewall. The router's OpenWrt `tailscale0` zone and
`--netfilter-mode=off` policy do not apply to this VPS. Keep the VPS's reviewed
Tailscale/host-firewall policy intact and verify application ports separately
from TSMP.

### Management-only DNS, route, and update preferences

The VPS is a management peer, not a Tailscale subnet-route or DNS client. An
operator must keep `--accept-dns=false`, `--accept-routes=false`,
`--update-check=true`, and `--auto-update=false`. Update checks stay enabled
so a reviewed upgrade can be scheduled, but unattended application is
disabled because it can restart Tailscale and change the status contract
outside this release's acceptance boundary. The watchdog only observes
runtime health and must never mutate Tailscale preferences. Preserve the VPS
default netfilter auto/on policy; do not copy the router's
`--netfilter-mode=off` setting onto Debian.

Record an allowlisted projection of the current preferences and the resolver,
apply only the four management flags with `tailscale set`, then prove ordinary
DNS, tailnet delivery, and the exact update policy. Never redirect or print raw
`tailscale debug prefs` output: Tailscale's preference view can contain
persistent private node and network-lock keys. The helper below streams raw
bytes directly into `jq` and stores only six reviewed scalar fields:

```bash
set -eu
umask 077
SAFE_BEFORE="$(mktemp)"
SAFE_AFTER="$(mktemp)"
PREFS_RC="$(mktemp)"
ROLLBACK_REQUIRED=0

cleanup_preferences() {
  cleanup_rc=$?
  trap - EXIT HUP INT TERM
  if [ "$ROLLBACK_REQUIRED" -eq 1 ]; then
    if sudo /usr/bin/timeout --signal=TERM --kill-after=2 10 \
         /usr/bin/tailscale set \
         --accept-dns="$BEFORE_DNS" \
         --accept-routes="$BEFORE_ROUTES" \
         --update-check="$BEFORE_UPDATE_CHECK" \
         --auto-update="$BEFORE_AUTO_UPDATE" >/dev/null 2>&1 &&
       capture_safe_preferences "$SAFE_AFTER" &&
       /usr/bin/jq -e \
         --argjson dns "$BEFORE_DNS" \
         --argjson routes "$BEFORE_ROUTES" \
         --argjson update_check "$BEFORE_UPDATE_CHECK" \
         --argjson auto_update "$BEFORE_AUTO_UPDATE" '
           .CorpDNS == $dns and
           .RouteAll == $routes and
           .AutoUpdateCheck == $update_check and
           .AutoUpdateApply == $auto_update
         ' \
         "$SAFE_AFTER" >/dev/null
    then
      :
    else
      echo "ERROR: Tailscale preference rollback could not be proven" >&2
      cleanup_rc=1
    fi
  fi
  rm -f "$SAFE_BEFORE" "$SAFE_AFTER" "$PREFS_RC"
  exit "$cleanup_rc"
}
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup_preferences EXIT

capture_safe_preferences() {
  safe_output="$1"
  : >"$PREFS_RC" || return 1
  if (
    set +e
    ulimit -c 0 || {
      printf '%s\n' 125 >"$PREFS_RC"
      exit 125
    }
    sudo /usr/bin/timeout --signal=TERM --kill-after=2 5 \
      /usr/bin/tailscale debug prefs 2>/dev/null
    producer_rc=$?
    printf '%s\n' "$producer_rc" >"$PREFS_RC"
    exit "$producer_rc"
  ) | (
    ulimit -c 0 || exit 125
    ulimit -f 1 || exit 125
    exec /usr/bin/jq -sce '
        if length == 1 and
           (.[0] | type) == "object" and
           (.[0].WantRunning | type) == "boolean" and
           (.[0].RouteAll | type) == "boolean" and
           (.[0].CorpDNS | type) == "boolean" and
           (.[0].NetfilterMode | type) == "number" and
           (.[0].AutoUpdate | type) == "object" and
           (.[0].AutoUpdate.Check | type) == "boolean" and
           (.[0].AutoUpdate.Apply | type) == "boolean"
        then
          .[0] | {
            WantRunning,
            RouteAll,
            CorpDNS,
            NetfilterMode,
            AutoUpdateCheck: .AutoUpdate.Check,
            AutoUpdateApply: .AutoUpdate.Apply
          }
        else
          error("unexpected prefs projection contract")
        end
      '
  ) >"$safe_output"
  then
    filter_rc=0
  else
    filter_rc=$?
  fi
  [ "$filter_rc" -eq 0 ] || return 1
  producer_result="$(cat "$PREFS_RC")" || return 1
  [ "$producer_result" = '0' ] || return 1
  safe_size="$(wc -c <"$safe_output" | tr -d ' ')" || return 1
  case "$safe_size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$safe_size" -le 128 ] || return 1
  /usr/bin/jq -e '
    keys == [
      "AutoUpdateApply",
      "AutoUpdateCheck",
      "CorpDNS",
      "NetfilterMode",
      "RouteAll",
      "WantRunning"
    ] and
    (.WantRunning | type) == "boolean" and
    (.RouteAll | type) == "boolean" and
    (.CorpDNS | type) == "boolean" and
    (.NetfilterMode | type) == "number" and
    (.AutoUpdateCheck | type) == "boolean" and
    (.AutoUpdateApply | type) == "boolean"
  ' "$safe_output" >/dev/null || return 1
  return 0
}

capture_safe_preferences "$SAFE_BEFORE"
BEFORE_DNS="$(/usr/bin/jq -r '.CorpDNS' "$SAFE_BEFORE")"
BEFORE_ROUTES="$(/usr/bin/jq -r '.RouteAll' "$SAFE_BEFORE")"
BEFORE_UPDATE_CHECK="$(/usr/bin/jq -r '.AutoUpdateCheck' "$SAFE_BEFORE")"
BEFORE_AUTO_UPDATE="$(/usr/bin/jq -r '.AutoUpdateApply' "$SAFE_BEFORE")"
case "$BEFORE_DNS" in true|false) ;; *) exit 1 ;; esac
case "$BEFORE_ROUTES" in true|false) ;; *) exit 1 ;; esac
case "$BEFORE_UPDATE_CHECK" in true|false) ;; *) exit 1 ;; esac
case "$BEFORE_AUTO_UPDATE" in true|false) ;; *) exit 1 ;; esac
printf 'reviewed prefs before: %s\n' "$(cat "$SAFE_BEFORE")"
sudo readlink -f /etc/resolv.conf
sudo sed -n '1,20p' /etc/resolv.conf

ROLLBACK_REQUIRED=1
sudo /usr/bin/timeout --signal=TERM --kill-after=2 10 \
  /usr/bin/tailscale set \
  --accept-dns=false \
  --accept-routes=false \
  --update-check=true \
  --auto-update=false

capture_safe_preferences "$SAFE_AFTER"
printf 'reviewed prefs after: %s\n' "$(cat "$SAFE_AFTER")"
/usr/bin/jq -e '
  .WantRunning == true and
  .RouteAll == false and
  .CorpDNS == false and
  .NetfilterMode == 2 and
  .AutoUpdateCheck == true and
  .AutoUpdateApply == false
' "$SAFE_AFTER" >/dev/null
sudo readlink -f /etc/resolv.conf
sudo sed -n '1,20p' /etc/resolv.conf
if sudo grep -Eq \
  '^nameserver[[:space:]]+(100[.]100[.]100[.]100([[:space:]]|$)|fd7a:115c:a1e0:)' \
  /etc/resolv.conf; then
  echo "Tailscale still owns the VPS resolver" >&2
  exit 1
fi
getent ahostsv4 deb.debian.org >/dev/null
sudo tailscale ping --tsmp --c=1 --timeout=3s \
  --until-direct=false '<ROUTER_TAILSCALE_IP>'

ROLLBACK_REQUIRED=0
rm -f "$SAFE_BEFORE" "$SAFE_AFTER" "$PREFS_RC"
trap - EXIT HUP INT TERM
```

Acceptance requires `WantRunning=true`, `RouteAll=false`, `CorpDNS=false`,
`AutoUpdateCheck=true`, and `AutoUpdateApply=false` in the reviewed six-field
projection. `NetfilterMode` must remain at the reviewed Debian auto/on value.
`/etc/resolv.conf` must no longer contain either Tailscale resolver address
shown above, the public DNS lookup must succeed, and the router TSMP probe must
still succeed. On an ordinary command failure or handled signal after
mutation, the exit trap attempts and proves restoration of all four prior
boolean preferences. A failed rollback is loud and returns unsuccessfully.
`SIGKILL` and power loss cannot execute a shell trap, so an interrupted run
still requires the operator to recapture the safe projection and compare it
with the recorded pre-change values. Resolver recovery requires operator
review if the host's ordinary resolver does not return. Review Tailscale
release notes and run a fresh watchdog compatibility and restart acceptance
test before any manual package upgrade; update availability alone does not
authorize applying it.

For both infrastructure nodes, disable key expiry directly or use a narrowly
granted tag whose policy disables expiry. If organizational policy requires
expiry, assign an owner, document and test rotation, and configure an
independent key-expiry alarm with enough lead time to rotate safely. A
watchdog restart cannot repair an expired key.

## Verified local installation

Complete the repository-wide release gate in the root README first. It runs
all shell suites under both `sh` and `dash`, parses both JavaScript files,
parses `jammonitor.lua` with Lua 5.1, validates the AWS stack, and regenerates
and verifies both router and VPS manifests. The commands below are the
subsequent VPS staging procedure, not a substitute for that gate.

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

- `/usr/bin/tailscale`, GNU `/usr/bin/timeout`, `/usr/bin/jq`,
  `/usr/bin/logger`, `/usr/bin/flock`, `/usr/bin/dd`, `/usr/bin/stat`, GNU
  `/usr/bin/mv`, and `/usr/bin/systemctl` must be regular executable files. These are the
  absolute paths used by the installed watchdog. GNU `mv` is required because
  the state and status commit boundary uses `mv -T -f`; a plain move that can
  nest the temporary file inside a directory target is rejected. `dd` provides
  the bounded single-read snapshots used for maintenance, peer, and prior
  memory inputs.
- The installer requires executable `/bin/sync` for its durable write-ahead
  and evidence-removal barriers.
- `tailscaled.service` must already be present. The preflight reads only its
  load state. It does not start, stop, restart, enable, or disable it.
- Each owned target must be absent or a regular file, never a symlink or
  another file type.
- No unresolved rollback evidence or recovery bundle may exist.

The installer serializes installations with a nonblocking kernel `flock` on
the persistent
`/var/lib/jammonitor-tailscale-watchdog/install.lock` inode. It never unlinks
that inode. Descriptor close, including kernel cleanup after `SIGKILL`, is the
only ownership transition, so simultaneous installers cannot lock different
replacement files. After taking the lock, it validates the source a second
time, records exact prior hashes, modes, owners, and timer state, then stops
only the JamMonitor timer and oneshot service. It proves both units are
quiescent before changing any target.

Before quiescence or target mutation, the installer writes a root-only
`transaction.*` write-ahead bundle under
`/var/lib/jammonitor-tailscale-watchdog`, records the prior file bytes and
metadata plus timer state, verifies them, writes a hash seal, synchronizes the
sealed bundle, and synchronizes its parent directory. Only that durable
boundary authorizes mutation. After the new files, unit reload, and requested
timer state all verify, it synchronizes every live target and the recovery
directory before removing the exact transaction bundle, then synchronizes the
recovery directory again after removal. Verified rollback follows the same
live-target, pre-clear, delete, and post-delete ordering. A failed barrier or
`SIGKILL` preserves a sealed bundle that blocks retry instead of treating
unsynchronized bytes as committed.

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
authentication. The watchdog itself can request only the bounded three-attempt
episode described above, beginning after the configured failure threshold.

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
and the fresh schema-3 result:

```bash
set -eu
ROUTER_TAILSCALE_IP='<ROUTER_TAILSCALE_IP>'
[ "$(sudo cat /etc/jammonitor/tailscale-critical-peer)" = \
  "$ROUTER_TAILSCALE_IP" ]
sudo systemctl is-enabled --quiet tailscaled.service
[ "$(sudo systemctl show tailscaled.service \
  --property=UnitFileState --value)" = 'enabled' ]
sudo systemctl is-active --quiet tailscaled.service
sudo systemctl start jammonitor-tailscale-watchdog.timer
[ "$(sudo systemctl show jammonitor-tailscale-watchdog.service \
  --property=LimitCORE --value)" = '0' ]
[ "$(sudo systemctl show jammonitor-tailscale-watchdog.service \
  --property=LimitCORESoft --value)" = '0' ]

STATUS=/run/jammonitor-tailscale-watchdog/status.json
OLD_OBSERVED_AT="$(
  sudo jq -r '.observed_at // 0' "$STATUS" 2>/dev/null || printf '0'
)"
case "$OLD_OBSERVED_AT" in ""|*[!0-9]*) exit 1 ;; esac
# observed_at has one-second resolution; cross the prior second deliberately.
sleep 1
sudo systemctl start jammonitor-tailscale-watchdog.service
sudo systemctl is-enabled --quiet jammonitor-tailscale-watchdog.timer
sudo systemctl is-active --quiet jammonitor-tailscale-watchdog.timer
[ "$(sudo systemctl show jammonitor-tailscale-watchdog.service \
  --property=Result --value)" = 'success' ]
[ "$(sudo cat /etc/jammonitor/tailscale-critical-peer)" = \
  "$ROUTER_TAILSCALE_IP" ]
[ "$(sudo sed -n 's/^peer_contract_key=//p' \
  /run/jammonitor-tailscale-watchdog/memory | tail -n 1)" = \
  "$ROUTER_TAILSCALE_IP" ]

NOW_EPOCH="$(date +%s)"
sudo jq -e \
  --argjson now "$NOW_EPOCH" \
  --argjson old "$OLD_OBSERVED_AT" '
  .schema == 3 and
  (.observed_at | type) == "number" and
  .observed_at > $old and
  ($now - .observed_at) >= 0 and
  ($now - .observed_at) <= 45 and
  .connected == true and
  .control_online == true and
  .localapi_valid == true and
  .service_active == true and
  .unit_file_state == "enabled" and
  .peer_configured == true and
  .peer_reachable == true and
  (
    (
      .status == "running" and
      .reason == "ok" and
      .healthy == true and
      .degraded == false and
      .health_warning == false
    ) or
    (
      .status == "running_warning" and
      .reason == "health_warning" and
      .healthy == false and
      .degraded == true and
      .health_warning == true
    )
  ) and
  (.process_started_monotonic_usec | type) == "number" and
  .process_started_monotonic_usec > 0 and
  (.process_uptime_seconds | type) == "number" and
  .process_uptime_seconds >= 0 and
  (.connectivity_uptime_seconds | type) == "number" and
  .connectivity_uptime_seconds >= 0
' "$STATUS" >/dev/null

RAW_STATUS="$(mktemp /tmp/jammonitor-tailscale-status.XXXXXX)"
RAW_HEALTH="$(mktemp /tmp/jammonitor-tailscale-health.XXXXXX)"
trap 'rm -f "$RAW_STATUS" "$RAW_HEALTH"' EXIT HUP INT TERM
sudo /usr/bin/timeout --signal=TERM --kill-after=2 5 \
  /bin/sh -c 'ulimit -f "$1" || exit 125; shift; exec "$@"' \
  jammonitor-acceptance-limit 128 \
  /usr/bin/tailscale --socket=/run/tailscale/tailscaled.sock \
  status --json --peers=false > "$RAW_STATUS"
[ "$(wc -c < "$RAW_STATUS" | tr -d ' ')" -le 65536 ]
jq -e '
  (type == "object") and
  (.BackendState | type == "string" and length > 0) and
  (.Health | type == "array") and
  (.Health | length <= 100) and
  (all(.Health[]; type == "string" and length <= 512))
' "$RAW_STATUS" >/dev/null
jq -c '.Health' "$RAW_STATUS" > "$RAW_HEALTH"
RAW_HEALTH_COUNT="$(jq -r 'length' "$RAW_HEALTH")"
RAW_HEALTH_SHA256="$(sha256sum "$RAW_HEALTH" | awk '{print $1}')"
STATUS_HEALTH_WARNING="$(sudo jq -r '.health_warning' "$STATUS")"
case "$STATUS_HEALTH_WARNING" in
  false)
    [ "$RAW_HEALTH_COUNT" = '0' ]
    ;;
  true)
    [ "$RAW_HEALTH_COUNT" -gt 0 ]
    jq -r '.[] | "Tailscale Health: \(.)"' "$RAW_HEALTH" >&2
    printf 'raw Health SHA256: %s\n' "$RAW_HEALTH_SHA256" >&2
    [ -n "${REVIEWED_HEALTH_SHA256:-}" ]
    [ "$REVIEWED_HEALTH_SHA256" = "$RAW_HEALTH_SHA256" ]
    ;;
  *) exit 1 ;;
esac

FIRST_OBSERVED_AT="$(sudo jq -r '.observed_at' "$STATUS")"
FIRST_GENERATION="$(sudo jq -r \
  '.process_started_monotonic_usec' "$STATUS")"
FIRST_PROCESS_UPTIME="$(sudo jq -r '.process_uptime_seconds' "$STATUS")"
FIRST_CONNECTIVITY_UPTIME="$(sudo jq -r \
  '.connectivity_uptime_seconds' "$STATUS")"
sleep 2
sudo systemctl start jammonitor-tailscale-watchdog.service
[ "$(sudo systemctl show jammonitor-tailscale-watchdog.service \
  --property=Result --value)" = 'success' ]
sudo jq -e \
  --argjson observed "$FIRST_OBSERVED_AT" \
  --argjson generation "$FIRST_GENERATION" \
  --argjson process_uptime "$FIRST_PROCESS_UPTIME" \
  --argjson connectivity_uptime "$FIRST_CONNECTIVITY_UPTIME" '
    .observed_at > $observed and
    .connected == true and
    .peer_configured == true and
    .peer_reachable == true and
    .process_started_monotonic_usec == $generation and
    .process_uptime_seconds > $process_uptime and
    .connectivity_uptime_seconds > $connectivity_uptime
  ' "$STATUS" >/dev/null
[ "$(sudo cat /etc/jammonitor/tailscale-critical-peer)" = \
  "$ROUTER_TAILSCALE_IP" ]
[ "$(sudo sed -n 's/^peer_contract_key=//p' \
  /run/jammonitor-tailscale-watchdog/memory | tail -n 1)" = \
  "$ROUTER_TAILSCALE_IP" ]

sudo systemctl list-timers jammonitor-tailscale-watchdog.timer --all
sudo journalctl -u jammonitor-tailscale-watchdog.service \
  --since today --no-pager
rm -f "$RAW_STATUS" "$RAW_HEALTH"
trap - EXIT HUP INT TERM
```

This acceptance intentionally fails when no critical peer is configured,
when the peer is unreachable, when only stale status remains, when the peer
file changes across either forced observation, or when the private persisted
peer-contract key is not the exact configured IPv4 literal. A warning passes
only after the raw adjacent `Health` array is reviewed and its exact digest is
supplied as `REVIEWED_HEALTH_SHA256`. The second forced observation proves
that process and delivered-connectivity uptime advance for the same exact
process generation and peer contract.

### Bounded maintenance marker

Before an intentional transient stop or other `tailscaled.service` maintenance
action, create a marker containing the creation and expiry Unix epochs. The
expiry must be later than creation and the interval must not exceed one hour:

```bash
sudo install -d -m 0700 -o root -g root \
  /run/jammonitor-tailscale-watchdog
NOW_EPOCH="$(date +%s)"
case "$NOW_EPOCH" in ""|*[!0-9]*) exit 1 ;; esac
MAINTENANCE=/run/jammonitor-tailscale-watchdog/maintenance-until
sudo test ! -e "$MAINTENANCE"
sudo test ! -L "$MAINTENANCE"
sudo sh -c '
  set -C
  umask 077
  printf "%s %s\n" "$1" "$2" > "$3"
' sh "$NOW_EPOCH" "$((NOW_EPOCH + 600))" "$MAINTENANCE"
```

Remove the marker after maintenance. If the operator process crashes, the
absolute expiry prevents indefinite suppression. An invalid, expired, future
created, or more-than-one-hour marker fails open for recovery and is reported
as a bounded `maintenance_state` enum in `status.json`. Invalid marker content
is retained for operator diagnosis but is never copied into status or logs.
A symlink or any other non-regular maintenance path is
`maintenance_state=invalid_type`; it is never followed and never suppresses
recovery.

## Failure injection

Perform crash and LocalAPI-hang tests only with a separate working SSH path,
such as the public Lightsail SSH endpoint. Never inject a Tailscale failure
from a Tailscale-only session.

Before a test, confirm the normal systemd recovery policy and record the
current watchdog counters. A process crash should ordinarily be repaired by
`tailscaled.service` before the watchdog threshold. A controlled missing
socket or LocalAPI hang should result in the first watchdog restart request,
a second only after the 60-second cooldown, a third only after the subsequent
300-second cooldown, and then an exhausted state. Five valid responses reset
the episode. Peer, control-plane, authentication, health, and generic CLI
failures must not request a restart.
Do not weaken the production thresholds to make a test pass.

First run one controlled generation-reset check from the public SSH session.
This is a deliberate service restart, not a crash injection:

```bash
set -eu
STATUS=/run/jammonitor-tailscale-watchdog/status.json
ROUTER_TAILSCALE_IP='<ROUTER_TAILSCALE_IP>'
BEFORE_GENERATION="$(sudo jq -r \
  '.process_started_monotonic_usec' "$STATUS")"
BEFORE_OBSERVED_AT="$(sudo jq -r '.observed_at' "$STATUS")"

STATE_DIR=/run/jammonitor-tailscale-watchdog
MAINTENANCE="$STATE_DIR/maintenance-until"
NOW_EPOCH="$(date +%s)"
sudo install -d -m 0700 -o root -g root "$STATE_DIR"
printf '%s %s\n' "$NOW_EPOCH" "$((NOW_EPOCH + 300))" |
  sudo tee "$MAINTENANCE" >/dev/null
sudo chmod 0600 "$MAINTENANCE"
trap 'sudo rm -f "$MAINTENANCE"' EXIT HUP INT TERM
sudo systemctl restart tailscaled.service
sudo systemctl is-active --quiet tailscaled.service
sudo rm -f "$MAINTENANCE"
trap - EXIT HUP INT TERM

for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
do
  sudo systemctl start jammonitor-tailscale-watchdog.service
  AFTER_GENERATION="$(sudo jq -r \
    '.process_started_monotonic_usec' "$STATUS")"
  AFTER_OBSERVED_AT="$(sudo jq -r '.observed_at' "$STATUS")"
  AFTER_CONNECTED="$(sudo jq -r '.connected' "$STATUS")"
  if [ "$AFTER_GENERATION" != "$BEFORE_GENERATION" ] &&
     [ "$AFTER_OBSERVED_AT" -gt "$BEFORE_OBSERVED_AT" ] &&
     [ "$AFTER_CONNECTED" = 'true' ]; then
    break
  fi
  sleep 2
done
[ "$AFTER_GENERATION" != "$BEFORE_GENERATION" ]
[ "$AFTER_CONNECTED" = 'true' ]
RESET_UPTIME="$(sudo jq -r '.connectivity_uptime_seconds' "$STATUS")"
[ "$RESET_UPTIME" -ge 0 ]
[ "$RESET_UPTIME" -le 20 ]
[ "$(sudo cat /etc/jammonitor/tailscale-critical-peer)" = \
  "$ROUTER_TAILSCALE_IP" ]
[ "$(sudo sed -n 's/^peer_contract_key=//p' \
  "$STATE_DIR/memory" | tail -n 1)" = "$ROUTER_TAILSCALE_IP" ]

sleep 2
sudo systemctl start jammonitor-tailscale-watchdog.service
sudo jq -e \
  --argjson generation "$AFTER_GENERATION" \
  --argjson observed "$AFTER_OBSERVED_AT" \
  --argjson uptime "$RESET_UPTIME" '
    .process_started_monotonic_usec == $generation and
    .observed_at > $observed and
    .connected == true and
    .connectivity_uptime_seconds > $uptime
  ' "$STATUS" >/dev/null
```

The generation must change, the first proven connected sample must start a new
low uptime interval, and a second sample for the same generation must advance
it. Then rerun the full runtime-acceptance block and the separate router
SSH/LuCI application probes.

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

These `/var/lib` artifacts are persistent across reboot, unlike the watchdog's
same-boot `/run` latch. Do not delete incomplete evidence as a retry tactic.
Maintain a separate, working public SSH session and inspect it read-only:

```bash
set -eu
RECOVERY=/var/lib/jammonitor-tailscale-watchdog
sudo test -f "$RECOVERY/INSTALL-ROLLBACK-INCOMPLETE"
sudo test ! -L "$RECOVERY/INSTALL-ROLLBACK-INCOMPLETE"
sudo sed -n '1,120p' "$RECOVERY/INSTALL-ROLLBACK-INCOMPLETE"
sudo find "$RECOVERY" -maxdepth 2 -type f -print
```

Copy the marker and complete named `transaction.*` bundle off-host before any
repair. Compare each of the four owned targets with its saved bytes and `.meta`
record, and inspect `prior-timer-state`. Keep both JamMonitor units stopped
while restoring either the complete old file set or the complete new manifest
set. Run `systemd-analyze verify`, `systemctl daemon-reload`, verify every file
hash/mode/owner, and restore the exact recorded timer enabled and active
states. Only after all those checks pass may the exact reviewed evidence file
and named bundle be removed. Then rerun the verified installer and the full
runtime acceptance gate.
