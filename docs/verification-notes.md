# Measured results

Everything here was measured on a single `g4dn.xlarge` with a Tesla T4 in
`us-west-2`, most recently on 2026-09-24. Nothing in this file is quoted from
upstream unless it says so.

## Environment

| Item | Value |
| --- | --- |
| Instance | `g4dn.xlarge`, Tesla T4, 15360 MiB, driver `580.178.04` |
| AMI | Amazon Linux 2023 ECS GPU, `ami-0d5c3753473c66011` |
| Laya | `0.3.11` |
| PyTorch | `2.14.0+cu126`, CUDA build 12.6 |
| transformers | `5.17.0` |
| huggingface_hub | `1.32.0` |
| Python | `3.11.16` |
| Image size | 7.19 GB before checkpoints |
| Checkpoint snapshot | `aa8c91ca088ec597df95a0d1c76b3063cb2ae5e8` |

One snapshot revision covers both checkpoints, because the English and
multilingual models are served from the single `convaiinnovations/laya`
repository through subfolders.

## Latency

Twenty samples per cell after one warm-up, called over loopback on the host, with
distinct questions inside each multi-question request.

| Model | Questions | Mean | Stdev | p50 | p95 | ms/question | Questions/sec |
| --- | --- | --- | --- | --- | --- | --- | --- |
| english | 1 | 32.73 | 0.39 | 32.62 | 33.54 | 32.73 | 30.6 |
| english | 5 | 42.27 | 0.78 | 42.49 | 43.51 | 8.45 | 118.3 |
| english | 10 | 71.27 | 1.21 | 71.34 | 72.78 | 7.13 | 140.3 |
| english | 50 | 285.84 | 1.73 | 286.60 | 287.76 | 5.72 | 174.9 |
| multilingual | 1 | 27.73 | 0.72 | 27.69 | 28.76 | 27.73 | 36.1 |
| multilingual | 5 | 30.13 | 0.40 | 30.10 | 30.65 | 6.03 | 165.9 |
| multilingual | 10 | 36.04 | 0.41 | 35.96 | 36.72 | 3.60 | 277.5 |
| multilingual | 50 | 142.45 | 1.07 | 142.23 | 144.45 | 2.85 | 351.0 |

The single-question rows come from a dedicated 30-sample run against an
already-warm process. In the original sweep the `english/1` cell ran first and
reported 44.76 ms with a standard deviation of 6.48 against roughly 1.0
everywhere else, which was the Triton warm-up being paid inside the measured
samples rather than a real result.

GPU memory was 3898 MiB after single-question inference and 4136 MiB after the
full sweep, of 15360 MiB available.

### Through the public endpoint

Same harness, called from the GPU host against the API Gateway hostname so
client-side network noise is excluded.

| Path | english/1 p50 | english/10 p50 |
| --- | --- | --- |
| Loopback, direct to the container | 32.62 ms | 71.34 ms |
| API Gateway, VPC link, internal ALB | 64.38 ms | 98.80 ms |

The managed HTTPS path adds a roughly fixed 30 ms.

### Against upstream's published table

Upstream's figures first, this repository's mean second.

| Questions | english upstream | english here | multilingual upstream | multilingual here |
| --- | --- | --- | --- | --- |
| 1 | 39.5 ms | 32.73 ms | 32.8 ms | 27.73 ms |
| 5 | 84.5 ms | 42.27 ms | 40.1 ms | 30.13 ms |
| 10 | 158.6 ms | 71.27 ms | 72.3 ms | 36.04 ms |
| 50 | 771 ms | 285.84 ms | 337 ms | 142.45 ms |

Batched performance here is 2.0 to 2.7 times better than upstream publishes at 10
and 50 questions per call, and peak throughput of 351 questions per second is
above the top of upstream's stated 103 to 332 range.

The most likely cause is the Triton dispatch path that torch 2.14 reaches and the
earlier 2.11 pin did not, which is consistent with single-question latency being
unchanged while batched latency improves sharply. This has not been isolated by
running both torch versions through the same sweep, so it is a hypothesis.

The single-question gap is **not** explained by the PyTorch version. The same
measurement gives 32.62 ms on torch 2.14 and 32.95 ms on torch 2.11, which are
statistically indistinguishable. The two harnesses are measuring different
things. Treat every figure above as this repository's own measurement under the
stated conditions, not as a reproduction of upstream's table.

## Correctness

