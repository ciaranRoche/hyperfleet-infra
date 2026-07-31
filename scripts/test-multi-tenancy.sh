#!/usr/bin/env bash
# test-multi-tenancy.sh - End-to-end validation of Envoy + Authorino + tenant isolation
#
# Prerequisites:
#   - Envoy accessible at ENVOY_URL (default: http://localhost:8080)
#   - Mock JWT server accessible at JWT_URL (default: http://localhost:8081)
#   - HyperFleet API deployed with tenant enforcement enabled
#   - AuthConfig applied (org+project model by default)
#
# Usage:
#   # Port-forward first:
#   kubectl -n hyperfleet-local port-forward svc/mock-jwt-server 8081:8080 &
#   kubectl -n hyperfleet-local port-forward svc/envoy 8080:8000 &
#   ./scripts/test-multi-tenancy.sh

set -euo pipefail

ENVOY_URL="${ENVOY_URL:-http://localhost:8080}"
JWT_URL="${JWT_URL:-http://localhost:8081}"
API_PATH="/api/hyperfleet/v1"

PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

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

# Get a JWT token for the given claims
get_token() {
    local response
    response=$(curl -s -X POST "${JWT_URL}/token" -d "$1")
    echo "$response" | jq -r '.token'
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
echo "  Multi-Tenancy POC Validation Test Suite"
echo "============================================"
echo "Envoy:     ${ENVOY_URL}"
echo "JWT Server: ${JWT_URL}"
echo ""

# --------------------------------------------------------
# Test 1: Unauthenticated request → 401/403
# --------------------------------------------------------
log_test "Unauthenticated request should be rejected"
result=$(envoy_request GET "/clusters")
status=$(echo "$result" | cut -d'|' -f1)
if [ "$status" = "401" ] || [ "$status" = "403" ]; then
    pass "Got HTTP $status (expected 401 or 403)"
else
    fail "Got HTTP $status, expected 401 or 403"
fi

# --------------------------------------------------------
# Test 2: Token missing required org_id → 403
# --------------------------------------------------------
log_test "Token missing required org_id claim → 403"
token=$(get_token "sub=user1&email=user1@test.com")
result=$(envoy_request GET "/clusters" "$token")
status=$(echo "$result" | cut -d'|' -f1)
if [ "$status" = "403" ]; then
    pass "Got HTTP 403 (missing org_id rejected)"
else
    fail "Got HTTP $status, expected 403"
fi

# --------------------------------------------------------
# Test 3: Valid token for tenant acme → create cluster
# --------------------------------------------------------
log_test "Tenant acme creates a cluster"
token_acme=$(get_token "sub=user1&email=user1@acme.com&org_id=acme&project_id=proj-1")
create_body='{"name":"acme-cluster-1","spec":{"region":"us-east-1"}}'
result=$(envoy_request POST "/clusters" "$token_acme" "$create_body")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
if [ "$status" = "201" ]; then
    acme_cluster_id=$(echo "$body" | jq -r '.id // empty')
    if [ -n "$acme_cluster_id" ]; then
        pass "Created cluster $acme_cluster_id for acme (HTTP 201)"
    else
        fail "HTTP 201 but no id in response"
    fi
else
    fail "Got HTTP $status, expected 201. Body: $body"
    acme_cluster_id=""
fi

# --------------------------------------------------------
# Test 4: Valid token for tenant globex → create cluster
# --------------------------------------------------------
log_test "Tenant globex creates a cluster"
token_globex=$(get_token "sub=user2&email=user2@globex.com&org_id=globex&project_id=proj-2")
create_body='{"name":"globex-cluster-1","spec":{"region":"eu-west-1"}}'
result=$(envoy_request POST "/clusters" "$token_globex" "$create_body")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
if [ "$status" = "201" ]; then
    globex_cluster_id=$(echo "$body" | jq -r '.id // empty')
    if [ -n "$globex_cluster_id" ]; then
        pass "Created cluster $globex_cluster_id for globex (HTTP 201)"
    else
        fail "HTTP 201 but no id in response"
    fi
else
    fail "Got HTTP $status, expected 201. Body: $body"
    globex_cluster_id=""
fi

# --------------------------------------------------------
# Test 5: Tenant acme lists clusters → sees only acme's
# --------------------------------------------------------
log_test "Tenant acme lists clusters → sees only own clusters"
result=$(envoy_request GET "/clusters" "$token_acme")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
if [ "$status" = "200" ]; then
    count=$(echo "$body" | jq '.items | length')
    has_acme=$(echo "$body" | jq "[.items[]? | select(.name == \"acme-cluster-1\")] | length")
    has_globex=$(echo "$body" | jq "[.items[]? | select(.name == \"globex-cluster-1\")] | length")
    if [ "$has_acme" -ge 1 ] && [ "$has_globex" -eq 0 ]; then
        pass "Acme sees $count cluster(s), includes own, excludes globex"
    else
        fail "Acme sees unexpected results: has_acme=$has_acme, has_globex=$has_globex"
    fi
else
    fail "Got HTTP $status, expected 200"
fi

# --------------------------------------------------------
# Test 6: Tenant globex lists clusters → sees only globex's
# --------------------------------------------------------
log_test "Tenant globex lists clusters → sees only own clusters"
result=$(envoy_request GET "/clusters" "$token_globex")
status=$(echo "$result" | cut -d'|' -f1)
body=$(echo "$result" | cut -d'|' -f2-)
if [ "$status" = "200" ]; then
    has_acme=$(echo "$body" | jq "[.items[]? | select(.name == \"acme-cluster-1\")] | length")
    has_globex=$(echo "$body" | jq "[.items[]? | select(.name == \"globex-cluster-1\")] | length")
    if [ "$has_globex" -ge 1 ] && [ "$has_acme" -eq 0 ]; then
        pass "Globex sees own cluster, excludes acme"
    else
        fail "Globex sees unexpected results: has_acme=$has_acme, has_globex=$has_globex"
    fi
else
    fail "Got HTTP $status, expected 200"
fi

# --------------------------------------------------------
# Test 7: Cross-tenant GET by ID → 404
# --------------------------------------------------------
log_test "Tenant globex tries to GET acme's cluster by ID → 404"
if [ -n "${acme_cluster_id:-}" ]; then
    result=$(envoy_request GET "/clusters/$acme_cluster_id" "$token_globex")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "404" ]; then
        pass "Got HTTP 404 (cross-tenant access denied)"
    else
        fail "Got HTTP $status, expected 404"
    fi
