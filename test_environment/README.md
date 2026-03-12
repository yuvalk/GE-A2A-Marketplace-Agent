# Test Environment

A self-contained, GCP-deployable test environment that simulates the full GE A2A Marketplace Agent lifecycle — from marketplace purchase to agent invocation — without requiring a real Google Cloud Marketplace listing or Okta account.

## Architecture

```
                        ┌─────────────────────────┐
                        │   Customer / Scripts     │
                        │  (create-order, DCR,     │
                        │   get-token, call-agent) │
                        └────┬───┬───┬───┬────────┘
                             │   │   │   │
                ┌────────────┘   │   │   └────────────┐
                ▼                ▼   ▼                ▼
  ┌──────────────────┐ ┌──────────────┐ ┌───────────────────┐
  │ mock-procurement │ │   mock-idp   │ │  marketplace-     │
  │      -api        │ │  (OAuth2 /   │ │    handler        │
  │                  │ │   OIDC)      │ │                   │
  │ Simulates Google │ │ Replaces     │ │ Order processing  │
  │ Partner          │ │ Okta:        │ │ + DCR endpoint    │
  │ Procurement API  │ │ • authorize  │ │                   │
  │ • accounts       │ │ • token      │ │ Uses:             │
  │ • entitlements   │ │ • introspect │ │ • Firestore       │
  │ • orders (test)  │ │ • clients    │ │ • Pub/Sub         │
  └────────┬─────────┘ │ • certs/JWKS │ └─────────┬─────────┘
           │           └──────┬───────┘           │
           │  Pub/Sub         │ introspect        │
           │  message         │                   │
           │                  ▼                   │
           │           ┌──────────────┐           │
           └──────────►│ agent-service│◄──────────┘
                       │              │   DCR target
                       │ A2A Time     │
                       │ Agent with   │
                       │ OAuth        │
                       │ middleware   │
                       └──────────────┘

  Real GCP services: Pub/Sub (notifications), Firestore (order-to-client mappings)
  Everything else: Cloud Run containers
```

### Services

| Service | What it does | Replaces |
|---------|-------------|----------|
| **mock-procurement-api** | Simulates Google's Partner Procurement API (CRUD for accounts/entitlements, order creation with Pub/Sub notification) | `cloudcommerceprocurement.googleapis.com` |
| **mock-idp** | Full OAuth2/OIDC Identity Provider (authorize, token, introspect, client management, JWKS, DCR JWT signing) | Okta |
| **marketplace-handler** | Receives Pub/Sub order notifications, creates OAuth clients, handles DCR requests, stores mappings in Firestore | Same as `5_gcp_marketplace_setup/` |
| **agent-service** | A2A time agent with OAuth middleware — validates tokens via mock-idp introspection | Same as `3_deploy_agent/` |

## Prerequisites

- **Google Cloud SDK** (`gcloud`) installed and authenticated
- A **GCP project** with billing enabled
- **Python 3.11+** installed locally (used by deployment scripts for JSON manipulation)

## Quick Start

### 1. Configure

```bash
cd test_environment
cp config.env.template config.env
```

Edit `config.env` and set your GCP project ID:

```bash
PROJECT_ID=my-gcp-project-id
```

The other defaults work out of the box. Here's what each setting does:

| Variable | Default | Purpose |
|----------|---------|---------|
| `PROJECT_ID` | *(must set)* | Your GCP project |
| `REGION` | `us-central1` | GCP region for all resources |
| `PROVIDER_URL` | `https://test-agent-provider.example.com` | JWT audience for DCR validation |
| `MOCK_API_TOKEN` | `mock-api-token-for-testing` | API token for mock-idp client management |
| `PUBSUB_TOPIC_NAME` | `test-marketplace-orders` | Pub/Sub topic for order notifications |
| `PUBSUB_SUBSCRIPTION_NAME` | `test-marketplace-orders-sub` | Pub/Sub push subscription name |
| `PROVIDER_ID` | `test-provider` | Provider ID in procurement API paths |

### 2. Deploy

```bash
chmod +x deploy-all.sh setup-rs-client.sh teardown.sh scripts/*.sh
./deploy-all.sh
```

This takes ~10-15 minutes and performs these steps:

1. Enables required GCP APIs (Cloud Run, Pub/Sub, Firestore, Cloud Build)
2. Creates Firestore database
3. Creates Pub/Sub topic
4. Deploys **mock-procurement-api** (with Pub/Sub topic configured)
5. Deploys **mock-idp** (two-step deploy — needs its own URL as `ISSUER_URL`)
6. Creates a resource-server OAuth client in mock-idp (for agent token introspection)
7. Deploys **marketplace-handler** (wired to mock-procurement-api, mock-idp, and Firestore)
8. Creates Pub/Sub push subscription pointing to marketplace-handler's `/dcr` endpoint
9. Deploys **agent-service** (two-step deploy — updates `agent.json` with real URLs)
10. Writes all service URLs back to `config.env`

After deployment, `config.env` will contain the deployed service URLs (appended automatically).

### 3. Run the Full Lifecycle

```bash
./scripts/full-lifecycle.sh
```

This runs all 4 steps in sequence:

1. **Create order** — simulates a marketplace purchase
2. **Register agent (DCR)** — exchanges a signed JWT for OAuth client credentials
3. **Get OAuth token** — authorization code flow to get an access token
4. **Call agent** — sends an A2A request with the token

You can also pass a custom question:

```bash
./scripts/full-lifecycle.sh "What time is it in Berlin?"
```

### 4. Run Steps Individually

Each step can be run independently:

```bash
# Create a marketplace order
./scripts/create-order.sh

# Register the agent (uses order from previous step)
./scripts/register-agent.sh

# Get an OAuth token (uses credentials from previous step)
./scripts/get-token.sh

# Call the agent (uses token from previous step)
./scripts/call-agent.sh "What time is it in Paris?"
```

You can also pass explicit values:

```bash
./scripts/register-agent.sh <order_id>
./scripts/get-token.sh <client_id> <client_secret>
```

### 5. Python Customer Client

For programmatic access, use the Python client:

```bash
cd customer-client
pip install -r requirements.txt

# Source the URLs from config.env (or set env vars manually)
export $(grep -v '^#' ../config.env | grep -v '^$' | xargs)

python client.py "What time is it in Tokyo?"
```

### 6. Tear Down

```bash
./teardown.sh
```

Deletes all Cloud Run services, Pub/Sub resources, Firestore documents, and local state files. Prompts for confirmation before proceeding.

## How It Works

### End-to-End Flow

```
1. CREATE ORDER
   Customer ──POST──► mock-procurement-api ──Pub/Sub──► marketplace-handler
                      Creates account +                 Approves account via
                      entitlement, publishes             mock-procurement-api,
                      Pub/Sub message                   creates OAuth client
                                                        in mock-idp, stores
                                                        orderId→clientId in
                                                        Firestore

2. REGISTER AGENT (DCR)
   Customer ──POST──► mock-idp/sign-dcr-jwt            Signs a JWT with the
              │       (returns signed JWT)               order ID
              │
              └──POST──► marketplace-handler/dcr        Validates JWT, looks up
                         (returns client_id/secret)      order in Firestore,
                                                        returns credentials

3. GET TOKEN
   Customer ──GET───► mock-idp/authorize                Auto-approves, redirects
              │       (returns auth code)                with auth code
              │
              └──POST──► mock-idp/token                 Exchanges code for
                         (returns access_token)          signed JWT access token

4. CALL AGENT
   Customer ──POST──► agent-service/a2a/...             OAuth middleware calls
                      Authorization: Bearer <token>      mock-idp/introspect to
                      (returns agent response)           validate token, then
                                                        ADK agent processes query
```

### State Files

The scripts save intermediate state to files in `test_environment/` so each step can use the output of the previous one:

| File | Written by | Contains |
|------|-----------|----------|
| `_last_order.json` | `create-order.sh` | `orderId`, `accountId`, `entitlementId` |
| `_last_dcr.json` | `register-agent.sh` | `client_id`, `client_secret` |
| `_last_token.json` | `get-token.sh` | `access_token`, `refresh_token`, `id_token` |
| `_rs_credentials.json` | `setup-rs-client.sh` | Resource-server client credentials |

All state files are in `.gitignore`.

## File Structure

```
test_environment/
├── config.env.template          # Configuration template
├── deploy-all.sh                # Master deployment script
├── setup-rs-client.sh           # Creates resource-server OAuth client
├── teardown.sh                  # Removes all resources
├── .gitignore                   # Excludes state files and config.env
│
├── mock-procurement-api/        # Mock Google Partner Procurement API
│   ├── main.py
│   ├── Dockerfile
│   └── requirements.txt
│
├── mock-idp/                    # Mock OAuth2 Identity Provider
│   ├── main.py
│   ├── Dockerfile
│   └── requirements.txt
│
├── marketplace-handler/         # Order processing + DCR endpoint
│   ├── marketplace_handler.py
│   ├── Dockerfile
│   ├── requirements.txt
│   └── dcr/
│       ├── __init__.py
│       └── utils.py
│
├── agent-service/               # A2A time agent with OAuth
│   ├── Dockerfile
│   ├── requirements.txt
│   └── remote_time_agent/
│       ├── __init__.py
│       ├── agent.py
│       └── .well-known/
│           └── agent.json
│
├── scripts/                     # Interaction scripts
│   ├── create-order.sh
│   ├── register-agent.sh
│   ├── get-token.sh
│   ├── call-agent.sh
│   └── full-lifecycle.sh
│
└── customer-client/             # Python customer client
    ├── client.py
    └── requirements.txt
```

## Troubleshooting

### "MOCK_PROCUREMENT_API_URL is not set in config.env"

The interaction scripts need service URLs that are written by `deploy-all.sh`. Make sure you've run `deploy-all.sh` successfully — it appends the URLs to `config.env` at the end.

### DCR returns "Invalid Order ID: Order not found in client records"

The Pub/Sub message from order creation hasn't been processed yet. The marketplace-handler needs to receive and process the Pub/Sub notification before DCR will work. Try:
- Waiting longer (increase the sleep in `create-order.sh`)
- Checking the marketplace-handler Cloud Run logs: `gcloud run services logs read marketplace-handler --region us-central1`

### Token introspection fails (401 from agent-service)

The resource-server client credentials may not match. Check that:
- `_rs_credentials.json` exists and was created after the current mock-idp deployment
- The agent-service was deployed with the correct `RESOURCE_SERVER_CLIENT_ID` and `RESOURCE_SERVER_CLIENT_SECRET`

If in doubt, re-run `deploy-all.sh` — it's idempotent.

### Agent returns 403 "Missing required scope: agent:time"

The access token doesn't include the `agent:time` scope. Make sure the authorize request includes `scope=openid+agent:time+offline_access`. The provided scripts handle this automatically.

### Redeployment after code changes

If you modify any service code, re-run `deploy-all.sh`. It rebuilds and redeploys all services. To redeploy a single service:

```bash
source config.env
gcloud run deploy <service-name> \
    --source <service-dir> \
    --region $REGION \
    --platform managed \
    --allow-unauthenticated \
    --quiet
```
