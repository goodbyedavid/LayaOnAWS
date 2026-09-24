#!/usr/bin/env bash
set -euo pipefail

# All settings are environment-overridable so this script works in any account.
#
# Set LAYA_EXPECTED_ACCOUNT to pin deployment to a single AWS account. When it
# is set, the script refuses to deploy anywhere else. When it is unset, the
# script reports the resolved account and continues, which is the behaviour a
# first-time cloner wants.
readonly expected_account="${LAYA_EXPECTED_ACCOUNT:-}"
readonly region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
readonly profile="${AWS_PROFILE:-default}"
readonly stack_name="${STACK_NAME:-LayaVerificationStack}"
readonly results_file="${RESULTS_FILE:-live-verification.txt}"

export AWS_PROFILE="$profile"
export AWS_REGION="$region"

gpu_deployment_attempted=0
gpu_scaled_down=0

log() {
  printf '\n[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$results_file"
}

scale_down() {
  if [[ "$gpu_deployment_attempted" -eq 1 && "$gpu_scaled_down" -eq 0 ]]; then
    log "Returning ECS and Auto Scaling desired capacity to zero"
    if AWS_PROFILE="$profile" AWS_REGION="$region" CDK_DOCKER=finch \
      npx cdk deploy "$stack_name" -c capacity=0 --require-approval never \
      --outputs-file cdk-outputs.json 2>&1 | tee -a "$results_file"; then
      gpu_scaled_down=1
    else
      log "CDK scale-down failed; applying a direct zero-capacity fallback"
      asg_name="$(
        aws cloudformation list-stack-resources \
          --stack-name "$stack_name" \
          --region "$region" \
          --query "StackResourceSummaries[?ResourceType=='AWS::AutoScaling::AutoScalingGroup'].PhysicalResourceId | [0]" \
          --output text 2>/dev/null || true
      )"
      cluster_name="$(
        aws cloudformation describe-stacks \
          --stack-name "$stack_name" \
          --region "$region" \
          --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue | [0]" \
          --output text 2>/dev/null || true
      )"

      if [[ -n "$cluster_name" && "$cluster_name" != "None" ]]; then
        service_arn="$(
          aws ecs list-services \
            --cluster "$cluster_name" \
            --region "$region" \
            --query 'serviceArns[0]' \
            --output text 2>/dev/null || true
        )"
        if [[ -n "$service_arn" && "$service_arn" != "None" ]]; then
          aws ecs update-service \
            --cluster "$cluster_name" \
            --service "$service_arn" \
            --desired-count 0 \
            --region "$region" >/dev/null || true
        fi
      fi

      if [[ -n "$asg_name" && "$asg_name" != "None" ]]; then
        aws autoscaling update-auto-scaling-group \
          --auto-scaling-group-name "$asg_name" \
          --min-size 0 \
          --desired-capacity 0 \
          --region "$region" || true
      fi

      log "Direct zero-capacity fallback completed"
    fi
  fi
}

trap scale_down EXIT
: > "$results_file"

log "Verifying AWS identity"
caller_account="$(
  aws sts get-caller-identity \
    --region "$region" \
    --query Account \
    --output text
)"
caller_arn="$(
  aws sts get-caller-identity \
    --region "$region" \
    --query Arn \
    --output text
)"
printf 'Account: %s\nPrincipal: %s\nRegion: %s\n' \
  "$caller_account" "$caller_arn" "$region" | tee -a "$results_file"

if [[ -n "$expected_account" && "$caller_account" != "$expected_account" ]]; then
  log "Refusing deployment: expected account $expected_account, received $caller_account"
  exit 1
fi

if [[ -z "$expected_account" ]]; then
  log "LAYA_EXPECTED_ACCOUNT is not set, so no account pin is enforced"
  log "Deploying a GPU instance into account $caller_account in $region"
fi

if aws cloudformation describe-stacks \
  --stack-name "$stack_name" \
  --region "$region" >/dev/null 2>&1; then
  stack_status="$(
    aws cloudformation describe-stacks \
      --stack-name "$stack_name" \
      --region "$region" \
      --query 'Stacks[0].StackStatus' \
      --output text
  )"
  log "Existing stack status: $stack_status"

  if [[ "$stack_status" == "ROLLBACK_COMPLETE" ]]; then
    log "Deleting the failed stack before redeployment"
    aws cloudformation delete-stack \
      --stack-name "$stack_name" \
      --region "$region"
    aws cloudformation wait stack-delete-complete \
      --stack-name "$stack_name" \
      --region "$region"
  fi
fi

log "Building the CDK application"
npm run build 2>&1 | tee -a "$results_file"

log "Deploying one g4dn.xlarge GPU instance"
gpu_deployment_attempted=1
AWS_PROFILE="$profile" AWS_REGION="$region" CDK_DOCKER=finch \
  npx cdk deploy "$stack_name" -c capacity=1 --require-approval never \
  --outputs-file cdk-outputs.json 2>&1 | tee -a "$results_file"

log "Running GPU, health, model revision, inference, and latency checks"
AWS_PROFILE="$profile" AWS_REGION="$region" \
  scripts/verify-remote.sh 2>&1 | tee -a "$results_file"

log "Scaling the deployed stack to zero GPU capacity"
AWS_PROFILE="$profile" AWS_REGION="$region" CDK_DOCKER=finch \
  npx cdk deploy "$stack_name" -c capacity=0 --require-approval never \
  --outputs-file cdk-outputs.json 2>&1 | tee -a "$results_file"
gpu_scaled_down=1

cluster_name="$(
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue | [0]" \
    --output text
)"
service_arn="$(
  aws ecs list-services \
    --cluster "$cluster_name" \
    --region "$region" \
    --query 'serviceArns[0]' \
    --output text
)"

log "Confirming zero desired and running ECS tasks"
aws ecs describe-services \
  --cluster "$cluster_name" \
  --services "$service_arn" \
  --region "$region" \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}' \
  --output json | tee -a "$results_file"

log "Confirming no active GPU instance remains"
aws ec2 describe-instances \
  --region "$region" \
  --filters \
    Name=tag:aws:cloudformation:stack-name,Values="$stack_name" \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType}' \
  --output json | tee -a "$results_file"

log "Verification workflow completed"