else
    fail "Skipped — acme cluster was not created"
fi

# --------------------------------------------------------
# Test 8: Cross-tenant DELETE → 404
# --------------------------------------------------------
log_test "Tenant globex tries to DELETE acme's cluster → 404"
if [ -n "${acme_cluster_id:-}" ]; then
    result=$(envoy_request DELETE "/clusters/$acme_cluster_id" "$token_globex")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "404" ]; then
        pass "Got HTTP 404 (cross-tenant delete denied)"
    else
        fail "Got HTTP $status, expected 404"
    fi
else
    fail "Skipped — acme cluster was not created"
fi

# --------------------------------------------------------
# Test 9: Header spoofing prevention
# --------------------------------------------------------
log_test "Forged X-Tenant-Org header with valid token → correct org used"
# User has org_id=acme in JWT, but tries to forge X-Tenant-Org: globex
# Envoy strips the forged header, Authorino injects the correct one
result=$(curl -s -w "\n%{http_code}" -X GET "${ENVOY_URL}${API_PATH}/clusters" \
    -H "Authorization: Bearer $token_acme" \
    -H "X-Tenant-Org: globex")
status=$(echo "$result" | tail -1)
body=$(echo "$result" | sed '$d')
if [ "$status" = "200" ]; then
    has_globex=$(echo "$body" | jq "[.items[]? | select(.name == \"globex-cluster-1\")] | length")
    if [ "$has_globex" -eq 0 ]; then
        pass "Forged header stripped — acme still sees only own clusters"
    else
        fail "Forged header was NOT stripped — saw globex clusters!"
    fi
else
    pass "Request returned HTTP $status (forged header rejected)"
fi

# --------------------------------------------------------
# Test 10: Tenant labels present on created resources
# --------------------------------------------------------
log_test "Created resources have tenant labels"
if [ -n "${acme_cluster_id:-}" ]; then
    result=$(envoy_request GET "/clusters/$acme_cluster_id" "$token_acme")
    status=$(echo "$result" | cut -d'|' -f1)
    body=$(echo "$result" | cut -d'|' -f2-)
    if [ "$status" = "200" ]; then
        org_label=$(echo "$body" | jq -r '.labels["hyperfleet.io/org"] // empty')
        if [ "$org_label" = "acme" ]; then
            pass "Resource has label hyperfleet.io/org=acme"
        else
            fail "Expected label hyperfleet.io/org=acme, got '$org_label'"
        fi
    else
        fail "Got HTTP $status fetching resource"
    fi
else
    fail "Skipped — acme cluster was not created"
fi

# --------------------------------------------------------
# Cleanup: delete test resources
# --------------------------------------------------------
echo -e "\n${YELLOW}=== Cleanup ===${NC}"
if [ -n "${acme_cluster_id:-}" ]; then
    envoy_request DELETE "/clusters/$acme_cluster_id" "$token_acme" > /dev/null 2>&1 || true
    echo "Deleted acme cluster $acme_cluster_id"
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
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL)"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
