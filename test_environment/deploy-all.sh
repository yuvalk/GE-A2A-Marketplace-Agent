#!/bin/bash
set -e

# =============================================================================
# Test Environment - Full Deployment Script
# =============================================================================
# Deploys all 4 Cloud Run services and supporting GCP infrastructure.
# Idempotent: safe to re-run.
#
# Prerequisites:
#   1. Copy config.env.template to config.env and fill in values
#   2. Authenticate with gcloud: gcloud auth login
#   3. Install gcloud CLI with beta components
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Step 0: Load configuration
# -----------------------------------------------------------------------------
echo -e "${BLUE}=== Step 0: Loading configuration ===${NC}"

CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: config.env not found.${NC}"
    echo "Please copy config.env.template to config.env and fill in your values:"
    echo "  cp ${SCRIPT_DIR}/config.env.template ${SCRIPT_DIR}/config.env"
    exit 1
fi

source "$CONFIG_FILE"

# Validate required variables
REQUIRED_VARS="PROJECT_ID REGION PROVIDER_URL MOCK_API_TOKEN PUBSUB_TOPIC_NAME PUBSUB_SUBSCRIPTION_NAME PROVIDER_ID"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: ${var} is not set in config.env${NC}"
        exit 1
    fi
done

echo -e "${GREEN}Configuration loaded successfully.${NC}"
echo "  Project:  ${PROJECT_ID}"
echo "  Region:   ${REGION}"

# -----------------------------------------------------------------------------
# Step 1: Validate prerequisites
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 1: Validating prerequisites ===${NC}"

# Check gcloud is installed
if ! command -v gcloud &>/dev/null; then
    echo -e "${RED}Error: gcloud CLI is not installed.${NC}"
    exit 1
fi

# Check authentication
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
if [ -z "$ACTIVE_ACCOUNT" ]; then
    echo -e "${RED}Error: No active gcloud account. Run 'gcloud auth login' first.${NC}"
    exit 1
fi
echo -e "${GREEN}Authenticated as: ${ACTIVE_ACCOUNT}${NC}"

# Set project
gcloud config set project "$PROJECT_ID" --quiet
echo -e "${GREEN}Project set to: ${PROJECT_ID}${NC}"

# Full topic path
PUBSUB_TOPIC="projects/${PROJECT_ID}/topics/${PUBSUB_TOPIC_NAME}"

# -----------------------------------------------------------------------------
# Step 2: Enable required APIs
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 2: Enabling required GCP APIs ===${NC}"

APIS="run.googleapis.com pubsub.googleapis.com firestore.googleapis.com cloudbuild.googleapis.com"
for api in $APIS; do
    echo -e "  Enabling ${CYAN}${api}${NC}..."
    gcloud services enable "$api" --quiet
done
echo -e "${GREEN}All required APIs enabled.${NC}"

# -----------------------------------------------------------------------------
# Step 3: Create Firestore database (if not exists)
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 3: Creating Firestore database (if not exists) ===${NC}"

if gcloud firestore databases describe --project="$PROJECT_ID" &>/dev/null; then
    echo -e "${YELLOW}Firestore database already exists, skipping creation.${NC}"
else
    echo "Creating Firestore database in ${REGION}..."
    gcloud firestore databases create --location="$REGION" --type=firestore-native --quiet || {
        echo -e "${YELLOW}Warning: Could not create Firestore database. It may already exist in a different region.${NC}"
    }
fi

# -----------------------------------------------------------------------------
# Step 4: Create Pub/Sub topic (if not exists)
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 4: Creating Pub/Sub topic (if not exists) ===${NC}"

if gcloud pubsub topics describe "$PUBSUB_TOPIC_NAME" --project="$PROJECT_ID" &>/dev/null; then
    echo -e "${YELLOW}Topic '${PUBSUB_TOPIC_NAME}' already exists, skipping creation.${NC}"
else
    echo "Creating Pub/Sub topic '${PUBSUB_TOPIC_NAME}'..."
    gcloud pubsub topics create "$PUBSUB_TOPIC_NAME" --project="$PROJECT_ID"
    echo -e "${GREEN}Topic created.${NC}"
