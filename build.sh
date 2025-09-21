#!/bin/bash
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
CIBW_BUILD_VERBOSITY="${CIBW_BUILD_VERBOSITY:-1}"
FA_REPO="${FA_REPO:-https://github.com/Dao-AILab/flash-attention.git}"
FA_VERSIONS="${FA_VERSIONS:-2.8.2}"
TORCH_VERSIONS="${TORCH_VERSIONS:-2.8 2.7 2.6}"
CUDA_VERSIONS="${CUDA_VERSIONS:-126 128 129 124 118}"
CUDA_ARCHS="${CUDA_ARCHS:-80 86 89 120}"
PYTHON_VERSIONS="${PYTHON_VERSIONS:-cp312 cp313}"
PLATFORMS="${PLATFORMS:-linux}"
MAX_JOBS="${MAX_JOBS:-16}"
NVCC_THREADS="${NVCC_THREADS:-2}"
OVERWRITE="${OVERWRITE:-false}"

# Paths
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${ROOT_DIR}/src"
OUT_DIR="${ROOT_DIR}/dist"
CONFIG_FILE="${ROOT_DIR}/cibuildwheel.toml"

# Docker images for Linux builds
declare -A LINUX_IMAGES=(
  ["118"]="pytorch/manylinux2_28-builder:cuda11.8"
  ["121"]="pytorch/manylinux2_28-builder:cuda12.1"
  ["124"]="pytorch/manylinux2_28-builder:cuda12.4"
  ["126"]="pytorch/manylinux2_28-builder:cuda12.6"
  ["128"]="pytorch/manylinux2_28-builder:cuda12.8"
  ["129"]="pytorch/manylinux2_28-builder:cuda12.9"
)

# Compatibility matrix (loaded from CSV)
declare -A COMPAT_MATRIX
# torch-cuda -> sm architectures mapping
declare -A TORCH_CUDA_ARCHS

# =============================================================================
# Utility Functions
# =============================================================================
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" >&2; }
die() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2; exit 1; }

# =============================================================================
# Load compatibility matrix and build torch-cuda -> archs mapping
# =============================================================================
load_compatibility_matrix() {
  local csv_file="${ROOT_DIR}/torch_cuda_sm_matrix.csv"
  [[ ! -f "$csv_file" ]] && die "Compatibility matrix not found: $csv_file"
  
  # Skip header and load data
  while IFS=, read -r torch cuda sm channel; do
    # Normalize values
    local cuda_norm="${cuda#cu}"  # Remove 'cu' prefix
    local sm_norm="${sm//./}"     # Remove dots (8.6 -> 86)
    
    # Store in compatibility matrix
    local key="${torch}-${cuda_norm}-${sm_norm}"
    COMPAT_MATRIX["$key"]="$channel"
    
    # Build torch-cuda -> archs mapping
    local tc_key="${torch}-${cuda_norm}"
    if [[ -v TORCH_CUDA_ARCHS["$tc_key"] ]]; then
      # Append if not already in the list
      if [[ ! " ${TORCH_CUDA_ARCHS[$tc_key]} " =~ " ${sm_norm} " ]]; then
        TORCH_CUDA_ARCHS["$tc_key"]+=" ${sm_norm}"
      fi
    else
      TORCH_CUDA_ARCHS["$tc_key"]="${sm_norm}"
    fi
  done < <(tail -n +2 "$csv_file")
  
  log "Loaded ${#COMPAT_MATRIX[@]} compatibility entries from CSV"
  log "Created ${#TORCH_CUDA_ARCHS[@]} torch-cuda combinations"
}

# =============================================================================
# Get all supported architectures for a torch/cuda combination
# Filter by CUDA_ARCHS variable to only include requested architectures
# =============================================================================
get_supported_archs() {
  local torch=$1
  local cuda=$2
  local key="${torch}-${cuda}"
  
  if [[ -v TORCH_CUDA_ARCHS["$key"] ]]; then
    local all_archs="${TORCH_CUDA_ARCHS[$key]}"
    local filtered_archs=""
    
    # Filter architectures based on CUDA_ARCHS variable
    for arch in $all_archs; do
      if [[ " $CUDA_ARCHS " =~ " $arch " ]]; then
        if [[ -z "$filtered_archs" ]]; then
          filtered_archs="$arch"
        else
          filtered_archs+=" $arch"
        fi
      fi
    done
    
    echo "$filtered_archs"
  else
    echo ""
  fi
}

