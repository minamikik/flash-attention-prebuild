#!/usr/bin/env bash
# Windows (Git Bash) assumed. Fetches FlashAttention → checks out each version →
# mass produces Windows + Linux wheels using cibuildwheel.
set -euo pipefail

curl -LsSf https://astral.sh/uv/install.sh | sh

# ======== Variable parameters (can be overridden via environment variables) ========
: "${FA_REPO_URL:=https://github.com/Dao-AILab/flash-attention.git}"

# FlashAttention versions (tags) to build simultaneously: space-separated
# ex: "${FA_VERSIONS:=2.8.2 2.8.3}
: "${FA_VERSIONS:=2.8.2}"

# Torch major.minor series (patch is left as * wildcard)
# ex: "${TORCH_SERIES:=2.6 2.7 2.8}"
: "${TORCH_SERIES:=2.8}"

# CUDA channels (cu126 / cu128 / cu129)
# ex: "${CUDA_SETS:=126 128}"
: "${CUDA_SETS:=126 128}"

# Python versions to build (tag names)
# ex: "${PY_WIN:=cp310 cp311 cp312}"
# ex: "${PY_LINUX:=cp310 cp311 cp312}"
: "${PY_WIN:=cp312}"
: "${PY_LINUX:=cp312}"

# Docker images for Linux builds (manylinux + CUDA)
# PyTorch official manylinux2_28-builder recommended if available (tags may change)
: "${LINUX_IMAGE_CU126:=pytorch/manylinux2_28-builder:cuda12.6}"
: "${LINUX_IMAGE_CU128:=pytorch/manylinux2_28-builder:cuda12.8}"
: "${LINUX_IMAGE_CU129:=pytorch/manylinux2_28-builder:cuda12.9}"

# Alternative (fallback when above tags unavailable. Less compatible manylinux_2_34)
: "${ALT_LINUX_IMAGE_CU126:=sameli/manylinux_2_34_x86_64_cuda_12.6}"
: "${ALT_LINUX_IMAGE_CU128:=sameli/manylinux_2_34_x86_64_cuda_12.8}"
: "${ALT_LINUX_IMAGE_CU129:=sameli/manylinux_2_34_x86_64_cuda_12.9}"

# Number of parallel jobs for cibuildwheel
: "${MAX_JOBS:=48}"

# 7.5=Turing, 8.0=Ampere(A100), 8.6=Ampere(L4, RTX30xx), 8.9=Ada(RTX40xx), 9.0=Hopper(H100), 12.0=Blackwell
# ex: "${TORCH_CUDA_ARCH_LIST:=8.0;8.6;8.9;9.0}"
: "${TORCH_CUDA_ARCH_LIST:=8.6}"  

# ======== No need to edit below this line ========
ROOT_DIR="$(pwd)"
SRC_DIR="${ROOT_DIR}/src"
WHEEL_DIR="${ROOT_DIR}/wheelhouse"
mkdir -p "${SRC_DIR}" "${WHEEL_DIR}"

# --- Prerequisite checks ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required" >&2; exit 1; }; }
need git
need bash
need uvx || true  # uvx comes with uv >= 0.4. If not, run 'uv tool install cibuildwheel' then use 'uvx'
need docker || { echo "ERROR: Docker Desktop (WSL2 backend) is required."; exit 1; }

# Windows CUDA switching (concurrent installation recommended)
set_cuda_windows() {
  local cu="$1"  # 126 / 128 / 129
  local var="CUDA_PATH_V${cu}"
  local val="${!var:-}"
  if [[ -z "${val}" ]]; then
    echo "[windows] WARNING: ${var} not set, skipping Windows build for ${cu}" >&2
    return 1
  fi
  export CUDA_PATH="${val}"
  case "$OSTYPE" in
    msys*|cygwin*) export PATH="${CUDA_PATH}/bin:${PATH}" ;;
  esac
  export CUDACXX="${CUDA_PATH}/bin/nvcc.exe"
  return 0
}

# Check if Torch × CUDA combination exists
is_supported_combo() {
  local tv="$1" ; local cu="$2"  # tv: 2.6 / 2.7 / 2.8, cu: 126/128/129
  case "$tv" in
    2.6) [[ "$cu" == "126" ]] && return 0 || return 1 ;;
    2.7) [[ "$cu" == "126" || "$cu" == "128" ]] && return 0 || return 1 ;;
    2.8) [[ "$cu" == "126" || "$cu" == "128" || "$cu" == "129" ]] && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

linux_image_for() {
  local cu="$1"
  case "$cu" in
    126) echo "${LINUX_IMAGE_CU126}" ;;
    128) [[ -n "${LINUX_IMAGE_CU128}" ]] && echo "${LINUX_IMAGE_CU128}" || echo "${ALT_LINUX_IMAGE_CU128}" ;;
    129) [[ -n "${LINUX_IMAGE_CU129}" ]] && echo "${LINUX_IMAGE_CU129}" || echo "${ALT_LINUX_IMAGE_CU129}" ;;
  esac
}

