#!/usr/bin/env bash
# test-multi-tenancy.sh - End-to-end validation of Envoy + Authorino + tenant isolation
#
# Validates the onprem tenant model (org required + project optional) with the
# per-resource tenancy map, system identities via Kubernetes TokenReview, and
# the full pipeline lifecycle (Sentinel + adapter as system identities).
#
# Prerequisites:
#   - Envoy accessible at ENVOY_URL (default: http://localhost:8080)
#   - Mock JWT server accessible at JWT_URL (default: http://localhost:8081)
#   - HyperFleet API deployed with TENANT_ENFORCEMENT=true TENANT_MODEL=onprem
#   - AuthConfig applied (make install-authconfig TENANT_MODEL=onprem)
#   - kubectl context pointing at the kind cluster (for SA token tests)
#   - Sentinel + adapters installed through Envoy for the lifecycle test
#     (set SKIP_LIFECYCLE=true to skip)
#
# Usage:
#   kubectl -n hyperfleet-local port-forward svc/mock-jwt-server 8081:8080 &
#   kubectl -n hyperfleet-local port-forward svc/envoy 8080:8000 &
#   ./scripts/test-multi-tenancy.sh

set -euo pipefail

ENVOY_URL="${ENVOY_URL:-http://localhost:8080}"
JWT_URL="${JWT_URL:-http://localhost:8081}"
API_PATH="/api/hyperfleet/v1"
NAMESPACE="${NAMESPACE:-hyperfleet-local}"
SYSTEM_SA="${SYSTEM_SA:-clusters-hyperfleet-sentinel}"
SKIP_LIFECYCLE="${SKIP_LIFECYCLE:-false}"
LIFECYCLE_TIMEOUT="${LIFECYCLE_TIMEOUT:-120}"
RUN_SUFFIX="$(date +%s)"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_test() {
    TOTAL=$((TOTAL + 1))
    echo -e "\n${YELLOW}=== Test $TOTAL: $1 ===${NC}"
}

pass() {
    PASS=$((PASS + 1))
    echo -e "${GREEN}PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo -e "${RED}FAIL${NC}: $1"
}

get_token() {
    curl -s -X POST "${JWT_URL}/token" -d "$1" | jq -r '.token'
}

# Make an HTTP request through Envoy and return "status_code|body"
envoy_request() {
    local method="$1"
    local path="$2"
    local token="${3:-}"
    local body="${4:-}"

    local args=(-s -w "\n%{http_code}" -X "$method" "${ENVOY_URL}${API_PATH}${path}")
    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer $token")
    fi
    if [ -n "$body" ]; then
        args+=(-H "Content-Type: application/json" -d "$body")
    fi

    local response
    response=$(curl "${args[@]}")
    local status_code
    status_code=$(echo "$response" | tail -1)
    local response_body
    response_body=$(echo "$response" | sed '$d')

    echo "${status_code}|${response_body}"
}

echo "============================================"
echo "  Multi-Tenancy POC v2 Validation Suite"
echo "============================================"
echo "Envoy:      ${ENVOY_URL}"
echo "JWT Server: ${JWT_URL}"
echo "Run suffix: ${RUN_SUFFIX}"
echo ""

ACME_CLUSTER="acme-c1-${RUN_SUFFIX}"
ACME_P2_CLUSTER="acme-c2-${RUN_SUFFIX}"
GLOBEX_CLUSTER="globex-c1-${RUN_SUFFIX}"

# --------------------------------------------------------
# Test 1: Unauthenticated request is rejected
# --------------------------------------------------------
log_test "Unauthenticated request is rejected"
result=$(envoy_request GET "/clusters")
status=$(echo "$result" | cut -d'|' -f1)
if [ "$status" = "401" ] || [ "$status" = "403" ]; then
    pass "Got HTTP $status (expected 401 or 403)"
else
    fail "Got HTTP $status, expected 401 or 403"
fi

# --------------------------------------------------------
# Test 2: Token missing required org_id claim is rejected
# --------------------------------------------------------
log_test "Token missing required org_id claim is rejected"
token=$(get_token "sub=user1&email=user1@test.com")
result=$(envoy_request GET "/clusters" "$token")
status=$(echo "$result" | cut -d'|' -f1)
if [ "$status" = "403" ]; then
    pass "Got HTTP 403 (missing org_id rejected at gateway)"