fi

# -----------------------------------------------------------------------------
# Step 5: Deploy mock-procurement-api
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 5: Deploying mock-procurement-api ===${NC}"

gcloud run deploy mock-procurement-api \
    --source "${SCRIPT_DIR}/mock-procurement-api" \
    --region "$REGION" \
    --platform managed \
    --allow-unauthenticated \
    --set-env-vars="PUBSUB_TOPIC=${PUBSUB_TOPIC}" \
    --quiet

MOCK_PROCUREMENT_URL=$(gcloud run services describe mock-procurement-api \
    --region "$REGION" --platform managed --format 'value(status.url)')

echo -e "${GREEN}mock-procurement-api deployed at: ${MOCK_PROCUREMENT_URL}${NC}"

# -----------------------------------------------------------------------------
# Step 6: Deploy mock-idp (two-step deploy)
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 6: Deploying mock-idp (two-step) ===${NC}"

echo -e "${CYAN}[Step 6a] Initial deploy to obtain URL...${NC}"
gcloud run deploy mock-idp \
    --source "${SCRIPT_DIR}/mock-idp" \
    --region "$REGION" \
    --platform managed \
    --allow-unauthenticated \
    --set-env-vars="ISSUER_URL=https://placeholder.run.app,MOCK_API_TOKEN=${MOCK_API_TOKEN}" \
    --quiet

MOCK_IDP_URL=$(gcloud run services describe mock-idp \
    --region "$REGION" --platform managed --format 'value(status.url)')

echo -e "${CYAN}[Step 6b] Redeploying with correct ISSUER_URL...${NC}"
gcloud run deploy mock-idp \
    --source "${SCRIPT_DIR}/mock-idp" \
    --region "$REGION" \
    --platform managed \
    --allow-unauthenticated \
    --set-env-vars="ISSUER_URL=${MOCK_IDP_URL},MOCK_API_TOKEN=${MOCK_API_TOKEN}" \
    --quiet

echo -e "${GREEN}mock-idp deployed at: ${MOCK_IDP_URL}${NC}"

# -----------------------------------------------------------------------------
# Step 7: Create resource-server OAuth client in mock-idp
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 7: Creating resource-server OAuth client ===${NC}"

export MOCK_IDP_URL
bash "${SCRIPT_DIR}/setup-rs-client.sh"

# Read credentials from the saved file
RS_CLIENT_ID=$(python3 -c "import json; d=json.load(open('${SCRIPT_DIR}/_rs_credentials.json')); print(d['client_id'])")
RS_CLIENT_SECRET=$(python3 -c "import json; d=json.load(open('${SCRIPT_DIR}/_rs_credentials.json')); print(d['client_secret'])")

echo -e "${GREEN}Resource-server client configured.${NC}"

# -----------------------------------------------------------------------------
# Step 8: Deploy marketplace-handler
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 8: Deploying marketplace-handler ===${NC}"

gcloud run deploy marketplace-handler \
    --source "${SCRIPT_DIR}/marketplace-handler" \
    --region "$REGION" \
    --platform managed \
    --allow-unauthenticated \
    --set-env-vars="PROCUREMENT_API_URL=${MOCK_PROCUREMENT_URL}/v1,IDP_URL=${MOCK_IDP_URL},IDP_API_TOKEN=${MOCK_API_TOKEN},JWT_CERTS_URL=${MOCK_IDP_URL}/certs,PROVIDER_URL=${PROVIDER_URL}" \
    --quiet

MARKETPLACE_HANDLER_URL=$(gcloud run services describe marketplace-handler \
    --region "$REGION" --platform managed --format 'value(status.url)')

echo -e "${GREEN}marketplace-handler deployed at: ${MARKETPLACE_HANDLER_URL}${NC}"

# -----------------------------------------------------------------------------
# Step 9: Create Pub/Sub push subscription
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 9: Creating Pub/Sub push subscription ===${NC}"

