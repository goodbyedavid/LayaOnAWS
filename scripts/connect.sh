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

echo "Forwarding localhost:8000 to $instance_id:8000. Keep this terminal open."
aws ssm start-session \
  --target "$instance_id" \
  --region "$region" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8000"],"localPortNumber":["8000"]}'
