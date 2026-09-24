# Development handoff

## Current state

The live GPU verification is complete as of 2026-09-23. The
launch-template stack deployed successfully, twelve of the thirteen acceptance
criteria were verified live, and capacity was returned to zero with the GPU
instance and its root volume confirmed deleted.

The one criterion not verified live is rejection of an unauthenticated request.
It rests on the earlier local smoke test because `scripts/verify-remote.sh`
always sends the `Authorization` header.

The stack `LayaVerificationStack` is retained at zero GPU capacity in
`UPDATE_COMPLETE`. It costs only the CloudWatch log group, the generated
secret, and the retained ECR image. No decision has been made yet on whether to
destroy it.

Measured evidence is recorded in
[`verification-notes.md`](verification-notes.md). The findings that affect any
published claim are the latency measurement conditions, the untested batching
dimension, and the divergence from the upstream PyTorch dependency set.

A future agent must still check actual stack and EC2 state rather than relying
solely on this note.

## Environment

| Item | Value |
| --- | --- |
| Workspace | `<repository root>` |
| AWS account | `111122223333` |
| AWS region | `us-west-2` |
| Local AWS profile | `default` |
| Last verified principal | `arn:aws:iam::111122223333:user/EXAMPLE-USER` |
| Stack | `LayaVerificationStack` |
| Container builder | Finch |
| CDK Docker setting | `CDK_DOCKER=finch` |
| Desired live capacity | `1` during test |
| Required final capacity | `0` |

AWS CLI credentials are resolved from the local shared credentials file. Do
not read, copy, log, or expose the access key or secret key.

Docker Desktop is installed, but the local organization policy requires an
additional Docker sign-in. Finch has already built and smoke-tested the image,
so use Finch for CDK image builds.

## First action

Run:

```bash
aws sts get-caller-identity --profile default --region us-west-2

aws cloudformation describe-stacks \
  --stack-name LayaVerificationStack \
  --profile default \
  --region us-west-2

aws ec2 describe-instances \
  --profile default \
  --region us-west-2 \
  --filters \
    Name=tag:aws:cloudformation:stack-name,Values=LayaVerificationStack \
    Name=instance-state-name,Values=pending,running,stopping,stopped
```

Confirm account `111122223333` and make sure no GPU is unexpectedly running.
If a previous stack is in `ROLLBACK_COMPLETE`, delete it and
wait for deletion before deploying again.

## Recommended continuation

The complete workflow is:

```bash
cd <repository root>
scripts/deploy-and-verify.sh
```

This script:

1. Verifies the exact AWS account.
2. Deletes only the named stack when it is `ROLLBACK_COMPLETE`.
3. Builds the CDK app.
4. Deploys one `g4dn.xlarge`.
5. Runs GPU, health, inference, model revision, latency, and memory checks.
6. Deploys capacity zero.
7. Confirms ECS task counts and active EC2 instances.
8. Writes `live-verification.txt`.

Monitor CloudFormation, ECS service events, stopped task reasons, and the Laya
CloudWatch log group while the deployment runs. The initial image pull and
checkpoint downloads can take several minutes.

## Known implementation details

- Laya version: `0.3.11`.
- Reviewed upstream revision:
  `1e28ac20c0896b1c37a744cd11f740eb98f8b178`.
- PyTorch pin: `2.14.0+cu126`, with `transformers` 5.17.0 and `huggingface_hub` 1.32.0.
- Container architecture: `linux/amd64`.
- Approximate image size before checkpoints: 7.19 GB.
- Models requested: `english,multilingual`.
- Task GPU requirement: one.
- Task CPU units: 3072.
- Task memory reservation: 8192 MiB.
- Task network mode: bridge.
- Host and container port: 8000.
- Model cache: `/opt/laya-cache` mounted at
  `/home/laya/.cache/huggingface`.
- Health start period: 300 seconds.

The CDK asset was uploaded during the earlier attempt. The corrected
`.dockerignore` includes only `Dockerfile` and `.dockerignore` in the build
context. A new asset hash may be produced, but existing image layers should
deduplicate in ECR.

## Files to review

| File | Purpose |
| --- | --- |
| [`lib/laya-verification-stack.ts`](../lib/laya-verification-stack.ts) | AWS CDK architecture |
| [`Dockerfile`](../Dockerfile) | Laya CUDA runtime image |
| [`scripts/deploy-and-verify.sh`](../scripts/deploy-and-verify.sh) | End-to-end guarded workflow |
| [`scripts/verify-remote.sh`](../scripts/verify-remote.sh) | SSM-based live test and benchmark |
| [`scripts/connect.sh`](../scripts/connect.sh) | Interactive SSM port forwarding |
| [`scripts/verify.sh`](../scripts/verify.sh) | Interactive local API calls |
| [`architecture.md`](architecture.md) | Architecture, networking, IAM, and diagram |
| [`deployment-plan.md`](deployment-plan.md) | Deployment, rollback, and cost plan |
| [`test-plan.md`](test-plan.md) | Acceptance criteria and evidence |
| [`verification-notes.md`](verification-notes.md) | Execution record to update |

## Decisions and limitations

1. The proof is private and has no internet-facing API endpoint.
2. The instance has public outbound connectivity for image and model
   downloads, with no inbound security-group rules.
3. The stack uses one Availability Zone and is not highly available.
4. Model revisions are not pinned by the current Laya server contract. Record
   the downloaded snapshot revisions during the live test.
5. Returning capacity to zero deletes the model cache and increases the next
   cold start.
6. The instance role can read the generated secret solely for host-side test
   automation.
7. A production public API requires a separate ingress, authentication,
   availability, and scaling design.

## Completion checklist

- [x] Verify AWS identity and existing resource state.
- [x] Delete the failed `ROLLBACK_COMPLETE` stack.
- [x] Deploy the launch-template stack with capacity one.
- [x] Confirm ECS GPU registration and healthy task.
- [x] Capture model revisions, inference response, latency, and GPU memory.
- [x] Review CloudWatch logs.
- [x] Return capacity to zero.
- [x] Confirm no active GPU instance.
- [x] Update `verification-notes.md` with measured evidence.
- [ ] Decide whether to retain the idle stack or destroy it.

## Remaining work

1. Decide whether to keep the zero-capacity stack or run `npm run destroy`.
2. Raise the `choice:11+` temperature clamp with the Laya maintainers before
   publishing anything that quotes confidence on high-option-count questions.
3. Consider setting `HF_TOKEN` and shrinking the 7.19 GB image if repeated cold
   starts matter.