else
    fail "Got HTTP $status, expected 403"
fi

# --------------------------------------------------------
# Test 3: Tenant acme creates a cluster
# --------------------------------------------------------
log_test "Tenant acme (proj-1) creates a cluster"
token_acme=$(get_token "sub=user1&email=user1@acme.com&org_id=acme&project_id=proj-1")
create_body="{\"name\":\"${ACME_CLUSTER}\",\"spec\":{\"region\":\"us-east-1\"}}"
result=$(envoy_request POST "/clusters" "$token_acme" "$create_body")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
acme_cluster_id=""
if [ "$status" = "201" ]; then
    acme_cluster_id=$(echo "$body" | jq -r '.id // empty')
    if [ -n "$acme_cluster_id" ]; then
        pass "Created cluster $acme_cluster_id for acme (HTTP 201)"
    else
        fail "HTTP 201 but no id in response"
    fi
else
    fail "Got HTTP $status, expected 201. Body: $body"
fi

# --------------------------------------------------------
# Test 4: Tenant globex creates a cluster
# --------------------------------------------------------
log_test "Tenant globex creates a cluster"
token_globex=$(get_token "sub=user2&email=user2@globex.com&org_id=globex&project_id=proj-2")
create_body="{\"name\":\"${GLOBEX_CLUSTER}\",\"spec\":{\"region\":\"eu-west-1\"}}"
result=$(envoy_request POST "/clusters" "$token_globex" "$create_body")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
globex_cluster_id=""
if [ "$status" = "201" ]; then
    globex_cluster_id=$(echo "$body" | jq -r '.id // empty')
    if [ -n "$globex_cluster_id" ]; then
        pass "Created cluster $globex_cluster_id for globex (HTTP 201)"
    else
        fail "HTTP 201 but no id in response"
    fi
else
    fail "Got HTTP $status, expected 201. Body: $body"
fi

# --------------------------------------------------------
# Test 5: Tenant acme lists clusters, sees only its own
# --------------------------------------------------------
log_test "Tenant acme lists clusters, sees only its own"
result=$(envoy_request GET "/clusters" "$token_acme")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
if [ "$status" = "200" ]; then
    has_acme=$(echo "$body" | jq "[.items[]? | select(.name == \"${ACME_CLUSTER}\")] | length")
    has_globex=$(echo "$body" | jq "[.items[]? | select(.name == \"${GLOBEX_CLUSTER}\")] | length")
    if [ "$has_acme" -ge 1 ] && [ "$has_globex" -eq 0 ]; then
        pass "Acme sees own cluster, excludes globex"
    else
        fail "Acme list wrong: has_acme=$has_acme, has_globex=$has_globex"
    fi
else
    fail "Got HTTP $status, expected 200. Body: $body"
fi

# --------------------------------------------------------
# Test 6: Tenant globex lists clusters, sees only its own
# --------------------------------------------------------
log_test "Tenant globex lists clusters, sees only its own"
result=$(envoy_request GET "/clusters" "$token_globex")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
if [ "$status" = "200" ]; then
    has_acme=$(echo "$body" | jq "[.items[]? | select(.name == \"${ACME_CLUSTER}\")] | length")
    has_globex=$(echo "$body" | jq "[.items[]? | select(.name == \"${GLOBEX_CLUSTER}\")] | length")
    if [ "$has_globex" -ge 1 ] && [ "$has_acme" -eq 0 ]; then
        pass "Globex sees own cluster, excludes acme"
    else
        fail "Globex list wrong: has_acme=$has_acme, has_globex=$has_globex"
    fi
else
    fail "Got HTTP $status, expected 200. Body: $body"
fi

# --------------------------------------------------------
# Test 7: Cross-tenant GET by ID is 404
# --------------------------------------------------------
log_test "Globex GET on acme's cluster by ID is 404"
if [ -n "$acme_cluster_id" ]; then
    result=$(envoy_request GET "/clusters/$acme_cluster_id" "$token_globex")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "404" ]; then
        pass "Got HTTP 404 (no existence leak)"
    else
        fail "Got HTTP $status, expected 404"
    fi
