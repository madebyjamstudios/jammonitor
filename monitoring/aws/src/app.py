"""Independent Tailscale control-plane monitor for JamMonitor infrastructure.

This Lambda is intentionally outside the router, VPS, and tailnet data path. It
uses a read-only Tailscale OAuth client to detect a missing, stale, unapproved,
or expired router/VPS node and publishes low-cardinality CloudWatch metrics.
It never authenticates, approves, tags, modifies, or deletes a Tailscale node.
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.config import Config


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

HTTP_TIMEOUT_SECONDS = 4
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
SECRET_CACHE_SECONDS = 300
TOKEN_REFRESH_MARGIN_SECONDS = 300
DEFAULT_NAMESPACE = "JamMonitor/Tailscale"

AWS_CONFIG = Config(
    connect_timeout=2,
    read_timeout=4,
    # EventBridge Scheduler invokes Lambda asynchronously and the function's
    # EventInvokeConfig retries the whole observation once. Keep individual
    # SDK calls bounded so the failure metric still has time to publish.
    retries={"total_max_attempts": 1, "mode": "standard"},
)
SECRETS_CLIENT = boto3.client("secretsmanager", config=AWS_CONFIG)
CLOUDWATCH_CLIENT = boto3.client("cloudwatch", config=AWS_CONFIG)

_secret_cache: tuple[float, dict[str, str]] | None = None
_token_cache: tuple[float, str] | None = None


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Reject redirects so OAuth credentials never cross an origin boundary."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        del req, fp, code, msg, headers, newurl
        return None


HTTP_OPENER = urllib.request.build_opener(_NoRedirectHandler())


def _safe_log(level: int, event: str, **fields: Any) -> None:
    record = {"event": event, **fields}
    LOGGER.log(level, json.dumps(record, separators=(",", ":"), sort_keys=True))


def _read_json_response(request: urllib.request.Request) -> Any:
    try:
        with HTTP_OPENER.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        # urllib raises HTTPError before entering the response context manager.
        # Close its response body here so every caller, including OAuth token
        # failures that are not retried, has a bounded descriptor lifetime.
        error.close()
        raise
    if len(body) > MAX_RESPONSE_BYTES:
        raise ValueError("Tailscale API response exceeded the size limit")
    return json.loads(body.decode("utf-8"))


def _load_oauth_secret(secret_arn: str, now_monotonic: float) -> dict[str, str]:
    global _secret_cache

    if _secret_cache and now_monotonic - _secret_cache[0] < SECRET_CACHE_SECONDS:
        return _secret_cache[1]

    response = SECRETS_CLIENT.get_secret_value(SecretId=secret_arn)
    secret_text = response.get("SecretString")
    if not isinstance(secret_text, str):
        raise ValueError("OAuth secret must use SecretString")

    parsed = json.loads(secret_text)
    client_id = parsed.get("client_id")
    client_secret = parsed.get("client_secret")
    if not isinstance(client_id, str) or not client_id:
        raise ValueError("OAuth secret is missing client_id")
    if not isinstance(client_secret, str) or not client_secret:
        raise ValueError("OAuth secret is missing client_secret")

    value = {"client_id": client_id, "client_secret": client_secret}
    _secret_cache = (now_monotonic, value)
    return value


def _oauth_access_token(secret_arn: str, now_monotonic: float) -> str:
    global _token_cache

    if _token_cache and now_monotonic < _token_cache[0]:
        return _token_cache[1]

    credentials = _load_oauth_secret(secret_arn, now_monotonic)
    form = urllib.parse.urlencode(
        {
            "client_id": credentials["client_id"],
            "client_secret": credentials["client_secret"],
            "scope": "devices:core:read",
        }
    ).encode("ascii")
    request = urllib.request.Request(
        "https://api.tailscale.com/api/v2/oauth/token",
        data=form,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    response = _read_json_response(request)
    token = response.get("access_token") if isinstance(response, dict) else None
    expires_in = response.get("expires_in") if isinstance(response, dict) else None
    if not isinstance(token, str) or not token:
        raise ValueError("OAuth response did not contain an access token")
    if (
        isinstance(expires_in, bool)
        or not isinstance(expires_in, (int, float))
        or expires_in <= 0
    ):
        raise ValueError("OAuth response did not contain a valid expiry")

    # Never cache a token beyond its advertised lifetime. If Tailscale returns
    # an unusually short lifetime, use the token for this request but refresh
    # it on the next invocation.
    lifetime = max(0, int(expires_in) - TOKEN_REFRESH_MARGIN_SECONDS)
    _token_cache = (now_monotonic + lifetime, token)
    return token


def _fetch_devices(access_token: str) -> list[dict[str, Any]]:
    request = urllib.request.Request(
        "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {access_token}",
        },
        method="GET",
    )
    response = _read_json_response(request)
    devices = response.get("devices") if isinstance(response, dict) else None
    if not isinstance(devices, list):
        raise ValueError("Devices response did not contain a device list")
    if any(not isinstance(device, dict) for device in devices):
        raise ValueError("Devices response contained a malformed entry")
    return devices


def _invalidate_oauth_caches() -> None:
    global _secret_cache, _token_cache
    _secret_cache = None
    _token_cache = None


def _fetch_devices_with_one_auth_refresh(
    secret_arn: str, now_monotonic: float
) -> list[dict[str, Any]]:
    """Retry one rejected OAuth credential with a fresh secret and token."""

    for attempt in range(2):
        try:
            token = _oauth_access_token(secret_arn, now_monotonic)
        except urllib.error.HTTPError as error:
            error.close()
            # OAuth token endpoints may report a rotated/revoked client as
            # either `invalid_client` (400) or an authentication challenge
            # (401), depending on the credential transport. Retry no other
            # token-endpoint failure.
            if error.code not in (400, 401) or attempt != 0:
                raise
            _invalidate_oauth_caches()
            continue

        try:
            return _fetch_devices(token)
        except urllib.error.HTTPError as error:
            # `_read_json_response` already closes real responses. Keep this
            # idempotent close at the orchestration boundary as well so a
            # replacement transport cannot leak an authentication response.
            error.close()
            if error.code != 401 or attempt != 0:
                raise
            # Revoking or rotating a Tailscale trust credential revokes active
            # access tokens too. A warm Lambda must not retain either its token
            # or the old Secrets Manager value after the devices boundary says
            # that credential is no longer authoritative.
            _invalidate_oauth_caches()
    raise RuntimeError("unreachable OAuth refresh state")


def _parse_rfc3339(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def _find_device(
    devices: list[dict[str, Any]], expected_identifier: str
) -> dict[str, Any] | None:
    matches = [
        device
        for device in devices
        if any(
            isinstance(device.get(field), str)
            and device.get(field) == expected_identifier
            for field in ("id", "nodeId")
        )
    ]
    # Device identifiers are an authority boundary. Ambiguous API results must
    # fail closed rather than letting list order choose which node is trusted.
    return matches[0] if len(matches) == 1 else None


def _devices_are_same(
    first: dict[str, Any], second: dict[str, Any]
) -> bool:
    if first is second:
        return True
    first_identifiers = {
        value
        for field in ("id", "nodeId")
        if isinstance((value := first.get(field)), str) and value
    }
    second_identifiers = {
        value
        for field in ("id", "nodeId")
        if isinstance((value := second.get(field)), str) and value
    }
    return bool(first_identifiers & second_identifiers)


def _approval_state(device: dict[str, Any]) -> bool:
    # `authorized` is part of the Tailscale devices API contract. Missing,
    # malformed, or differently named fields must fail closed.
    return device.get("authorized") is True


def evaluate_device(
    devices: list[dict[str, Any]],
    expected_identifier: str,
    now: datetime,
    offline_after_seconds: int,
    key_warning_days: int,
) -> dict[str, Any]:
    device = _find_device(devices, expected_identifier)
    if device is None:
        return {
            "found": False,
            "healthy": False,
            "approved": False,
            "key_valid": False,
            "key_expiring": True,
            "connected_to_control": False,
            "seconds_since_last_seen": offline_after_seconds + 1,
        }

    approved = _approval_state(device)
    # A shared-in or ephemeral node is not the durable infrastructure member
    # identified by this monitor. `multipleConnections` is omitted when false,
    # but true means more than one machine is concurrently using the node key,
    # usually because its state was copied. Such an identity could otherwise
    # keep the control-plane heartbeat green while the intended host is down.
    tailnet_member = device.get("isExternal") is False
    durable_identity = device.get("isEphemeral") is False
    multiple_connections = device.get("multipleConnections")
    identity_unique = (
        "multipleConnections" not in device or multiple_connections is False
    )
    expiry_disabled = device.get("keyExpiryDisabled") is True
    expiry = _parse_rfc3339(device.get("expires"))
    explicitly_expired = device.get("expired") is True

    if explicitly_expired:
        key_valid = False
        key_expiring = True
    elif expiry_disabled:
        key_valid = True
        key_expiring = False
    elif expiry is None:
        key_valid = False
        key_expiring = True
    else:
        seconds_until_expiry = int((expiry - now).total_seconds())
        key_valid = not explicitly_expired and seconds_until_expiry > 0
        key_expiring = seconds_until_expiry <= key_warning_days * 86400

    connected_to_control = device.get("connectedToControl") is True
    last_seen = _parse_rfc3339(device.get("lastSeen"))
    if connected_to_control:
        seconds_since_last_seen = 0
        recently_seen = True
    elif last_seen is not None:
        raw_age = int((now - last_seen).total_seconds())
        if raw_age < -60:
            # A materially future timestamp is malformed and must not keep a
            # disconnected device healthy indefinitely.
            seconds_since_last_seen = offline_after_seconds + 1
            recently_seen = False
        else:
            seconds_since_last_seen = max(0, raw_age)
            recently_seen = seconds_since_last_seen <= offline_after_seconds
    else:
        seconds_since_last_seen = offline_after_seconds + 1
        recently_seen = False

    return {
        "found": True,
        "healthy": (
            approved
            and tailnet_member
            and durable_identity
            and identity_unique
            and key_valid
            and recently_seen
        ),
        "approved": approved,
        "tailnet_member": tailnet_member,
        "durable_identity": durable_identity,
        "identity_unique": identity_unique,
        "key_valid": key_valid,
        "key_expiring": key_expiring,
        "connected_to_control": connected_to_control,
        "seconds_since_last_seen": seconds_since_last_seen,
    }


def _metric(
    name: str,
    value: float,
    device: str | None = None,
    unit: str = "Count",
) -> dict[str, Any]:
    datum: dict[str, Any] = {
        "MetricName": name,
        "Value": value,
        "Unit": unit,
    }
    if device is not None:
        datum["Dimensions"] = [{"Name": "Device", "Value": device}]
    return datum


def _publish_observations(
    namespace: str, evaluations: dict[str, dict[str, Any]]
) -> None:
    metrics = [_metric("ObservationSucceeded", 1)]
    for label, evaluation in evaluations.items():
        metrics.extend(
            [
                _metric(
                    "ControlPlaneHealthy",
                    1 if evaluation["healthy"] else 0,
                    label,
                ),
                _metric("KeyValid", 1 if evaluation["key_valid"] else 0, label),
                _metric(
                    "KeyExpiryWithinWarningWindow",
                    1 if evaluation["key_expiring"] else 0,
                    label,
                ),
                _metric("Approved", 1 if evaluation["approved"] else 0, label),
                _metric(
                    "SecondsSinceLastSeen",
                    float(evaluation["seconds_since_last_seen"]),
                    label,
                    "Seconds",
                ),
            ]
        )
    CLOUDWATCH_CLIENT.put_metric_data(Namespace=namespace, MetricData=metrics)


def _publish_monitor_failure(namespace: str) -> None:
    CLOUDWATCH_CLIENT.put_metric_data(
        Namespace=namespace,
        MetricData=[_metric("ObservationSucceeded", 0)],
    )


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"Required environment variable is missing: {name}")
    return value


def lambda_handler(event: Any, context: Any) -> dict[str, Any]:
    del event, context
    namespace = os.environ.get("METRIC_NAMESPACE", DEFAULT_NAMESPACE).strip()
    if namespace != DEFAULT_NAMESPACE:
        raise ValueError("Unexpected metric namespace")

    try:
        secret_arn = _required_environment("OAUTH_SECRET_ARN")
        router_id = _required_environment("ROUTER_DEVICE_ID")
        vps_id = _required_environment("VPS_DEVICE_ID")
        if router_id == vps_id:
            raise ValueError("Router and VPS device identifiers must differ")
        offline_after = int(os.environ.get("OFFLINE_AFTER_SECONDS", "180"))
        key_warning_days = int(os.environ.get("KEY_WARNING_DAYS", "7"))
        if not 60 <= offline_after <= 3600:
            raise ValueError("OFFLINE_AFTER_SECONDS is outside the safe range")
        if not 1 <= key_warning_days <= 30:
            raise ValueError("KEY_WARNING_DAYS is outside the safe range")

        now_monotonic = time.monotonic()
        devices = _fetch_devices_with_one_auth_refresh(
            secret_arn, now_monotonic
        )
        router_device = _find_device(devices, router_id)
        vps_device = _find_device(devices, vps_id)
        if (
            router_device is not None
            and vps_device is not None
            and _devices_are_same(router_device, vps_device)
        ):
            raise ValueError(
                "Router and VPS identifiers resolve to the same Tailscale node"
            )
        now = datetime.now(timezone.utc)
        evaluations = {
            "router": evaluate_device(
                devices, router_id, now, offline_after, key_warning_days
            ),
            "vps": evaluate_device(
                devices, vps_id, now, offline_after, key_warning_days
            ),
        }
        _publish_observations(namespace, evaluations)
        _safe_log(
            logging.INFO,
            "tailscale_observation",
            router_healthy=evaluations["router"]["healthy"],
            router_key_valid=evaluations["router"]["key_valid"],
            vps_healthy=evaluations["vps"]["healthy"],
            vps_key_valid=evaluations["vps"]["key_valid"],
        )
        return {"ok": True, "evaluations": evaluations}
    except Exception as error:
        try:
            _publish_monitor_failure(namespace)
        except Exception:
            _safe_log(logging.ERROR, "failure_metric_publish_failed")
        _safe_log(
            logging.ERROR,
            "tailscale_observation_failed",
            error_type=type(error).__name__,
        )
        raise
