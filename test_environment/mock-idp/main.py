"""Mock Identity Provider (OAuth2 / OpenID Connect).

Replaces Okta as the OAuth2 Identity Provider for testing.
Generates RSA keys at startup and issues signed JWTs.
All state is stored in-memory.
"""

import base64
import hashlib
import logging
import os
import secrets
import time
import uuid
from datetime import datetime, timezone
from typing import Any

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from fastapi import FastAPI, Form, Header, HTTPException, Query, Request
from fastapi.responses import RedirectResponse
from jose import jwt as jose_jwt
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ISSUER_URL = os.environ.get("ISSUER_URL", "http://localhost:8080")
MOCK_API_TOKEN = os.environ.get("MOCK_API_TOKEN", "mock-api-token-for-testing")
AUTH_CODE_TTL_SECONDS = 300  # 5 minutes
ACCESS_TOKEN_TTL_SECONDS = 3600  # 1 hour

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("mock-idp")

app = FastAPI(
    title="Mock Identity Provider",
    description="Mock OAuth2 / OIDC Identity Provider for testing.",
    version="1.0.0",
)

# ---------------------------------------------------------------------------
# RSA Key Pair & Self-Signed Certificate (generated at startup)
# ---------------------------------------------------------------------------

_rsa_private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_rsa_public_key = _rsa_private_key.public_key()

# Key ID derived from public key fingerprint
_public_key_der = _rsa_public_key.public_bytes(
    encoding=serialization.Encoding.DER,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
)
KID = hashlib.sha256(_public_key_der).hexdigest()[:16]

# Generate a self-signed certificate for the /certs endpoint
_cert_builder = (
    x509.CertificateBuilder()
    .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "mock-idp")]))
    .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "mock-idp")]))
    .public_key(_rsa_public_key)
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime(2024, 1, 1, tzinfo=timezone.utc))
    .not_valid_after(datetime(2030, 1, 1, tzinfo=timezone.utc))
)
_self_signed_cert = _cert_builder.sign(
    private_key=_rsa_private_key, algorithm=hashes.SHA256()
)
_cert_pem = _self_signed_cert.public_bytes(serialization.Encoding.PEM).decode("utf-8")

logger.info("Generated RSA key pair and self-signed certificate (kid=%s)", KID)

# ---------------------------------------------------------------------------
# In-memory storage
# ---------------------------------------------------------------------------

# client_id -> client dict
clients: dict[str, dict[str, Any]] = {}

# auth_code -> {client_id, redirect_uri, scope, expires_at}
auth_codes: dict[str, dict[str, Any]] = {}

# refresh_token -> {client_id, scope, sub}
refresh_tokens: dict[str, dict[str, Any]] = {}

# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------


class CreateClientRequest(BaseModel):
    client_name: str
    redirect_uris: list[str] = []
    response_types: list[str] = ["code"]
    grant_types: list[str] = ["authorization_code"]
    scope: str = "openid"


class SignDcrJwtRequest(BaseModel):
    order_id: str
    provider_url: str
    redirect_uris: list[str] = []


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _validate_ssws_token(authorization: str | None) -> None:
    """Validate the SSWS API token from the Authorization header."""
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0] != "SSWS":
        raise HTTPException(
            status_code=401, detail="Authorization header must use 'SSWS <token>' format"
        )
    if parts[1] != MOCK_API_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid API token")


def _validate_basic_auth(authorization: str | None) -> tuple[str, str]:
    """Validate Basic auth and return (client_id, client_secret)."""
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0] != "Basic":
        raise HTTPException(
            status_code=401, detail="Authorization header must use 'Basic' scheme"
        )
    try:
        decoded = base64.b64decode(parts[1]).decode("utf-8")
        client_id, client_secret = decoded.split(":", 1)
    except Exception:
        raise HTTPException(status_code=401, detail="Malformed Basic auth credentials")
    return client_id, client_secret


def _validate_client_credentials(client_id: str, client_secret: str) -> dict[str, Any]:
    """Look up client and verify its secret."""
    client = clients.get(client_id)
    if client is None:
        raise HTTPException(status_code=401, detail=f"Unknown client_id: {client_id}")
    if client["client_secret"] != client_secret:
        raise HTTPException(status_code=401, detail="Invalid client_secret")
    return client


def _build_jwt(
    sub: str,
    scope: str,
    aud: str = "api://default",
    extra_claims: dict[str, Any] | None = None,
    ttl: int = ACCESS_TOKEN_TTL_SECONDS,
) -> str:
    """Create and sign a JWT access token."""
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": ISSUER_URL,
        "sub": sub,
        "aud": aud,
        "iat": now,
        "exp": now + ttl,
        "scope": scope,
    }
    if extra_claims:
        claims.update(extra_claims)
    return jose_jwt.encode(claims, _rsa_private_key, algorithm="RS256", headers={"kid": KID})


