#!/usr/bin/env bash
# test-model-swap.sh - Validate the oracle tenant model after a model swap
#
# Proves per-deployment tenant-model configurability: after switching the
# AuthConfig and API dimensions to the oracle model (tenancy OCID required,
# compartment optional), isolation works on the new dimensions and tokens
# from the old model are rejected. Zero code changes in any component.
#
# Prerequisites (run after the main suite):
#   make poc-switch-model TENANT_MODEL=oracle
#   make install-hyperfleet TENANT_ENFORCEMENT=true TENANT_MODEL=oracle JWT_AUTH_ENABLED=true API_BASE_URL=... (re-render API config)
#   Port-forwards as in test-multi-tenancy.sh
#
# Usage:
#   ./scripts/test-model-swap.sh

set -euo pipefail

ENVOY_URL="${ENVOY_URL:-http://localhost:8080}"
JWT_URL="${JWT_URL:-http://localhost:8081}"
API_PATH="/api/hyperfleet/v1"
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
    echo "$(echo "$response" | tail -1)|$(echo "$response" | sed '$d')"
}

echo "============================================"
echo "  Oracle Tenant Model Swap Validation"
echo "============================================"

OCID_A="ocid1.tenancy.oc1..aaaa${RUN_SUFFIX}"
OCID_B="ocid1.tenancy.oc1..bbbb${RUN_SUFFIX}"
CLUSTER_A="oci-a-${RUN_SUFFIX}"
CLUSTER_B="oci-b-${RUN_SUFFIX}"

# --------------------------------------------------------
# Test 1: Old-model token (org_id claims) is rejected
# --------------------------------------------------------
log_test "Old-model token with org_id claims is rejected under the oracle model"
token_old=$(get_token "sub=user1&email=user1@acme.com&org_id=acme&project_id=proj-1")
result=$(envoy_request GET "/clusters" "$token_old")
status=$(echo "$result" | cut -d'|' -f1)
if [ "$status" = "403" ]; then
    pass "Got HTTP 403 (missing tenancy_ocid claim)"
else
    fail "Got HTTP $status, expected 403"
fi

# --------------------------------------------------------
# Test 2: Tenancy-OCID tenants are isolated
# --------------------------------------------------------
log_test "Two tenancy OCIDs create clusters and are isolated"
token_a=$(get_token "sub=usera&email=a@oracle.test&tenancy_ocid=${OCID_A}&compartment_id=dev")
token_b=$(get_token "sub=userb&email=b@oracle.test&tenancy_ocid=${OCID_B}&compartment_id=dev")

result=$(envoy_request POST "/clusters" "$token_a" "{\"name\":\"${CLUSTER_A}\",\"spec\":{\"region\":\"us-ashburn-1\"}}")
status_a=$(echo "$result" | cut -d'|' -f1)
id_a=$(echo "$result" | cut -d'|' -f2- | jq -r '.id // empty')
result=$(envoy_request POST "/clusters" "$token_b" "{\"name\":\"${CLUSTER_B}\",\"spec\":{\"region\":\"eu-frankfurt-1\"}}")
status_b=$(echo "$result" | cut -d'|' -f1)
id_b=$(echo "$result" | cut -d'|' -f2- | jq -r '.id // empty')

if [ "$status_a" = "201" ] && [ "$status_b" = "201" ]; then
    result=$(envoy_request GET "/clusters" "$token_a")
    body=$(echo "$result" | cut -d'|' -f2-)
    sees_own=$(echo "$body" | jq "[.items[]? | select(.name == \"${CLUSTER_A}\")] | length")
    sees_other=$(echo "$body" | jq "[.items[]? | select(.name == \"${CLUSTER_B}\")] | length")
    if [ "$sees_own" -ge 1 ] && [ "$sees_other" -eq 0 ]; then
        pass "Tenancy ${OCID_A} sees only its own cluster"
    else
        fail "OCID isolation wrong: own=$sees_own other=$sees_other"
    fi
else
    fail "Creates failed: a=$status_a b=$status_b"
fi

# --------------------------------------------------------
# Test 3: Tenancy map carries the oracle dimensions
# --------------------------------------------------------
log_test "Created resource tenancy map carries tenancy_ocid and compartment"
if [ -n "$id_a" ]; then
    result=$(envoy_request GET "/clusters/$id_a" "$token_a")
    body=$(echo "$result" | cut -d'|' -f2-)
    got_ocid=$(echo "$body" | jq -r '.tenancy.tenancy_ocid // empty')
    got_comp=$(echo "$body" | jq -r '.tenancy.compartment // empty')
    if [ "$got_ocid" = "$OCID_A" ] && [ "$got_comp" = "dev" ]; then
        pass "Tenancy map is tenancy_ocid=${OCID_A} compartment=dev"
    else
        fail "Got tenancy_ocid='$got_ocid' compartment='$got_comp'"
    fi
else
    fail "Skipped, cluster A was not created"
fi

# --------------------------------------------------------
# Test 4: Cross-tenancy point read is 404
# --------------------------------------------------------
log_test "Cross-tenancy GET by ID is 404"
if [ -n "$id_a" ]; then
    result=$(envoy_request GET "/clusters/$id_a" "$token_b")
    status=$(echo "$result" | cut -d'|' -f1)
    if [ "$status" = "404" ]; then
        pass "Got HTTP 404"
    else
        fail "Got HTTP $status, expected 404"
    fi
else
    fail "Skipped, cluster A was not created"
fi

# --------------------------------------------------------
# Cleanup
# --------------------------------------------------------
echo -e "\n${YELLOW}=== Cleanup ===${NC}"
[ -n "${id_a:-}" ] && envoy_request DELETE "/clusters/$id_a" "$token_a" > /dev/null 2>&1 || true
[ -n "${id_b:-}" ] && envoy_request DELETE "/clusters/$id_b" "$token_b" > /dev/null 2>&1 || true
echo "Deleted oracle-model test clusters"

echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL tests)"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
