# Flash Attention Pre-build

A comprehensive build system for pre-building Flash Attention wheel files across multiple PyTorch, CUDA, and GPU architecture combinations.

## Overview

This project uses [cibuildwheel](https://cibuildwheel.readthedocs.io/) to automatically build Flash Attention for various environments. It supports both Windows and Linux platforms, generating optimized wheels for different combinations of Python versions, PyTorch versions, CUDA versions, and GPU architectures (SM versions).

### Build Scripts

The project provides two build scripts with different strategies:

1. **`build.sh`** - Multi-architecture build (recommended for general use)
   - Builds wheels containing multiple GPU architectures in a single file
   - Output: `flash_attn-2.8.2+cu126torch2.8-cp312-cp312-manylinux_2_24_x86_64.whl`
   - Smaller total download size, automatic architecture selection at runtime

2. **`build_per_sm.sh`** - Single-architecture build
   - Builds separate wheels for each GPU architecture
   - Output: `flash_attn-2.8.2+cu126torch2.8sm86-cp312-cp312-linux_x86_64.whl`
   - More granular control, smaller individual file sizes

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

### Multi-Architecture Build (Recommended)

```bash
# Build with default settings
bash build.sh

# Build for specific versions
TORCH_VERSIONS="2.8" CUDA_VERSIONS="128" bash build.sh

# Build for specific architectures (will be combined into single wheels)
CUDA_ARCHS="80 86 89 90" bash build.sh

# Windows-only build
PLATFORMS="windows" bash build.sh

# Rebuild existing wheels
OVERWRITE=true bash build.sh
```

Output format: `flash_attn-<ver>+cu<cuda>torch<torch>-<py>-<py>-<platform>.whl`

### Per-Architecture Build

```bash
# Build separate wheels for each architecture
bash build_per_sm.sh

# Build for specific architectures only
CUDA_ARCHS="86 89" bash build_per_sm.sh

# Build for specific CUDA/PyTorch versions
TORCH_VERSIONS="2.8" CUDA_VERSIONS="128" bash build_per_sm.sh
```

Output format: `flash_attn-<ver>+cu<cuda>torch<torch>sm<arch>-<py>-<py>-<platform>.whl`

Built wheel files will be placed in `dist/` directory.

## Configuration Variables

The behavior of both build scripts can be controlled via environment variables:

### Basic Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `FA_REPO` | `https://github.com/Dao-AILab/flash-attention.git` | Flash Attention repository URL |
| `FA_VERSIONS` | `2.8.2 2.8.3` | Flash Attention versions to build (space-separated) |
| `TORCH_VERSIONS` | `2.8 2.6` | PyTorch versions (space-separated) |
| `CUDA_VERSIONS` | `126 128 129` | CUDA versions without 'cu' prefix (space-separated) |
| `CUDA_ARCHS` | `80 86 89 120` | SM architectures to build for (space-separated) |
| `PYTHON_VERSIONS` | `cp312 cp313` | Python versions for all platforms |
| `PLATFORMS` | `linux` | Target platforms (space-separated) |

### Build Performance

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_JOBS` | `12` | Number of parallel compilation jobs |
| `NVCC_THREADS` | `2` | Number of threads for NVCC compilation |
| `OVERWRITE` | `false` | Set to `true` to rebuild existing wheels |

### GPU Architecture Values (SM)
- `80`: Ampere (A100)
- `86`: Ampere (RTX 30xx, A40, L4)
- `89`: Ada Lovelace (RTX 40xx, L40)
- `90`: Hopper (H100, H200)
- `100`: Blackwell (B100, B200) - Requires PyTorch 2.8+ with CUDA 12.8+
- `120`: Blackwell (RTX 5090) - Requires PyTorch 2.8+ with CUDA 12.8+

Note: SM70/75 (Volta/Turing) and older architectures are not included in default builds

## Examples

### Building Multiple Versions
```bash
FA_VERSIONS="2.8.2 2.8.3" TORCH_VERSIONS="2.7 2.8" bash build.sh
```

### Building for Specific GPU Architectures
```bash
# Modern GPUs only (Ampere and newer)
CUDA_ARCHS="80 86 89 90" bash build.sh

# Include Blackwell GPUs
CUDA_ARCHS="86 89 90 100 120" TORCH_VERSIONS="2.8" CUDA_VERSIONS="128" bash build.sh
```

### Building for All Python Versions
```bash
PYTHON_VERSIONS="cp310 cp311 cp312 cp313" bash build.sh
```

### Platform-Specific Builds
```bash
# Windows only with CUDA 12.6
PLATFORMS="windows" CUDA_VERSIONS="126" bash build.sh

# Linux only with latest CUDA
PLATFORMS="linux" CUDA_VERSIONS="128 129" bash build.sh
```

## Compatibility Matrix

The project uses `torch_cuda_sm_matrix.csv` to determine valid combinations. Key compatibility rules:

### PyTorch and CUDA Versions
| PyTorch | Available CUDA Versions | Notes |
|---------|------------------------|-------|
| 2.6.x | cu126 | Stable release |
| 2.8.x | cu126, cu128, cu129 | cu128/cu129 adds Blackwell support |

### Architecture Support by CUDA Version
| CUDA | Supported Architectures | Notes |
|------|------------------------|-------|
| 12.6 | SM80, SM86, SM89, SM90 | No Blackwell support |
| 12.8 | SM80, SM86, SM89, SM90, SM100, SM120 | Full Blackwell support |
| 12.9 | SM80, SM86, SM89, SM90, SM100, SM120 | Latest version |

### Architecture Support Changes
- **PyTorch 2.8 + CUDA 12.8/12.9**: Removes support for Maxwell (SM5x) and Pascal (SM6x)
- **SM100/SM120 (Blackwell)**: Requires PyTorch 2.8+ with CUDA 12.8+
- **SM89 (RTX 4090)**: Supported across all CUDA versions

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
MAX_JOBS=16 NVCC_THREADS=2 bash build.sh
```

## Directory Structure

```
.
├── build.sh                  # Multi-architecture build script
├── build_per_sm.sh          # Per-architecture build script
├── cibuildwheel.toml        # cibuildwheel configuration
├── torch_cuda_sm_matrix.csv # Compatibility matrix
├── CLAUDE.md                # Development documentation
├── src/                     # Flash Attention source code (auto-cloned)
│   ├── flash-attention-2.8.2/
│   └── flash-attention-2.8.3/
├── dist/                    # Multi-architecture wheels
│   └── *.whl               # Format: flash_attn-{ver}+cu{cuda}torch{torch}-{py}-{py}-{platform}.whl
└── wheelhouse/             # Per-architecture wheels
    └── *.whl               # Format: flash_attn-{ver}+cu{cuda}torch{torch}sm{arch}-{py}-{py}-{platform}.whl
```

## Key Files

- **build.sh**: Multi-architecture build script that combines multiple GPU architectures into single wheels
- **build_per_sm.sh**: Per-architecture build script that creates separate wheels for each GPU architecture
- **torch_cuda_sm_matrix.csv**: Defines valid PyTorch/CUDA/SM combinations
- **cibuildwheel.toml**: Platform-specific build configurations
- **CLAUDE.md**: Detailed development documentation and lessons learned

## License

This build script is MIT licensed. For Flash Attention's license, please refer to the [Flash Attention repository](https://github.com/Dao-AILab/flash-attention).