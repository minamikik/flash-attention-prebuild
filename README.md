# Flash Attention Pre-build

A build system for pre-building Flash Attention wheel files for multiple PyTorch/CUDA version combinations.

## Overview

This project uses [cibuildwheel](https://cibuildwheel.readthedocs.io/) to automatically build Flash Attention for various environments. It supports both Windows and Linux, generating wheels for multiple combinations of Python, PyTorch, and CUDA versions.

## Requirements

### Windows
- Git Bash (Git for Windows)
- Docker Desktop (WSL2 backend)
- CUDA Toolkit (multiple versions can be installed side-by-side)
  - Environment variables `CUDA_PATH_V126`, `CUDA_PATH_V128`, `CUDA_PATH_V129` must be set
- Visual Studio 2022 or Build Tools for Visual Studio 2022

### Linux
- Docker
- Git

## Usage

```bash
bash build.sh
```

Built wheel files will be placed in `wheelhouse/fa<version>/torch<series>/cu<xxx>/` directories.

## build.sh Configuration Variables

The behavior of build.sh can be controlled via environment variables. The following variables are available:

### Basic Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `FA_REPO_URL` | `https://github.com/Dao-AILab/flash-attention.git` | Flash Attention repository URL |
| `FA_VERSIONS` | `2.8.2` | Flash Attention versions to build (space-separated for multiple) |
| `TORCH_SERIES` | `2.8` | Target PyTorch major.minor versions (space-separated for multiple) |
| `CUDA_SETS` | `126 128` | CUDA versions to build (126=12.6, 128=12.8, 129=12.9) |

### Python Versions

| Variable | Default | Description |
|----------|---------|-------------|
| `PY_WIN` | `cp312` | Python versions for Windows builds (e.g., cp310 cp311 cp312) |
| `PY_LINUX` | `cp312` | Python versions for Linux builds (e.g., cp310 cp311 cp312) |

### Docker Images (for Linux builds)

| Variable | Default | Description |
|----------|---------|-------------|
| `LINUX_IMAGE_CU126` | `pytorch/manylinux2_28-builder:cuda12.6` | Docker image for CUDA 12.6 |
| `LINUX_IMAGE_CU128` | `pytorch/manylinux2_28-builder:cuda12.8` | Docker image for CUDA 12.8 |
| `LINUX_IMAGE_CU129` | `pytorch/manylinux2_28-builder:cuda12.9` | Docker image for CUDA 12.9 |
| `ALT_LINUX_IMAGE_CU*` | `sameli/manylinux_2_34_x86_64_cuda_*` | Alternative Docker images (fallback) |

### Build Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_JOBS` | `48` | Number of parallel jobs during build |
| `TORCH_CUDA_ARCH_LIST` | `8.6` | Target GPU architectures (semicolon-separated) |

### GPU Architecture Values
- `75`: Turing (RTX 20xx)
- `80`: Ampere (A100)
- `86`: Ampere (L4, RTX 30xx)
- `89`: Ada Lovelace (RTX 40xx)
- `90`: Hopper (H100)
- `120`: Blackwell

## Examples

### Building Multiple Versions
```bash
FA_VERSIONS="2.8.2 2.8.3" TORCH_SERIES="2.7 2.8" bash build.sh
```

### Building for Specific GPU Architectures
```bash
TORCH_CUDA_ARCH_LIST="80;86;89;90" bash build.sh
```

### Building for All Python Versions
```bash
PY_WIN="cp310 cp311 cp312" PY_LINUX="cp310 cp311 cp312" bash build.sh
```

### Windows Only Build (CUDA 12.6 only)
```bash
CUDA_SETS="126" bash build.sh
```

## PyTorch and CUDA Compatibility Matrix

| PyTorch | Available CUDA Versions |
|---------|------------------------|
| 2.6.x | cu126 |
| 2.7.x | cu126, cu128 |
| 2.8.x | cu126, cu128, cu129 |

## Troubleshooting

### CUDA Not Found on Windows
Ensure the environment variables `CUDA_PATH_V126`, `CUDA_PATH_V128`, `CUDA_PATH_V129` are correctly set:
```bash
export CUDA_PATH_V126="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.6"
export CUDA_PATH_V128="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"
```

### Docker Image Not Found
If PyTorch official images are not available, the script will automatically fall back to alternative images (`sameli/manylinux_2_34_*`).

### Slow Build
Adjust `MAX_JOBS`:
```bash
MAX_JOBS=16 bash build.sh
```

## Directory Structure

```
.
├── build.sh              # Main build script
├── cibuildwheel.toml     # cibuildwheel configuration
├── pyproject.toml        # Project configuration
├── src/                  # Flash Attention source code (auto-generated)
│   └── flash-attention-*/
└── wheelhouse/           # Built wheel files
    └── fa*/
        └── torch*/
            └── cu*/
                └── *.whl
```

## License

This build script is MIT licensed. For Flash Attention's license, please refer to the [Flash Attention repository](https://github.com/Dao-AILab/flash-attention).