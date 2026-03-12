"""Mock Google Partner Procurement API.

Simulates cloudcommerceprocurement.googleapis.com for testing purposes.
Stores all data in-memory.
"""

import logging
import os
import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PUBSUB_TOPIC = os.environ.get("PUBSUB_TOPIC", "")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("mock-procurement-api")

app = FastAPI(
    title="Mock Partner Procurement API",
    description="Simulates Google Cloud Partner Procurement API for testing.",
    version="1.0.0",
)

# ---------------------------------------------------------------------------
# In-memory storage
# ---------------------------------------------------------------------------

# Keyed by provider_id -> account_id -> account dict
accounts: dict[str, dict[str, dict[str, Any]]] = {}

# Keyed by provider_id -> entitlement_id -> entitlement dict
entitlements: dict[str, dict[str, dict[str, Any]]] = {}

# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------


class CreateOrderRequest(BaseModel):
    """Body for the test-helper create-order endpoint."""
    plan: str = "default"
    product: str = "test-product"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _publish_pubsub_message(message: dict[str, Any]) -> None:
    """Publish a message to the configured Pub/Sub topic, if any."""
    if not PUBSUB_TOPIC:
        logger.info("PUBSUB_TOPIC not set; skipping Pub/Sub publish.")
        return

    try:
        import json

        from google.cloud import pubsub_v1  # type: ignore[import-untyped]

        publisher = pubsub_v1.PublisherClient()
        data = json.dumps(message).encode("utf-8")
        future = publisher.publish(PUBSUB_TOPIC, data)
        result = future.result(timeout=10)
        logger.info("Published Pub/Sub message %s to %s", result, PUBSUB_TOPIC)
    except Exception:
        logger.exception("Failed to publish Pub/Sub message to %s", PUBSUB_TOPIC)


def _ensure_provider(provider_id: str) -> None:
    accounts.setdefault(provider_id, {})
    entitlements.setdefault(provider_id, {})


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Accounts
# ---------------------------------------------------------------------------


@app.get("/v1/providers/{provider_id}/accounts")
def list_accounts(provider_id: str) -> dict[str, Any]:
    _ensure_provider(provider_id)
    return {"accounts": list(accounts[provider_id].values())}


@app.get("/v1/providers/{provider_id}/accounts/{account_id}")
def get_account(provider_id: str, account_id: str) -> dict[str, Any]:
    _ensure_provider(provider_id)
    account = accounts[provider_id].get(account_id)
    if account is None:
        raise HTTPException(status_code=404, detail=f"Account {account_id} not found")
    return account


@app.post("/v1/providers/{provider_id}/accounts/{account_id}:approve")
def approve_account(provider_id: str, account_id: str) -> dict[str, Any]:
    _ensure_provider(provider_id)
    account = accounts[provider_id].get(account_id)
    if account is None:
        raise HTTPException(status_code=404, detail=f"Account {account_id} not found")

    account["state"] = "ACCOUNT_ACTIVE"
    account["updateTime"] = datetime.now(timezone.utc).isoformat()
    logger.info("Approved account %s for provider %s", account_id, provider_id)
    return account


@app.post("/v1/providers/{provider_id}/accounts/{account_id}:reset")
def reset_account(provider_id: str, account_id: str) -> dict[str, Any]:
    _ensure_provider(provider_id)
    account = accounts[provider_id].get(account_id)
    if account is None:
        raise HTTPException(status_code=404, detail=f"Account {account_id} not found")

    account["state"] = "ACCOUNT_CREATION_REQUESTED"
    account["updateTime"] = datetime.now(timezone.utc).isoformat()
    logger.info("Reset account %s for provider %s", account_id, provider_id)
    return account


# ---------------------------------------------------------------------------
# Entitlements
# ---------------------------------------------------------------------------


@app.get("/v1/providers/{provider_id}/entitlements")
def list_entitlements(provider_id: str) -> dict[str, Any]:
    _ensure_provider(provider_id)
    return {"entitlements": list(entitlements[provider_id].values())}


@app.get("/v1/providers/{provider_id}/entitlements/{entitlement_id}")
def get_entitlement(provider_id: str, entitlement_id: str) -> dict[str, Any]:
    _ensure_provider(provider_id)
    entitlement = entitlements[provider_id].get(entitlement_id)
    if entitlement is None:
        raise HTTPException(
            status_code=404, detail=f"Entitlement {entitlement_id} not found"
        )
    return entitlement


@app.post("/v1/providers/{provider_id}/entitlements/{entitlement_id}:approve")
def approve_entitlement(provider_id: str, entitlement_id: str) -> dict[str, Any]:
    _ensure_provider(provider_id)
    entitlement = entitlements[provider_id].get(entitlement_id)
    if entitlement is None:
        raise HTTPException(
            status_code=404, detail=f"Entitlement {entitlement_id} not found"
        )

    entitlement["state"] = "ENTITLEMENT_ACTIVE"
    entitlement["updateTime"] = datetime.now(timezone.utc).isoformat()
    logger.info(
        "Approved entitlement %s for provider %s", entitlement_id, provider_id
    )
    return entitlement


# ---------------------------------------------------------------------------
# Test helper: Create Order
# ---------------------------------------------------------------------------


@app.post("/v1/providers/{provider_id}/orders")
def create_order(provider_id: str, body: CreateOrderRequest) -> dict[str, Any]:
    """Test helper endpoint (not part of the real Procurement API).

    Creates an account + entitlement in one call, simulating a marketplace
    purchase flow.
    """
    _ensure_provider(provider_id)

    order_id = str(uuid.uuid4())
    account_id = str(uuid.uuid4())
    entitlement_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    # Create account
    account = {
        "name": f"providers/{provider_id}/accounts/{account_id}",
        "id": account_id,
        "state": "ACCOUNT_CREATION_REQUESTED",
        "orderId": order_id,
        "createTime": now,
        "updateTime": now,
    }
    accounts[provider_id][account_id] = account

    # Create entitlement
    entitlement = {
        "name": f"providers/{provider_id}/entitlements/{entitlement_id}",
        "id": entitlement_id,
        "account": f"providers/{provider_id}/accounts/{account_id}",
        "state": "ENTITLEMENT_CREATION_REQUESTED",
        "plan": body.plan,
        "product": body.product,
        "orderId": order_id,
        "createTime": now,
        "updateTime": now,
    }
    entitlements[provider_id][entitlement_id] = entitlement

    logger.info(
        "Created order %s (account=%s, entitlement=%s) for provider %s",
        order_id,
        account_id,
        entitlement_id,
        provider_id,
    )

    # Publish Pub/Sub notification if configured
    pubsub_message = {
        "eventType": "ACCOUNT_CREATION_REQUESTED",
        "providerId": provider_id,
        "account": {"id": account_id, "orderId": order_id},
        "entitlement": {"id": entitlement_id, "orderId": order_id},
    }
    _publish_pubsub_message(pubsub_message)

    return {
        "orderId": order_id,
        "accountId": account_id,
        "entitlementId": entitlement_id,
    }