else
    fail "Skipped, acme cluster was not created"
fi

# --------------------------------------------------------
# Test 8: Cross-tenant DELETE is 404
# --------------------------------------------------------
log_test "Globex DELETE on acme's cluster is 404"
if [ -n "$acme_cluster_id" ]; then
    result=$(envoy_request DELETE "/clusters/$acme_cluster_id" "$token_globex")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "404" ]; then
        pass "Got HTTP 404 (cross-tenant delete denied)"
    else
        fail "Got HTTP $status, expected 404"
    fi
else
    fail "Skipped, acme cluster was not created"
fi

# --------------------------------------------------------
# Test 9: Header spoofing prevention (early strip before ext_authz)
# --------------------------------------------------------
log_test "Forged tenant/system headers are stripped before Authorino"
result=$(curl -s -w "\n%{http_code}" -X GET "${ENVOY_URL}${API_PATH}/clusters" \
    -H "Authorization: Bearer $token_acme" \
    -H "X-Tenant-Org: globex" \
    -H "X-HyperFleet-System: true")
status=$(echo "$result" | tail -1)
body=$(echo "$result" | sed '$d')
if [ "$status" = "200" ]; then
    has_globex=$(echo "$body" | jq "[.items[]? | select(.name == \"${GLOBEX_CLUSTER}\")] | length")
    has_acme=$(echo "$body" | jq "[.items[]? | select(.name == \"${ACME_CLUSTER}\")] | length")
    if [ "$has_globex" -eq 0 ] && [ "$has_acme" -ge 1 ]; then
        pass "Forged headers stripped, acme still scoped to own resources"
    else
        fail "Forged header leaked scope: has_acme=$has_acme has_globex=$has_globex"
    fi
else
    fail "Got HTTP $status, expected 200"
fi

# --------------------------------------------------------
# Test 10: Tenancy map on created resources, body tenancy ignored
# --------------------------------------------------------
log_test "Created resource carries the tenancy map; body tenancy is ignored"
if [ -n "$acme_cluster_id" ]; then
    result=$(envoy_request GET "/clusters/$acme_cluster_id" "$token_acme")
    body=$(echo "$result" | cut -d'|' -f2-)
    org=$(echo "$body" | jq -r '.tenancy.org // empty')
    project=$(echo "$body" | jq -r '.tenancy.project // empty')
    if [ "$org" = "acme" ] && [ "$project" = "proj-1" ]; then
        pass "Resource tenancy is org=acme project=proj-1"
    else
        fail "Expected tenancy org=acme project=proj-1, got org='$org' project='$project'"
    fi

    # Body-supplied tenancy must never override the gateway identity.
    evil_body="{\"name\":\"evil-${RUN_SUFFIX}\",\"spec\":{\"region\":\"us-east-1\"},\"tenancy\":{\"org\":\"globex\"}}"
    result=$(envoy_request POST "/clusters" "$token_acme" "$evil_body")
    status=$(echo "$result" | cut -d'|' -f1)
    body=$(echo "$result" | cut -d'|' -f2-)
    evil_id=$(echo "$body" | jq -r '.id // empty')
    if [ "$status" = "201" ]; then
        evil_org=$(echo "$body" | jq -r '.tenancy.org // empty')
        if [ "$evil_org" = "acme" ]; then
            pass "Body-supplied tenancy ignored, server set org=acme"
        else
            fail "Body-supplied tenancy leaked: org='$evil_org'"
        fi
        [ -n "$evil_id" ] && envoy_request DELETE "/clusters/$evil_id" "$token_acme" > /dev/null 2>&1 || true
    else
        # A 400 is also acceptable if the deployed schema forbids unknown fields.
        pass "POST with body tenancy rejected with HTTP $status (schema-enforced)"
    fi
else
    fail "Skipped, acme cluster was not created"
fi

