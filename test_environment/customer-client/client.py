"""
Customer Client for the GE A2A Marketplace Agent Test Environment.

This script demonstrates the complete customer lifecycle:
1. Purchase an agent on the marketplace (create order)
2. Register the agent via DCR
3. Obtain OAuth tokens
4. Call the agent via A2A protocol
"""

import json
import os
import sys
import time
from urllib.parse import parse_qs, urlparse

import httpx

# ---------------------------------------------------------------------------
# Configuration (from environment variables with localhost defaults)
# ---------------------------------------------------------------------------

MOCK_PROCUREMENT_API_URL = os.environ.get(
    "MOCK_PROCUREMENT_API_URL", "http://localhost:8000"
).rstrip("/")
MOCK_IDP_URL = os.environ.get("MOCK_IDP_URL", "http://localhost:8080").rstrip("/")
MARKETPLACE_HANDLER_URL = os.environ.get(
    "MARKETPLACE_HANDLER_URL", "http://localhost:8081"
).rstrip("/")
AGENT_SERVICE_URL = os.environ.get(
    "AGENT_SERVICE_URL", "http://localhost:8001"
).rstrip("/")
PROVIDER_ID = os.environ.get("PROVIDER_ID", "test-provider")
PROVIDER_URL = os.environ.get("PROVIDER_URL", "https://google.com")
REDIRECT_URI = "https://example.com/callback"

# How long to wait for Pub/Sub processing after order creation
PUBSUB_WAIT_SECONDS = int(os.environ.get("PUBSUB_WAIT_SECONDS", "5"))


def step_banner(step_num: int, total: int, title: str) -> None:
    """Print a step banner."""
    print(f"\n{'='*50}")
    print(f"  [{step_num}/{total}] {title}")
    print(f"{'='*50}\n")


# ---------------------------------------------------------------------------
# Step 1: Create Order
# ---------------------------------------------------------------------------


def create_order(client: httpx.Client) -> dict:
    """Create a marketplace order via the mock procurement API."""
    step_banner(1, 4, "Creating Marketplace Order")

    url = f"{MOCK_PROCUREMENT_API_URL}/v1/providers/{PROVIDER_ID}/orders"
    payload = {"plan": "default", "product": "time-agent"}

    print(f"  POST {url}")
    response = client.post(url, json=payload)
    response.raise_for_status()

    data = response.json()
    print(f"  Order ID:       {data['orderId']}")
    print(f"  Account ID:     {data['accountId']}")
    print(f"  Entitlement ID: {data['entitlementId']}")

    print(f"\n  Waiting {PUBSUB_WAIT_SECONDS}s for Pub/Sub processing...")
    time.sleep(PUBSUB_WAIT_SECONDS)
    print("  Done.")

    return data


# ---------------------------------------------------------------------------
# Step 2: Register Agent (DCR)
# ---------------------------------------------------------------------------


def register_agent(client: httpx.Client, order_id: str) -> dict:
    """Perform DCR registration for the given order."""
    step_banner(2, 4, "Registering Agent via DCR")

    # Step 2a: Get a signed DCR JWT from mock-idp
    print("  Getting signed DCR JWT from mock-idp...")
    sign_url = f"{MOCK_IDP_URL}/sign-dcr-jwt"
    sign_payload = {
        "order_id": order_id,
        "provider_url": PROVIDER_URL,
        "redirect_uris": [REDIRECT_URI],
    }

    response = client.post(sign_url, json=sign_payload)
    response.raise_for_status()
    signed_jwt = response.json()["signed_jwt"]
    print("  Got signed JWT.")

    # Step 2b: Send DCR request to marketplace handler
    print("  Sending DCR request to marketplace handler...")
    dcr_url = f"{MARKETPLACE_HANDLER_URL}/dcr"
    dcr_payload = {"software_statement": signed_jwt}

    response = client.post(dcr_url, json=dcr_payload)
    response.raise_for_status()

    data = response.json()
    print(f"  Client ID:     {data['client_id']}")
    print(f"  Client Secret: {data['client_secret']}")

    return data


# ---------------------------------------------------------------------------
# Step 3: Get OAuth Token
# ---------------------------------------------------------------------------