PUSH_ENDPOINT="${MARKETPLACE_HANDLER_URL}/dcr"

if gcloud pubsub subscriptions describe "$PUBSUB_SUBSCRIPTION_NAME" --project="$PROJECT_ID" &>/dev/null; then
    echo -e "${YELLOW}Subscription '${PUBSUB_SUBSCRIPTION_NAME}' already exists. Updating push endpoint...${NC}"
    gcloud pubsub subscriptions update "$PUBSUB_SUBSCRIPTION_NAME" \
        --project="$PROJECT_ID" \
        --push-endpoint="$PUSH_ENDPOINT" \
        --quiet
else
    echo "Creating Pub/Sub subscription '${PUBSUB_SUBSCRIPTION_NAME}'..."
    gcloud pubsub subscriptions create "$PUBSUB_SUBSCRIPTION_NAME" \
        --project="$PROJECT_ID" \
        --topic="$PUBSUB_TOPIC_NAME" \
        --push-endpoint="$PUSH_ENDPOINT" \
        --ack-deadline=60 \
        --quiet
fi

echo -e "${GREEN}Pub/Sub subscription configured to push to: ${PUSH_ENDPOINT}${NC}"

# -----------------------------------------------------------------------------
# Step 10: Deploy agent-service (two-step deploy)
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Step 10: Deploying agent-service (two-step) ===${NC}"

AGENT_JSON_PATH="${SCRIPT_DIR}/agent-service/remote_time_agent/.well-known/agent.json"

echo -e "${CYAN}[Step 10a] Initial deploy to obtain URL...${NC}"
gcloud run deploy agent-service \
    --source "${SCRIPT_DIR}/agent-service" \
    --region "$REGION" \
    --platform managed \
    --port 8001 \
    --allow-unauthenticated \
    --set-env-vars="IDP_URL=${MOCK_IDP_URL},RESOURCE_SERVER_CLIENT_ID=${RS_CLIENT_ID},RESOURCE_SERVER_CLIENT_SECRET=${RS_CLIENT_SECRET},GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=global,GOOGLE_GENAI_USE_VERTEXAI=True" \
    --quiet

AGENT_SERVICE_URL=$(gcloud run services describe agent-service \
    --region "$REGION" --platform managed --format 'value(status.url)')

echo -e "${CYAN}[Step 10b] Updating agent.json with real URLs...${NC}"

# Compute the DCR target host (strip protocol for target_url)
MARKETPLACE_HANDLER_HOST=$(echo "$MARKETPLACE_HANDLER_URL" | sed 's|https://||;s|http://||' | sed 's|/$||')

python3 -c "
import json
import sys

file_path = '${AGENT_JSON_PATH}'
agent_url = '${AGENT_SERVICE_URL}'
marketplace_handler_host = '${MARKETPLACE_HANDLER_HOST}'
idp_url = '${MOCK_IDP_URL}'
provider_url = '${PROVIDER_URL}'

