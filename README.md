# Flash Attention Pre-build

A comprehensive build system for pre-building Flash Attention wheel files across multiple PyTorch, CUDA, and GPU architecture combinations.

## Overview

This project uses [cibuildwheel](https://cibuildwheel.readthedocs.io/) to automatically build Flash Attention for various environments. It supports both Windows and Linux platforms, generating optimized wheels for different combinations of Python versions, PyTorch versions, CUDA versions, and GPU architectures (SM versions).

### Key Features
- CSV-based compatibility matrix for valid PyTorch/CUDA/SM combinations
- Automatic dependency resolution and version matching
- Support for latest GPU architectures including Blackwell (SM100/SM120)
- Intelligent build skipping for invalid or unsupported combinations
- Pattern-based existing wheel detection

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

## Quick Start

```bash
# Build with default settings
bash build_new.sh

# Build for specific versions
TORCH_VERSIONS="2.8" CUDA_VERSIONS="128" bash build_new.sh

# Build for specific architectures
CUDA_ARCHS="80 86 89 90" bash build_new.sh

# Windows-only build
PLATFORMS="windows" bash build_new.sh

# Rebuild existing wheels
OVERWRITE=true bash build_new.sh
```

Built wheel files will be placed in `wheelhouse/` directory with the naming format:
`flash_attn-<ver>+cu<cuda>torch<torch>sm<arch>-<py>-<py>-<platform>.whl`

## Configuration Variables

The behavior of build_new.sh can be controlled via environment variables:

### Basic Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `FA_REPO` | `https://github.com/Dao-AILab/flash-attention.git` | Flash Attention repository URL |
| `FA_VERSIONS` | `2.8.2` | Flash Attention versions to build (space-separated) |
| `TORCH_VERSIONS` | `2.8 2.7 2.6` | PyTorch versions (space-separated) |
| `CUDA_VERSIONS` | `126 128` | CUDA versions without 'cu' prefix (space-separated) |
| `CUDA_ARCHS` | `80 86 89 90 120` | SM architectures to build for (space-separated) |
| `PYTHON_VERSIONS` | `cp312 cp313` | Python versions for all platforms |
| `PLATFORMS` | `linux windows` | Target platforms (space-separated) |

### Build Performance

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_JOBS` | `32` | Number of parallel compilation jobs |
| `NVCC_THREADS` | `4` | Number of threads for NVCC compilation |
| `OVERWRITE` | `false` | Set to `true` to rebuild existing wheels |

### GPU Architecture Values (SM)
- `70`: Volta (V100)
- `75`: Turing (RTX 20xx, T4)
- `80`: Ampere (A100)
- `86`: Ampere (RTX 30xx, A40, L4)
- `89`: Ada Lovelace (RTX 40xx, L40)
- `90`: Hopper (H100, H200)
- `100`: Blackwell (B100, B200) - Requires PyTorch 2.8+ with CUDA 12.8+
- `120`: Blackwell (RTX 5090) - Requires PyTorch 2.8+ with CUDA 12.8+

## Examples

### Building Multiple Versions
```bash
FA_VERSIONS="2.8.2 2.8.3" TORCH_VERSIONS="2.7 2.8" bash build_new.sh
```

### Building for Specific GPU Architectures
```bash
# Modern GPUs only (Ampere and newer)
CUDA_ARCHS="80 86 89 90" bash build_new.sh

# Include Blackwell GPUs
CUDA_ARCHS="86 89 90 100 120" TORCH_VERSIONS="2.8" CUDA_VERSIONS="128" bash build_new.sh
```

### Building for All Python Versions
```bash
PYTHON_VERSIONS="cp310 cp311 cp312 cp313" bash build_new.sh
```

### Platform-Specific Builds
```bash
# Windows only with CUDA 12.6
PLATFORMS="windows" CUDA_VERSIONS="126" bash build_new.sh

# Linux only with latest CUDA
PLATFORMS="linux" CUDA_VERSIONS="128 129" bash build_new.sh
```

## Compatibility Matrix

The project uses `torch_cuda_sm_matrix.csv` to determine valid combinations. Key compatibility rules:

### PyTorch and CUDA Versions
| PyTorch | Available CUDA Versions | Notes |
|---------|------------------------|-------|
| 2.6.x | cu118, cu124, cu126 | - |
| 2.7.x | cu118, cu126, cu128 | cu128 adds Blackwell support |
| 2.8.x | cu126, cu128, cu129 | cu128/cu129 remove Maxwell/Pascal |

### Architecture Support Changes
- **PyTorch 2.8 + CUDA 12.8/12.9**: Removes support for Maxwell (SM5x) and Pascal (SM6x)
- **SM100/SM120 (Blackwell)**: Requires PyTorch 2.8+ with CUDA 12.8+
- **SM120**: Not supported in CUDA 12.6

## Troubleshooting

### CUDA Not Found on Windows
Ensure the environment variables `CUDA_PATH_V126`, `CUDA_PATH_V128`, `CUDA_PATH_V129` are correctly set:
```bash
export CUDA_PATH_V126="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.6"
export CUDA_PATH_V128="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"
```

### "No module named pip" Error on Windows
When using uvx, the script includes `--with pip` option. If you still encounter issues:
```bash
# Use direct pip installation instead of uvx
pip install cibuildwheel
python -m cibuildwheel --platform windows
```

### Build Failures
Check the compatibility matrix in `torch_cuda_sm_matrix.csv`. Invalid combinations will be skipped with informative messages.

### Slow Build
Adjust parallel jobs and NVCC threads:
```bash
MAX_JOBS=16 NVCC_THREADS=2 bash build_new.sh
```

## Directory Structure

```
.
├── build_new.sh              # Main build script
├── cibuildwheel.toml         # cibuildwheel configuration
├── torch_cuda_sm_matrix.csv  # Compatibility matrix
├── CLAUDE.md                 # Development notes and best practices
├── src/                      # Flash Attention source code (auto-cloned)
│   └── flash-attention-*/
└── wheelhouse/               # Built wheel files
    └── *.whl                 # Format: flash_attn-<ver>+cu<cuda>torch<torch>sm<arch>-<py>-<py>-<platform>.whl
```

## Key Files

- **build_new.sh**: Main orchestration script with compatibility checking
- **torch_cuda_sm_matrix.csv**: Defines valid PyTorch/CUDA/SM combinations
- **cibuildwheel.toml**: Platform-specific build configurations
- **CLAUDE.md**: Detailed development documentation and lessons learned

## License

This build script is MIT licensed. For Flash Attention's license, please refer to the [Flash Attention repository](https://github.com/Dao-AILab/flash-attention).