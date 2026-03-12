#!/bin/bash
set -e

# =============================================================================
# Setup Resource Server Client in Mock IdP
# =============================================================================
# Creates an OAuth2 client for the agent-service to use for token introspection.
# Called by deploy-all.sh after mock-idp is deployed.
#
# Required environment variables:
#   MOCK_IDP_URL - The URL of the deployed mock-idp service
#
# Outputs:
#   _rs_credentials.json - File containing client_id and client_secret
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS_FILE="${SCRIPT_DIR}/_rs_credentials.json"

if [ -z "$MOCK_IDP_URL" ]; then
    echo -e "${RED}Error: MOCK_IDP_URL environment variable is not set.${NC}"
    exit 1
fi

if [ -z "$MOCK_API_TOKEN" ]; then
    MOCK_API_TOKEN="mock-api-token-for-testing"
fi

echo -e "${YELLOW}Creating resource-server OAuth client in mock-idp...${NC}"
echo "  Mock IdP URL: ${MOCK_IDP_URL}"

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${MOCK_IDP_URL}/oauth2/v1/clients" \
    -H "Content-Type: application/json" \
    -H "Authorization: SSWS ${MOCK_API_TOKEN}" \
    -d '{
        "client_name": "Resource Server (Agent)",
        "redirect_uris": ["https://localhost/callback"],
        "scope": "openid agent:time offline_access"
    }')

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ] && [ "$HTTP_CODE" -ne 201 ]; then
    echo -e "${RED}Error: Failed to create resource-server client (HTTP ${HTTP_CODE}).${NC}"
    echo "Response: ${BODY}"
    exit 1
fi

# Save credentials to file
echo "$BODY" > "$CREDENTIALS_FILE"

CLIENT_ID=$(echo "$BODY" | python3 -c "import sys, json; print(json.load(sys.stdin)['client_id'])")
CLIENT_SECRET=$(echo "$BODY" | python3 -c "import sys, json; print(json.load(sys.stdin)['client_secret'])")

echo -e "${GREEN}Resource-server client created successfully.${NC}"
echo "  Client ID:     ${CLIENT_ID}"
echo "  Client Secret: ${CLIENT_SECRET}"
echo "  Credentials saved to: ${CREDENTIALS_FILE}"
