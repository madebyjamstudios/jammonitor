# Independent AWS Tailscale Monitor

The router watchdog can repair a local daemon crash, but it cannot page anyone
when the router, WAN, LuCI, or entire tailnet path is unreachable. This
serverless monitor is deliberately outside those failure domains.

Every minute, EventBridge Scheduler invokes a Lambda function that uses a
read-only Tailscale OAuth client to inspect the exact BPI-R4 and VPS device
identifiers. It publishes CloudWatch metrics for:

- control-plane health and last-seen age
- node approval
- node-key validity
- key expiry entering a configurable warning window
- monitor execution success

The stack adds M-of-N alarms, a composite alarm, an SNS topic encrypted with a
rotating customer-managed KMS key, Lambda error/throttle/duration alarms, and a
retained encrypted dead-letter queue. The KMS key and SNS topic policies grant
only same-account CloudWatch alarms the cross-service permissions needed to
publish notifications. Missing heartbeat metrics are treated as breaching. The
function has no Tailscale write scope and contains no reauthentication or
node-mutation code.

This is independent control-plane monitoring, not a data-plane proof. Keep the
router watchdog's critical-peer ping for delivered peer reachability.

## Prerequisites

1. In Tailscale, create an OAuth client with only `devices:core:read`.
2. Store the credential in AWS Secrets Manager as:

   ```json
   {"client_id":"...","client_secret":"..."}
   ```

   Use a secret in the deployment account and Region. The template's execution
   role supports the default `aws/secretsmanager` encryption key. If the secret
   uses a customer-managed KMS key, add a narrowly scoped `kms:Decrypt` grant
   for that key before deployment.

3. Obtain the exact non-empty string `id` or `nodeId` for the existing BPI-R4
   and VPS devices. The monitor fails closed when required authorization,
   key-expiry, or recency signals are missing or malformed.
4. Choose the required notification email. The stack cannot deploy with an
   unaddressed alarm topic.

Do not place the OAuth secret in this repository, a CloudFormation parameter,
Lambda environment variables, or shell history.

## Validate

```bash
python3 -m unittest discover -s monitoring/aws/tests -p 'test_*.py'
cfn-lint --format json --template monitoring/aws/template.yaml --regions us-east-1
sam validate --lint --template-file monitoring/aws/template.yaml
```

The template expects `us-east-1` for Mario's current Lightsail environment, but
contains no hardcoded account, Region, device identifier, or secret. The
customer-managed KMS key incurs standard AWS KMS charges and is retained if the
stack is deleted to avoid destructive key removal during stack teardown.

## Deploy through a reviewed change set

```bash
sam build --template-file monitoring/aws/template.yaml
sam deploy \
  --guided \
  --region us-east-1 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    OAuthSecretArn='<SECRET_ARN>' \
    RouterDeviceId='<EXACT_ROUTER_DEVICE_ID>' \
    VpsDeviceId='<EXACT_VPS_DEVICE_ID>' \
    NotificationEmail='<EMAIL>'
```

Review the CloudFormation change set before execution. The deployment is not
accepted until the recipient confirms the SNS subscription and receives a test
notification. Then invoke the function once, confirm both device metrics, and
inspect the dead-letter queue and composite alarm.

Do not deploy while both nodes are intentionally expired unless an immediate
alarm is expected. Repair the existing node identities first, disable key
expiry for these trusted infrastructure nodes or re-provision them with
narrowly granted tags, and retain alternate LAN/public management access.
