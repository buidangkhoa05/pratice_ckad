#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-2-2

assert_exists deployment/site
assert_jsonpath deployment/site '{.spec.replicas}' '3'
assert_jsonpath deployment/site '{.spec.template.spec.containers[0].image}' 'nginx:1.28-alpine'
assert_jsonpath deployment/site '{.metadata.labels.env}' 'prod'
# The label must reach the Pods too, not just the Deployment - that is the
# difference between labels with includeTemplates and a stray metadata edit.
retry_until 180 assert_pod_ready -l env=prod --count 3

finish
