# syntax=docker/dockerfile:1.4

ARG CUDA_VERSION=12.8.1
ARG IMAGE_TYPE=cudnn-devel
ARG OS_VERSION=ubuntu22.04
FROM nvcr.io/nvidia/cuda:${CUDA_VERSION}-${IMAGE_TYPE}-${OS_VERSION}

ARG PYTHON_VERSION=3.12

SHELL ["/usr/bin/bash", "-c"]

RUN mkdir -p /workspace

WORKDIR /workspace

# Install apt dependencies
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y \
    build-essential \
    cmake \
    curl \
    wget \
    git \
    zip \
    unzip \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /usr/local/src/* \
    && rm -rf /var/lib/apt/lists/*


# Build the Python environment
RUN touch ~/.bashrc && \
    curl -LsSf https://astral.sh/uv/install.sh | sh

ENV PATH="/root/.local/bin:${PATH}"
ENV UV_LINK_MODE=copy
ENV UV_COMPILE_BYTECODE=1
# ENV UV_NO_CACHE=1

# Finalize
CMD ["bash"]
