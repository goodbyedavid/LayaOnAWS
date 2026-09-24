#!/usr/bin/env bash
#
# Runs scripts/benchmark.py on the GPU host through AWS Systems Manager.
#
# The benchmark file is shipped to the instance rather than embedded in this
# script, so the Python stays readable and lintable. The generated bearer token
# is never placed in the SSM command parameters, because those are retained in
# command history and CloudTrail. The remote shell fetches the secret itself
# using the instance role.
#
# Usage:
#   scripts/benchmark-remote.sh
#   QUESTION_COUNTS=1,5 SAMPLES=30 scripts/benchmark-remote.sh
set -euo pipefail

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
stack_name="${STACK_NAME:-LayaVerificationStack}"
models="${MODELS:-english,multilingual}"
question_counts="${QUESTION_COUNTS:-1,5,10,50}"
samples="${SAMPLES:-20}"
target_url="${TARGET_URL:-http://127.0.0.1:8000}"

if [[ ! -f scripts/benchmark.py ]]; then
  echo "Run this from the repository root; scripts/benchmark.py not found." >&2
  exit 1
fi

stack_output() {
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" \
    --output text
}

cluster_name="$(stack_output ClusterName)"
secret_arn="$(stack_output ApiKeySecretArn)"

container_instance_arn="$(
  aws ecs list-container-instances \
    --cluster "$cluster_name" \
    --region "$region" \
    --query 'containerInstanceArns[0]' \
    --output text
)"

if [[ -z "$container_instance_arn" || "$container_instance_arn" == "None" ]]; then
  echo "No ECS container instance is registered. Deploy with -c capacity=1 first." >&2
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

benchmark_b64="$(base64 < scripts/benchmark.py | tr -d '\n')"

parameters="$(
  python3 - \
    "$region" "$secret_arn" "$benchmark_b64" \
    "$models" "$question_counts" "$samples" "$target_url" <<'PY'
import json
import shlex
import sys

region, secret_arn, benchmark_b64, models, counts, samples, url = sys.argv[1:]

commands = [
    "set -euo pipefail",
    "nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader",
    (
        "api_key=$(aws secretsmanager get-secret-value "
        f"--secret-id {shlex.quote(secret_arn)} "
        f"--region {shlex.quote(region)} --query SecretString --output text)"
    ),
    f"printf %s {shlex.quote(benchmark_b64)} | base64 -d > /tmp/laya-benchmark.py",
    (
        'LAYA_BENCHMARK_API_KEY="${api_key}" python3 /tmp/laya-benchmark.py'
        f" --url {shlex.quote(url)}"
        f" --models {shlex.quote(models)}"
        f" --question-counts {shlex.quote(counts)}"
        f" --samples {shlex.quote(samples)}"
    ),
    "nvidia-smi --query-compute-apps=used_memory --format=csv,noheader",
    "rm -f /tmp/laya-benchmark.py",
]
print(json.dumps({"commands": commands}))
PY
)"

command_id="$(
  aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "$parameters" \
    --comment "Laya questions-per-call latency sweep" \
    --region "$region" \
    --query 'Command.CommandId' \
    --output text
)"

echo "SSM command $command_id running on $instance_id; the 50-question cells take a while." >&2

aws ssm wait command-executed \
  --command-id "$command_id" \
  --instance-id "$instance_id" \
  --region "$region" || true

aws ssm get-command-invocation \
  --command-id "$command_id" \
  --instance-id "$instance_id" \
  --region "$region" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json
