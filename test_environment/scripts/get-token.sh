#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# get-token.sh - Gets an OAuth access token using DCR credentials
#
# Usage: ./get-token.sh [client_id] [client_secret]
#   If no args provided, reads from _last_dcr.json
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

# ---------------------------------------------------------------------------
# Get client credentials
# ---------------------------------------------------------------------------
if [[ $# -ge 2 ]]; then
    CLIENT_ID="$1"
    CLIENT_SECRET="$2"
else
    LAST_DCR_FILE="${TEST_ENV_DIR}/_last_dcr.json"
    if [[ ! -f "${LAST_DCR_FILE}" ]]; then
        echo -e "${RED}ERROR: No credentials provided and _last_dcr.json not found.${NC}"
        echo "Usage: $0 [client_id] [client_secret]"
        echo "Or run register-agent.sh first."
        exit 1
    fi
    CLIENT_ID=$(python3 -c "import json; print(json.load(open('${LAST_DCR_FILE}'))['client_id'])")
    CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('${LAST_DCR_FILE}'))['client_secret'])")
fi

REDIRECT_URI="https://example.com/callback"

echo -e "${CYAN}Getting OAuth access token...${NC}"
echo -e "  Mock IDP URL: ${MOCK_IDP_URL}"
echo -e "  Client ID:    ${CLIENT_ID}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Get authorization code
# ---------------------------------------------------------------------------
echo -e "${CYAN}Step 1: Getting authorization code...${NC}"

REDIRECT_URL=$(curl -s -o /dev/null -w "%{redirect_url}" \
    "${MOCK_IDP_URL}/oauth2/default/v1/authorize?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_URI}&response_type=code&scope=openid+agent:time+offline_access&state=test")

if [[ -z "${REDIRECT_URL}" ]]; then
    echo -e "${RED}ERROR: No redirect URL received from authorize endpoint.${NC}"
    echo "The mock IDP may not have returned a redirect. Check that the client_id is valid."
    exit 1
fi

# Extract the code parameter from the redirect URL
AUTH_CODE=$(python3 -c "
from urllib.parse import urlparse, parse_qs
url = '${REDIRECT_URL}'
params = parse_qs(urlparse(url).query)
if 'code' in params:
    print(params['code'][0])
else:
    # Try fragment
    params = parse_qs(urlparse(url).fragment)
    if 'code' in params:
        print(params['code'][0])
    else:
        raise ValueError('No code found in redirect URL: ' + url)
")

echo -e "${GREEN}Got authorization code.${NC}"

# ---------------------------------------------------------------------------
# Step 2: Exchange code for token
# ---------------------------------------------------------------------------
echo -e "${CYAN}Step 2: Exchanging code for token...${NC}"

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=${AUTH_CODE}&redirect_uri=${REDIRECT_URI}&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" \
    "${MOCK_IDP_URL}/oauth2/default/v1/token")

HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -ne 200 ]]; then
    echo -e "${RED}ERROR: Token exchange failed (HTTP ${HTTP_CODE})${NC}"
    echo "${BODY}"
    exit 1
fi

ACCESS_TOKEN=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo ""
echo -e "${GREEN}Token obtained successfully!${NC}"
echo -e "  Access Token: ${YELLOW}${ACCESS_TOKEN:0:50}...${NC}"

# Save full token response
echo "${BODY}" > "${TEST_ENV_DIR}/_last_token.json"
echo -e "${CYAN}Saved to ${TEST_ENV_DIR}/_last_token.json${NC}"
