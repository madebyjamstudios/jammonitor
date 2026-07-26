import importlib.util
import io
import json
import os
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch


class _Config:
    def __init__(self, **kwargs):
        self.kwargs = kwargs


class _Boto3(types.ModuleType):
    def client(self, name, config=None):
        del name, config
        return object()


sys.modules.setdefault("boto3", _Boto3("boto3"))
botocore_module = types.ModuleType("botocore")
botocore_config_module = types.ModuleType("botocore.config")
botocore_config_module.Config = _Config
sys.modules.setdefault("botocore", botocore_module)
sys.modules.setdefault("botocore.config", botocore_config_module)

APP_PATH = Path(__file__).parents[1] / "src" / "app.py"
SPEC = importlib.util.spec_from_file_location("tailscale_monitor_app", APP_PATH)
assert SPEC and SPEC.loader
APP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APP)


class DeviceEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 7, 23, 20, 0, tzinfo=timezone.utc)

    def evaluate(self, device):
        device = {
            "isExternal": False,
            "isEphemeral": False,
            **device,
        }
        return APP.evaluate_device(
            [device],
            "node-router",
            self.now,
            offline_after_seconds=180,
            key_warning_days=7,
        )

    def test_connected_node_with_disabled_expiry_is_healthy(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "keyExpiryDisabled": True,
                "authorized": True,
            }
        )
        self.assertTrue(result["healthy"])
        self.assertTrue(result["key_valid"])
        self.assertFalse(result["key_expiring"])
        self.assertEqual(result["seconds_since_last_seen"], 0)

    def test_expired_node_is_unhealthy_even_if_control_flag_is_true(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "expires": (self.now - timedelta(seconds=1)).isoformat(),
                "authorized": True,
            }
        )
        self.assertFalse(result["healthy"])
        self.assertFalse(result["key_valid"])
        self.assertTrue(result["key_expiring"])

    def test_key_inside_warning_window_is_visible_before_expiry(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "expires": (self.now + timedelta(days=2)).isoformat(),
                "authorized": True,
            }
        )
        self.assertTrue(result["healthy"])
        self.assertTrue(result["key_valid"])
        self.assertTrue(result["key_expiring"])

    def test_recent_last_seen_absorbs_short_control_plane_flap(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": False,
                "lastSeen": (self.now - timedelta(seconds=120)).isoformat(),
                "expires": (self.now + timedelta(days=30)).isoformat(),
                "authorized": True,
            }
        )
        self.assertTrue(result["healthy"])
        self.assertEqual(result["seconds_since_last_seen"], 120)

    def test_stale_last_seen_is_unhealthy(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": False,
                "lastSeen": (self.now - timedelta(seconds=181)).isoformat(),
                "expires": (self.now + timedelta(days=30)).isoformat(),
                "authorized": True,
            }
        )
        self.assertFalse(result["healthy"])
        self.assertEqual(result["seconds_since_last_seen"], 181)

    def test_unapproved_node_is_unhealthy(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "keyExpiryDisabled": True,
                "authorized": False,
            }
        )
        self.assertFalse(result["healthy"])
        self.assertFalse(result["approved"])

    def test_shared_in_or_ephemeral_nodes_fail_closed(self):
        for field in ("isExternal", "isEphemeral"):
            with self.subTest(field=field):
                result = self.evaluate(
                    {
                        "nodeId": "node-router",
                        "connectedToControl": True,
                        "keyExpiryDisabled": True,
                        "authorized": True,
                        field: True,
                    }
                )
                self.assertFalse(result["healthy"])

    def test_missing_membership_or_durability_fields_fail_closed(self):
        base = {
            "nodeId": "node-router",
            "connectedToControl": True,
            "keyExpiryDisabled": True,
            "authorized": True,
        }
        for missing in ("isExternal", "isEphemeral"):
            with self.subTest(missing=missing):
                device = {
                    **base,
                    "isExternal": False,
                    "isEphemeral": False,
                }
                del device[missing]
                result = APP.evaluate_device(
                    [device],
                    "node-router",
                    self.now,
                    offline_after_seconds=180,
                    key_warning_days=7,
                )
                self.assertFalse(result["healthy"])

    def test_concurrently_copied_node_state_fails_closed(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "keyExpiryDisabled": True,
                "authorized": True,
                "multipleConnections": True,
            }
        )
        self.assertFalse(result["healthy"])
        self.assertFalse(result["identity_unique"])

    def test_omitted_multiple_connections_means_one_or_zero_live_users(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "keyExpiryDisabled": True,
                "authorized": True,
            }
        )
        self.assertTrue(result["healthy"])
        self.assertTrue(result["identity_unique"])

    def test_malformed_multiple_connections_fails_closed(self):
        for malformed in (None, "false", 0):
            with self.subTest(malformed=malformed):
                result = self.evaluate(
                    {
                        "nodeId": "node-router",
                        "connectedToControl": True,
                        "keyExpiryDisabled": True,
                        "authorized": True,
                        "multipleConnections": malformed,
                    }
                )
                self.assertFalse(result["healthy"])
                self.assertFalse(result["identity_unique"])

    def test_missing_authorized_field_fails_closed(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "keyExpiryDisabled": True,
                "approved": True,
            }
        )
        self.assertFalse(result["healthy"])
        self.assertFalse(result["approved"])

    def test_explicit_expired_state_overrides_disabled_expiry(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "keyExpiryDisabled": True,
                "expired": True,
                "authorized": True,
            }
        )
        self.assertFalse(result["healthy"])
        self.assertFalse(result["key_valid"])
        self.assertTrue(result["key_expiring"])

    def test_missing_or_unknown_expiry_fails_closed(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": True,
                "authorized": True,
            }
        )
        self.assertFalse(result["healthy"])
        self.assertFalse(result["key_valid"])

    def test_device_identifier_match_is_exact(self):
        result = APP.evaluate_device(
            [
                {
                    "nodeId": "node-router-suffix",
                    "connectedToControl": True,
                    "keyExpiryDisabled": True,
                }
            ],
            "node-router",
            self.now,
            offline_after_seconds=180,
            key_warning_days=7,
        )
        self.assertFalse(result["found"])
        self.assertFalse(result["healthy"])

    def test_null_device_identifiers_do_not_match_string_none(self):
        result = APP.evaluate_device(
            [
                {
                    "id": None,
                    "nodeId": None,
                    "connectedToControl": True,
                    "keyExpiryDisabled": True,
                    "authorized": True,
                }
            ],
            "None",
            self.now,
            offline_after_seconds=180,
            key_warning_days=7,
        )
        self.assertFalse(result["found"])

    def test_duplicate_exact_device_identifiers_fail_closed(self):
        result = APP.evaluate_device(
            [
                {
                    "nodeId": "node-router",
                    "connectedToControl": True,
                    "keyExpiryDisabled": True,
                    "authorized": True,
                },
                {
                    "id": "node-router",
                    "connectedToControl": True,
                    "keyExpiryDisabled": True,
                    "authorized": True,
                },
            ],
            "node-router",
            self.now,
            offline_after_seconds=180,
            key_warning_days=7,
        )
        self.assertFalse(result["found"])
        self.assertFalse(result["healthy"])

    def test_materially_future_last_seen_fails_closed(self):
        result = self.evaluate(
            {
                "nodeId": "node-router",
                "connectedToControl": False,
                "lastSeen": (self.now + timedelta(minutes=5)).isoformat(),
                "expires": (self.now + timedelta(days=30)).isoformat(),
                "authorized": True,
            }
        )
        self.assertFalse(result["healthy"])
        self.assertGreater(result["seconds_since_last_seen"], 180)

    def test_rfc3339_requires_timezone(self):
        self.assertIsNone(APP._parse_rfc3339("2026-07-23T20:00:00"))
        parsed = APP._parse_rfc3339("2026-07-23T20:00:00Z")
        self.assertEqual(parsed, self.now)


