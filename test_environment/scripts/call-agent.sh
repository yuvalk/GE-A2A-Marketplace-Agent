#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# call-agent.sh - Calls the A2A agent with a question
#
# Usage: ./call-agent.sh [question]
#   Default question: "What time is it in Tokyo?"
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

AGENT_SERVICE_URL="${AGENT_SERVICE_URL:?AGENT_SERVICE_URL is not set in config.env}"

# ---------------------------------------------------------------------------
# Get access token
# ---------------------------------------------------------------------------
LAST_TOKEN_FILE="${TEST_ENV_DIR}/_last_token.json"
if [[ ! -f "${LAST_TOKEN_FILE}" ]]; then
    echo -e "${RED}ERROR: _last_token.json not found.${NC}"
    echo "Run get-token.sh first to obtain an access token."
    exit 1
fi

ACCESS_TOKEN=$(python3 -c "import json; print(json.load(open('${LAST_TOKEN_FILE}'))['access_token'])")

# ---------------------------------------------------------------------------
# Build request
# ---------------------------------------------------------------------------
QUESTION="${1:-What time is it in Tokyo?}"

echo -e "${CYAN}Calling A2A agent...${NC}"
echo -e "  Agent URL: ${AGENT_SERVICE_URL}"
echo -e "  Question:  ${YELLOW}${QUESTION}${NC}"
echo ""

REQUEST_BODY=$(python3 -c "
import json
print(json.dumps({
    'jsonrpc': '2.0',
    'method': 'message/send',
    'id': 'test-1',
    'params': {
        'message': {
            'role': 'user',
            'parts': [{'kind': 'text', 'text': '${QUESTION}'}],
            'messageId': 'msg-1'
        }
    }
}))
")

# ---------------------------------------------------------------------------
# Call agent
# ---------------------------------------------------------------------------
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${REQUEST_BODY}" \
    "${AGENT_SERVICE_URL}/a2a/remote_time_agent/")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 ]]; then
    echo -e "${RED}ERROR: Agent call failed (HTTP ${HTTP_CODE})${NC}"
    echo "${BODY}"
    exit 1
fi

echo -e "${GREEN}Agent response:${NC}"
echo "${BODY}" | python3 -m json.tool 2>/dev/null || echo "${BODY}"
