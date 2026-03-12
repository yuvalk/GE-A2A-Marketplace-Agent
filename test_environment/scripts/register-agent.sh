#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# register-agent.sh - Performs DCR registration for a marketplace order
#
# Usage: ./register-agent.sh [order_id]
#   If no order_id is provided, reads from _last_order.json
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ENV_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${TEST_ENV_DIR}/config.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

MOCK_IDP_URL="${MOCK_IDP_URL:?MOCK_IDP_URL is not set in config.env}"
MARKETPLACE_HANDLER_URL="${MARKETPLACE_HANDLER_URL:?MARKETPLACE_HANDLER_URL is not set in config.env}"
PROVIDER_URL="${PROVIDER_URL:-https://google.com}"

# ---------------------------------------------------------------------------
# Get order ID
# ---------------------------------------------------------------------------
if [[ $# -ge 1 ]]; then
    ORDER_ID="$1"
else
    LAST_ORDER_FILE="${TEST_ENV_DIR}/_last_order.json"
    if [[ ! -f "${LAST_ORDER_FILE}" ]]; then
        echo -e "${RED}ERROR: No order_id provided and _last_order.json not found.${NC}"
        echo "Usage: $0 [order_id]"
        echo "Or run create-order.sh first."
        exit 1
    fi
    ORDER_ID=$(python3 -c "import json; print(json.load(open('${LAST_ORDER_FILE}'))['orderId'])")
fi

echo -e "${CYAN}Registering agent via DCR...${NC}"
echo -e "  Order ID:            ${YELLOW}${ORDER_ID}${NC}"
echo -e "  Mock IDP URL:        ${MOCK_IDP_URL}"
echo -e "  Marketplace Handler: ${MARKETPLACE_HANDLER_URL}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Get a signed DCR JWT from mock-idp
# ---------------------------------------------------------------------------
echo -e "${CYAN}Step 1: Getting signed DCR JWT from mock-idp...${NC}"

DCR_JWT_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'order_id': '${ORDER_ID}',
    'provider_url': '${PROVIDER_URL}',
    'redirect_uris': ['https://example.com/callback']
}))
")

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${DCR_JWT_PAYLOAD}" \
    "${MOCK_IDP_URL}/sign-dcr-jwt")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 ]]; then
    echo -e "${RED}ERROR: Failed to get signed DCR JWT (HTTP ${HTTP_CODE})${NC}"
    echo "${BODY}"
    exit 1
fi

SIGNED_JWT=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['signed_jwt'])")
echo -e "${GREEN}Got signed DCR JWT.${NC}"

# ---------------------------------------------------------------------------
# Step 2: Send DCR request to marketplace handler
# ---------------------------------------------------------------------------
echo -e "${CYAN}Step 2: Sending DCR request to marketplace handler...${NC}"

DCR_PAYLOAD=$(python3 -c "
import json
print(json.dumps({'software_statement': '${SIGNED_JWT}'}))
")

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${DCR_PAYLOAD}" \
    "${MARKETPLACE_HANDLER_URL}/dcr")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 ]]; then
    echo -e "${RED}ERROR: DCR request failed (HTTP ${HTTP_CODE})${NC}"
    echo "${BODY}"
    exit 1
fi

CLIENT_ID=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
CLIENT_SECRET=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_secret'])")

echo ""
echo -e "${GREEN}DCR registration successful!${NC}"
echo -e "  Client ID:     ${YELLOW}${CLIENT_ID}${NC}"
echo -e "  Client Secret: ${YELLOW}${CLIENT_SECRET}${NC}"

# Save DCR details
echo "${BODY}" > "${TEST_ENV_DIR}/_last_dcr.json"
echo -e "${CYAN}Saved to ${TEST_ENV_DIR}/_last_dcr.json${NC}"
