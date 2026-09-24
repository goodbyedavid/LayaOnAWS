# Agent handoff instructions

Read these files before changing or deploying the project:

1. `docs/handoff.md`
2. `docs/architecture.md`
3. `docs/deployment-plan.md`
4. `docs/test-plan.md`
5. `docs/verification-notes.md`

The authorized deployment target is AWS account `111122223333` in
`us-west-2`, using the local AWS CLI `default` profile. Verify the caller
identity and current CloudFormation and EC2 state before any mutation. Never
read or expose raw AWS credentials or the generated Laya bearer token.

Use Finch for CDK container builds:

```bash
CDK_DOCKER=finch
```

The previous CloudFormation attempt failed because the account disallows
legacy Auto Scaling launch configurations. The code now uses an EC2 launch
template and passes local synthesis assertions. The corrected version still
requires a live deployment and GPU test.

The preferred continuation is:

```bash
scripts/deploy-and-verify.sh
```

The live run must finish with ECS and Auto Scaling desired capacity zero and
no active `g4dn.xlarge`. Record measured evidence in
`docs/verification-notes.md`.
