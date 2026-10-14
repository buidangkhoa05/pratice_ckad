#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-5-2

assert_exists networkpolicy/default-deny
# An empty podSelector is what makes this policy a default; kubectl v1.34
# renders it as {} in jsonpath output.
assert_jsonpath networkpolicy/default-deny '{.spec.podSelector}'    '{}'
assert_jsonpath networkpolicy/default-deny '{.spec.policyTypes[0]}' 'Ingress'

assert_exists networkpolicy/allow-frontend
assert_jsonpath networkpolicy/allow-frontend \
  '{.spec.podSelector.matchLabels.app}' 'api'
assert_jsonpath networkpolicy/allow-frontend \
  '{.spec.ingress[0].from[0].podSelector.matchLabels.role}' 'frontend'
assert_jsonpath networkpolicy/allow-frontend \
  '{.spec.ingress[0].ports[0].port}' '80'

retry_until 120 assert_pod_ready -l app=api --count 1

# Behaviour, not just spec fields. These two assertions are the drill: a
# policy that parses but enforces nothing fails here.
retry_until 90 assert_exec --pod client-allowed --contains 'Welcome to nginx' \
  -- wget -q -T3 -O- http://api
assert_exec --pod client-denied --expect-fail \
  -- wget -q -T3 -O- http://api

finish
