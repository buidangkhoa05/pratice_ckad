#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DRILLS="$(make_drill_tree "$TMP")"
stub_setup

# A drill whose verify.sh passes only when a marker file exists. The marker
# stands in for cluster state: "apply the solution" creates it, "delete the
# namespace" removes it.
GOOD="$DRILLS/1-design-build/01-sidecar"
mkdir -p "$GOOD/.solution"
printf 'kind: ConfigMap\n' > "$GOOD/.solution/cm.yaml"
cat > "$GOOD/verify.sh" <<EOF
#!/usr/bin/env bash
[[ -f "$TMP/applied" ]] && exit 0
exit 1
EOF
chmod +x "$GOOD/verify.sh"

# A broken drill: verify.sh always passes, even against an empty namespace.
BAD="$DRILLS/1-design-build/02-init-job"
mkdir -p "$BAD/.solution"
printf 'kind: ConfigMap\n' > "$BAD/.solution/cm.yaml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BAD/verify.sh"
chmod +x "$BAD/verify.sh"

# Stub kubectl so `apply` creates the marker and `delete namespace` removes it.
cat > "$STUB_DIR/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_LOG"
case "\$*" in
  *"apply"*)            touch "$TMP/applied" ;;
  *"delete namespace"*) rm -f "$TMP/applied" ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/kubectl"

selftest() {
  CKAD_ROOT="$CKAD_TEST_ROOT" DRILLS_ROOT="$DRILLS" NO_COLOR=1 \
  bash "$CKAD_TEST_ROOT/bin/selftest.sh" "$@" 2>&1
}

out="$(selftest 1.1)"; rc=$?
expect_rc "$rc" 0 "a well-formed drill passes selftest"
expect_contains "$out" "1.1" "selftest names the drill it checked"

out="$(selftest 1.2)"; rc=$?
expect_rc "$rc" 1 "a verify.sh that passes on an empty namespace is caught"
expect_contains "$out" "empty namespace" "the failure explains that it passed against nothing"

out="$(selftest)"; rc=$?
expect_rc "$rc" 1 "running all drills fails when any drill is broken"

# A drill with no verify.sh at all is a repo bug.
out="$(selftest 3.1)"; rc=$?
expect_rc "$rc" 1 "a drill with no verify.sh fails selftest"
expect_contains "$out" "verify.sh" "the missing verify.sh is named"

# A drill that has a verify.sh but no .solution is also a repo bug, and must
# be reported rather than silently skipped.
printf '#!/usr/bin/env bash\nexit 0\n' > "$DRILLS/3-observability/01-broken-probe/verify.sh"
chmod +x "$DRILLS/3-observability/01-broken-probe/verify.sh"
out="$(selftest 3.1)"; rc=$?
expect_rc "$rc" 1 "a drill with no .solution fails selftest"
expect_contains "$out" "solution" "the missing .solution is named"

harness_finish
