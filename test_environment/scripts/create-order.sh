#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# create-order.sh - Creates a new marketplace order via the mock procurement API
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ENV_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${TEST_ENV_DIR}/config.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo -e "${RED}ERROR: config.env not found at ${CONFIG_FILE}${NC}"
    echo "Run deploy-all.sh first or create config.env with the required service URLs."
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

MOCK_PROCUREMENT_API_URL="${MOCK_PROCUREMENT_API_URL:?MOCK_PROCUREMENT_API_URL is not set in config.env}"
PROVIDER_ID="${PROVIDER_ID:?PROVIDER_ID is not set in config.env}"

# ---------------------------------------------------------------------------
# Create order
# ---------------------------------------------------------------------------
echo -e "${CYAN}Creating marketplace order...${NC}"
echo -e "  Procurement API: ${MOCK_PROCUREMENT_API_URL}"
echo -e "  Provider ID:     ${PROVIDER_ID}"
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"plan": "default", "product": "time-agent"}' \
    "${MOCK_PROCUREMENT_API_URL}/v1/providers/${PROVIDER_ID}/orders")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 ]]; then
    echo -e "${RED}ERROR: Failed to create order (HTTP ${HTTP_CODE})${NC}"
    echo "${BODY}"
    exit 1
fi

ORDER_ID=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['orderId'])")
ACCOUNT_ID=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['accountId'])")
ENTITLEMENT_ID=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['entitlementId'])")

echo -e "${GREEN}Order created successfully!${NC}"
echo -e "  Order ID:       ${YELLOW}${ORDER_ID}${NC}"
echo -e "  Account ID:     ${ACCOUNT_ID}"
echo -e "  Entitlement ID: ${ENTITLEMENT_ID}"

# Save order details
echo "${BODY}" > "${TEST_ENV_DIR}/_last_order.json"
echo -e "${CYAN}Saved to ${TEST_ENV_DIR}/_last_order.json${NC}"

# Wait for Pub/Sub processing
echo ""
echo -e "${YELLOW}Waiting 5 seconds for Pub/Sub processing...${NC}"
sleep 5
echo -e "${GREEN}Done.${NC}"
