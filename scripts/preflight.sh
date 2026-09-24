#!/usr/bin/env bash
set -euo pipefail

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"

aws sts get-caller-identity --output json
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --region "$region" \
  --query 'Quota.{Name:QuotaName,VcpuLimit:Value}' \
  --output table
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=g4dn.xlarge \
  --region "$region" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table
aws ssm get-parameter \
  --name /aws/service/ecs/optimized-ami/amazon-linux-2023/gpu/recommended \
  --region "$region" \
  --query 'Parameter.Value' \
  --output text