def _purge_expired_codes() -> None:
    """Remove expired auth codes."""
    now = time.time()
    expired = [code for code, data in auth_codes.items() if data["expires_at"] < now]
    for code in expired:
        del auth_codes[code]


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# JWKS / Certs
# ---------------------------------------------------------------------------


@app.get("/.well-known/jwks.json")
def jwks() -> dict[str, Any]:
    """Serve the public key as a JSON Web Key Set."""
    from jose.backends import RSAKey as JoseRSAKey

    pub_numbers = _rsa_public_key.public_numbers()

    def _int_to_base64url(n: int, length: int | None = None) -> str:
        byte_length = length or ((n.bit_length() + 7) // 8)
        n_bytes = n.to_bytes(byte_length, byteorder="big")
        return base64.urlsafe_b64encode(n_bytes).rstrip(b"=").decode("ascii")

    return {
        "keys": [
            {
                "kty": "RSA",
                "use": "sig",
                "alg": "RS256",
                "kid": KID,
                "n": _int_to_base64url(pub_numbers.n, 256),
                "e": _int_to_base64url(pub_numbers.e),
            }
        ]
    }


@app.get("/certs")
def certs() -> dict[str, str]:
    """Return the public key as PEM certificate, keyed by kid.

    This matches the format expected by google-auth's id_token.verify_token().
    """
    return {KID: _cert_pem}


# ---------------------------------------------------------------------------
# Client Management (mimics Okta /oauth2/v1/clients)
# ---------------------------------------------------------------------------


@app.post("/oauth2/v1/clients")
def create_client(
    body: CreateClientRequest,
    authorization: str | None = Header(None),
) -> dict[str, Any]:
    """Create a new OAuth2 client application."""
    _validate_ssws_token(authorization)

    client_id = str(uuid.uuid4())
    client_secret = secrets.token_urlsafe(32)

    client = {
        "client_id": client_id,
        "client_secret": client_secret,
        "client_name": body.client_name,
        "redirect_uris": body.redirect_uris,
        "response_types": body.response_types,
        "grant_types": body.grant_types,
        "scope": body.scope,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    clients[client_id] = client
    logger.info("Created OAuth client '%s' (id=%s)", body.client_name, client_id)

    return client


# ---------------------------------------------------------------------------
# OAuth2 Authorization Server
# ---------------------------------------------------------------------------


@app.get("/oauth2/default/v1/authorize")
def authorize(
    client_id: str = Query(...),
    redirect_uri: str = Query(...),
    response_type: str = Query("code"),
    scope: str = Query("openid"),
    state: str = Query(""),
) -> RedirectResponse:
    """Authorization endpoint. Auto-approves and redirects with an auth code."""
    if response_type != "code":
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported response_type: {response_type}. Only 'code' is supported.",
        )

    client = clients.get(client_id)
    if client is None:
        raise HTTPException(status_code=400, detail=f"Unknown client_id: {client_id}")

    _purge_expired_codes()

    code = secrets.token_urlsafe(32)
    auth_codes[code] = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "expires_at": time.time() + AUTH_CODE_TTL_SECONDS,
    }

    separator = "&" if "?" in redirect_uri else "?"
    location = f"{redirect_uri}{separator}code={code}&state={state}"
    logger.info("Issued auth code for client %s, redirecting to %s", client_id, redirect_uri)
    return RedirectResponse(url=location, status_code=302)


@app.post("/oauth2/default/v1/token")
def token(
    grant_type: str = Form(...),
    code: str | None = Form(None),
    redirect_uri: str | None = Form(None),
    client_id: str | None = Form(None),
    client_secret: str | None = Form(None),
    refresh_token: str | None = Form(None),
) -> dict[str, Any]:
    """Token endpoint. Supports authorization_code and refresh_token grants."""

    if grant_type == "authorization_code":
        return _handle_authorization_code_grant(code, redirect_uri, client_id, client_secret)
    elif grant_type == "refresh_token":
        return _handle_refresh_token_grant(refresh_token, client_id, client_secret)
    else:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported grant_type: {grant_type}",
        )


