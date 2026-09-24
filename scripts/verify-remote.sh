#!/usr/bin/env bash
set -euo pipefail

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
stack_name="${STACK_NAME:-LayaVerificationStack}"

cluster_name="$(
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue | [0]" \
    --output text
)"
secret_arn="$(
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='ApiKeySecretArn'].OutputValue | [0]" \
    --output text
)"
container_instance_arn="$(
  aws ecs list-container-instances \
    --cluster "$cluster_name" \
    --region "$region" \
    --query 'containerInstanceArns[0]' \
    --output text
)"

if [[ -z "$container_instance_arn" || "$container_instance_arn" == "None" ]]; then
  echo "No ECS container instance is registered yet." >&2
  exit 1
fi

instance_id="$(
  aws ecs describe-container-instances \
    --cluster "$cluster_name" \
    --container-instances "$container_instance_arn" \
    --region "$region" \
    --query 'containerInstances[0].ec2InstanceId' \
    --output text
)"
request_b64="$(base64 < examples/support-ticket.json | tr -d '\n')"

parameters="$(
  python3 - "$region" "$secret_arn" "$request_b64" <<'PY'
import base64
import json
import shlex
import sys

region, secret_arn, request_b64 = sys.argv[1:]
benchmark_script = r'''
import json
import math
import os
import time
import urllib.request

with open("/tmp/laya-request.json", "rb") as request_file:
    payload = request_file.read()

api_key = os.environ["LAYA_BENCHMARK_API_KEY"]
durations_ms = []
response_body = None

for iteration in range(21):
    request = urllib.request.Request(
        "http://127.0.0.1:8000/v1/systemone",
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=120) as response:
        response_body = response.read()
    elapsed_ms = (time.perf_counter() - started) * 1000
    if iteration:
        durations_ms.append(elapsed_ms)

ordered = sorted(durations_ms)
snapshot_revisions = []
for root, directories, _ in os.walk("/opt/laya-cache"):
    if os.path.basename(root) == "snapshots":
        snapshot_revisions.extend(sorted(directories))
        directories[:] = []

result = {
    "samples": len(durations_ms),
    "latency_ms": {
        "min": round(ordered[0], 2),
        "p50": round(ordered[len(ordered) // 2], 2),
        "p95": round(ordered[math.ceil(len(ordered) * 0.95) - 1], 2),
        "max": round(ordered[-1], 2),
    },
    "snapshot_revisions": sorted(set(snapshot_revisions)),
    "response": json.loads(response_body),
}
print(json.dumps(result, indent=2))
'''
benchmark_b64 = base64.b64encode(benchmark_script.encode()).decode()
commands = [
    "set -euo pipefail",
    "nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader",
    (
        "api_key=$(aws secretsmanager get-secret-value "
        f"--secret-id {shlex.quote(secret_arn)} "
        f"--region {shlex.quote(region)} --query SecretString --output text)"
    ),
    f"printf %s {shlex.quote(request_b64)} | base64 -d > /tmp/laya-request.json",
    f"printf %s {shlex.quote(benchmark_b64)} | base64 -d > /tmp/laya-benchmark.py",
    "curl --fail-with-body --silent --show-error http://127.0.0.1:8000/health",
    'LAYA_BENCHMARK_API_KEY="${api_key}" python3 /tmp/laya-benchmark.py',
    "nvidia-smi --query-compute-apps=used_memory --format=csv,noheader",
    "rm -f /tmp/laya-request.json /tmp/laya-benchmark.py",
]
print(json.dumps({"commands": commands}))
PY
)"

command_id="$(
  aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "$parameters" \
    --comment "Verify Laya GPU, health, model revisions, inference, and warm latency" \
    --region "$region" \
    --query 'Command.CommandId' \
    --output text
)"

aws ssm wait command-executed \
  --command-id "$command_id" \
  --instance-id "$instance_id" \
  --region "$region"
aws ssm get-command-invocation \
  --command-id "$command_id" \
  --instance-id "$instance_id" \
  --region "$region" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json
