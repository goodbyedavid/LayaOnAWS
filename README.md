# Laya on AWS

A reference architecture for running [Laya](https://github.com/NandhaKishorM/laya),
an open-source System One inference server, on Amazon ECS with GPU capacity in
your own AWS account.

Laya speaks the same `POST /v1/systemone` wire protocol as the hosted Jev API, so
an existing client can be repointed at your endpoint by changing one base URL.
This repository preserves that path end to end.

Read [docs/why-laya-on-aws.md](docs/why-laya-on-aws.md) for the reasoning,
including the cases where this is the wrong tool.

## Status

| Component | State |
| --- | --- |
| Private stack, Systems Manager access | Deployed and verified live on a Tesla T4 |
| GPU registration, health, inference, latency, scale to zero | Verified live |
| Public HTTPS endpoint through API Gateway | Verified live end to end, including path and bearer token preservation |
| Bearer token rejection of unauthenticated requests | Verified live on the GPU host |
| Questions-per-call benchmark sweep, both checkpoints | Run live, results below |
| Optional custom domain (ACM and Route 53) | Code complete and template-asserted, **not tested live** |

Measured evidence is in [docs/verification-notes.md](docs/verification-notes.md).

## Measured results

One `g4dn.xlarge` with a Tesla T4, PyTorch 2.14.0+cu126, twenty samples per cell
after warm-up, measured on the host over loopback.

| Model | 1 question | 5 | 10 | 50 | Best ms/question | Peak questions/sec |
| --- | --- | --- | --- | --- | --- | --- |
| english | 32.73 ms | 42.27 ms | 71.27 ms | 285.84 ms | 5.72 | 174.9 |
| multilingual | 27.73 ms | 30.13 ms | 36.04 ms | 142.45 ms | 2.85 | 351.0 |

GPU memory after the sweep was 4136 MiB of 15360 MiB. Adding the managed HTTPS
path costs a roughly fixed 30 ms, taking single-question english from 32.62 ms to
64.38 ms at the p50.

These are this repository's own measurements, not a reproduction of upstream's
published table. Batched figures here are 2.0 to 2.7 times faster than upstream
publishes; single-question latency is close. The discrepancy is not explained,
and is discussed in [docs/verification-notes.md](docs/verification-notes.md).

## What gets deployed

Always:

- A VPC across two Availability Zones with public subnets and no NAT gateway
- An ECS cluster with an EC2 capacity provider, backed by an Auto Scaling group
  using a launch template, bounded to at most one `g4dn.xlarge`
- One ECS task running Laya with one GPU, an encrypted 100 GiB root volume for
  the model cache, and IMDSv2 required
- A generated bearer token in AWS Secrets Manager, injected into the container
- A CloudWatch log group with seven-day retention

Only with `-c publicEndpoint=true`:

- An Amazon API Gateway HTTP API, which serves HTTPS on a generated
  `*.execute-api` hostname with a trusted certificate. **No domain or hosted zone
  is required.**
- A VPC link and an **internal** Application Load Balancer, so nothing in the
  data path is reachable from the internet
- API Gateway request throttling, since AWS WAF cannot attach to an HTTP API
- An S3 bucket holding load balancer access logs, expiring after 30 days
- Security group rules allowing port 80 to the load balancer from the VPC link
  only, and port 8000 to the GPU host from the load balancer only

There are no CIDR-based ingress rules in any configuration.

Without the public endpoint there are no inbound security group rules at all and
Laya is reachable only through AWS Systems Manager.

## Cost

| Configuration | Approximate cost |
| --- | --- |
| Default, GPU capacity zero, no public endpoint | Near zero. Log group, secret, and the container image in ECR only |
| GPU capacity one | `$0.526` per hour for the `g4dn.xlarge` in us-west-2, plus the volume and a public IPv4 address |
| Public endpoint added | A further `$16` to `$18` per month for the internal load balancer, billed even while GPU capacity is zero, plus API Gateway per-request charges |

The stack defaults to **zero** GPU instances. Launching one is always explicit.
The two live verification runs behind the measurements above cost under `$1`
in total.

## Prerequisites

- Node.js 22 or newer, and an AWS account with the CDK bootstrapped
- Credentials for that account resolvable by the AWS CLI
- At least four available On-Demand G-family vCPUs in the target region
- A container builder. [Finch](https://runfinch.com/) is used here via
  `CDK_DOCKER=finch`; Docker also works if you drop that variable
- For a **custom domain** only: a Route 53 public hosted zone you control. The
  public endpoint itself needs no domain.

Run the read-only preflight checks:

```bash
npm install
scripts/preflight.sh
```

## Quick start: private stack

Start here. It costs nothing while idle and proves the path.

```bash
npm install
npm run build
npm run synth          # defaults to zero GPU capacity
npm run deploy:gpu     # launches one g4dn.xlarge
```

Wait for the ECS task to report healthy, then run the automated check over
Systems Manager. It needs the instance role to read the token, which is off by
default:

```bash
CDK_DOCKER=finch npx cdk deploy LayaVerificationStack \
  -c capacity=1 -c hostBenchmarkAccess=true --require-approval never

scripts/benchmark-remote.sh
```

It reports the GPU, the health response, rejection of an unauthenticated
request, model snapshot revisions, a real inference response, the latency sweep,
and GPU memory. The bearer token is never placed in the SSM command parameters;
the remote host fetches it itself using the instance role.

For interactive access, install the Session Manager plugin and run, in one
terminal:

```bash
scripts/connect.sh
```

and in another:

```bash
scripts/verify.sh
```

Return to zero capacity when finished:

```bash
npm run deploy:idle
```

## Public HTTPS endpoint

No domain is required. API Gateway serves the endpoint on a generated hostname
that already has a trusted certificate.

```bash
npm run build

CDK_DOCKER=finch npx cdk deploy LayaVerificationStack \
  -c capacity=1 \
  -c publicEndpoint=true \
  --require-approval never
```

The stack outputs `EndpointBaseUrl`, `EndpointUrl`, and `HealthUrl`. Point an
existing Jev client at `EndpointBaseUrl` and nothing else changes, because the
`/v1/systemone` path and the `Authorization` header are both preserved.

```bash
BASE=$(aws cloudformation describe-stacks --stack-name LayaVerificationStack \
  --query "Stacks[0].Outputs[?OutputKey=='EndpointBaseUrl'].OutputValue | [0]" \
  --output text)

API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "$(aws cloudformation describe-stacks \
    --stack-name LayaVerificationStack \
    --query "Stacks[0].Outputs[?OutputKey=='ApiKeySecretArn'].OutputValue | [0]" \
    --output text)" \
  --query SecretString --output text)

curl -sS "$BASE/health"

curl -sS "$BASE/v1/systemone" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  --data @examples/support-ticket.json
```

At zero GPU capacity the endpoint returns HTTP 503, because no backend is
registered. That is expected.

Throttling defaults to 20 requests per second sustained with a burst of 40,
chosen because Laya serialises inference through a single worker. Adjust with
`-c rateLimit=50 -c burstLimit=100`.

### Optional custom domain

If you do own a domain, add it to the API Gateway front door. The backend is
unchanged.

```bash
CDK_DOCKER=finch npx cdk deploy LayaVerificationStack \
  -c capacity=1 -c publicEndpoint=true \
  -c domainName=laya.example.com \
  -c hostedZoneId=Z0123456789ABCDEFGHIJ \
  -c hostedZoneName=example.com \
  --require-approval never
```

This path is template-asserted but has not been tested against a live domain.

## Benchmarking

`scripts/benchmark.py` mirrors the questions-per-call sweep that upstream
publishes, so results are comparable with upstream's `BENCHMARKS.md` rather than
being a differently shaped measurement. It retains raw per-request samples,
reports mean and standard deviation alongside percentiles, uses distinct
questions within a multi-question request, and checks that an unauthenticated
request is rejected.

The host-side scripts read the bearer token on the instance, which requires a
grant that is **off by default**. Deploy with it enabled only while
benchmarking:

```bash
npm run build
CDK_DOCKER=finch npx cdk deploy LayaVerificationStack \
  -c capacity=1 -c hostBenchmarkAccess=true --require-approval never

scripts/benchmark-remote.sh
QUESTION_COUNTS=1,5 SAMPLES=30 scripts/benchmark-remote.sh
```

`hostBenchmarkAccess` lets the EC2 instance role read the API token, which means
any process on the host, and anyone with SSM shell access to it, can read it.
Leave it off for production, and redeploy without it when benchmarking is done.
Leave it off for production, and redeploy without it when benchmarking is done.

Read the percentiles with the sample count in mind. At twenty samples a p95 is
one observation, not a converged tail estimate.

## Guarded end-to-end workflow

`scripts/deploy-and-verify.sh` deploys, tests, returns capacity to zero, and
writes `live-verification.txt`. It installs an exit trap that scales the GPU back
down on failure or interruption.

```bash
scripts/deploy-and-verify.sh

# Pin it to one account so it refuses to deploy anywhere else:
LAYA_EXPECTED_ACCOUNT=111122223333 scripts/deploy-and-verify.sh
```

If the script is killed with SIGKILL the trap will not run. Verify directly:

```bash
aws ec2 describe-instances \
  --filters Name=tag:aws:cloudformation:stack-name,Values=LayaVerificationStack \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}'
```

## Teardown

```bash
npm run deploy:idle   # GPU to zero, keep the stack
npm run destroy       # remove everything
```

`npm run destroy` can fail with `ResourceInUseException` on
`AWS::ECS::ClusterCapacityProviderAssociations` even with zero tasks. If that
happens, disassociate the capacity provider and retry:

```bash
CLUSTER=$(aws ecs list-clusters --query 'clusterArns[0]' --output text)
aws ecs put-cluster-capacity-providers --cluster "$CLUSTER" \
  --capacity-providers --default-capacity-provider-strategy
npm run destroy
```

The GPU instance and its volume are deleted when capacity returns to zero, which
also deletes the model cache and lengthens the next cold start. The container
image may persist in the CDK bootstrap ECR repository until its lifecycle policy
removes it.

## Limitations

Upstream advises keeping choice questions under about twenty options, and reports
a clear architectural loss on 77-label classification. If your use case is
many-class intent detection, this is the wrong tool. See
[docs/why-laya-on-aws.md](docs/why-laya-on-aws.md) for the full set, including
what this repository has and has not measured.

Model checkpoint revisions are not pinned, because the current `laya-serve`
contract does not expose that control. For production, mirror the checkpoints you
validated into your own S3 bucket or image.

## Documentation

| File | Purpose |
| --- | --- |
| [docs/why-laya-on-aws.md](docs/why-laya-on-aws.md) | Replacing Jev with Laya, and when not to |
| [docs/architecture.md](docs/architecture.md) | Architecture, networking, IAM, diagram |
| [docs/verification-notes.md](docs/verification-notes.md) | Measured results |
| [NOTICE.md](NOTICE.md) | Third-party licenses and model provenance |

## License

MIT No Attribution. See [LICENSE](LICENSE).

Laya is a separate Apache-2.0 project and is not redistributed here; it is
installed from PyPI at container build time. This repository is not affiliated
with or endorsed by the Laya maintainers, and is not an official AWS publication.
See [NOTICE.md](NOTICE.md).
