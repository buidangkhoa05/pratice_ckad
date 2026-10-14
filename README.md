# CKAD practice

Self-grading Kubernetes drills, grouped by the CKAD curriculum domains and run
against a local three-node kind cluster.

## One-time setup

    winget install Kubernetes.kind      # kubectl and docker are already present
    # start Docker Desktop, wait for "Running"
    bash cluster/bootstrap.sh           # ~4 min: cluster, Calico, ingress, metrics

Cluster: 1 control-plane + 2 workers (labelled `disk=ssd` and `zone=a` for
nodeSelector practice), Kubernetes **v1.37.0**, kubectl v1.34.1, Calico CNI.

Docker Desktop needs about 4 GiB for three nodes plus Calico; `bootstrap.sh`
warns if it reports less.

**After installing kind, open a new terminal.** winget adds it to PATH but
existing shells keep the old value, and `bootstrap.sh` will report
`kind not found` in the shell you installed from.

Calico replaces kind's default CNI because kindnet does not enforce
NetworkPolicy — under kindnet, drill 5.2 would pass with a policy that blocks
nothing.

## Every session

    source bin/setup-shell.sh    # k, kgp, kn, $do, $now, $yd
    ckad list                    # what is there, and how you did last time

Add `bin/` to your PATH, or call it as `bash bin/ckad`.

## The loop

    ckad start 3.2      # prints the task, creates ckad-3-2, starts the timer
    # ... work in scratch/3.2/ ...
    ckad verify 3.2     # per-requirement pass/fail against the live cluster
    ckad solution 3.2   # only after one verify attempt
    ckad reset 3.2      # wipe the namespace and try again
    ckad score          # which domain to grind next

Assertions read the live cluster, never your files — solving a drill
imperatively with `kubectl create` passes exactly like an applied manifest.
`ckad solution` refuses until you have run `verify` at least once, because
reading the answer first feels like progress and teaches nothing.

## Drills

| ID  | Domain | Weight | Drill |
|-----|--------|--------|-------|
| 1.1 | Design & Build | 20% | Sidecar sharing an emptyDir |
| 1.2 | Design & Build | | Init container ordering, Job backoffLimit |
| 2.1 | Deployment | 20% | Rollout, then undo to revision 1 |
| 2.2 | Deployment | | kustomize base plus a prod overlay |
| 3.1 | Observability | 15% | Diagnose a readiness probe that never passes |
| 3.2 | Observability | | startup, readiness and liveness probes |
| 4.1 | App Environment | 25% | ConfigMap volume plus Secret envFrom |
| 4.2 | App Environment | | runAsNonRoot, dropped caps, resource limits |
| 5.1 | Services & Networking | 20% | Path-based Ingress over two Services |
| 5.2 | Services & Networking | | Default-deny NetworkPolicy, then one allow |

## Exam-day shorthands

| What | How |
|---|---|
| Generate YAML, create nothing | `k run web --image=nginx:1.27-alpine $do > p.yaml` |
| Deployment skeleton | `k create deploy api --image=nginx:1.27-alpine $do` |
| Delete immediately | `k delete pod web $now` |
| Switch namespace | `kn ckad-3-2` |
| Why is it not Ready | `k describe pod <p>` then `k get events --sort-by=.lastTimestamp` |
| Previous container's logs | `k logs <p> --previous` |
| One field, scriptably | `k get deploy api -o jsonpath='{.spec.replicas}'` |
| Explain a field | `k explain deploy.spec.strategy --recursive` |

`k explain` works offline and is faster than the docs site. Practice it.

## Adding a drill

    drills/<domain>/<nn>-<slug>/
      task.md       # H1 title, "**Target time:** N min", numbered requirements
      setup.sh      # optional; seeds state, $NS is exported
      verify.sh     # source lib/assert.sh, ns <namespace>, assert, finish
      .solution/    # *.yaml, or apply.sh for command sequences

Then: `bash bin/selftest.sh <id>` — it checks that your solution satisfies
your verify script, and that the verify script fails on an empty namespace.
The second check is the one that catches a drill that silently grades nothing.

Two things that will bite you when writing assertions, both learned the hard
way here:

- Hold jsonpath prefixes **without** braces and wrap at the use site:
  `C='.spec.template.spec.containers[0]'` then `"{$C.image}"`. Putting the
  braces in the variable closes the path early and the rest is read as
  literal text — every such assertion fails with the whole container JSON as
  the "actual" value.
- kubectl v1.34 renders an empty object as `{}` in jsonpath output (older
  versions printed Go's `map[]`). Check with a real `kubectl get ... -o
  jsonpath=` before asserting either.

## Repo tests

    bash tests/run.sh        # unit tests, no cluster needed (stub kubectl)
    bash bin/selftest.sh     # all drills, needs the cluster, ~15 min

The unit tests put a fake `kubectl` on `PATH`, so they run in about a second
and need no cluster at all.