# =============================================================================
# Convert architecture to decimal format for TORCH_CUDA_ARCH_LIST
# =============================================================================
arch_to_decimal() {
  local arch=$1
  case $arch in
    50) echo "5.0" ;;
    60) echo "6.0" ;;
    70) echo "7.0" ;;
    75) echo "7.5" ;;
    80) echo "8.0" ;;
    86) echo "8.6" ;;
    89) echo "8.9" ;;
    90) echo "9.0" ;;
    100) echo "10.0" ;;
    120) echo "12.0" ;;
    *) echo "$arch" ;;
  esac
}

# =============================================================================
# Convert architecture list to decimal format (e.g., "80 86 89" -> "8.0;8.6;8.9")
# =============================================================================
archs_to_decimal_list() {
  local archs=$1
  local result=""
  
  for arch in $archs; do
    local decimal=$(arch_to_decimal "$arch")
    if [[ -z "$result" ]]; then
      result="$decimal"
    else
      result="${result};${decimal}"
    fi
  done
  
  echo "$result"
}

# =============================================================================
# Sort architectures numerically
# =============================================================================
sort_archs() {
  local archs=$1
  echo "$archs" | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# =============================================================================
# Setup CUDA environment on Windows
# =============================================================================
setup_cuda_win() {
  local cuda=$1
  
  if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "win32" ]]; then
    # Try to find CUDA path
    local var="CUDA_PATH_V${cuda}"
    local path="${!var:-}"
    
    if [[ -z "$path" ]]; then
      path="C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v${cuda:0:2}.${cuda:1}"
      if [[ ! -d "$path" ]]; then
        die "CUDA ${cuda} not found. Please set ${var} environment variable"
      fi
    fi
    
    export CUDA_PATH="$path"
    export CUDACXX="${CUDA_PATH}/bin/nvcc"
    export PATH="${CUDA_PATH}/bin:${PATH}"
    log "Set up CUDA ${cuda} at ${CUDA_PATH}"
  fi
}

# =============================================================================
# Clone or update Flash Attention source
# =============================================================================
get_source() {
  local ver=$1
  local dir="${SRC_DIR}/flash-attention-${ver}"
  
  if [[ -d "$dir" ]]; then
    log "Using existing source at $dir"
  else
    log "Cloning Flash Attention v${ver}..."
    git clone --branch "v${ver}" --depth 1 "$FA_REPO" "$dir" || die "Failed to clone Flash Attention"
  fi
  
  echo "$dir"
}

# =============================================================================
# Generate wheel filename
# =============================================================================
get_wheel_name() {
  local fa_ver=$1
  local torch=$2
  local cuda=$3
  local archs=$4  # Space-separated list of archs (not used in filename)
  local pyver=$5
  local os=$6
  
  local plat
  if [[ "$os" == "linux" ]]; then
    plat="manylinux_2_24_x86_64"
  else
    plat="win_amd64"
  fi
  
  echo "flash_attn-${fa_ver}+cu${cuda}torch${torch}-${pyver}-${pyver}-${plat}.whl"
}