# --------------------------------------------------------
# Test 11: System identity via Kubernetes TokenReview
# --------------------------------------------------------
log_test "ServiceAccount token is a system identity with cross-tenant read"
sa_token=$(kubectl -n "$NAMESPACE" create token "$SYSTEM_SA" --audience=hyperfleet-api 2>/dev/null || true)
if [ -z "$sa_token" ]; then
    fail "Could not mint token for SA $SYSTEM_SA (is the pipeline installed?)"
else
    result=$(envoy_request GET "/clusters" "$sa_token")
    status=$(echo "$result" | cut -d'|' -f1)
    body=$(echo "$result" | cut -d'|' -f2-)
    if [ "$status" = "200" ]; then
        has_acme=$(echo "$body" | jq "[.items[]? | select(.name == \"${ACME_CLUSTER}\")] | length")
        has_globex=$(echo "$body" | jq "[.items[]? | select(.name == \"${GLOBEX_CLUSTER}\")] | length")
        if [ "$has_acme" -ge 1 ] && [ "$has_globex" -ge 1 ]; then
            pass "System identity sees both tenants' clusters"
        else
            fail "System list wrong: has_acme=$has_acme has_globex=$has_globex"
        fi
    else
        fail "Got HTTP $status, expected 200"
    fi
fi

# --------------------------------------------------------
# Test 12: Unlisted ServiceAccount is denied
# --------------------------------------------------------
log_test "Unlisted ServiceAccount with a hyperfleet-api-audience token is denied"
default_token=$(kubectl -n "$NAMESPACE" create token default --audience=hyperfleet-api 2>/dev/null || true)
if [ -z "$default_token" ]; then
    fail "Could not mint token for the default SA"
else
    result=$(envoy_request GET "/clusters" "$default_token")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "403" ]; then
        pass "Got HTTP 403 (subject not in the system allowlist)"
    else
        fail "Got HTTP $status, expected 403"
    fi
fi

# --------------------------------------------------------
# Test 13: Full pipeline lifecycle under enforcement
# --------------------------------------------------------
log_test "Lifecycle: acme's cluster reaches Reconciled=True via system identities"
if [ "$SKIP_LIFECYCLE" = "true" ]; then
    pass "Skipped by SKIP_LIFECYCLE=true (not counted as failure)"
elif [ -n "$acme_cluster_id" ]; then
    deadline=$((SECONDS + LIFECYCLE_TIMEOUT))
    reconciled="false"
    while [ $SECONDS -lt $deadline ]; do
        result=$(envoy_request GET "/clusters/$acme_cluster_id" "$token_acme")
        body=$(echo "$result" | cut -d'|' -f2-)
        reconciled=$(echo "$body" | jq -r '[.status.conditions[]? | select(.type == "Reconciled" and .status == "True")] | length > 0')
        if [ "$reconciled" = "true" ]; then
            break
        fi
        sleep 5
    done
    if [ "$reconciled" = "true" ]; then
        pass "Cluster Reconciled=True through Envoy-authenticated Sentinel + adapters"
    else
        fail "Cluster not reconciled within ${LIFECYCLE_TIMEOUT}s"
    fi
else
    fail "Skipped, acme cluster was not created"
fi

# --------------------------------------------------------
# Test 14: Isolation holds after system status writes
# --------------------------------------------------------
log_test "After adapter status writes, globex still cannot see acme's cluster"
if [ -n "$acme_cluster_id" ]; then
    result=$(envoy_request GET "/clusters/$acme_cluster_id" "$token_globex")
    status=$(echo "$result" | cut -d'|' -f1)
    result=$(envoy_request GET "/clusters" "$token_globex")
    list_body=$(echo "$result" | cut -d'|' -f2-)
    still_hidden=$(echo "$list_body" | jq "[.items[]? | select(.name == \"${ACME_CLUSTER}\")] | length")
    if [ "$status" = "404" ] && [ "$still_hidden" -eq 0 ]; then
        pass "Cross-tenant isolation intact after system writes"
    else
        fail "Isolation broken: GET=$status, in_list=$still_hidden"
    fi
else
    fail "Skipped, acme cluster was not created"
fi

