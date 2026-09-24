# Agent handoff instructions

Read these files before changing or deploying the project:

1. `docs/handoff.md`
2. `docs/architecture.md`
3. `docs/deployment-plan.md`
4. `docs/test-plan.md`
5. `docs/verification-notes.md`

Deploy only into an AWS account you are authorized to use. Verify the caller
identity and the current CloudFormation and EC2 state before any mutation. Set
`LAYA_EXPECTED_ACCOUNT` to pin deployment to one account. Never read or expose
raw AWS credentials or the generated Laya bearer token.

This stack launches a GPU instance that costs money. The default is zero
capacity; launching one must always be explicit.

Use Finch for CDK container builds:

```bash
CDK_DOCKER=finch
```

The private stack and the API Gateway public endpoint have both been verified
live on a Tesla T4. See `docs/verification-notes.md` for measured evidence and
`docs/test-plan.md` for what remains untested.

Any live run must finish with ECS and Auto Scaling desired capacity zero and no
active `g4dn.xlarge`. Record measured evidence in `docs/verification-notes.md`,
and never record the bearer token.
