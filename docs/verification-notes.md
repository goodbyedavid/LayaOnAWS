# Verification execution notes

Date: 2026-09-23  
Region: `us-west-2`

The live GPU verification is complete.
See [Live verification results](#live-verification-results) for measured
evidence.

## Completed without billable GPU infrastructure

- Reviewed Laya `0.3.11` at upstream revision
  `1e28ac20c0896b1c37a744cd11f740eb98f8b178`.
- Confirmed `POST /v1/systemone`, `GET /health`, optional bearer
  authentication, request limits, and preload behavior from source and tests.
- Confirmed the AWS account has enough On-Demand G-family quota.
- Confirmed `g4dn.xlarge` is offered in `us-west-2a`, `us-west-2b`, and
  `us-west-2c`.
- Confirmed the current Amazon Linux 2023 ECS GPU AMI is available.
- Compiled the TypeScript infrastructure.
- Synthesized the zero-capacity and one-capacity CloudFormation variants.
- Validated the template with the CloudFormation API.
- Reviewed the CDK security diff. The instance has no inbound rule; its role
  can read only the generated Laya secret in addition to standard ECS and SSM
  permissions.
- Built the target `linux/amd64` CUDA image using Finch.
- Confirmed the image contains Laya `0.3.11`, PyTorch `2.11.0+cu128`, CUDA
  runtime `12.8`, and the `laya-serve` executable.
- Started the container without preloading weights. `GET /health` returned 200
  and an unauthenticated decision request returned 401.

## Findings

1. The reviewed upstream Dockerfile defaults to PyTorch `2.14.0`. That version
   was not present in the official CUDA 12.8 wheel index during verification.
   The newest available version was `2.11.0`, which built successfully and
   passed `pip check`.
2. The runtime image is approximately 7.50 GB before model weights. Initial
   image upload and pull time must be included in cold-start measurements.
3. Laya serializes HTTP inference through one worker. Load testing should
   distinguish individual request latency from batched questions in one
   request.
4. Model files are not revision-pinned by the current `laya-serve` environment
   contract. The first live run will record the Hugging Face snapshot revisions
   present in the cache.

## Cloud deployment attempts

1. The first deployment reached CloudFormation and failed because the ECS
   health-check start period exceeded the supported maximum. It is now 300
   seconds.
2. The second deployment reached CloudFormation and failed because the account
   disallows legacy Auto Scaling launch configurations. The infrastructure now
   uses an EC2 launch template.
3. Both failed stacks were deleted and reached `DELETE_COMPLETE`.
4. The corrected launch-template version deployed successfully on
   2026-09-23 and reached `CREATE_COMPLETE`. Assertions confirmed the launch
   template is present, no launch configuration remains, public IPv4
   association is enabled, and the instance security group has no inbound rule.

Both CloudFormation failures occurred before a GPU instance launched, so
neither incurred GPU charges.

## Live verification results

The live GPU run completed on 2026-09-23 in `us-west-2`, in a single AWS
account, using an IAM user with deployment permissions.
Account and principal identifiers are omitted here because this repository is
public.
The launch-template correction deployed successfully on the first attempt.

Twelve of the thirteen acceptance criteria in [`test-plan.md`](test-plan.md)
were verified live.
Criterion 7, rejection of an unauthenticated decision request, was not
exercised on the GPU host because `scripts/verify-remote.sh` sends the
`Authorization` header on every request.
That criterion rests on the earlier local container smoke test, which returned
HTTP 401.
Adding an unauthenticated call to the remote script would close the gap on the
next run.

The multilingual checkpoint was confirmed loaded and resident, but its
inference path was not exercised.
The fixture is English text, and the router selected the `english` model, so
multilingual correctness on this GPU remains unproven.

### Timeline

All timestamps are UTC.

| Time | Event |
| --- | --- |
| `21:39:39` | CloudFormation stack creation initiated |
| `21:45:52` | ECS task started on the GPU host |
| `21:45:55` | First checkpoint fetch began |
| `21:46:05` | Second checkpoint fetch completed |
| `21:46:08` | Uvicorn reported application startup complete |
| `21:46:24` | First container health check returned HTTP 200 |
| `21:48:29` | ECS service reached steady state; stack `CREATE_COMPLETE` |
| `21:50:14` | Automated verification began |
| `21:50:15` | Twenty-one inference requests completed |
| `21:51:13` | Container shut down gracefully after scale-down |
| `21:58` | GPU instance reached `terminated`; root volume deleted |

Total stack creation took 524 seconds.
Scale-down to zero capacity took 55 seconds.
The measured cold start from task start to a serving process was 16 seconds,
far below the 300-second health-check start period.
Checkpoint download accounted for roughly 10 seconds of that interval, so the
large image pull rather than model download dominates first-start time.

### Infrastructure evidence

| Item | Measured value |
| --- | --- |
| Instance ID | `i-EXAMPLE` (terminated) |
| Instance type | `g4dn.xlarge` |
| Availability Zone | `us-west-2a` |
| AMI ID | `ami-0d5c3753473c66011` |
| ECS registered GPU | `GPU-2466d8d2-bfcb-0f84-a617-f7c224832a18` |
| Container image digest | `sha256:1f484f61c00d7b250a374b2a9e4268623c8afdd659a68c28d3e6035e14f4d380` |
| ECS task ID | `7b24e80034c14dd88cfe9dc65ced7148` |
| Task and container health | `RUNNING` and `HEALTHY` |

The container health check asserts `torch.cuda.is_available()` before calling
`/health`, so a healthy task is direct evidence that PyTorch `2.11.0+cu128`
reached the GPU.

### GPU and runtime evidence

```text
Tesla T4, 15360 MiB, driver 580.178.04
```

The health endpoint returned:

```json
{"status":"ok","loaded":["english","multilingual"],"device":"cuda"}
```

Both requested checkpoints were resident on the T4 and the server reported the
`cuda` device.
GPU memory in use after inference was `3898 MiB` of `15360 MiB`, so a single
task leaves substantial headroom on this instance type.

### Warm latency

Twenty measured samples followed one discarded warm-up request.

| Metric | Value |
| --- | --- |
| Samples | 20 |
| Minimum | `32.50 ms` |
| p50 | `32.95 ms` |
| p95 | `33.82 ms` |
| Maximum | `34.59 ms` |

The distribution is unusually tight, with only `2.09 ms` between the minimum
and the maximum.
These figures cover one question in one request against a warm process on an
idle host, and they exclude all network transit because the calls originated on
the instance itself.
Any published latency claim must state those conditions.

### Comparison with upstream published figures

The upstream repository publishes a latency table measured on a T4, indexed by
questions per call.
Its single-question figures are `39.5 ms` for the `laya` English checkpoint and
`32.8 ms` for `laya-multilingual`.

This run routed to the English checkpoint and measured a p50 of `32.95 ms`,
roughly 17 percent faster than the upstream English figure and close to the
upstream multilingual figure.
The gap is unexplained.
Plausible causes include the pinned PyTorch `2.11.0` rather than the upstream
`2.14` dependency set, loopback-only transport in this harness, a different
fixture size, and unknown measurement boundaries upstream.
Do not present this number as a reproduction of the upstream benchmark until
the discrepancy is understood.

The upstream methodology measures 1, 5, 10, and 50 questions per call, and its
headline claim is batched throughput of `7.2 ms` per question and
`103` to `332` questions per second.
This run measured only the single-question case, so it covers one cell of that
table and omits the dimension upstream treats as most important.

### Inference response

The support-ticket fixture routed correctly to the billing department.

```json
{
  "model": "laya-rl-agent",
  "answers": {
    "department": {
      "type": "choice",
      "choice": "billing",
      "probabilities": {
        "billing": 0.96,
        "technical": 0.0143,
        "sales": 0.0112,
        "other": 0.0145
      },
      "confidence": 0.8474,
      "action": { "act_probability": 1.0 }
    }
  },
  "usage": { "input_tokens": 94, "output_tokens": 0 },
  "routing": {
    "model": "english",
    "repo": "convaiinnovations/laya",
    "reason": "English Latin text",
    "detection": {
      "script": "latin",
      "language": "en",
      "is_english": true,
      "language_undecided": false,
      "diacritic_rate": 0.0,
      "non_latin_fraction": 0.0
    },
    "workflow": null
  }
}
```

The response is Jev-compatible, selects the correct department for a duplicate
charge, and reports `output_tokens` of zero because the model emits a
classification rather than generated text.

### Model revisions

One Hugging Face snapshot revision was present in the cache:

```text
aa8c91ca088ec597df95a0d1c76b3063cb2ae5e8
```

The test plan anticipated two revisions.
Only one appears because both the English and multilingual checkpoints are
served from the single `convaiinnovations/laya` repository through subfolders,
so one snapshot hash covers both.

### Scale-down evidence

After deploying capacity zero:

```json
{"Desired": 0, "Running": 0, "Pending": 0}
```

The Auto Scaling group reported desired capacity zero with no instances,
instance `i-EXAMPLE` (terminated) reached `terminated`, and
`describe-volumes` returned an empty list, confirming the 100 GiB root volume
was deleted with the instance.
No `g4dn.xlarge` remains in any billable state anywhere in the region.

## Live run findings

1. Laya emitted exactly one calibration warning while loading a checkpoint:
   `laya: this checkpoint ships invalid temperatures or values outside
   [0.5, 5]; using choice:11+=0.10058280825614929 -> 0.5. Treat confidence
   from the affected entries as uncalibrated.`
   Upstream refits temperatures per question type and option count, so the
   clamped entry `choice:11+` applies only to choice questions with eleven or
   more options.
   The fixture used a four-option choice, so the measured `confidence` of
   `0.8474` did not come from an affected bucket and is not invalidated by this
   warning.
   The practical consequence is narrower than it first appears: any production
   use of choice questions with eleven or more options would receive
   uncalibrated confidence from this checkpoint and should be validated
   separately.
   A log filter confirmed this was the only temperature warning in the run.
2. Laya warned that unauthenticated Hugging Face requests are rate limited.
   Setting `HF_TOKEN` would make checkpoint downloads faster and more reliable
   for repeated cold starts.
3. Cold start was dominated by the image pull rather than checkpoint download.
   Reducing the 7.50 GB image would shorten cold start more than caching
   weights would.
4. PyTorch `2.11.0+cu128` ran Laya `0.3.11` on an NVIDIA T4 with no runtime
   errors, which resolves the open question created by pinning away from the
   upstream default of `2.14.0`.
   The divergence is broader than the torch version alone, because upstream
   states that `huggingface_hub` 1.x, `transformers` 5.x, and `torch` 2.14 form
   its expected dependency set, and that `0.3.11` specifically restores
   `transformers` 4.x loading with correct RoPE settings.
   Numerical equivalence to the upstream dependency set was not verified.
5. Only the `choice` question type was exercised. Upstream documents `choice`,
   `score`, and `noul`, and advises validating `noul` label overrides and
   `score` questions on the multilingual checkpoint against local data.
6. Upstream documents a catastrophic multilingual failure case, reporting
   `0.000` accuracy at `0.952` confidence for Khmer.
   Because this run never exercised the multilingual path, that risk is
   unmeasured here and matters for any claim about non-English input.
7. Upstream ships a reproducible benchmark harness, including
   `research/scripts/laya_benchmark_colab.ipynb`, `BENCHMARKS.md`, and
   `benchmarks/parity_fast.py`, and its published suite covers 17,416 questions.
   This run used a bespoke twenty-sample harness instead, so its numbers are
   not directly comparable to upstream results.
8. Upstream also ships official container assets, including `compose.cuda.yaml`
   and `docs/docker.md`. This project builds its own Dockerfile. Reconciling
   against the upstream image would reduce the risk of environment drift.

## Reference solution work, 2026-09-23

### PyTorch dependency divergence resolved

The earlier finding that PyTorch `2.14.0` was unavailable was correct only for
the `cu128` wheel index.
A survey of the published indexes found `2.14.0` in both `cu126` and `cu130`.

| Index | Newest torch |
| --- | --- |
| `cu126` | `2.14.0` |
| `cu128` | `2.11.0` |
| `cu129` | `2.13.0` |
| `cu130` | `2.14.0` |

The correct remedy was therefore to change the CUDA index rather than to
downgrade torch by three minor versions.
The image now pins `torch==2.14.0` from `cu126`.
`cu126` was chosen over `cu130` because CUDA 12.6 requires an NVIDIA driver of
560 or newer while CUDA 13.0 requires 580 or newer, and the ECS GPU AMI shipped
`580.178.04`, leaving no headroom for customers on an older AMI.

The rebuilt image was verified to contain the full upstream dependency set:

```text
python       : 3.11.16
laya         : 0.3.11
torch        : 2.14.0+cu126
cuda build   : 12.6
transformers : 5.17.0
huggingface_hub : 1.32.0
```

This matches upstream's stated expectation of `torch` 2.14, `transformers` 5.x,
and `huggingface_hub` 1.x.
The previous `2.11.0` pin was resolving `transformers` 4.x through the
compatibility path that Laya `0.3.11` restored, so the new image is closer to
what upstream actually tests.
The image is `7.192 GB`, slightly smaller than the `7.502 GB` produced by the
`2.11.0` pin.

Local smoke tests on the rebuilt image passed:

| Check | Result |
| --- | --- |
| `GET /health` | HTTP 200, `{"status":"ok","loaded":[],"device":"cpu"}` |
| `POST /v1/systemone` with no token | HTTP 401, `invalid or missing bearer token` |
| `POST /v1/systemone` with a wrong token | HTTP 401 |

The two rejection cases close the criterion 7 gap for the image, though they
were measured locally on CPU rather than on the GPU host.

The unexplained latency gap against upstream's published `39.5 ms` English
figure has not been retested on the new image.
A live run is required before drawing any conclusion about whether the torch
version contributed to it.

### Public endpoint template assertions

The optional public endpoint compiles and synthesizes. Template assertions
confirmed the following across three synthesized variants.

| Variant | Result |
| --- | --- |
| Private, default | No load balancer, listener, certificate, web ACL, or DNS record, and no security group ingress of any kind |
| Public, no allowlist | Internet-facing load balancer, HTTP 80 redirect to HTTPS, HTTPS 443 on `ELBSecurityPolicy-TLS13-1-2-Res-2021-06`, target group health check on `/health`, web ACL with a 300 request per IP rate limit, GPU host reachable on 8000 only from the load balancer security group |
| Public, `allowedCidrs` set | Ingress on 80 and 443 restricted to the supplied CIDR only |

A security defect was found and fixed during this assertion pass.
`ApplicationLoadBalancer.addListener` defaults to `open: true`, which adds its
own `0.0.0.0/0` ingress rule per listener.
The first synthesized template therefore contained the caller's `/32` allowlist
entry *and* two `0.0.0.0/0` entries, meaning `allowedCidrs` was silently
ineffective and the endpoint was open to the internet.
Both listeners now pass `open: false` and all ingress is declared explicitly.
This is exactly the class of defect that template assertions exist to catch, and
it would have shipped to anyone cloning the repository.

### Live run 2, 2026-09-24: API Gateway endpoint and benchmark sweep

The stack was destroyed and redeployed to add a second Availability Zone. The
original VPC could not be extended in place because its single subnet occupied
the entire `10.0.0.0/16` range, leaving no room for a second subnet.

Two defects were found and fixed during this run.

**Torch 2.14 requires a C toolchain in the image.** The server started, loaded
both checkpoints, and answered `/health` correctly, but every authenticated
inference returned HTTP 500 with `{"detail":"inference failed"}`. Upstream's
0.3.11 hardening deliberately does not leak tracebacks, so the cause was only
visible by reproducing inference inside the container:

```text
RuntimeError: Failed to find C compiler.
```

On a GPU, Laya dispatches through a Triton kernel
(`_bmm_outer_product_kernel`), and Triton JIT-compiles a small C extension at
runtime. The slim Python base image has no compiler. Installing `gcc` alone was
not sufficient and moved the failure to `fatal error: stdlib.h: No such file or
directory`, because `--no-install-recommends` does not pull in `libc6-dev`. The
image now installs both.

This failure mode is worth noting for anyone deploying Laya on a GPU in a slim
container: the health check passes, the models load, and only inference fails.

**`cdk destroy` fails on the ECS capacity provider.** Deletion of
`AWS::ECS::ClusterCapacityProviderAssociations` returned
`ResourceInUseException` even with zero services and zero tasks. The workaround
is to disassociate the provider first:

```bash
aws ecs put-cluster-capacity-providers \
  --cluster <cluster> --capacity-providers --default-capacity-provider-strategy
```

Any user running `npm run destroy` may hit this.

#### Endpoint verification

The API Gateway HTTP API served the endpoint over HTTPS on its generated
hostname with no domain or hosted zone, as designed.

| Check | Result |
| --- | --- |
| `GET /health` through API Gateway | HTTP 200, certificate validated, `{"status":"ok","loaded":["english","multilingual"],"device":"cuda"}` |
| `POST /v1/systemone` with no token | HTTP 401 |
| `POST /v1/systemone` with the token | HTTP 200, correct answer |
| Path preservation | `/v1/systemone` reached Laya unchanged through the `$default` route |
| `Authorization` forwarding | Preserved; the 401 and 200 cases prove the header arrives intact |
| At zero GPU capacity | HTTP 503, correct behaviour with no backend registered |

Criterion 7 is now verified live on the GPU host rather than only locally,
closing the gap recorded earlier.

The first authenticated request after a container start took `2.98 s` and the
second took `0.297 s`, both measured from a laptop over the public internet. The
difference is Triton compiling its kernel on first use. The cache now lives in
the mounted model-cache volume so the cost is paid once per host rather than once
per container start.

#### Numerical parity with the previous image

The response was byte-identical to the torch `2.11.0` run: `billing` at
probability `0.96` with confidence `0.8474`, routed to the English checkpoint.
Changing torch, transformers, and huggingface_hub did not change the output.

#### Questions-per-call sweep

Twenty samples per cell after one warm-up, measured on the GPU host over
loopback, using distinct questions within each request.

| Model | Questions | Mean ms | Stdev | p50 | p95 | ms/question | Questions/sec |
| --- | --- | --- | --- | --- | --- | --- | --- |
| english | 1 | 44.76 | 6.48 | 46.70 | 52.86 | 44.76 | 22.3 |
| english | 5 | 42.27 | 0.78 | 42.49 | 43.51 | 8.45 | 118.3 |
| english | 10 | 71.27 | 1.21 | 71.34 | 72.78 | 7.13 | 140.3 |
| english | 50 | 285.84 | 1.73 | 286.60 | 287.76 | 5.72 | 174.9 |
| multilingual | 1 | 27.36 | 0.28 | 27.33 | 27.80 | 27.36 | 36.6 |
| multilingual | 5 | 30.13 | 0.40 | 30.10 | 30.65 | 6.03 | 165.9 |
| multilingual | 10 | 36.04 | 0.41 | 35.96 | 36.72 | 3.60 | 277.5 |
| multilingual | 50 | 142.45 | 1.07 | 142.23 | 144.45 | 2.85 | 351.0 |

GPU memory after the sweep was `4136 MiB` of `15360 MiB`.

The `english/1` cell ran first and its standard deviation of `6.48` against
roughly `1.0` everywhere else indicated the Triton warm-up was still being paid
inside the measured samples. A clean rerun with thirty samples against an
already-warm process gave:

| Model | Min | Mean | Stdev | p50 | p95 | Max |
| --- | --- | --- | --- | --- | --- | --- |
| english | 32.18 | 32.73 | 0.39 | 32.62 | 33.54 | 33.64 |
| multilingual | 26.59 | 27.73 | 0.72 | 27.69 | 28.76 | 29.09 |

**This resolves the open latency discrepancy.** The English single-question p50
is `32.62 ms` on torch `2.14.0`, against `32.95 ms` previously measured on torch
`2.11.0`. The two are statistically indistinguishable, so the PyTorch version was
never a candidate explanation for the gap against upstream's published
`39.5 ms`. The gap is a difference in measurement methodology between the two
harnesses, not in this stack. Treat both numbers as this repository's own
measurement under stated conditions.

#### Comparison with upstream's published table

Upstream's figures are in the left column of each pair, this repository's mean in
the right.

| Questions | english upstream | english here | multilingual upstream | multilingual here |
| --- | --- | --- | --- | --- |
| 1 | 39.5 ms | 32.73 ms | 32.8 ms | 27.73 ms |
| 5 | 84.5 ms | 42.27 ms | 40.1 ms | 30.13 ms |
| 10 | 158.6 ms | 71.27 ms | 72.3 ms | 36.04 ms |
| 50 | 771 ms | 285.84 ms | 337 ms | 142.45 ms |

Batched performance here is materially better than upstream publishes, by
roughly 2.0 to 2.7 times at 10 and 50 questions per call. Measured throughput
reached `351` questions per second on multilingual at 50 questions per call,
above the top of upstream's stated `103` to `332` range, and `2.85 ms` per
question against upstream's `6.8 ms`.

The most likely cause is the Triton dispatch path that torch `2.14` enables and
that the earlier `2.11.0` pin did not reach, which is consistent with single
question latency being unchanged while batched latency improves substantially.
This has not been isolated by running both torch versions through the same sweep,
so it remains a hypothesis rather than a measured attribution.

#### Ingress overhead

The same harness run against the public API Gateway hostname from the GPU host,
so client-side network noise is excluded.

| Path | english/1 p50 | english/10 p50 |
| --- | --- | --- |
| Loopback, direct to the container | 32.62 ms | 71.34 ms |
| API Gateway, VPC link, internal load balancer | 64.38 ms | 98.80 ms |

The managed HTTPS path adds a roughly fixed `30 ms`, which roughly doubles
single-question latency but becomes proportionally smaller as questions per call
increase.

#### Teardown

After deploying capacity zero, the ECS service reported `0` desired, running,
and pending, the GPU instance reached `terminated`, `describe-volumes` returned
an empty list, and the public endpoint returned HTTP 503. No billable compute
remained.

### Security review before publication

An IAM audit of the synthesized template found the scoped grants in good shape.
The task execution role can pull only the stack's own image, write only to the
stack's log group, and read only the generated secret. The task role holds no
permissions. The remaining wildcard actions are the standard ECS agent and
capacity-provider drain-hook permissions.

One finding was material for a public repository and has been fixed.
The EC2 instance role was granted read access to the bearer token
unconditionally. That grant exists only so the host-side benchmark scripts can
fetch the token locally instead of passing it through SSM command parameters,
but it also means any process on the host, and anyone with SSM shell access,
can read the API token. A cloner deploying the stack unmodified for production
would have inherited it silently.

The grant is now controlled by `hostBenchmarkAccess`, which defaults to off.
Assertions confirm the instance role has no `secretsmanager` action in the
default template and gains it only when the flag is set.

Load balancer access logging was also added, to an encrypted bucket with public
access blocked, SSL enforced, and a 30-day expiry so an abandoned deployment
cannot accumulate storage cost. Access logs are the only record of who called a
public inference endpoint.

Two accepted risks remain documented rather than fixed:

1. The GPU host sits in a public subnet with a public IPv4 address. Inbound is
   restricted to the load balancer security group, or denied entirely in the
   private configuration, but a stricter design would use private subnets with a
   NAT gateway. That was rejected because a NAT gateway would become the
   dominant idle cost of a stack whose whole point is scaling to zero.
2. The hop from the load balancer to the container is plaintext HTTP inside the
   VPC, so the bearer token is not encrypted on that segment. This is a common
   pattern, and end-to-end encryption would require issuing and rotating a
   certificate for the task.

## Cost

The On-Demand `g4dn.xlarge` price in `us-west-2` is `$0.526/hour`.
The instance ran for approximately 19 minutes from launch to termination, so
compute for this run cost roughly `$0.17`.
Including the short-lived 100 GiB gp3 volume and the public IPv4 address, the
run stayed well below `$1`.

The zero-capacity stack was retained.
It still incurs small charges for the CloudWatch log group, the generated
secret, and the 7.50 GB image in the CDK bootstrap ECR repository.
Run `npm run destroy` to remove the stack when the proof is no longer needed.
