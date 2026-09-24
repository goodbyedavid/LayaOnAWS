# Laya on AWS - 3D architecture diagram

The editable source is [`laya-aws-architecture-3d.drawio`](laya-aws-architecture-3d.drawio).
Open it in diagrams.net or draw.io Desktop with the AWS 3D shape library
enabled.

## What the diagram shows

The primary request path is:

1. A Jev-compatible client sends an HTTPS request with the Laya bearer token.
2. Amazon API Gateway receives the request on its generated public HTTPS
   endpoint and applies request throttling.
3. An API Gateway VPC Link reaches an internal Application Load Balancer.
4. Security-group-to-security-group rules permit the VPC Link to reach the ALB
   on port 80 and the ALB to reach the GPU host on port 8000.
5. The ALB forwards the request to the Laya ECS task running on a
   `g4dn.xlarge`.

The private operations path is:

1. An authorized operator uses the AWS CLI and Systems Manager Session Manager.
2. Session Manager creates a tunnel to the EC2 container instance without
   opening an inbound administration port.
3. The operator reaches Laya through `localhost:8000`.

Supporting flows show Secrets Manager injecting the bearer token, ECR supplying
the container image, CloudWatch receiving container logs, S3 receiving ALB
access logs, and the Laya workload downloading model checkpoints from Hugging
Face through the internet gateway.

## Capacity and network semantics

- The VPC has public subnets in two Availability Zones and no NAT gateway.
- The internal ALB spans both public subnets.
- The ECS EC2 capacity provider and Auto Scaling group can place the GPU host
  in either AZ.
- Desired capacity is zero by default and the maximum is one `g4dn.xlarge`;
  the diagram does not imply two GPU instances.
- A live verification run must finish with ECS and Auto Scaling desired
  capacity at zero and no active stack-owned GPU instance.

## Optional custom domain

Route 53 and AWS Certificate Manager are shown with amber dashed connections.
The custom-domain implementation is code complete but has not been live-tested,
so it is visually separated from the verified API Gateway hostname path.

## 3D stencil substitutions

The legacy native draw.io `mxgraph.aws3d` library does not provide current
service-specific artwork for every service used by this stack. The diagram
therefore uses the native `mxgraph.aws3d.application` isometric stencil for
service tiles, with explicit service labels and AWS category colors. It does
not substitute flat AWS4 icons or hand-drawn platforms.

| Color | Category represented |
| --- | --- |
| Purple | Networking and content delivery |
| Orange | Compute and containers |
| Pink | Management, logging, and API ingress |
| Red | Security and secrets |
| Green | Storage and the Laya application |
| Blue or gray | External callers |
| Amber dashed | Optional, not live-tested |

## Source of truth

This view is based on [`architecture.md`](architecture.md),
[`verification-notes.md`](verification-notes.md), and the deployment behavior
documented in the project [`README.md`](../README.md). Measured software and
hardware labels in the diagram use the conditions recorded in the verification
notes.
