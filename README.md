# Laya on AWS

A reference architecture for running [Laya](https://github.com/NandhaKishorM/laya),
an open-source System One inference server, on Amazon ECS with GPU capacity in
your own AWS account.

Laya speaks the same `POST /v1/systemone` wire protocol as the hosted Jev API,
and this repository preserves that path end to end, so an existing client moves
over by changing one base URL.

Read [docs/why-laya-on-aws.md](docs/why-laya-on-aws.md) for why you would do
this, and for the cases where you should not.

## What it does

Send a state and a set of typed questions. Get back a decision per question with
calibrated probabilities, and no text to parse.

```bash
curl -sS "$BASE/v1/systemone" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  --data @examples/support-ticket.json
```

Request, abbreviated from
[examples/support-ticket.json](examples/support-ticket.json):

```json
{
  "state": {
    "subject": "Duplicate charge",
    "body": "We were billed twice for March. Please refund the duplicate charge."
  },
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which department should handle this request?",
      "criteria": {
        "billing": "Invoices, payments, duplicate charges, and refunds",
        "technical": "Bugs, outages, and system errors",
        "sales": "Pricing, proposals, and new contracts",
        "other": "Everything else"
      }
    }
  }
}
```

Response, abbreviated, measured from this deployment:

```json
{
  "answers": {
    "department": {
      "type": "choice",
      "choice": "billing",
      "probabilities": {
        "billing": 0.96, "technical": 0.0143, "sales": 0.0112, "other": 0.0145
      },
      "confidence": 0.8474
    }
  },
  "usage": { "input_tokens": 94, "output_tokens": 0 },
  "routing": { "model": "english", "reason": "English Latin text" }
}
```

Question types are `choice`, `score`, and `noul`. Many questions can share one
request against the same state, which is also the fastest way to use it.

## Measured performance

One `g4dn.xlarge` with a Tesla T4, PyTorch 2.14.0+cu126, called on the host over
loopback.

| Model | 1 question | 5 | 10 | 50 | Best ms/question | Peak questions/sec |
| --- | --- | --- | --- | --- | --- | --- |
| english | 32.73 ms | 42.27 ms | 71.27 ms | 285.84 ms | 5.72 | 174.9 |
| multilingual | 27.73 ms | 30.13 ms | 36.04 ms | 142.45 ms | 2.85 | 351.0 |

Both checkpoints stay resident in 4136 MiB of the card's 15360 MiB. Calling
through the public endpoint adds a roughly fixed 30 ms, taking single-question
english from 32.62 ms to 64.38 ms at the p50.

Single-question figures come from a 30-sample run against a warm process; the
rest are 20 samples per cell after one warm-up. Batched results here run 2.0 to
2.7 times faster than upstream Laya publishes, most likely because PyTorch 2.14
reaches a Triton dispatch path that older pins did not. Method, caveats, and the
unresolved difference against upstream's single-question figure are in
[docs/verification-notes.md](docs/verification-notes.md).

## Prerequisites

- Node.js 22 or newer, and an AWS account with the CDK bootstrapped
- Credentials for that account resolvable by the AWS CLI
- At least four available On-Demand G-family vCPUs in the target region
- A container builder. [Finch](https://runfinch.com/) is used here via
  `CDK_DOCKER=finch`; Docker also works if you drop that variable
- For a **custom domain** only: a Route 53 public hosted zone you control. The
  public endpoint itself needs no domain.

The region defaults to `us-west-2`. Override with `CDK_DEFAULT_REGION`.

Read-only preflight checks, including GPU quota and instance availability:

```bash
npm install
scripts/preflight.sh
```

## Quick start: private stack

Start here. There is no inbound network access, and it costs nothing while idle.

```bash
npm install
npm run build
npm run synth          # defaults to zero GPU capacity, so inspect it first
npm run deploy:gpu     # launches one g4dn.xlarge
```

If you intend to run the benchmark, add the grant it needs on this first deploy
rather than deploying twice:

```bash
CDK_DOCKER=finch npx cdk deploy LayaVerificationStack \
  -c capacity=1 -c hostBenchmarkAccess=true --require-approval never
```

Once the ECS task reports healthy, reach Laya through Systems Manager. In one
terminal, with the Session Manager plugin installed:

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

- An Amazon API Gateway HTTP API serving HTTPS on a generated `*.execute-api`
  hostname with a trusted certificate. **No domain or hosted zone is required.**
- A VPC link and an **internal** Application Load Balancer, so nothing in the
  data path is reachable from the internet
- API Gateway request throttling, since AWS WAF cannot attach to an HTTP API
- An S3 bucket holding load balancer access logs, expiring after 30 days
- Security group rules allowing port 80 to the load balancer from the VPC link
  only, and port 8000 to the GPU host from the load balancer only

There are no CIDR-based ingress rules in any configuration. Without the public
endpoint there are no inbound security group rules at all, and Laya is reachable
only through AWS Systems Manager.

See [docs/architecture.md](docs/architecture.md) for the design, the IAM model,
and the accepted limitations.

## Cost

| Configuration | Approximate cost |
| --- | --- |
| Default, GPU capacity zero, no public endpoint | Near zero. Log group, secret, and the container image in ECR only |
| GPU capacity one | `$0.526` per hour for the `g4dn.xlarge` in us-west-2, plus the volume and a public IPv4 address |
| Public endpoint added | A further `$16` to `$18` per month for the internal load balancer, billed even while GPU capacity is zero, plus API Gateway per-request charges |

The stack defaults to **zero** GPU instances, so launching one is always
explicit. The two live verification runs behind the measurements above cost under
`$1` in total.

## Benchmarking

`scripts/benchmark.py` mirrors the questions-per-call sweep that upstream Laya
publishes, so results are comparable rather than differently shaped. It retains
raw per-request samples, reports mean and standard deviation alongside
percentiles, uses distinct questions within a multi-question request, and checks
that an unauthenticated request is rejected.

It runs on the GPU host over Systems Manager, and reads the bearer token there so
the token never appears in an SSM command parameter. That requires
`hostBenchmarkAccess`, which is **off by default**:

```bash
scripts/benchmark-remote.sh
QUESTION_COUNTS=1,5 SAMPLES=30 scripts/benchmark-remote.sh
```

`hostBenchmarkAccess` lets the EC2 instance role read the API token, which means
any process on the host, and anyone with SSM shell access to it, can read it.
Leave it off in production, and redeploy without it once benchmarking is done.

Read the percentiles with the sample count in mind. At twenty samples a p95 is
one observation, not a converged tail estimate.

## Guarded end-to-end workflow

`scripts/deploy-and-verify.sh` deploys, benchmarks, returns capacity to zero, and
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

## What has been verified

| Component | State |
| --- | --- |
| Private stack, Systems Manager access | Verified live on a Tesla T4 |
| GPU registration, health, inference, scale to zero | Verified live |
| Public HTTPS endpoint through API Gateway | Verified live end to end, including path and bearer token preservation |
| Rejection of unauthenticated requests | Verified live on the GPU host |
| Questions-per-call sweep, both checkpoints | Run live |
| Optional custom domain (ACM and Route 53) | Template-asserted, **not tested live** |
| Concurrent or sustained load | **Not tested** |
| Multilingual answer quality | **Not tested**, only its latency |

## Limitations

Upstream advises keeping choice questions under about twenty options, and reports
an architectural loss on 77-label classification. If your use case is many-class
intent detection, this is the wrong tool.

Model checkpoint revisions are not pinned, because the current `laya-serve`
contract does not expose that control. For production, mirror the checkpoints you
validated into your own S3 bucket or image.

No accuracy claim in this repository is our own measurement. See
[docs/why-laya-on-aws.md](docs/why-laya-on-aws.md) for the full picture.

## Documentation

| File | Purpose |
| --- | --- |
| [docs/why-laya-on-aws.md](docs/why-laya-on-aws.md) | Replacing Jev with Laya, and when not to |
| [docs/architecture.md](docs/architecture.md) | Architecture, networking, IAM, diagram |
| [docs/verification-notes.md](docs/verification-notes.md) | Measured results and method |
| [NOTICE.md](NOTICE.md) | Third-party licenses and model provenance |

## License

MIT No Attribution. See [LICENSE](LICENSE).

Laya is a separate Apache-2.0 project and is not redistributed here; it is
installed from PyPI at container build time. This repository is not affiliated
with or endorsed by the Laya maintainers, and is not an official AWS publication.
See [NOTICE.md](NOTICE.md).