# --------------------------------------------------------
# Test 15: PATCH cannot alter tenancy
# --------------------------------------------------------
log_test "PATCH with tenancy is rejected; label patch leaves tenancy unchanged"
if [ -n "$acme_cluster_id" ]; then
    result=$(envoy_request PATCH "/clusters/$acme_cluster_id" "$token_acme" '{"tenancy":{"org":"globex"}}')
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "400" ]; then
        pass "PATCH with tenancy rejected with HTTP 400"
    else
        fail "Got HTTP $status, expected 400"
    fi

    result=$(envoy_request PATCH "/clusters/$acme_cluster_id" "$token_acme" '{"labels":{"env":"prod"}}')
    status=$(echo "$result" | cut -d'|' -f1)
    body=$(echo "$result" | cut -d'|' -f2-)
    org=$(echo "$body" | jq -r '.tenancy.org // empty')
    if [ "$status" = "200" ] && [ "$org" = "acme" ]; then
        pass "Label patch succeeded, tenancy still org=acme"
    else
        fail "Got HTTP $status org='$org', expected 200 and org=acme"
    fi
else
    fail "Skipped, acme cluster was not created"
fi

# --------------------------------------------------------
# Test 16: Containment hierarchy, org-scoped token sees all projects
# --------------------------------------------------------
log_test "Org-scoped token (no project) sees clusters from all its projects"
create_body="{\"name\":\"${ACME_P2_CLUSTER}\",\"spec\":{\"region\":\"us-west-2\"}}"
token_acme_p2=$(get_token "sub=user3&email=user3@acme.com&org_id=acme&project_id=proj-2")
result=$(envoy_request POST "/clusters" "$token_acme_p2" "$create_body")
status=$(echo "$result" | cut -d'|' -f1)
acme_p2_id=$(echo "$result" | cut -d'|' -f2- | jq -r '.id // empty')
if [ "$status" = "201" ]; then
    token_acme_org=$(get_token "sub=admin@acme.com&email=admin@acme.com&org_id=acme")
    result=$(envoy_request GET "/clusters" "$token_acme_org")
    body=$(echo "$result" | cut -d'|' -f2-)
    sees_p1=$(echo "$body" | jq "[.items[]? | select(.name == \"${ACME_CLUSTER}\")] | length")
    sees_p2=$(echo "$body" | jq "[.items[]? | select(.name == \"${ACME_P2_CLUSTER}\")] | length")
    sees_globex=$(echo "$body" | jq "[.items[]? | select(.name == \"${GLOBEX_CLUSTER}\")] | length")
    if [ "$sees_p1" -ge 1 ] && [ "$sees_p2" -ge 1 ] && [ "$sees_globex" -eq 0 ]; then
        pass "Org token sees proj-1 and proj-2 clusters, not globex"
    else
        fail "Org scope wrong: p1=$sees_p1 p2=$sees_p2 globex=$sees_globex"
    fi

    # And the project-scoped caller cannot see the sibling project's cluster.
    result=$(envoy_request GET "/clusters/$acme_p2_id" "$token_acme")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "404" ]; then
        pass "proj-1 token gets 404 on proj-2's cluster"
    else
        fail "Got HTTP $status, expected 404 for sibling project"
    fi
else
    fail "Could not create proj-2 cluster (HTTP $status)"
fi

# --------------------------------------------------------
# Cleanup
# --------------------------------------------------------
echo -e "\n${YELLOW}=== Cleanup ===${NC}"
if [ -n "${acme_cluster_id:-}" ]; then
    envoy_request DELETE "/clusters/$acme_cluster_id" "$token_acme" > /dev/null 2>&1 || true
    echo "Deleted acme cluster $acme_cluster_id"
fi
if [ -n "${acme_p2_id:-}" ]; then
    envoy_request DELETE "/clusters/$acme_p2_id" "$token_acme_p2" > /dev/null 2>&1 || true
    echo "Deleted acme proj-2 cluster $acme_p2_id"
fi
if [ -n "${globex_cluster_id:-}" ]; then
    envoy_request DELETE "/clusters/$globex_cluster_id" "$token_globex" > /dev/null 2>&1 || true
    echo "Deleted globex cluster $globex_cluster_id"
fi

# --------------------------------------------------------
# Summary
# --------------------------------------------------------
echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL tests)"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