# =============================================================================
# Build wheel for a torch/cuda combination with all supported architectures
# =============================================================================
build_wheel() {
  local fa_ver=$1
  local torch=$2
  local cuda=$3
  local pyver=$4
  local os=$5
  
  # Get all supported architectures for this torch/cuda combination
  local archs=$(get_supported_archs "$torch" "$cuda")
  if [[ -z "$archs" ]]; then
    log "No supported architectures for PyTorch ${torch} + CUDA ${cuda}, skipping"
    return 0
  fi
  
  # Sort architectures for consistent naming
  archs=$(sort_archs "$archs")
  
  log "Building for PyTorch ${torch} + CUDA ${cuda} with architectures: ${archs} (filtered from CUDA_ARCHS: ${CUDA_ARCHS})"
  
  # Check for existing wheel (platform-specific)
  if [[ "$os" == "linux" ]]; then
    local pattern="flash_attn-${fa_ver}+cu${cuda}torch${torch}-${pyver}-${pyver}-manylinux*.whl"
  else
    local pattern="flash_attn-${fa_ver}+cu${cuda}torch${torch}-${pyver}-${pyver}-win_amd64.whl"
  fi
  if [[ "$OVERWRITE" != "true" ]] && ls "${OUT_DIR}"/${pattern} 2>/dev/null | grep -q .; then
    local existing_wheel=$(ls "${OUT_DIR}"/${pattern} 2>/dev/null | head -n1)
    log "Wheel already exists: $(basename "$existing_wheel"), skipping"
    return 0
  fi
  
  # Get source
  local src=$(get_source "$fa_ver")
  
  # Convert architectures to decimal format
  local torch_arch=$(archs_to_decimal_list "$archs")
  
  # Create temporary output directory for this build
  local temp_dir="${ROOT_DIR}/temp/build_temp_${fa_ver}_${torch}_${cuda}_${pyver}_${os}_$$"
  mkdir -p "$temp_dir"
  
  # Determine platform and build tag
  local platform
  local build_tag
  if [[ "$os" == "linux" ]]; then
    platform="linux"
    build_tag="${pyver}-*linux*"
    local image="${LINUX_IMAGES[$cuda]}"
    [[ -z "$image" ]] && die "No Linux image defined for CUDA ${cuda}"
  else
    platform="windows"
    build_tag="${pyver}-*win_amd64"
    setup_cuda_win "$cuda"
  fi
  
  # Build wheel using cibuildwheel
  log "Building wheel with cibuildwheel..."
  local env=(
    "CIBW_PLATFORM=$platform"
    "CIBW_BUILD=$build_tag"
    "CIBW_OUTPUT_DIR=$temp_dir"
  )
  
  if [[ "$os" == "linux" ]]; then
    env+=("CIBW_MANYLINUX_X86_64_IMAGE=$image")
    env+=("CIBW_ENVIRONMENT=FLASH_ATTENTION_FORCE_BUILD=TRUE TORCH_SPEC=$torch CUDA_CHANNEL=cu$cuda TORCH_CUDA_ARCH_LIST='$torch_arch' MAX_JOBS=$MAX_JOBS NVCC_THREADS=$NVCC_THREADS FLASH_ATTN_CUDA_ARCHS='$torch_arch'")
  else
    env+=("CIBW_ENVIRONMENT_WINDOWS=FLASH_ATTENTION_FORCE_BUILD=TRUE TORCH_SPEC=$torch CUDA_CHANNEL=cu$cuda TORCH_CUDA_ARCH_LIST='$torch_arch' MAX_JOBS=$MAX_JOBS NVCC_THREADS=$NVCC_THREADS FLASH_ATTN_CUDA_ARCHS='$torch_arch' DISTUTILS_USE_SDK=1")
  fi
  
  # Execute build
  (
    cd "$src"
    env "${env[@]}" CIBW_BUILD_VERBOSITY="$CIBW_BUILD_VERBOSITY" \
      uvx --with pip cibuildwheel --config-file "$CONFIG_FILE"
  )
  
  # Move and rename wheel from temp directory to final destination
  local base=$(ls "${temp_dir}"/flash_attn-${fa_ver}*.whl 2>/dev/null | grep -E "${pyver}-${pyver}-(manylinux.*|win_amd64)" | sort -r | head -n1)
  if [[ -n "$base" ]]; then
    local new_name=$(get_wheel_name "$fa_ver" "$torch" "$cuda" "$archs" "$pyver" "$os")
    local dest="${OUT_DIR}/${new_name}"
    mv "$base" "$dest"
    log "Created wheel: $new_name"
  else
    log "Warning: No wheel found in temporary directory"
  fi
  
  # Cleanup temporary directory
  rm -rf "$temp_dir"
}

# =============================================================================
# Main
# =============================================================================
main() {
  log "Flash Attention Multi-Architecture Build Script"
  log "=============================================="
  log "Configuration:"
  log "  FA_VERSIONS: $FA_VERSIONS"
  log "  TORCH_VERSIONS: $TORCH_VERSIONS"
  log "  CUDA_VERSIONS: $CUDA_VERSIONS"
  log "  CUDA_ARCHS: $CUDA_ARCHS"
  log "  PYTHON_VERSIONS: $PYTHON_VERSIONS"
  log "  PLATFORMS: $PLATFORMS"
  
  # Create output directory
  mkdir -p "$OUT_DIR" "$SRC_DIR"
  
  # Load compatibility matrix
  load_compatibility_matrix
  
  # Main build loop - iterate by torch/cuda combinations
  for fa_ver in $FA_VERSIONS; do
    for torch in $TORCH_VERSIONS; do
      for cuda in $CUDA_VERSIONS; do
        # Check if this torch/cuda combination has any supported architectures
        local supported_archs=$(get_supported_archs "$torch" "$cuda")
        if [[ -z "$supported_archs" ]]; then
          log "Skipping PyTorch ${torch} + CUDA ${cuda} (no supported architectures)"
          continue
        fi
        
        log "Processing PyTorch ${torch} + CUDA ${cuda} (architectures: ${supported_archs})"
        
        for pyver in $PYTHON_VERSIONS; do
          for os in $PLATFORMS; do
            log "Building Flash Attention ${fa_ver} for PyTorch ${torch}, CUDA ${cuda}, Python ${pyver}, ${os}"
            build_wheel "$fa_ver" "$torch" "$cuda" "$pyver" "$os" || true
          done
        done
      done
    done
  done
  
  log "Build process completed!"
  log "Built wheels are in: $OUT_DIR"
}

# Run main function
main "$@"