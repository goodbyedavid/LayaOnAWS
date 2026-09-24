# Third-party notices

This repository contains AWS infrastructure code that deploys third-party
software. It does not redistribute that software. The container image is built
at deploy time from public package indexes, and model weights are downloaded at
first run.

## Laya

[Laya](https://github.com/NandhaKishorM/laya) is licensed under Apache-2.0 and
is installed from PyPI as `laya[serve]` during the container build.
This repository is not affiliated with or endorsed by the Laya maintainers.

Laya is an independent open-source project maintained outside AWS.
Evaluate its suitability, security posture, and support model against your own
requirements before production use.

## Model weights

Model checkpoints are downloaded at first container start from the Hugging Face
repository `convaiinnovations/laya`.
Review the model card and its license terms before deploying.
Weights are not redistributed here, and this project does not pin a checkpoint
revision, because the current `laya-serve` contract does not expose that
control.

For production use, mirror the checkpoints you validated into your own Amazon S3
bucket or container image so that deployments do not depend on an external
download at runtime.

## PyTorch

PyTorch is installed from the official PyTorch CUDA 12.6 wheel index and is
licensed under its own BSD-style license.

## AWS

Amazon Web Services, AWS, and related marks are property of Amazon.com, Inc. or
its affiliates. This is a personal project and is not an official AWS
publication.
