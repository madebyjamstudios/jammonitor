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
retained encrypted dead-letter queue. The SNS topic policy accepts only
same-account CloudWatch alarms. The KMS key separately authorizes that alarm
publisher and the exact stack-named SNS topic, including its encryption
context. Missing heartbeat metrics are treated as breaching. The function has
no Tailscale write scope and contains no reauthentication or node-mutation
code.

The Scheduler execution role is scoped to this account and the exact ARN of
its `default` schedule group. A dedicated group would narrow the same-account
trust boundary further, but it is intentionally deferred. EventBridge
Scheduler does not support moving an existing schedule between groups, and
open CloudFormation provider issues report false drift and `NotFound` failures
for schedules in non-default groups:

- [AWS CDK issue 34216](https://github.com/aws/aws-cdk/issues/34216)
- [CloudFormation coverage issue 1725](https://github.com/aws-cloudformation/cloudformation-coverage-roadmap/issues/1725)
- [CloudFormation coverage issue 1726](https://github.com/aws-cloudformation/cloudformation-coverage-roadmap/issues/1726)

Until a dedicated group is proven through a controlled disposable-stack test,
restrict `iam:PassRole` for the Scheduler execution role to the scoped
deployment identity. Template lint alone is not proof that the provider can
create, read, update, and detect drift for the grouped schedule.

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
contains no hardcoded account, Region, device identifier, or secret. This stack
is not guaranteed to be free. Standard charges can apply for the retained
customer-managed KMS key, one Secrets Manager secret, CloudWatch custom
metrics and alarms (including the composite alarm), Logs, X-Ray, Lambda,
Scheduler, SQS, and SNS after any account-level free usage or credits. Review
the current AWS pricing and the account's existing usage before executing the
change set. The KMS key, log group, and dead-letter queue are retained if the
stack is deleted so teardown cannot silently destroy audit or recovery
evidence; retained resources continue to incur their normal charges until an
operator separately reviews and removes them.

## Create and review a non-executed change set

```bash
set -eu
sam build --template-file monitoring/aws/template.yaml
sam deploy \
  --stack-name jammonitor-tailscale-monitor \
  --region us-east-1 \
  --capabilities CAPABILITY_IAM \
  --resolve-s3 \
  --parameter-overrides \
    OAuthSecretArn='<SECRET_ARN>' \
    RouterDeviceId='<EXACT_ROUTER_DEVICE_ID>' \
    VpsDeviceId='<EXACT_VPS_DEVICE_ID>' \
    NotificationEmail='<EMAIL>' \
  --no-execute-changeset

# Copy the exact ARN printed by SAM. Do not guess the generated name.
CHANGE_SET_ARN='<EXACT_CHANGE_SET_ARN>'
aws cloudformation describe-change-set \
  --change-set-name "$CHANGE_SET_ARN" \
  --region us-east-1 \
  --no-cli-pager
aws cloudformation describe-events \
  --change-set-name "$CHANGE_SET_ARN" \
  --region us-east-1 \
  --output json \
  --no-cli-pager
aws cloudformation get-template \
  --change-set-name "$CHANGE_SET_ARN" \
  --template-stage Processed \
  --region us-east-1 \
  --no-cli-pager
```

Wait until `describe-change-set` reports `CREATE_COMPLETE` or `FAILED`.
Review every add, modify, replacement, deletion, IAM capability, parameter,
processed-template change, and every `describe-events` validation result.
Resolve every `FAIL` and explicitly accept every warning. Creating and
reviewing this change set does not authorize execution.

Only after that review and a separate human authorization may the exact
reviewed ARN be executed:

```bash
aws cloudformation execute-change-set \
  --change-set-name "$CHANGE_SET_ARN" \
  --region us-east-1
```

The deployment is not accepted until the stack reaches its complete state,
the recipient confirms the SNS subscription and receives a test notification,
the function is invoked once, both device metrics are present, and the
dead-letter queue and composite alarm have been inspected.

## Retirement and cleanup

Stack deletion, credential revocation, retained-evidence deletion, and SAM
artifact cleanup are separate authorized actions. Before deleting the stack,
record the exact physical identifiers of the retained resources and the ARN of
the externally managed secret:

```bash
STACK_NAME='jammonitor-tailscale-monitor'
aws cloudformation list-stack-resources \
  --stack-name "$STACK_NAME" \
  --region us-east-1 \
  --query "StackResourceSummaries[?LogicalResourceId=='AlertTopicKey' || LogicalResourceId=='MonitorLogGroup' || LogicalResourceId=='FailureQueue'].[LogicalResourceId,PhysicalResourceId,ResourceStatus]" \
  --output table \
  --no-cli-pager
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region us-east-1 \
  --query "Stacks[0].Parameters[?ParameterKey=='OAuthSecretArn'].ParameterValue" \
  --output text \
  --no-cli-pager
```

Deleting the stack removes the schedule, function, roles, alarms, topic, and
email subscription, but intentionally retains the KMS key, log group, and
dead-letter queue. It does not revoke the Tailscale OAuth client or delete the
Secrets Manager secret because neither credential is owned by this stack.
After the monitor is retired, separately revoke only the exact monitor OAuth
client, then review whether the now-unused secret can be deleted. Do not
delete or reauthenticate either monitored Tailscale device.

Retained evidence must remain until its incident, audit, and recovery
requirements are satisfied. Later deletion of the exact reviewed log group or
queue is irreversible. KMS key deletion uses a waiting period and must be
scheduled as its own reviewed action. Verify the recorded physical identifiers
again immediately before any cleanup.

`--resolve-s3` can create or reuse an AWS SAM managed bucket and uploads
artifacts before the application change set is executed. That bucket and its
objects are outside this stack, so rejecting or deleting the application stack
does not remove them. Record the exact bucket and object keys reported by SAM.
After no retained change set or deployment depends on them, remove only those
reviewed objects. Do not delete an auto-managed bucket wholesale because other
SAM applications can share it. Delete a rejected change set by its exact ARN;
if a first-create stack remains in `REVIEW_IN_PROGRESS`, inspect it before a
separately authorized stack deletion.

Do not deploy while both nodes are intentionally expired unless an immediate
alarm is expected. Repair the existing node identities first, disable key
expiry for these trusted infrastructure nodes or re-provision them with
narrowly granted tags, and retain alternate LAN/public management access.
