#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# full-lifecycle.sh - Runs the complete marketplace lifecycle end-to-end
#
# Steps:
#   1. Create order
#   2. Register agent (DCR)
#   3. Get OAuth token
#   4. Call agent
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ENV_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${TEST_ENV_DIR}/config.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo -e "${RED}ERROR: config.env not found at ${CONFIG_FILE}${NC}"
    echo "Run deploy-all.sh first or create config.env with the required service URLs."
    exit 1
fi

echo -e "${BOLD}${CYAN}========================================${NC}"
echo -e "${BOLD}${CYAN}  GE A2A Marketplace - Full Lifecycle   ${NC}"
echo -e "${BOLD}${CYAN}========================================${NC}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Create order
# ---------------------------------------------------------------------------
echo -e "${BOLD}${YELLOW}[Step 1/4] Creating marketplace order...${NC}"
echo "-------------------------------------------"
"${SCRIPT_DIR}/create-order.sh"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Register agent (DCR)
# ---------------------------------------------------------------------------
echo -e "${BOLD}${YELLOW}[Step 2/4] Registering agent via DCR...${NC}"
echo "-------------------------------------------"
"${SCRIPT_DIR}/register-agent.sh"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Get OAuth token
# ---------------------------------------------------------------------------
echo -e "${BOLD}${YELLOW}[Step 3/4] Getting OAuth token...${NC}"
echo "-------------------------------------------"
"${SCRIPT_DIR}/get-token.sh"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Call agent
# ---------------------------------------------------------------------------
echo -e "${BOLD}${YELLOW}[Step 4/4] Calling A2A agent...${NC}"
echo "-------------------------------------------"
"${SCRIPT_DIR}/call-agent.sh" "${1:-What time is it in Tokyo?}"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}========================================${NC}"
echo -e "${BOLD}${CYAN}  Lifecycle Complete                    ${NC}"
echo -e "${BOLD}${CYAN}========================================${NC}"
echo ""

ORDER_ID=$(python3 -c "import json; print(json.load(open('${TEST_ENV_DIR}/_last_order.json'))['orderId'])")
CLIENT_ID=$(python3 -c "import json; print(json.load(open('${TEST_ENV_DIR}/_last_dcr.json'))['client_id'])")

echo -e "${GREEN}Summary:${NC}"
echo -e "  Order ID:  ${ORDER_ID}"
echo -e "  Client ID: ${CLIENT_ID}"
echo -e "  State files saved in: ${TEST_ENV_DIR}/"
echo -e "    - _last_order.json"
echo -e "    - _last_dcr.json"
echo -e "    - _last_token.json"
echo ""
echo -e "${GREEN}All steps completed successfully!${NC}"
