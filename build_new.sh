#!/usr/bin/env bash
# Build Flash Attention wheels for multiple configurations
set -euo pipefail

# Install uv if needed
curl -LsSf https://astral.sh/uv/install.sh | sh
export CIBW_BUILD_VERBOSITY=3

# ======== Configuration ========
: "${FA_REPO:=https://github.com/Dao-AILab/flash-attention.git}"
: "${FA_VERSIONS:=2.8.2}"
: "${TORCH_VERSIONS:=2.8 2.7 2.6}"
: "${CUDA_VERSIONS:=126 128}"
: "${CUDA_ARCHS:=80 86 89 90 120}"  # SM values
: "${PYTHON_VERSIONS:=cp312 cp313}"
: "${PLATFORMS:=linux windows}"
: "${MAX_JOBS:=32}"
: "${NVCC_THREADS:=4}"
: "${OVERWRITE:=false}"  # Set to true to rebuild existing wheels

# Directories
ROOT_DIR="$(pwd)"
SRC_DIR="${ROOT_DIR}/src"
OUT_DIR="${ROOT_DIR}/wheelhouse"
CONFIG_FILE="${ROOT_DIR}/cibuildwheel.toml"

# Docker images for Linux
declare -A LINUX_IMAGES=(
  [126]="pytorch/manylinux2_28-builder:cuda12.6"
  [128]="pytorch/manylinux2_28-builder:cuda12.8"
  [129]="pytorch/manylinux2_28-builder:cuda12.9"
)

# ======== Helper Functions ========
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# Check prerequisites
command -v git >/dev/null || die "git is required"
command -v docker >/dev/null || die "Docker is required"

# Check PyTorch/CUDA compatibility
is_valid_combo() {
  local torch=$1 cuda=$2
  case "${torch}-${cuda}" in
    2.6-126|2.7-126|2.7-128|2.8-126|2.8-128|2.8-129) return 0 ;;
    *) return 1 ;;
  esac
}

# Check PyTorch/SM architecture compatibility
# Based on official PyTorch CUDA architecture support
is_valid_arch() {
  local torch=$1 cuda=$2 arch=$3
  
  # Blackwell architecture support (SM100 for B100/B200, SM120 for RTX 5090):
  # - PyTorch 2.8+ supports both SM100 and SM120
  # - SM120 is NOT supported in CUDA 12.6
  if [[ "$arch" == "100" || "$arch" == "120" ]]; then
    local gpu_type="B100/B200"
    [[ "$arch" == "120" ]] && gpu_type="RTX 5090"
    
    # SM120 is not supported in CUDA 12.6
    if [[ "$arch" == "120" && "$cuda" == "126" ]]; then
      log "Skip: SM${arch} (${gpu_type}) is not supported in CUDA 12.6"
      return 1
    fi
    
    # SM100 and SM120 require PyTorch 2.8+
    if [[ "$torch" == "2.8" ]] && [[ "$cuda" == "128" || "$cuda" == "129" ]]; then
      log "Info: SM${arch} (Blackwell ${gpu_type}) supported in PyTorch ${torch} with CUDA 12.${cuda:2}"
      return 0
    else
      log "Skip: SM${arch} (Blackwell ${gpu_type}) requires PyTorch 2.8+ with CUDA 12.8+"
      return 1
    fi
  fi
  
  # PyTorch 2.8+ with CUDA 12.8/12.9 removes Maxwell (5x) and Pascal (6x) support
  if [[ "$torch" == "2.8" ]] && [[ "$cuda" == "128" || "$cuda" == "129" ]]; then
    case "$arch" in
      50|52|53)  # Maxwell
        log "Skip: SM${arch} (Maxwell) not supported in PyTorch ${torch} with CUDA 12.${cuda:2}"
        return 1 ;;
      60|61|62)  # Pascal
        log "Skip: SM${arch} (Pascal) not supported in PyTorch ${torch} with CUDA 12.${cuda:2}"
        return 1 ;;
    esac
  fi
  
  # Supported architectures:
  # PyTorch 2.1-2.6: SM50, SM60, SM70, SM75, SM80, SM86, SM89, SM90
  # PyTorch 2.8+: SM50, SM60, SM70, SM75, SM80, SM86, SM89, SM90, SM100, SM120
  # Note: Maxwell (5x) and Pascal (6x) are removed in PyTorch 2.8 with CUDA 12.8/12.9
  
  # Common supported architectures
  case "$arch" in
    70|75|80|86|89|90) return 0 ;;  # Volta/Turing/Ampere/Ada/Hopper
    50|52|53|60|61|62)  # Maxwell/Pascal - check version compatibility
      if [[ "$torch" == "2.6" || "$torch" == "2.7" ]]; then
        return 0
      fi
      ;;
  esac
  
  # Unknown architecture - skip with warning
  log "Warning: Unknown architecture SM${arch} - skipping"
  return 1
}