| Check | Result |
| --- | --- |
| ECS registers the GPU | `GPU-2466d8d2-bfcb-0f84-a617-f7c224832a18` |
| Task and container health | `RUNNING`, `HEALTHY` |
| `GET /health` | HTTP 200, `{"status":"ok","loaded":["english","multilingual"],"device":"cuda"}` |
| `POST /v1/systemone`, no token | HTTP 401 |
| `POST /v1/systemone`, wrong token | HTTP 401 |
| `POST /v1/systemone`, valid token | HTTP 200, correct answer |
| Path preservation through API Gateway | `/v1/systemone` reaches Laya unchanged |
| `Authorization` forwarding | Preserved; the 401 and 200 cases prove it |
| Endpoint at zero GPU capacity | HTTP 503, correct with no backend |
| Scale to zero | Instance `terminated`, root volume deleted, ECS 0/0/0 |

The container health check asserts `torch.cuda.is_available()` before calling
`/health`, so a healthy task is direct evidence that PyTorch reached the GPU.

The support-ticket fixture routes to `billing` at probability 0.96 with
confidence 0.8474. That response is byte-identical to the earlier torch 2.11
run, so changing torch, transformers, and huggingface_hub did not change the
output.

## Cold start

| Phase | Duration |
| --- | --- |
| Task start to a serving process | 16 s |
| Of which checkpoint download | about 10 s |
| First authenticated request after container start | 2.98 s |
| Subsequent requests | 0.297 s |
| Stack creation, end to end | 371 to 524 s |
| Scale to zero | 55 s |

The image pull rather than checkpoint download dominates first-start time. The
2.98 s first request is Triton compiling its kernel; the cache now lives in the
mounted model volume, so that cost is paid once per host rather than once per
container start.

## Findings

**Torch 2.14 needs a C toolchain in the image.** On a GPU, Laya dispatches
through a Triton kernel (`_bmm_outer_product_kernel`) that is JIT-compiled at
runtime. Without a compiler the server starts, loads both checkpoints, answers
`/health`, reports healthy to ECS, and then fails every inference request with
`{"detail":"inference failed"}`. Upstream's 0.3.11 hardening deliberately does
not leak tracebacks, so the real error is only visible by reproducing inference
inside the container:

```text
RuntimeError: Failed to find C compiler.
```

Installing `gcc` alone is not enough. `--no-install-recommends` skips
`libc6-dev`, and the failure moves to `fatal error: stdlib.h: No such file or
directory`. The image installs both.

**PyTorch 2.14 is available, just not on cu128.** `torch==2.14.0` is absent from
the `cu128` wheel index but published to `cu126` and `cu130`. The image uses
`cu126`, which resolves the full upstream dependency set. `cu126` is preferred
over `cu130` because CUDA 12.6 requires an NVIDIA driver of 560 or newer while
CUDA 13.0 requires 580 or newer, and the ECS GPU AMI shipped exactly
`580.178.04`.

**The calibration warning is narrower than it looks.** Laya emits one warning at
load time:

```text
laya: this checkpoint ships invalid temperatures or values outside [0.5, 5];
using choice:11+=0.10058280825614929 -> 0.5.
```

Upstream refits temperatures per question type and option count, and confirms
`choice:11+` is the only bucket the clamp touches. The fixture uses a four-option
choice, so its confidence value is not from an affected bucket. The practical
consequence is limited to choice questions with eleven or more options, which
upstream advises against anyway.

**`cdk destroy` can fail on the capacity provider.** Deleting
`AWS::ECS::ClusterCapacityProviderAssociations` returns `ResourceInUseException`
even with zero services and zero tasks. Disassociate first:

```bash
aws ecs put-cluster-capacity-providers \
  --cluster <cluster> --capacity-providers --default-capacity-provider-strategy
```

**Unauthenticated Hugging Face downloads are rate limited.** Setting `HF_TOKEN`
would make repeated cold starts faster and more reliable.

## Security review

An IAM audit of the synthesized template found the scoped grants sound. The task
execution role can pull only this stack's image, write only to its log group, and
read only the generated secret. The task role holds no permissions. Remaining
wildcard actions are the standard ECS agent and drain-hook permissions.

Two defects were found by asserting the synthesized template and both are fixed.

`ApplicationLoadBalancer.addListener` defaults to `open: true` and adds its own
`0.0.0.0/0` ingress rule per listener. The first template therefore contained the
caller's `/32` allowlist entry *and* two wide-open entries, so an operator who
restricted access would have got an open endpoint. Both listeners now pass
`open: false` and all ingress is declared explicitly. The current design has no
CIDR-based rules at all.

The EC2 instance role was granted read access to the bearer token
unconditionally. It is now behind `hostBenchmarkAccess`, default off.

## Not verified

No accuracy claim is reproduced here. Upstream's benchmark figures, including the
banking77 result and the calibration numbers, are upstream's measurements.

Multilingual *quality* was never tested, only its latency. The fixture is English
and the router selects the English checkpoint.

Nothing concurrent was tested. Every measurement is sequential, and Laya
serialises inference through one worker.

The optional custom domain path with ACM and Route 53 is template-asserted but
has never been deployed against a live domain.

Cold start remains a single observation.