# Resolve tag name for specified version (v2.8.2 or 2.8.2)
resolve_tag() {
  local ver="$1"
  local found=""
  # First look for tags in remote (prefer v-prefixed)
  if git ls-remote --tags --refs "${FA_REPO_URL}" | grep -q -E "refs/tags/v?${ver}$"; then
    if git ls-remote --tags --refs "${FA_REPO_URL}" | grep -q -E "refs/tags/v${ver}$"; then
      found="v${ver}"
    else
      found="${ver}"
    fi
  fi
  echo "${found}"
}

# Fetch source for specified version
prepare_source() {
  local ver="$1"
  local dest="${SRC_DIR}/flash-attention-${ver}"
  if [[ -d "${dest}" ]]; then
    echo "[src] already prepared: ${dest}"
    return 0
  fi
  local tag; tag="$(resolve_tag "${ver}")"
  if [[ -z "${tag}" ]]; then
    echo "ERROR: tag for ${ver} not found in ${FA_REPO_URL}" >&2
    exit 1
  fi
  echo "[src] cloning ${FA_REPO_URL} @ ${tag} -> ${dest}"
  git clone --depth 1 --branch "${tag}" "${FA_REPO_URL}" "${dest}"
}

# Build one case (FA version × Torch × CUDA)
build_one() {
  local ver="$1"       # FA version (e.g., 2.8.2)
  local torch="$2"     # 2.6 / 2.7 / 2.8
  local cu="$3"        # 126 / 128 / 129

  local proj="${SRC_DIR}/flash-attention-${ver}"
  local outdir="${WHEEL_DIR}/fa${ver}/torch${torch}/cu${cu}"
  mkdir -p "${outdir}"

  # ---- Linux (manylinux_x86_64) ----
  local img; img="$(linux_image_for "${cu}")"
  if [[ -n "${img}" ]]; then
    echo "[linux] FA ${ver} | torch ${torch}.* | cu${cu} | image=${img}"
    CIBW_PLATFORM=linux \
    CIBW_BUILD="$(printf "%s-manylinux_x86_64 " ${PY_LINUX})" \
    CIBW_SKIP="*-musllinux_*" \
    CIBW_OUTPUT_DIR="${outdir}" \
    CIBW_MANYLINUX_X86_64_IMAGE="${img}" \
    CIBW_TEST_COMMAND='python -c "import flash_attn; print(\"import-ok\")"' \
    CIBW_ENVIRONMENT="MAX_JOBS=${MAX_JOBS} TORCH_CUDA_ARCH_LIST='${TORCH_CUDA_ARCH_LIST}' CXXFLAGS='-D_GLIBCXX_USE_CXX11_ABI=1' TORCH_SPEC=${torch}.* CUDA_CHANNEL=cu${cu}" \
    uvx cibuildwheel --platform linux --config-file "${ROOT_DIR}/cibuildwheel.toml" "${proj}"
  else
    echo "[linux] no image for cu${cu}; skip"
  fi

  # ---- Windows (win_amd64) ----
  if set_cuda_windows "${cu}"; then
    echo "[windows] FA ${ver} | torch ${torch}.* | cu${cu} | CUDA_PATH=${CUDA_PATH}"
    CIBW_PLATFORM=windows \
    CIBW_BUILD="$(printf "%s-win_amd64 " ${PY_WIN})" \
    CIBW_SKIP="" \
    CIBW_OUTPUT_DIR="${outdir}" \
    CIBW_TEST_COMMAND='python -c "import flash_attn; print(\"import-ok\")"' \
    CIBW_ENVIRONMENT_WINDOWS="MAX_JOBS=${MAX_JOBS} TORCH_CUDA_ARCH_LIST='${TORCH_CUDA_ARCH_LIST}' TORCH_SPEC=${torch}.* CUDA_CHANNEL=cu${cu} CMAKE_GENERATOR=Ninja" \
    uvx cibuildwheel --platform windows --config-file "${ROOT_DIR}/cibuildwheel.toml" "${proj}"
  else
    echo "[windows] CUDA cu${cu} toolchain not configured; skipped."
  fi
}

# ====== Main process ======
echo ">>> Prepare sources..."
for ver in ${FA_VERSIONS}; do
  prepare_source "${ver}"
done

echo ">>> Build matrix..."
IFS_save="$IFS"
for ver in ${FA_VERSIONS}; do
  for tv in ${TORCH_SERIES}; do
    for cu in ${CUDA_SETS}; do
      if is_supported_combo "${tv}" "${cu}"; then
        echo "=== Build: FA ${ver} × Torch ${tv}.* × cu${cu} ==="
        build_one "${ver}" "${tv}" "${cu}"
      else
        echo "[skip] torch ${tv}.* + cu${cu} skipped as no public wheels available"
      fi
    done
  done
done
IFS="$IFS_save"

echo
echo "✅ Complete: Output placed in ${WHEEL_DIR}/fa<ver>/torch<series>/cu<xxx>."
