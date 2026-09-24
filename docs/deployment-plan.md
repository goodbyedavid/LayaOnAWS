# Deployment and operating plan

## Target

| Setting | Value |
| --- | --- |
| AWS account | `111122223333` |
| Region | `us-west-2` |
| Local profile | `default` |
| Stack | `LayaVerificationStack` |
| GPU | `g4dn.xlarge` |
| Container runtime | Amazon ECS on EC2 |
| Container builder | Finch through `CDK_DOCKER=finch` |
| Safe capacity | `0` |
| Test capacity | `1` |

The one-command workflow is:

```bash
scripts/deploy-and-verify.sh
```

It verifies the account identity, removes a previous
`ROLLBACK_COMPLETE` stack, deploys one GPU, runs the live test suite, scales
capacity to zero, and writes `live-verification.txt`.

## Preconditions

1. AWS CLI credentials are available through the local `default` profile.
2. The caller resolves to account `111122223333`.
3. The region is `us-west-2`.
4. Node.js dependencies are installed.
5. Finch is running and can build `linux/amd64` images.
6. The CDK environment is bootstrapped.
7. The account has at least four available On-Demand G-family vCPUs.
8. `g4dn.xlarge` capacity is offered in the selected Availability Zone.

Run the read-only checks separately when needed:

```bash
scripts/preflight.sh
```

## Deployment sequence

1. Run `npm run build`.
2. Synthesize with capacity zero and inspect the template.
3. Confirm the template contains `AWS::EC2::LaunchTemplate` and does not
   contain `AWS::AutoScaling::LaunchConfiguration`.
4. Check the existing stack status.
5. Delete the stack only when its status is `ROLLBACK_COMPLETE`.
6. Deploy with context `capacity=1`.
7. Wait for CloudFormation and ECS service stability.
8. Run `scripts/verify-remote.sh`.
9. Capture the response and measurements.
10. Deploy with context `capacity=0`.
11. Confirm ECS desired, running, and pending counts are zero.
12. Confirm no `g4dn.xlarge` remains in a billable state.

## Manual commands

Build and synthesize:

```bash
npm run build
CDK_DOCKER=finch npx cdk synth -c capacity=0
```

Deploy one GPU:

```bash
AWS_PROFILE=default AWS_REGION=us-west-2 CDK_DOCKER=finch \
  npx cdk deploy LayaVerificationStack \
  -c capacity=1 \
  --require-approval never \
  --outputs-file cdk-outputs.json
```

Run the automated live verification:

```bash
AWS_PROFILE=default AWS_REGION=us-west-2 scripts/verify-remote.sh
```

Return to zero:

```bash
AWS_PROFILE=default AWS_REGION=us-west-2 CDK_DOCKER=finch \
  npx cdk deploy LayaVerificationStack \
  -c capacity=0 \
  --require-approval never \
  --outputs-file cdk-outputs.json
```

## Failure handling

The deployment script installs an exit trap after beginning the GPU
deployment. On normal failure or interruption, it first tries a CDK deployment
with capacity zero. If that fails, it tries to set the ECS service and Auto
Scaling group desired capacities directly to zero.

After any interrupted deployment, verify cost-bearing resources immediately:

```bash
aws ec2 describe-instances \
  --profile default \
  --region us-west-2 \
  --filters \
    Name=tag:aws:cloudformation:stack-name,Values=LayaVerificationStack \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType}'
```

If the script is forcibly killed, the exit trap may not run. Set the ECS
service desired count and Auto Scaling group desired capacity to zero before
continuing diagnosis.

## Expected cold-start phases

1. Auto Scaling launches the ECS-optimized GPU AMI.
2. The ECS agent registers with GPU support enabled.
3. ECS pulls the large Laya CUDA image from ECR.
4. Laya downloads English and multilingual checkpoints into the encrypted
   model cache.
5. The server loads both checkpoints on the NVIDIA T4.
6. The container health check confirms CUDA and `/health`.

The ECS health-check start period is 300 seconds, the AWS maximum. If the first
model download and load exceed the available health-check window, increase the
number of health-check retries rather than increasing `startPeriod`.

## Cost controls

- The Auto Scaling group maximum is one instance.
- The synthesized default is capacity zero.
- The run script returns capacity to zero after testing.
- The instance root volume is deleted on termination.
- The proof has no NAT gateway or load balancer.
- CloudWatch logs, the generated secret, and ECR asset storage can continue to
  incur small charges while the zero-capacity stack remains.

Use `npm run destroy` to remove the proof stack. CDK bootstrap ECR assets may
remain under the bootstrap repository lifecycle policy.

## Production evolution

The verification result should be established before adding public ingress.
If a public API is required, design a separate stack with:

1. Private compute subnets across at least two Availability Zones.
2. A public Application Load Balancer with ACM TLS.
3. AWS WAF, request limits, and explicit authentication.
4. An autoscaling and capacity strategy appropriate for GPU scarcity.
5. Persistent or prebuilt model artifacts to reduce cold starts.
6. Metrics and alarms for latency, task health, GPU memory, and failed model
   downloads.
7. A clear upgrade and model-revision pinning process.
