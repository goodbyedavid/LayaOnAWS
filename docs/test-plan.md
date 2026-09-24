# Test plan and evidence

## Acceptance criteria

The AWS verification is successful when all of these conditions hold:

1. The stack deploys through CloudFormation using an EC2 launch template.
2. Exactly one `g4dn.xlarge` registers with the ECS cluster.
3. The ECS task reaches `RUNNING` and reports healthy.
4. `nvidia-smi` identifies the NVIDIA T4.
5. PyTorch reports CUDA availability through the container health check.
6. `GET /health` returns HTTP 200.
7. An unauthenticated decision request is rejected.
8. An authenticated support-ticket request returns valid JSON.
9. English and multilingual model snapshot revisions are recorded.
10. Twenty warm inference samples produce min, p50, p95, and max latency.
11. GPU memory usage is recorded after inference.
12. ECS and Auto Scaling capacity return to zero.
13. No GPU EC2 instance remains pending, running, stopping, or stopped.

## Test matrix

| Test | Method | Expected result | Status |
| --- | --- | --- | --- |
| TypeScript compile | `npm run build` | No compiler errors | Passed |
| Shell syntax | `bash -n scripts/*.sh` | No syntax errors | Passed |
| Zero-capacity synth | `npm run synth` | Valid CloudFormation output | Passed |
| Launch-template assertion | Inspect synthesized resource types | Launch template present; launch configuration absent | Passed |
| Network assertion | Inspect launch template and security group | Public IP enabled; no inbound SG rule | Passed |
| CloudFormation validation | `validate-template` on earlier synthesized template | Accepted by API | Passed before launch-template revision |
| Live stack deployment | `cdk deploy -c capacity=1` | `CREATE_COMPLETE` using a launch template | Passed |
| Image build | Finch, `linux/amd64` | Image builds and dependency check passes | Passed |
| Package versions, image tested live | Inspect image | Laya 0.3.11, PyTorch 2.11.0+cu128, CUDA 12.8 | Passed |
| Package versions, current image | Inspect image | Laya 0.3.11, PyTorch 2.14.0+cu126, transformers 5.17.0, huggingface_hub 1.32.0 | Passed, verified live on a T4 |
| Local health | Run without model preload | `/health` returns 200 | Passed |
| Local authentication | Unauthenticated `/v1/systemone` | HTTP 401 | Passed |
| AWS GPU registration | ECS and `nvidia-smi` | T4 available to task | Passed |
| Model preload | Laya health and logs | English and multilingual loaded | Passed |
| Real inference | Support-ticket fixture | Valid authenticated response | Passed |
| Warm latency | 1 warm-up + 20 measured calls | Report min/p50/p95/max | Passed |
| GPU memory | `nvidia-smi` after calls | Memory usage recorded | Passed |
| Cost shutdown | Capacity zero checks | No active GPU instance | Passed |
| Public HTTPS endpoint | API Gateway end to end | 200 health, 401 unauth, 200 authenticated | Passed |
| Path and header preservation | Call /v1/systemone through API Gateway | Path and Authorization reach Laya unchanged | Passed |
| Unauthenticated rejection on GPU | Live request without a token | HTTP 401 | Passed |
| Questions-per-call sweep | 1/5/10/50 on both checkpoints | min/mean/stdev/p50/p95 recorded | Passed |
| Endpoint at zero capacity | Call health with no backend | HTTP 503 | Passed |
| Custom domain | ACM plus Route 53 | Template asserted only | Not tested live |

## Local evidence

The built `linux/amd64` image contains:

```text
Laya: 0.3.11
PyTorch: 2.11.0+cu128
CUDA runtime: 12.8
Approximate uncompressed image size: 7.50 GB
```

The local smoke run disabled model preload. It established that the server
starts, the health route responds with HTTP 200, and bearer authentication
rejects an unauthenticated decision request with HTTP 401.

The current synthesized stack was checked programmatically for:

- `AWS::EC2::LaunchTemplate` present.
- `AWS::AutoScaling::LaunchConfiguration` absent.
- Public IPv4 association enabled in the launch template.
- No inbound rules in the instance security group.

## Automated live test

`scripts/verify-remote.sh` performs the live checks through Systems Manager.
It does not include the bearer token in the SSM command parameters. The remote
shell retrieves the secret using the scoped instance role and passes it to a
temporary Python benchmark process through an environment variable.

The script reports:

```text
GPU name, total memory, and driver version
/health response
20-request warm latency: min, p50, p95, max
Hugging Face snapshot revision identifiers
One complete Laya response
Post-inference GPU memory usage
```

The fixture is
[`examples/support-ticket.json`](../examples/support-ticket.json).

## Deployment failures already found

### ECS health-check start period

The first CloudFormation deployment was rejected because the initial
health-check `startPeriod` exceeded the ECS limit. The stack now uses the
maximum supported value of 300 seconds.

### Legacy Auto Scaling launch configuration

The second CloudFormation deployment was rejected because this AWS account no
longer permits creation of Auto Scaling launch configurations. The stack now
creates `AWS::EC2::LaunchTemplate` and attaches it to the Auto Scaling group.
The corrected template deployed successfully on 2026-09-23 and reached
`CREATE_COMPLETE`.

Both failures occurred before a GPU instance was launched.

## Dependency finding, resolved

The reviewed upstream Dockerfile defaults to PyTorch `2.14.0`. That version is
not published to the CUDA 12.8 wheel index, which initially led to pinning
`2.11.0`.

It is published to the `cu126` and `cu130` indexes. The image now installs
`torch==2.14.0` from `cu126`, which resolves `transformers` 5.17.0 and
`huggingface_hub` 1.32.0 and therefore matches upstream's stated dependency set
exactly. `cu126` is preferred over `cu130` because CUDA 12.6 requires an NVIDIA
driver of 560 or newer while CUDA 13.0 requires 580 or newer, and the ECS GPU AMI
shipped `580.178.04`.

There is no longer a PyTorch version difference to disclose.

Torch 2.14 does introduce a requirement: on a GPU, Laya dispatches through a
Triton kernel that is JIT-compiled at runtime, so the image must contain `gcc`
and `libc6-dev`. Without them the server starts, loads both checkpoints, and
answers `/health`, but every inference fails.

The live run also surfaced a checkpoint calibration warning scoped to choice
questions with eleven or more options, which the fixture did not exercise. See
the findings in [`verification-notes.md`](verification-notes.md).

## Evidence to retain after the live run

Copy the following into `docs/verification-notes.md`:

1. Deployment start, ECS registration, task start, and healthy timestamps.
2. EC2 AMI ID, instance type, NVIDIA driver, and GPU model.
3. Container image digest.
4. Laya, PyTorch, and CUDA versions.
5. Model snapshot revision identifiers.
6. Health response.
7. Redacted inference request and complete response.
8. Warm min, p50, p95, and max latency.
9. GPU memory after both models are resident.
10. Scale-down timestamp and zero-capacity evidence.
11. CloudWatch log excerpts for any warnings or errors.

Do not record the generated bearer token or local AWS secret values.
