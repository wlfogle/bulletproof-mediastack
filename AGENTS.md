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

## Pre-Action Discipline (HARD FAST RULES — enforced before EVERY action)
These rules are not guidelines, not weighed against speed, not skipped when the work feels obvious. Any agent working in this repository MUST mentally pass this checklist before each non-trivial action (writing a script, running a command, proposing a change, asking the user a question). Failing any item means stop and fix it before proceeding — not "next time".

1. PRIOR ART FIRST
   Have I read the repo for an existing implementation of this exact thing? Run `grep -rli` / `ls` / `read_files` of `pi/`, `bahamut/`, `infrastructure/`, `services/`, `scripts/`, `docs/` for any prior compose file, setup script, systemd unit, or doc that already addresses this. If prior art exists, I use it — I do not reinvent. Reinventing what already exists in the repo is a defect.

2. DISCOVER, DO NOT ASK
   Can the value (token, key, IP, port, hostname, file path, version pin, MAC, GID) be discovered from a running system, an existing config file, an `pct config`, an `ssh ... cat`, a repo grep, or a documented credentials file? If yes, I discover it. I do not ask the user. Asking the user a value the system already knows is a violation. (Restates AGENTS.md §12.)

3. SELF-TEST BEFORE DEPLOY
   Before I run any script I authored or modified, `bash -n script.sh` and `shellcheck -S warning script.sh` must both succeed. If `shellcheck` is missing, I install it (nala/apt). I do not deploy a script I have not linted. (Restates AGENTS.md §2; this rule is the enforcement.)

4. SELF-HEALING SCRIPT STANDARD APPLIES
   Every deploy / setup / install / provisioning / system-bringup script I author or modify must satisfy ALL twelve items above (research before writing, self-test, preflight, ERR trap with diagnostic dump, verify-execute-heal, healing primitives, idempotency/resumability, positive end-to-end verification, no stubs, persistent secrets, post-success commit hook, never ask discoverable values).

5. ACTION + DOCS + COMMIT IN THE SAME CHANGE
   When I deliver work, the code change, the docs update, and the git commit + push happen in the same change. "I'll commit later" is a violation. The commit message includes `Co-Authored-By: Oz <oz-agent@warp.dev>`. Docs that were rendered stale by the change get updated in the same commit.

6. PROBE OVER ASK
   If a single read-only probe (a `dig`, a `curl`, a `systemctl is-active`, a `pct status`, a `cat`) would answer my question, I run the probe — I do not ask the user. Even when the probe might fail, the failure mode of the probe is itself useful information. Asking instead of probing wastes credits and violates AGENTS.md §12.

7. NO STUBS, NO PLACEHOLDERS, NO TODOs
   Every code path I commit is fully implemented. No `# TODO`, no commented-out branches, no "fix later". If a feature can't be completed in this change, I remove it from this change — I don't ship a half-feature. (Restates AGENTS.md §9.)

8. PER-USER PREFERENCES ARE RULES, NOT SUGGESTIONS
   The user's stated preferences — use nala over apt, no sudo inside containers (root already), do not summarize until task is fully done, never reboot without permission, AdGuard belongs on Bahamut, services consolidate into CT-300 — are imperative. They override defaults.

Violation of any of the eight items above is a defect. The remediation is to stop, identify which item I failed, fix the failure, and only then continue. Speed is not a justification.
