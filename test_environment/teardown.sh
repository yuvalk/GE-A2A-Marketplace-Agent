#!/bin/bash
set -e

# =============================================================================
# Test Environment - Teardown Script
# =============================================================================
# Removes all Cloud Run services, Pub/Sub resources, and Firestore data
# created by deploy-all.sh.
#
# Each step is wrapped in error handling so cleanup continues even if
# individual resources do not exist.
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: config.env not found. Cannot determine resource names.${NC}"
    exit 1
fi

source "$CONFIG_FILE"

echo -e "${BLUE}=========================================================${NC}"
echo -e "${RED}  Test Environment Teardown${NC}"
echo -e "${BLUE}=========================================================${NC}"
echo ""
echo "  Project: ${PROJECT_ID}"
echo "  Region:  ${REGION}"
echo ""

# Confirm
read -p "Are you sure you want to delete all test environment resources? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

gcloud config set project "$PROJECT_ID" --quiet

DELETED=()
SKIPPED=()

# -----------------------------------------------------------------------------
# Step 1: Delete Cloud Run services
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 1: Deleting Cloud Run services ===${NC}"

SERVICES="agent-service marketplace-handler mock-idp mock-procurement-api"
for svc in $SERVICES; do
    echo -n "  Deleting ${svc}... "
    if gcloud run services delete "$svc" --region "$REGION" --platform managed --quiet 2>/dev/null; then
        echo -e "${GREEN}deleted.${NC}"
        DELETED+=("Cloud Run: ${svc}")
    else
        echo -e "${YELLOW}not found or already deleted.${NC}"
        SKIPPED+=("Cloud Run: ${svc}")
    fi
done

# -----------------------------------------------------------------------------
# Step 2: Delete Pub/Sub subscription
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 2: Deleting Pub/Sub subscription ===${NC}"

echo -n "  Deleting subscription '${PUBSUB_SUBSCRIPTION_NAME}'... "
if gcloud pubsub subscriptions delete "$PUBSUB_SUBSCRIPTION_NAME" --project="$PROJECT_ID" --quiet 2>/dev/null; then
    echo -e "${GREEN}deleted.${NC}"
    DELETED+=("Pub/Sub subscription: ${PUBSUB_SUBSCRIPTION_NAME}")
else
    echo -e "${YELLOW}not found or already deleted.${NC}"
    SKIPPED+=("Pub/Sub subscription: ${PUBSUB_SUBSCRIPTION_NAME}")
fi

# -----------------------------------------------------------------------------
# Step 3: Delete Pub/Sub topic
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 3: Deleting Pub/Sub topic ===${NC}"

echo -n "  Deleting topic '${PUBSUB_TOPIC_NAME}'... "
if gcloud pubsub topics delete "$PUBSUB_TOPIC_NAME" --project="$PROJECT_ID" --quiet 2>/dev/null; then
    echo -e "${GREEN}deleted.${NC}"
    DELETED+=("Pub/Sub topic: ${PUBSUB_TOPIC_NAME}")
else
    echo -e "${YELLOW}not found or already deleted.${NC}"
    SKIPPED+=("Pub/Sub topic: ${PUBSUB_TOPIC_NAME}")
fi

# -----------------------------------------------------------------------------
# Step 4: Delete Firestore documents in marketplace_clients collection
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 4: Cleaning up Firestore data ===${NC}"

echo -n "  Deleting documents in 'marketplace_clients' collection... "
if gcloud firestore databases describe --project="$PROJECT_ID" &>/dev/null; then
    # Use the REST API via gcloud to delete documents
    # List and delete all documents in the collection
    python3 -c "
import subprocess
import json
import sys

project = '${PROJECT_ID}'

# Use gcloud to list documents - firestore export is complex, so we use the REST approach
try:
    result = subprocess.run(
        ['gcloud', 'firestore', 'documents', 'list',
         '--project', project,
         '--collection-id', 'marketplace_clients',
         '--format', 'json'],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        print('No documents found or collection does not exist.')
        sys.exit(0)

    docs = json.loads(result.stdout) if result.stdout.strip() else []
    if not docs:
        print('No documents to delete.')
        sys.exit(0)

    count = 0
    for doc in docs:
        doc_name = doc.get('name', '')
        if doc_name:
            subprocess.run(
                ['gcloud', 'firestore', 'documents', 'delete', doc_name,
                 '--project', project, '--quiet'],
                capture_output=True, text=True, timeout=15
            )
            count += 1
    print(f'Deleted {count} document(s).')
except Exception as e:
    print(f'Warning: {e}')
" 2>/dev/null && echo -e "${GREEN}done.${NC}" || echo -e "${YELLOW}skipped (Firestore may not be available).${NC}"
else
    echo -e "${YELLOW}Firestore database not found, skipping.${NC}"
fi

# -----------------------------------------------------------------------------
# Step 5: Clean up local files
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 5: Cleaning up local files ===${NC}"

for f in _rs_credentials.json _last_order.json _last_dcr.json _last_token.json; do
    if [ -f "${SCRIPT_DIR}/${f}" ]; then
        rm -f "${SCRIPT_DIR}/${f}"
        echo -e "  ${GREEN}Removed ${f}${NC}"
        DELETED+=("Local: ${f}")
    fi
done

# Reset agent.json placeholders
AGENT_JSON="${SCRIPT_DIR}/agent-service/remote_time_agent/.well-known/agent.json"
if [ -f "$AGENT_JSON" ]; then
    python3 -c "
import json

file_path = '${AGENT_JSON}'
with open(file_path, 'r') as f:
    data = json.load(f)

data['url'] = 'PLACEHOLDER_AGENT_URL'
if 'provider' in data:
    data['provider']['url'] = 'PLACEHOLDER_PROVIDER_URL'
if 'capabilities' in data and 'extensions' in data['capabilities']:
    for ext in data['capabilities']['extensions']:
        if 'params' in ext and 'target_url' in ext['params']:
            ext['params']['target_url'] = 'PLACEHOLDER_DCR_URL'
if 'securitySchemes' in data and 'oauth2' in data['securitySchemes']:
    flows = data['securitySchemes']['oauth2'].get('flows', {})
    auth_code = flows.get('authorizationCode', {})
    if auth_code:
        auth_code['authorizationUrl'] = 'PLACEHOLDER_IDP_AUTHORIZE_URL'
        auth_code['tokenUrl'] = 'PLACEHOLDER_IDP_TOKEN_URL'
        auth_code['refreshUrl'] = 'PLACEHOLDER_IDP_TOKEN_URL'

with open(file_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
print('  agent.json reset to placeholders.')
"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=========================================================${NC}"
echo -e "${GREEN}  Teardown Complete${NC}"
echo -e "${BLUE}=========================================================${NC}"
echo ""
if [ ${#DELETED[@]} -gt 0 ]; then
    echo -e "  ${GREEN}Deleted:${NC}"
    for item in "${DELETED[@]}"; do
        echo "    - ${item}"
    done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${YELLOW}Skipped (not found):${NC}"
    for item in "${SKIPPED[@]}"; do
        echo "    - ${item}"
    done
fi
echo ""
echo -e "${BLUE}=========================================================${NC}"
