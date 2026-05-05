# AGENTS.md — bulletproof-mediastack
Project rules for any AI agent working in this repository.

## Self-Healing Deploy Script Standard
Any deployment, setup, install, provisioning, or system-bringup script you author or modify MUST be a self-healing script. It is not enough for it to "work on the happy path" — it must anticipate failures, detect them, and recover automatically. Apply ALL of the following without being asked:

1. RESEARCH BEFORE WRITING
   - Fetch the upstream Dockerfile, entrypoint, env example, lockfile, and compose for every component the script installs. Cite the resolved required env, version pins, capabilities, and ports in a script header comment. Never guess from memory.

2. SELF-TEST AT THE TOP OF THE SCRIPT
   - Run `bash -n "$0"` against itself and abort if it fails.
   - If `shellcheck` is available, run it; if not, install it (apt/nala/pkg). Treat warnings as warnings, errors as fatal.
   - Validate every required env var (length, format, allowed chars). If a required secret is missing, attempt to recover it from a known-good source on the system before failing.

3. PREFLIGHT (HOST/CONTAINER, BEFORE ANY MUTATION)
   - Authenticate every API token actually used (not just check it exists).
   - Reachability-probe every URL the script will hit (apt repos, GPG keys, GitHub releases, package mirrors, vendor APIs). Fail fast on unreachable endpoints with the URL printed.
   - Check available RAM and disk on host and target. Print warnings or abort with diagnostic.
   - Confirm every external resource (storage pool, network bridge, device node) exists.

4. ERR TRAP WITH FULL DIAGNOSTIC DUMP
   - Set `set -Eeuo pipefail` and a `trap` on ERR that captures: failing line, failing command, exit code, FUNCNAME stack, last 200 lines of relevant journal, `df -h`, `free -m`, listening ports, and dpkg status of critical packages. Write to `/var/log/<script>-failure-$TIMESTAMP.txt`.

5. PER-STEP verify–execute–heal PATTERN
   - Wrap every destructive step in a do_step engine: `verify` returns 0 if already in desired state (skip work); `execute` performs the step; `heal` runs on failure to remediate, then retry. Up to 3 attempts with backoff per step.

6. EXPLICIT HEALING PRIMITIVES FOR COMMON FAILURE MODES
   - apt/dpkg lock stuck → wait, kill stale processes, `dpkg --configure -a`, `apt-get --fix-broken install`, retry.
   - GPG key fetch flaky → retry with backoff, fall back to alternative key URL.
   - Disk pressure → prune pnpm/uv/npm caches, `journalctl --vacuum-size=200M`, retry; abort with diagnosis if still full.
   - Build OOM (Node/Vite/webpack) → stop non-essential services, raise NODE_OPTIONS/heap, retry.
   - FUSE mount failure → `fusermount -uz`, `umount -lf`, recreate mountpoint, retry.
   - PostgreSQL won't start/auth → fix locale, regenerate cluster if needed, repair pg_hba, reload, retry, then prove connectivity with a real query.
   - systemd unit inactive → `systemctl reset-failed`, `daemon-reload`, restart, capture journal if still failing.
   - Network/DNS blip → exponential backoff retry; rewrite resolv.conf as last resort.
   - GitHub release URL flake → fall back to vendor installer; pin version with checksum.

7. IDEMPOTENCY AND RESUMABILITY
   - Every step must be safe to re-run. Persist completion state (e.g. `/var/lib/<script>/state`) so reruns skip already-finished steps. Provide `--reset` to wipe state and `--resume` (default).
   - All resources (groups, users, dirs, packages, units) must be created with existence guards.

8. POSITIVE END-TO-END VERIFICATION
   - After enabling services, do not declare success on `systemctl is-active` alone. Run an HTTP/functional probe per service (active+responsive). For data services, run a real query. Loop with timeout and tail journal on failure.

9. NO STUBS, NO ZOMBIE CODE
   - Every code path is fully implemented. No "TODO", no "fix later", no commented-out branches. If a feature can't be completed, remove it.

10. PERSISTENT SECRETS, NEVER REGENERATED
    - Any secret the script generates (API keys, auth secrets) must be written once to a stable host path with mode 0600 and reused on every rerun.

11. POST-SUCCESS HOOK
    - On success, commit and push the script changes (with `Co-Authored-By: Oz <oz-agent@warp.dev>`), update related docs in the same commit, and write the resolved verification commands into the script's own summary output.

12. NEVER ASK THE USER A QUESTION YOU CAN ANSWER YOURSELF
    - If a value can be discovered (existing CT IDs, render gids, host gateway, DSN of an existing service), discover it. Asking the user for a value the system already knows is a violation of this rule.

Violation of any of the above is a defect. Do not create a deploy/setup script that does not satisfy every item.
