# Default-deny, then open one door

**Target time:** 14 min
**Namespace:** `ckad-5-2`

Already deployed for you: a Deployment `api` with Service `api` on port 80,
and two client Pods — `client-allowed` (label `role=frontend`) and
`client-denied` (label `role=batch`). Right now both can reach `api`.

Create two NetworkPolicies:

1. `default-deny` — denies **all** ingress to every Pod in the namespace.
   Its `podSelector` must be empty, and `policyTypes` must list `Ingress`.
2. `allow-frontend` — allows ingress to Pods labelled `app=api`, from Pods
   labelled `role=frontend`, on TCP port 80.

End state: `client-allowed` can reach `http://api`, `client-denied` cannot.

Test from inside:
`k exec client-allowed -- wget -q -T3 -O- http://api`
`k exec client-denied  -- wget -q -T3 -O- http://api`   # must time out

An empty `podSelector: {}` selects every Pod in the namespace — that is what
makes policy 1 a default. Policies are additive and there is no deny rule:
you open traffic back up by adding an allow, never by editing the deny.
