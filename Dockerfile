ARG PYTHON_IMAGE=python:3.11-slim-bookworm

FROM ${PYTHON_IMAGE} AS build

# Upstream Laya expects torch 2.14 alongside transformers 5.x and
# huggingface_hub 1.x. torch 2.14.0 is not published to the cu128 wheel index,
# but it is published to cu126 and cu130. cu126 is chosen over cu130 because
# CUDA 12.6 requires an NVIDIA driver of 560 or newer, while CUDA 13.0 requires
# 580 or newer. The ECS GPU AMI shipped 580.178.04 at the time of writing, so
# cu126 leaves headroom for customers running an older AMI. CUDA 12.6 also
# retains broad support for the Turing T4 in g4dn instances.
ARG TORCH_VERSION=2.14.0
ARG TORCH_INDEX=cu126
ARG LAYA_VERSION=0.3.11

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN python -m pip install "torch==${TORCH_VERSION}" \
      --index-url "https://download.pytorch.org/whl/${TORCH_INDEX}" \
    && python -m pip install "laya[serve]==${LAYA_VERSION}" \
    && python -m pip check

FROM ${PYTHON_IMAGE} AS runtime

LABEL org.opencontainers.image.title="Laya AWS verification" \
      org.opencontainers.image.source="https://github.com/NandhaKishorM/laya" \
      org.opencontainers.image.version="0.3.11" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    USE_TF=0 \
    USE_TORCH=1 \
    TOKENIZERS_PARALLELISM=false \
    OMP_NUM_THREADS=4 \
    HF_HOME=/home/laya/.cache/huggingface \
    # Triton compiles its CUDA utility module on first use. Keeping the cache
    # inside the mounted model-cache volume means the compilation is paid once
    # per host rather than once per container start.
    TRITON_CACHE_DIR=/home/laya/.cache/huggingface/.triton

# On a GPU, Laya dispatches through a Triton kernel, and Triton JIT-compiles a
# small C extension at runtime. That needs a C compiler and the libc headers,
# neither of which ships in the slim Python base image. Without them the server
# starts, loads both checkpoints, and answers /health, but every inference
# request fails with "Failed to find C compiler", which is easy to mistake for a
# model problem. `libc6-dev` is required explicitly because installing `gcc`
# with --no-install-recommends does not pull it in, and the failure then moves
# from a missing compiler to a missing stdlib.h.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 laya \
    && useradd --uid 10001 --gid laya --create-home laya \
    && mkdir -p /home/laya/.cache/huggingface \
    && chown -R laya:laya /home/laya

COPY --from=build /opt/venv /opt/venv

USER laya
WORKDIR /home/laya
EXPOSE 8000

CMD ["laya-serve"]