def _handle_authorization_code_grant(
    code: str | None,
    redirect_uri: str | None,
    client_id: str | None,
    client_secret: str | None,
) -> dict[str, Any]:
    if not code:
        raise HTTPException(status_code=400, detail="Missing 'code' parameter")
    if not client_id or not client_secret:
        raise HTTPException(status_code=400, detail="Missing client_id or client_secret")

    _purge_expired_codes()

    code_data = auth_codes.pop(code, None)
    if code_data is None:
        raise HTTPException(status_code=400, detail="Invalid or expired authorization code")

    if code_data["client_id"] != client_id:
        raise HTTPException(status_code=400, detail="Code was not issued to this client")

    if redirect_uri and code_data["redirect_uri"] != redirect_uri:
        raise HTTPException(status_code=400, detail="redirect_uri mismatch")

    client = _validate_client_credentials(client_id, client_secret)
    scope = code_data["scope"]
    sub = f"user-{client_id}"

    access_token = _build_jwt(sub=sub, scope=scope)
    id_token = _build_jwt(sub=sub, scope="openid", aud=client_id)
    new_refresh_token = secrets.token_urlsafe(32)

    refresh_tokens[new_refresh_token] = {
        "client_id": client_id,
        "scope": scope,
        "sub": sub,
    }

    logger.info("Issued tokens for client %s via authorization_code grant", client_id)

    return {
        "access_token": access_token,
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_TTL_SECONDS,
        "scope": scope,
        "refresh_token": new_refresh_token,
        "id_token": id_token,
    }


def _handle_refresh_token_grant(
    refresh_token_value: str | None,
    client_id: str | None,
    client_secret: str | None,
) -> dict[str, Any]:
    if not refresh_token_value:
        raise HTTPException(status_code=400, detail="Missing 'refresh_token' parameter")

    rt_data = refresh_tokens.get(refresh_token_value)
    if rt_data is None:
        raise HTTPException(status_code=400, detail="Invalid refresh token")

    # Validate client credentials if provided
    if client_id and client_secret:
        _validate_client_credentials(client_id, client_secret)
        if rt_data["client_id"] != client_id:
            raise HTTPException(
                status_code=400, detail="Refresh token was not issued to this client"
            )

    scope = rt_data["scope"]
    sub = rt_data["sub"]
    effective_client_id = rt_data["client_id"]

    access_token = _build_jwt(sub=sub, scope=scope)
    id_token = _build_jwt(sub=sub, scope="openid", aud=effective_client_id)

    # Rotate refresh token
    del refresh_tokens[refresh_token_value]
    new_refresh_token = secrets.token_urlsafe(32)
    refresh_tokens[new_refresh_token] = {
        "client_id": effective_client_id,
        "scope": scope,
        "sub": sub,
    }

    logger.info("Issued tokens for client %s via refresh_token grant", effective_client_id)

    return {
        "access_token": access_token,
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_TTL_SECONDS,
        "scope": scope,
        "refresh_token": new_refresh_token,
        "id_token": id_token,
    }


# ---------------------------------------------------------------------------
# Token Introspection
# ---------------------------------------------------------------------------


@app.post("/oauth2/default/v1/introspect")
def introspect(
    token: str = Form(...),
    token_type_hint: str | None = Form(None),
    authorization: str | None = Header(None),
) -> dict[str, Any]:
    """Token introspection endpoint (RFC 7662).

    Authenticates the caller via Basic auth (client_id:client_secret).
    """
    client_id, client_secret = _validate_basic_auth(authorization)
    _validate_client_credentials(client_id, client_secret)

    try:
        claims = jose_jwt.decode(
            token,
            _rsa_public_key,
            algorithms=["RS256"],
            options={"verify_aud": False},
        )
        return {
            "active": True,
            "scope": claims.get("scope", ""),
            "client_id": client_id,
            "sub": claims.get("sub", ""),
            "exp": claims.get("exp"),
            "iat": claims.get("iat"),
            "iss": claims.get("iss"),
            "token_type": "Bearer",
        }
    except Exception:
        logger.debug("Token introspection: token is invalid or expired")
        return {"active": False}


# ---------------------------------------------------------------------------
# DCR Test JWT Signing (test helper)
# ---------------------------------------------------------------------------


@app.post("/sign-dcr-jwt")
def sign_dcr_jwt(body: SignDcrJwtRequest) -> dict[str, str]:
    """Sign a JWT mimicking what Google would send for Dynamic Client Registration.

    This is a test helper endpoint, not part of a real IdP.
    """
    now = int(time.time())
    claims = {
        "iss": f"{ISSUER_URL}/certs",
        "aud": body.provider_url,
        "sub": "test-procurement-account",
        "google": {"order": body.order_id},
        "auth_app_redirect_uris": body.redirect_uris,
        "iat": now,
        "exp": now + 3600,
    }
    signed = jose_jwt.encode(claims, _rsa_private_key, algorithm="RS256", headers={"kid": KID})
    logger.info("Signed DCR JWT for order %s", body.order_id)
    return {"signed_jwt": signed}