class OAuthAndHandlerTests(unittest.TestCase):
    def setUp(self):
        APP._secret_cache = None
        APP._token_cache = None

    def test_short_lived_oauth_token_is_not_cached_past_expiry(self):
        with (
            patch.object(
                APP,
                "_load_oauth_secret",
                return_value={"client_id": "client", "client_secret": "secret"},
            ),
            patch.object(
                APP,
                "_read_json_response",
                side_effect=[
                    {"access_token": "token-1", "expires_in": 10},
                    {"access_token": "token-2", "expires_in": 10},
                ],
            ) as read_response,
        ):
            first = APP._oauth_access_token("arn:secret", 100.0)
            second = APP._oauth_access_token("arn:secret", 101.0)

        self.assertEqual(first, "token-1")
        self.assertEqual(second, "token-2")
        self.assertEqual(read_response.call_count, 2)

    def test_boolean_oauth_expiry_is_rejected(self):
        with (
            patch.object(
                APP,
                "_load_oauth_secret",
                return_value={"client_id": "client", "client_secret": "secret"},
            ),
            patch.object(
                APP,
                "_read_json_response",
                return_value={"access_token": "token", "expires_in": True},
            ),
        ):
            with self.assertRaisesRegex(ValueError, "valid expiry"):
                APP._oauth_access_token("arn:secret", 100.0)

    def test_oauth_request_is_downscoped_to_read_only_devices(self):
        captured = {}

        def response_for(request):
            captured["data"] = request.data.decode("ascii")
            captured["url"] = request.full_url
            return {"access_token": "token", "expires_in": 3600}

        with (
            patch.object(
                APP,
                "_load_oauth_secret",
                return_value={"client_id": "client", "client_secret": "secret"},
            ),
            patch.object(APP, "_read_json_response", side_effect=response_for),
        ):
            token = APP._oauth_access_token("arn:secret", 100.0)

        self.assertEqual(token, "token")
        self.assertEqual(
            captured["url"], "https://api.tailscale.com/api/v2/oauth/token"
        )
        self.assertIn("scope=devices%3Acore%3Aread", captured["data"])

    def test_http_redirects_are_refused_before_credentials_can_be_forwarded(self):
        handler = APP._NoRedirectHandler()
        self.assertTrue(
            any(
                isinstance(candidate, APP._NoRedirectHandler)
                for candidate in APP.HTTP_OPENER.handlers
            )
        )
        request = APP.urllib.request.Request(
            "https://api.tailscale.com/api/v2/tailnet/-/devices",
            headers={"Authorization": "Bearer secret"},
        )

        redirected = handler.redirect_request(
            request,
            None,
            302,
            "Found",
            {},
            "https://attacker.invalid/capture",
        )

        self.assertIsNone(redirected)

    def test_http_error_body_is_closed_before_propagation(self):
        body = io.BytesIO(b'{"error":"sentinel"}')
        error = APP.urllib.error.HTTPError(
            "https://api.tailscale.com/api/v2/oauth/token",
            503,
            "Unavailable",
            {},
            body,
        )
        request = APP.urllib.request.Request(
            "https://api.tailscale.com/api/v2/oauth/token"
        )

        with patch.object(APP.HTTP_OPENER, "open", side_effect=error):
            with self.assertRaises(APP.urllib.error.HTTPError):
                APP._read_json_response(request)

        self.assertTrue(body.closed)

    def test_device_inventory_requests_all_identity_fields(self):
        captured = {}

        def response_for(request):
            captured["url"] = request.full_url
            return {"devices": []}

        with patch.object(APP, "_read_json_response", side_effect=response_for):
            self.assertEqual(APP._fetch_devices("token"), [])

        self.assertEqual(
            captured["url"],
            "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all",
        )

    def test_malformed_device_entries_reject_the_entire_observation(self):
        with patch.object(
            APP,
            "_read_json_response",
            return_value={"devices": [{"nodeId": "valid"}, None]},
        ):
            with self.assertRaisesRegex(ValueError, "malformed entry"):
                APP._fetch_devices("token")

    def test_one_unauthorized_response_reloads_secret_and_token_once(self):
        unauthorized = APP.urllib.error.HTTPError(
            "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all",
            401,
            "Unauthorized",
            {},
            io.BytesIO(),
        )
        APP._secret_cache = (1.0, {"client_id": "old", "client_secret": "old"})
        APP._token_cache = (9999.0, "revoked")
        with (
            patch.object(
                APP,
                "_oauth_access_token",
                side_effect=["revoked", "fresh"],
            ) as access_token,
            patch.object(
                APP,
                "_fetch_devices",
                side_effect=[unauthorized, [{"nodeId": "node-router"}]],
            ) as fetch_devices,
        ):
            devices = APP._fetch_devices_with_one_auth_refresh(
                "arn:secret", 100.0
            )

        self.assertEqual(devices, [{"nodeId": "node-router"}])
        self.assertEqual(access_token.call_count, 2)
        self.assertEqual(fetch_devices.call_args_list[0].args, ("revoked",))
        self.assertEqual(fetch_devices.call_args_list[1].args, ("fresh",))
        self.assertIsNone(APP._secret_cache)
        self.assertIsNone(APP._token_cache)

    def test_oauth_unauthorized_reloads_rotated_secret_once(self):
        token_requests = []
        secret_reads = []
        APP._secret_cache = (
            99.0,
            {"client_id": "old-client", "client_secret": "old-secret"},
        )

        def get_secret_value(**kwargs):
            secret_reads.append(kwargs)
            return {
                "SecretString": json.dumps(
                    {
                        "client_id": "new-client",
                        "client_secret": "new-secret",
                    }
                )
            }

        def response_for(request):
            if request.full_url.endswith("/oauth/token"):
                form = request.data.decode("ascii")
                token_requests.append(form)
                if "old-secret" in form:
                    raise APP.urllib.error.HTTPError(
                        request.full_url,
                        401,
                        "Unauthorized",
                        {},
                        io.BytesIO(),
                    )
                return {"access_token": "fresh-token", "expires_in": 3600}
            self.assertEqual(
                request.get_header("Authorization"), "Bearer fresh-token"
            )
            return {"devices": [{"nodeId": "node-router"}]}

        fake_secrets = types.SimpleNamespace(
            get_secret_value=get_secret_value
        )
        with (
            patch.object(APP, "SECRETS_CLIENT", fake_secrets),
            patch.object(APP, "_read_json_response", side_effect=response_for),
        ):
            devices = APP._fetch_devices_with_one_auth_refresh(
                "arn:secret", 100.0
            )

        self.assertEqual(devices, [{"nodeId": "node-router"}])
        self.assertEqual(len(token_requests), 2)
        self.assertIn("client_secret=old-secret", token_requests[0])
        self.assertIn("client_secret=new-secret", token_requests[1])
        self.assertEqual(secret_reads, [{"SecretId": "arn:secret"}])
        self.assertEqual(APP._secret_cache[1]["client_secret"], "new-secret")
        self.assertEqual(APP._token_cache[1], "fresh-token")

    def test_oauth_invalid_client_400_gets_the_same_single_refresh(self):
        invalid_client = APP.urllib.error.HTTPError(
            "https://api.tailscale.com/api/v2/oauth/token",
            400,
            "Invalid client",
            {},
            io.BytesIO(),
        )
        with (
            patch.object(
                APP,
                "_oauth_access_token",
                side_effect=[invalid_client, "fresh"],
            ) as access_token,
            patch.object(
                APP,
                "_fetch_devices",
                return_value=[{"nodeId": "node-router"}],
            ) as fetch_devices,
        ):
            devices = APP._fetch_devices_with_one_auth_refresh(
                "arn:secret", 100.0
            )

        self.assertEqual(devices, [{"nodeId": "node-router"}])
        self.assertEqual(access_token.call_count, 2)
        fetch_devices.assert_called_once_with("fresh")

    def test_a_second_unauthorized_response_is_not_retried(self):
        first = APP.urllib.error.HTTPError(
            "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all",
            401,
            "Unauthorized",
            {},
            io.BytesIO(),
        )
        second = APP.urllib.error.HTTPError(
            "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all",
            401,
            "Unauthorized",
            {},
            io.BytesIO(),
        )
        with (
            patch.object(
                APP,
                "_oauth_access_token",
                side_effect=["revoked", "still-revoked"],
            ) as access_token,
            patch.object(
                APP,
                "_fetch_devices",
                side_effect=[first, second],
            ) as fetch_devices,
        ):
            with self.assertRaises(APP.urllib.error.HTTPError):
                APP._fetch_devices_with_one_auth_refresh(
                    "arn:secret", 100.0
                )
            second.close()

        self.assertEqual(access_token.call_count, 2)
        self.assertEqual(fetch_devices.call_count, 2)

    def test_duplicate_runtime_device_identifiers_fail_before_api_calls(self):
        environment = {
            "OAUTH_SECRET_ARN": "arn:secret",
            "ROUTER_DEVICE_ID": "same-node",
            "VPS_DEVICE_ID": "same-node",
            "OFFLINE_AFTER_SECONDS": "180",
            "KEY_WARNING_DAYS": "7",
            "METRIC_NAMESPACE": APP.DEFAULT_NAMESPACE,
        }
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(APP, "_oauth_access_token") as oauth_access_token,
            patch.object(APP, "_publish_monitor_failure") as publish_failure,
        ):
            with self.assertRaisesRegex(ValueError, "must differ"):
                APP.lambda_handler({}, None)

        oauth_access_token.assert_not_called()
        publish_failure.assert_called_once_with(APP.DEFAULT_NAMESPACE)

    def test_cross_field_aliases_for_one_node_fail_closed(self):
        environment = {
            "OAUTH_SECRET_ARN": "arn:secret",
            "ROUTER_DEVICE_ID": "device-router",
            "VPS_DEVICE_ID": "node-router",
            "OFFLINE_AFTER_SECONDS": "180",
            "KEY_WARNING_DAYS": "7",
            "METRIC_NAMESPACE": APP.DEFAULT_NAMESPACE,
        }
        devices = [
            {
                "id": "device-router",
                "nodeId": "node-router",
                "connectedToControl": True,
                "keyExpiryDisabled": True,
                "authorized": True,
            }
        ]
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(APP, "_oauth_access_token", return_value="token"),
            patch.object(APP, "_fetch_devices", return_value=devices),
            patch.object(APP, "_publish_observations") as publish_observations,
            patch.object(APP, "_publish_monitor_failure") as publish_failure,
        ):
            with self.assertRaisesRegex(ValueError, "same Tailscale node"):
                APP.lambda_handler({}, None)

        publish_observations.assert_not_called()
        publish_failure.assert_called_once_with(APP.DEFAULT_NAMESPACE)

    def test_metric_projection_uses_only_fixed_low_cardinality_dimensions(self):
        evaluations = {
            "router": {
                "healthy": True,
                "key_valid": True,
                "key_expiring": False,
                "approved": True,
                "seconds_since_last_seen": 0,
            },
            "vps": {
                "healthy": False,
                "key_valid": False,
                "key_expiring": True,
                "approved": False,
                "seconds_since_last_seen": 181,
            },
        }
        fake_cloudwatch = types.SimpleNamespace(put_metric_data=lambda **kwargs: None)
        calls = []
        fake_cloudwatch.put_metric_data = lambda **kwargs: calls.append(kwargs)

        with patch.object(APP, "CLOUDWATCH_CLIENT", fake_cloudwatch):
            APP._publish_observations(APP.DEFAULT_NAMESPACE, evaluations)

        self.assertEqual(len(calls), 1)
        metric_data = calls[0]["MetricData"]
        self.assertEqual(len(metric_data), 11)
        for datum in metric_data:
            dimensions = datum.get("Dimensions", [])
            self.assertLessEqual(len(dimensions), 1)
            if dimensions:
                self.assertEqual(dimensions[0]["Name"], "Device")
                self.assertIn(dimensions[0]["Value"], {"router", "vps"})
            expected_unit = (
                "Seconds"
                if datum["MetricName"] == "SecondsSinceLastSeen"
                else "Count"
            )
            self.assertEqual(datum["Unit"], expected_unit)


if __name__ == "__main__":
    unittest.main()