def get_token(client: httpx.Client, client_id: str, client_secret: str) -> dict:
    """Get an OAuth access token using the authorization code flow."""
    step_banner(3, 4, "Getting OAuth Token")

    # Step 3a: Get authorization code (don't follow redirect)
    print("  Getting authorization code...")
    authorize_url = (
        f"{MOCK_IDP_URL}/oauth2/default/v1/authorize"
        f"?client_id={client_id}"
        f"&redirect_uri={REDIRECT_URI}"
        f"&response_type=code"
        f"&scope=openid+agent:time+offline_access"
        f"&state=test"
    )

    response = client.get(authorize_url, follow_redirects=False)

    if response.status_code not in (302, 303, 307):
        print(f"  ERROR: Expected redirect, got HTTP {response.status_code}")
        print(f"  Body: {response.text}")
        sys.exit(1)

    redirect_location = response.headers.get("location", "")
    if not redirect_location:
        print("  ERROR: No Location header in redirect response.")
        sys.exit(1)

    # Extract the code from the redirect URL
    parsed = urlparse(redirect_location)
    params = parse_qs(parsed.query)
    if "code" not in params:
        print(f"  ERROR: No 'code' parameter in redirect URL: {redirect_location}")
        sys.exit(1)

    auth_code = params["code"][0]
    print("  Got authorization code.")

    # Step 3b: Exchange code for token
    print("  Exchanging code for token...")
    token_url = f"{MOCK_IDP_URL}/oauth2/default/v1/token"
    token_data = {
        "grant_type": "authorization_code",
        "code": auth_code,
        "redirect_uri": REDIRECT_URI,
        "client_id": client_id,
        "client_secret": client_secret,
    }

    response = client.post(
        token_url,
        data=token_data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    response.raise_for_status()

    data = response.json()
    access_token = data["access_token"]
    print(f"  Access Token: {access_token[:50]}...")

    return data


# ---------------------------------------------------------------------------
# Step 4: Call Agent
# ---------------------------------------------------------------------------


def call_agent(
    client: httpx.Client, access_token: str, question: str = "What time is it in Tokyo?"
) -> dict:
    """Call the A2A agent with a question."""
    step_banner(4, 4, "Calling A2A Agent")

    url = f"{AGENT_SERVICE_URL}/a2a/remote_time_agent/"
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    }
    payload = {
        "jsonrpc": "2.0",
        "method": "message/send",
        "id": "test-1",
        "params": {
            "message": {
                "role": "user",
                "parts": [{"kind": "text", "text": question}],
                "messageId": "msg-1",
            }
        },
    }

    print(f"  POST {url}")
    print(f"  Question: {question}")
    print()

    response = client.post(url, json=payload, headers=headers)
    response.raise_for_status()

    data = response.json()
    print("  Agent Response:")
    print(json.dumps(data, indent=2))

    return data


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    """Run the full customer lifecycle."""
    print("=" * 50)
    print("  GE A2A Marketplace - Customer Client")
    print("=" * 50)
    print()
    print("Configuration:")
    print(f"  Procurement API:     {MOCK_PROCUREMENT_API_URL}")
    print(f"  Mock IDP:            {MOCK_IDP_URL}")
    print(f"  Marketplace Handler: {MARKETPLACE_HANDLER_URL}")
    print(f"  Agent Service:       {AGENT_SERVICE_URL}")
    print(f"  Provider ID:         {PROVIDER_ID}")

    question = sys.argv[1] if len(sys.argv) > 1 else "What time is it in Tokyo?"

    with httpx.Client(timeout=30.0) as client:
        # Step 1: Create order
        order = create_order(client)

        # Step 2: Register agent
        dcr = register_agent(client, order["orderId"])

        # Step 3: Get token
        token_response = get_token(client, dcr["client_id"], dcr["client_secret"])

        # Step 4: Call agent
        call_agent(client, token_response["access_token"], question)

    print()
    print("=" * 50)
    print("  Lifecycle Complete!")
    print("=" * 50)
    print()
    print(f"  Order ID:  {order['orderId']}")
    print(f"  Client ID: {dcr['client_id']}")
    print()


if __name__ == "__main__":
    main()