# Convert arch to decimal (86->8.6, 120->12.0)
arch_to_decimal() {
  local arch=$1
  if [[ ${#arch} -eq 2 ]]; then
    echo "${arch:0:1}.${arch:1}"
  else
    echo "${arch:0:2}.${arch:2}"
  fi
}

# Setup Windows CUDA
setup_cuda_win() {
  local cuda=$1
  local var="CUDA_PATH_V${cuda}"
  local path="${!var:-}"
  [[ -z "$path" ]] && return 1
  export CUDA_PATH="$path"
  export CUDACXX="${CUDA_PATH}/bin/nvcc.exe"
  [[ "$OSTYPE" =~ ^(msys|cygwin) ]] && export PATH="${CUDA_PATH}/bin:${PATH}"
  return 0
}

# Clone Flash Attention source
get_source() {
  local ver=$1
  local dir="${SRC_DIR}/flash-attention-${ver}"
  
  [[ -d "$dir" ]] && { log "Source exists: $dir"; return; }
  
  # Try v-prefixed tag first
  for tag in "v${ver}" "${ver}"; do
    if git ls-remote --tags "${FA_REPO}" | grep -q "refs/tags/${tag}$"; then
      log "Cloning ${tag}"
      git clone --depth 1 --branch "${tag}" "${FA_REPO}" "$dir"
      return
    fi
  done
  
  die "Tag not found for version ${ver}"
}

# Get expected wheel filename
get_wheel_name() {
  local fa_ver=$1 torch=$2 cuda=$3 arch=$4 pyver=$5 os=$6
  local plat
  [[ "$os" == "linux" ]] && plat="linux_x86_64" || plat="win_amd64"
  echo "flash_attn-${fa_ver}+cu${cuda}torch${torch}sm${arch}-${pyver}-${pyver}-${plat}.whl"
}

# Build single wheel
build_wheel() {
  local fa_ver=$1 torch=$2 cuda=$3 arch=$4 pyver=$5 os=$6
  
  # Check if already exists
  local pattern="flash_attn-${fa_ver}+cu${cuda}torch${torch}sm${arch}-${pyver}-${pyver}-*.whl"
  if ls "${OUT_DIR}"/${pattern} >/dev/null 2>&1 && [[ "$OVERWRITE" != "true" ]]; then
    log "Skip: wheel already exists matching pattern: $pattern"
    return 0
  fi
  
  local src="${SRC_DIR}/flash-attention-${fa_ver}"
  local torch_arch=$(arch_to_decimal "$arch")
  
  # Platform-specific settings
  local platform build_tag image
  if [[ "$os" == "linux" ]]; then
    platform="linux"
    build_tag="${pyver}-manylinux_x86_64"
    image="${LINUX_IMAGES[$cuda]}"
    [[ -z "$image" ]] && { log "No Linux image for CUDA $cuda"; return 1; }
  else
    platform="windows"
    build_tag="${pyver}-win_amd64"
    setup_cuda_win "$cuda" || { log "CUDA $cuda not configured on Windows"; return 1; }
  fi
  
  log "Building: flash_attn-${fa_ver}+cu${cuda}torch${torch}sm${arch}-${pyver}-${pyver}-${os}"
  
  # Common environment
  local env="MAX_JOBS=${MAX_JOBS} NVCC_THREADS=${NVCC_THREADS} \
    TORCH_CUDA_ARCH_LIST='${torch_arch}' FLASH_ATTN_CUDA_ARCHS='${arch}' \
    TORCH_SPEC=${torch}.* CUDA_CHANNEL=cu${cuda}"
  
  # Build
  if [[ "$os" == "linux" ]]; then
    CIBW_PLATFORM=$platform \
    CIBW_BUILD="$build_tag" \
    CIBW_OUTPUT_DIR="$OUT_DIR" \
    CIBW_MANYLINUX_X86_64_IMAGE="$image" \
    CIBW_ENVIRONMENT="$env CXXFLAGS='-D_GLIBCXX_USE_CXX11_ABI=1'" \
    uvx --with pip cibuildwheel --platform $platform --config-file "$CONFIG_FILE" "$src" || {
      log "ERROR: Build failed for ${fa_ver}+cu${cuda}torch${torch}sm${arch}-${pyver}-${os}"
      return 1
    }
  else
    CIBW_PLATFORM=$platform \
    CIBW_BUILD="$build_tag" \
    CIBW_OUTPUT_DIR="$OUT_DIR" \
    CIBW_ENVIRONMENT_WINDOWS="$env CMAKE_GENERATOR=Ninja" \
    uvx --with pip cibuildwheel --platform $platform --config-file "$CONFIG_FILE" "$src" || {
      log "ERROR: Build failed for ${fa_ver}+cu${cuda}torch${torch}sm${arch}-${pyver}-${os}"
      return 1
    }
  fi
  
  # Rename wheel to include build info
  for wheel in "$OUT_DIR"/*.whl; do
    [[ ! -f "$wheel" ]] && continue
    local base=$(basename "$wheel")
    # Skip if already renamed
    [[ "$base" == *"+cu"* ]] && continue
    # flash_attn-2.8.2-cp312-cp312-linux_x86_64.whl -> flash_attn-2.8.2+cu126torch2.8sm86-cp312-cp312-linux_x86_64.whl
    if [[ "$base" =~ ^(flash_attn)-([0-9.]+)-(.*)$ ]]; then
      local new_name="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}+cu${cuda}torch${torch}sm${arch}-${BASH_REMATCH[3]}"
      mv -v "$wheel" "$OUT_DIR/$new_name"
    fi
  done
}

# ======== Main ========
log "Preparing sources..."
mkdir -p "$SRC_DIR" "$OUT_DIR"
for ver in $FA_VERSIONS; do
  get_source "$ver"
done

log "Building wheels..."
for fa_ver in $FA_VERSIONS; do
  for torch in $TORCH_VERSIONS; do
    for cuda in $CUDA_VERSIONS; do
      is_valid_combo "$torch" "$cuda" || continue
      
      for arch in $CUDA_ARCHS; do
        # Skip invalid architecture combinations
        is_valid_arch "$torch" "$cuda" "$arch" || continue
        
        for platform in $PLATFORMS; do
          for pyver in $PYTHON_VERSIONS; do
            build_wheel "$fa_ver" "$torch" "$cuda" "$arch" "$pyver" "$platform" || true
          done
        done
      done
    done
  done
done

log "✅ Complete! Wheels in: ${OUT_DIR}/"
log "Format: flash_attn-<ver>+cu<cuda>torch<torch>sm<arch>-<py>-<py>-<platform>.whl"