#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-1-2

# --- A: init container seeds content for the main container ---
assert_exists pod/web
assert_jsonpath pod/web '{.spec.initContainers[?(@.name=="seed")].name}' 'seed'
assert_jsonpath pod/web '{.spec.volumes[?(@.name=="content")].emptyDir}' '{}'
assert_jsonpath pod/web \
  '{.spec.containers[?(@.name=="web")].volumeMounts[?(@.name=="content")].mountPath}' \
  '/usr/share/nginx/html'
retry_until 120 assert_pod_ready --pod web
assert_exec --pod web -c web --contains 'seeded' -- cat /usr/share/nginx/html/index.html

# --- B: backoffLimit 2 means 1 attempt plus 2 retries = 3 failed pods ---
assert_exists job/migrate
assert_jsonpath job/migrate '{.spec.backoffLimit}' '2'
assert_jsonpath job/migrate '{.spec.template.spec.restartPolicy}' 'Never'
retry_until 240 assert_jsonpath job/migrate '{.status.failed}' '3'

finish