try:
    with open(file_path, 'r') as f:
        data = json.load(f)

    # Update the agent URL
    base_path = '/a2a/remote_time_agent/'
    data['url'] = agent_url.rstrip('/') + base_path
    print(f'  Updated url to: {data[\"url\"]}')

    # Update provider URL
    if 'provider' in data:
        data['provider']['url'] = provider_url
        print(f'  Updated provider url to: {provider_url}')

    # Update DCR target_url
    if 'capabilities' in data and 'extensions' in data['capabilities']:
        for ext in data['capabilities']['extensions']:
            if 'params' in ext and 'target_url' in ext['params']:
                ext['params']['target_url'] = marketplace_handler_host + '/dcr'
                print(f'  Updated dcr target_url to: {ext[\"params\"][\"target_url\"]}')

    # Update OAuth URLs in securitySchemes
    if 'securitySchemes' in data and 'oauth2' in data['securitySchemes']:
        flows = data['securitySchemes']['oauth2'].get('flows', {})
        auth_code = flows.get('authorizationCode', {})
        if auth_code:
            auth_code['authorizationUrl'] = idp_url + '/oauth2/default/v1/authorize'
            auth_code['tokenUrl'] = idp_url + '/oauth2/default/v1/token'
            auth_code['refreshUrl'] = idp_url + '/oauth2/default/v1/token'
            print(f'  Updated OAuth URLs to use: {idp_url}')

    with open(file_path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')

    print('  agent.json updated successfully.')
except Exception as e:
    print(f'Error updating agent.json: {e}')
    sys.exit(1)
"

echo -e "${CYAN}[Step 10c] Final deploy with updated agent.json...${NC}"
gcloud run deploy agent-service \
    --source "${SCRIPT_DIR}/agent-service" \
    --region "$REGION" \
    --platform managed \
    --port 8001 \
    --allow-unauthenticated \
    --set-env-vars="IDP_URL=${MOCK_IDP_URL},RESOURCE_SERVER_CLIENT_ID=${RS_CLIENT_ID},RESOURCE_SERVER_CLIENT_SECRET=${RS_CLIENT_SECRET},GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=global,GOOGLE_GENAI_USE_VERTEXAI=True" \
    --quiet

echo -e "${GREEN}agent-service deployed at: ${AGENT_SERVICE_URL}${NC}"

# -----------------------------------------------------------------------------
# Write service URLs to config.env for use by interaction scripts
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=== Writing service URLs to config.env ===${NC}"

# Remove any previously generated URL lines
sed -i '/^# --- Generated by deploy-all.sh ---$/,/^# --- End generated ---$/d' "$CONFIG_FILE"

cat >> "$CONFIG_FILE" << EOF

# --- Generated by deploy-all.sh ---
MOCK_PROCUREMENT_API_URL=${MOCK_PROCUREMENT_URL}
MOCK_IDP_URL=${MOCK_IDP_URL}
MARKETPLACE_HANDLER_URL=${MARKETPLACE_HANDLER_URL}
AGENT_SERVICE_URL=${AGENT_SERVICE_URL}
RESOURCE_SERVER_CLIENT_ID=${RS_CLIENT_ID}
RESOURCE_SERVER_CLIENT_SECRET=${RS_CLIENT_SECRET}
# --- End generated ---
EOF

echo -e "${GREEN}Service URLs written to config.env${NC}"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}=========================================================${NC}"
echo -e "${GREEN}  Test Environment Deployment Complete${NC}"
echo -e "${BLUE}=========================================================${NC}"
echo ""
echo -e "  ${CYAN}mock-procurement-api:${NC}  ${MOCK_PROCUREMENT_URL}"
echo -e "  ${CYAN}mock-idp:${NC}              ${MOCK_IDP_URL}"
echo -e "  ${CYAN}marketplace-handler:${NC}   ${MARKETPLACE_HANDLER_URL}"
echo -e "  ${CYAN}agent-service:${NC}         ${AGENT_SERVICE_URL}"
echo ""
echo -e "  ${CYAN}Agent Endpoint:${NC}        ${AGENT_SERVICE_URL}/a2a/remote_time_agent/"
echo -e "  ${CYAN}Agent Card:${NC}            ${AGENT_SERVICE_URL}/.well-known/agent.json"
echo -e "  ${CYAN}DCR Endpoint:${NC}          ${MARKETPLACE_HANDLER_URL}/dcr"
echo -e "  ${CYAN}IdP Authorize:${NC}         ${MOCK_IDP_URL}/oauth2/default/v1/authorize"
echo -e "  ${CYAN}IdP Token:${NC}             ${MOCK_IDP_URL}/oauth2/default/v1/token"
echo ""
echo -e "  ${CYAN}Pub/Sub Topic:${NC}         ${PUBSUB_TOPIC}"
echo -e "  ${CYAN}Pub/Sub Subscription:${NC}  ${PUBSUB_SUBSCRIPTION_NAME} -> ${PUSH_ENDPOINT}"
echo ""
echo -e "  ${CYAN}RS Client Credentials:${NC} ${SCRIPT_DIR}/_rs_credentials.json"
echo ""
echo -e "${BLUE}=========================================================${NC}"
