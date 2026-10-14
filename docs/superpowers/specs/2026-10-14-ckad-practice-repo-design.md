# CKAD Practice Repository — Design

**Date:** 2026-10-14
**Status:** Approved for planning

## Purpose

A local repository for drilling the CKAD exam curriculum. The user practices by
solving scoped tasks against a real multi-node Kubernetes cluster and gets
objective pass/fail feedback without reading the answer first.

Success criteria:

- Every drill is self-grading against live cluster state.
- A drill can be reset to a clean starting state in about a second.
- Practice happens in bash with exam-style aliases, so the habits transfer.
- Adding a new drill takes roughly 15 minutes.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Practice format | Topic drills grouped by curriculum domain | Matches how the exam is weighted; allows grinding weak areas |
| Cluster | `kind`, 1 control-plane + 2 workers | Multi-node matches the exam; create/destroy in ~60s |
| Feedback | Self-grading `verify.sh` per drill | Objective, retryable, no spoilers |
| Shell | bash via Git Bash | Exam terminal is Linux bash; quoting and jsonpath habits transfer |
| Verify architecture | Shared `lib/assert.sh` + thin per-drill scripts | Full bash expressiveness, uniform output, no custom DSL |

Rejected: a declarative `checks.yaml` + generic runner (invents a DSL that
breaks on `kubectl exec` and retry loops); standalone bash per drill (style
drift produces checks that pass without checking).

## Environment baseline

Confirmed present on the machine: `kubectl`, `docker` (Docker Desktop installed,
engine currently stopped), `wsl`, `git`. Absent: `kind`, `helm`, `kustomize`,
`minikube`.

One-time prerequisites, documented in the README and surfaced by `bootstrap.sh`
preflight errors — never installed silently:

```
winget install Kubernetes.kind
winget install Helm.Helm
winget install Kubernetes.kustomize
```

Docker Desktop must be running before `bootstrap.sh`.

A `.gitattributes` with `*.sh text eol=lf` is mandatory, not cosmetic. Git on
Windows otherwise checks scripts out with CRLF endings, which makes
`#!/usr/bin/env bash` fail under Git Bash with a `bad interpreter` error that
names the wrong cause.

## Repository layout

```
pratice_ckad/
├── README.md                    # quickstart, exam-day cheatsheet, progress table
├── .gitignore                   # scratch/, .ckad-state.json, kubeconfig, *.local.yaml
├── .gitattributes               # *.sh eol=lf — CRLF breaks bash shebangs
├── cluster/
│   ├── kind-config.yaml
│   └── bootstrap.sh
├── bin/
│   ├── ckad                     # single entrypoint
│   ├── setup-shell.sh           # aliases, $do/$now, completion, vim YAML config
│   └── selftest.sh              # validates the drills themselves
├── lib/
│   └── assert.sh                # assertion primitives + reporting
├── drills/
│   ├── 1-design-build/          # 20%
│   ├── 2-deployment/            # 20%
│   ├── 3-observability/         # 15%
│   ├── 4-app-environment/       # 25%
│   └── 5-services-networking/   # 20%
└── scratch/                     # gitignored working area
```

Each drill directory is `drills/<domain>/<nn>-<slug>/`:

```
├── task.md        # scenario, numbered requirements, target time
├── setup.sh       # optional; creates the namespace and pre-seeds state
├── verify.sh      # assertions
└── .solution/     # reference manifest + explanation
```

Domain directories are numbered so listings order by curriculum weight. Drill
numbering within a domain is `01`, `02`, … and the drill id used on the command
line is `<domain>.<drill>` (e.g. `3.2`).

## Components

### `cluster/kind-config.yaml`

- 1 control-plane, 2 workers.
- `extraPortMappings` for host 80 and 443 on the control-plane node, so Ingress
  resources are reachable at `localhost`.
- Worker `node-labels`: `disk=ssd` on worker 1, `zone=a` on worker 2, giving
  nodeSelector and affinity drills real labels to select on.

### `cluster/bootstrap.sh`

Idempotent. Exits early if the `ckad` cluster already exists, unless
`--recreate` is passed.

1. Preflight: `docker info` reachable; `kind` and `kubectl` on PATH. Each
   failure prints the exact remediation command and exits non-zero.
2. `kind create cluster --name ckad --config cluster/kind-config.yaml`.
3. Install `ingress-nginx` (kind provider manifest), then wait for the admission
   webhook to become ready. Without the wait, the first Ingress apply fails for
   reasons unrelated to the user's YAML.
4. Install `metrics-server` with `--kubelet-insecure-tls`. Without this flag
   `kubectl top` and HPA drills silently never report metrics on kind.

### `bin/ckad`

| Command | Behavior |
|---|---|
| `ckad list [domain]` | Table of id, title, target time, last result |
| `ckad start <id>` | Prints `task.md`, runs `setup.sh`, creates `scratch/<id>/`, starts a timer |
| `ckad verify <id>` | Runs `verify.sh`, prints per-requirement result, records outcome |
| `ckad solution <id>` | Prints `.solution/`; refuses until at least one verify attempt exists |
| `ckad reset [<id>\|--all]` | Deletes the drill namespace, or recreates the cluster |
| `ckad score` | Per-domain pass rate, weighted as on the exam |

Two properties carry the design:

- **Namespace isolation.** Each drill operates in its own namespace
  (`ckad-<domain>-<drill>`, e.g. `ckad-3-2`), created by `setup.sh` and deleted
  by `reset`. Leftover objects from one drill cannot satisfy another, and reset
  costs a namespace delete rather than a cluster rebuild.
- **Gated solutions.** `ckad solution` requires a prior verify attempt. The
  failure mode of a repo like this is reading answers and mistaking it for
  practice.

State lives in `.ckad-state.json` (gitignored):
`{ "<id>": { "attempts": n, "passed": bool, "best_time": seconds } }`.
`ckad score` reads it to identify the weakest domain.

### `lib/assert.sh`

Sources into each `verify.sh`. Owns all output formatting and the final exit
code. A `verify.sh` declares its namespace via `ns <namespace>` and then calls
assertions:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../../../lib/assert.sh"
ns ckad-3-2

assert_exists    deployment/web
assert_jsonpath  deployment/web '{.spec.replicas}' 2
assert_jsonpath  deployment/web '{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' /healthz
assert_pod_ready -l app=web --count 2
assert_logs      -l app=web --contains "listening on 8080"

finish
```

Primitives:

| Assertion | Checks |
|---|---|
| `assert_exists <resource>` | Resource is present |
| `assert_absent <resource>` | Resource is not present |
| `assert_jsonpath <resource> <path> <expected>` | Field equals expected value |
| `assert_pod_ready [-l sel] [--count n]` | Pods matching selector are Ready |
| `assert_logs [-l sel] --contains <str>` | Container logs contain a string |
| `assert_exec <pod> -- <cmd>` | Command succeeds inside a container |
| `assert_http <url> [--status n]` | HTTP reachable, via curl from an ephemeral Pod |
| `retry_until <seconds> <assertion…>` | Wraps any assertion for rollouts and probes |

`assert_http` runs curl from an ephemeral in-cluster Pod rather than from the
host, because that is the only truthful way to test a ClusterIP Service or a
NetworkPolicy.

Each failed assertion prints the resource, the expected value and the actual
value, so a failure localizes the problem instead of only reporting that one
exists. `finish` prints a summary and exits 0 only if every assertion passed.

Two deliberate constraints:

- Assertions read **live cluster state, never the user's YAML files**. Solving a
  drill imperatively with `kubectl create` — the correct instinct under exam time
  pressure — passes exactly as an applied manifest does.
- No assertion checks *how* a state was reached, only the end state.

### `bin/setup-shell.sh`

Sourced per session. Provides the exam-day productivity layer:

- Aliases: `k`, `kgp`, `kgd`, `kn` (namespace switch), `kdp`.
- `export do='--dry-run=client -o yaml'`, `export now='--force --grace-period=0'`.
- `kubectl` completion wired to the `k` alias.
- `KUBE_EDITOR` set to vim.
- A `~/.vimrc` block (`set ts=2 sw=2 et nu`, appended only if absent) so YAML
  indentation stops fighting the user.

Practicing with this layer active is part of the training, not a convenience.

### `bin/selftest.sh`

Validates the drills themselves. For each drill: apply `.solution/`, assert
`verify.sh` exits 0; delete the namespace, assert `verify.sh` exits non-zero.
This catches the two defects that would waste the user's practice time — a
verify script stricter than its own reference solution, and a verify script that
passes against an empty namespace.

## Initial content

Ten drills, two per domain. The goal is a proven harness rather than a question
bank; 60 shallow drills would be worth less than 10 that work.

| Domain | Drill | Focus |
|---|---|---|
| 1 Design & Build | 1.1 | Multi-container Pod with a sidecar sharing an `emptyDir` |
| 1 Design & Build | 1.2 | Init container ordering and a Job with `backoffLimit` |
| 2 Deployment | 2.1 | Rollout with `maxSurge`/`maxUnavailable`, undo to a named revision |
| 2 Deployment | 2.2 | `kustomize` overlay changing replicas and image tag |
| 3 Observability | 3.1 | Diagnose a failing readiness probe from events and logs |
| 3 Observability | 3.2 | Add liveness, readiness and startup probes to a slow-starting app |
| 4 App Environment | 4.1 | ConfigMap as volume plus Secret as env vars |
| 4 App Environment | 4.2 | `runAsNonRoot` SecurityContext that breaks the image, plus resource limits |
| 5 Services & Networking | 5.1 | ClusterIP → Ingress path-based routing |
| 5 Services & Networking | 5.2 | Default-deny NetworkPolicy, then selective ingress allow |

Every drill ships with a `task.md`, a `verify.sh` that has been executed against
a real cluster, and a `.solution/`. Drills are added later at roughly 15 minutes
each, including ones the user invents from observed weak spots.

## Error handling

- `bootstrap.sh` preflight failures print the specific remediation command.
- `ckad` validates the drill id against the filesystem and lists valid ids on a
  miss.
- `ckad verify` on a drill never started reports that rather than failing
  assertions confusingly.
- Assertions time out rather than hanging; `retry_until` bounds every wait.
- `assert_*` against a nonexistent namespace reports the missing namespace once
  instead of emitting one failure per assertion.

## Out of scope

Timed full-length mock exams, a CI pipeline, cloud clusters, and PowerShell
script equivalents. The drill format can accommodate mock exams later by
grouping drill ids under a shared timer; nothing in this design blocks it.
