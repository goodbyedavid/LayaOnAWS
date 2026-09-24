#!/usr/bin/env bash
set -euo pipefail

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
stack_name="${STACK_NAME:-LayaVerificationStack}"

secret_arn="$(
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='ApiKeySecretArn'].OutputValue | [0]" \
    --output text
)"
api_key="$(
  aws secretsmanager get-secret-value \
    --secret-id "$secret_arn" \
    --region "$region" \
    --query SecretString \
    --output text
)"

curl --fail-with-body --silent --show-error http://127.0.0.1:8000/health
printf '\n'
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${api_key}" \
  -H "Content-Type: application/json" \
  --data @examples/support-ticket.json \
  http://127.0.0.1:8000/v1/systemone
printf '\n'
