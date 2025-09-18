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

# Load PyTorch/CUDA/SM compatibility matrix from CSV
declare -A COMPAT_MATRIX
load_compatibility_matrix() {
  local csv_file="${ROOT_DIR}/torch_cuda_sm_matrix.csv"
  [[ ! -f "$csv_file" ]] && die "Compatibility matrix not found: $csv_file"
  
  # Skip header and load data
  while IFS=, read -r torch cuda sm channel; do
    # Normalize values
    local cuda_norm="${cuda#cu}"  # Remove 'cu' prefix
    local sm_norm="${sm//./}"     # Remove dots (8.6 -> 86)
    
    # Store in associative array with key: torch-cuda-sm
    local key="${torch}-${cuda_norm}-${sm_norm}"
    COMPAT_MATRIX["$key"]="$channel"
  done < <(tail -n +2 "$csv_file")
  
  log "Loaded ${#COMPAT_MATRIX[@]} compatibility entries from CSV"
}

# Check prerequisites
command -v git >/dev/null || die "git is required"
command -v docker >/dev/null || die "Docker is required"

# Check PyTorch/CUDA/SM compatibility using CSV
is_valid_combination() {
  local torch=$1 cuda=$2 arch=$3
  
  # Check full torch-cuda-arch combination
  local key="${torch}-${cuda}-${arch}"
  
  if [[ -n "${COMPAT_MATRIX[$key]}" ]]; then
    local channel="${COMPAT_MATRIX[$key]}"
    
    # Log info for special architectures
    case "$arch" in
      100) log "Info: SM${arch} (Blackwell B100/B200) - PyTorch ${torch}/CUDA ${cuda} (${channel})" ;;
      120) log "Info: SM${arch} (Blackwell RTX 5090) - PyTorch ${torch}/CUDA ${cuda} (${channel})" ;;
    esac
    
    return 0
  else
    # Provide helpful skip messages
    case "$arch" in
      100) log "Skip: SM${arch} (Blackwell B100/B200) not supported in PyTorch ${torch} with CUDA ${cuda}" ;;
      120) log "Skip: SM${arch} (Blackwell RTX 5090) not supported in PyTorch ${torch} with CUDA ${cuda}" ;;
      50|52|53) log "Skip: SM${arch} (Maxwell) not supported in PyTorch ${torch} with CUDA ${cuda}" ;;
      60|61|62) log "Skip: SM${arch} (Pascal) not supported in PyTorch ${torch} with CUDA ${cuda}" ;;
      70|75) log "Skip: SM${arch} (Volta/Turing) not supported in PyTorch ${torch} with CUDA ${cuda}" ;;
      80|86|89|90) log "Skip: SM${arch} (Ampere/Ada/Hopper) not supported in PyTorch ${torch} with CUDA ${cuda}" ;;
      *) log "Skip: Unknown architecture SM${arch} for PyTorch ${torch} with CUDA ${cuda}" ;;
    esac
    
    return 1
  fi
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
# Load compatibility matrix first
load_compatibility_matrix

log "Preparing sources..."
mkdir -p "$SRC_DIR" "$OUT_DIR"
for ver in $FA_VERSIONS; do
  get_source "$ver"
done

log "Building wheels..."
for fa_ver in $FA_VERSIONS; do
  for torch in $TORCH_VERSIONS; do
    for cuda in $CUDA_VERSIONS; do
      for arch in $CUDA_ARCHS; do
        # Check full torch-cuda-arch combination
        is_valid_combination "$torch" "$cuda" "$arch" || continue
        
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