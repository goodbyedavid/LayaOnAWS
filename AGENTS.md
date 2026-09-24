# Agent instructions

Read before changing or deploying this project:

1. `README.md` for how the stack is meant to be used
2. `docs/architecture.md` for the design and its accepted limitations
3. `docs/verification-notes.md` for what has actually been measured, and what
   has not

## Safety

This stack launches a GPU instance that costs money. The default is zero
capacity, and launching one must always stay explicit.

Deploy only into an AWS account you are authorized to use. Verify the caller
identity and the current CloudFormation and EC2 state before any mutation. Set
`LAYA_EXPECTED_ACCOUNT` to pin `scripts/deploy-and-verify.sh` to one account.

Never read, log, or expose raw AWS credentials or the generated Laya bearer
token.

Any live run must end with ECS and Auto Scaling desired capacity at zero and no
active `g4dn.xlarge`. Confirm it directly rather than trusting an exit code:

```bash
aws ec2 describe-instances \
  --filters Name=tag:aws:cloudformation:stack-name,Values=LayaVerificationStack \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}'
```

## Conventions

Use Finch for CDK container builds:

```bash
CDK_DOCKER=finch
```

Assert the synthesized template rather than trusting CDK defaults. Two real
security defects in this repository were caught that way and are described in
`docs/verification-notes.md`, including a load balancer listener that silently
added its own `0.0.0.0/0` ingress rule alongside a caller's allowlist.

Record measured evidence in `docs/verification-notes.md` with its conditions.
Do not present a number without stating how it was measured, and never record
the bearer token.
