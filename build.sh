#!/usr/bin/env bash
set -euo pipefail

PYTHON_VERSIONS=("3.12" "3.13")
TORCH_VERSIONS=("2.8.0" "2.7.1" "2.6.0")
CUDA_VERSIONS=("cu126" "cu128" "cu129")
FLASH_ATTN_VERSIONS=("2.8.2" "2.8.3" "2.7.4")

export MAX_JOBS=64

BASE_DIST_DIR="$PWD/dist"
BASE_BUILD_DIR="$PWD/build"
mkdir -p "$BASE_DIST_DIR"
mkdir -p "$BASE_BUILD_DIR"

for PYTHON_VERSION in "${PYTHON_VERSIONS[@]}"; do
    if [ -d "/.venv" ]; then
        echo "Removing existing virtual environment..."
        rm -rf /.venv
    fi

    uv python install ${PYTHON_VERSION}
    uv python pin ${PYTHON_VERSION}
    uv sync

    for TORCH_VERSION in "${TORCH_VERSIONS[@]}"; do
        for CUDA_VERSION in "${CUDA_VERSIONS[@]}"; do
            echo "Installing PyTorch $TORCH_VERSION with CUDA $CUDA_VERSION..."
            EXTRA_INDEX_URL="https://download.pytorch.org/whl/${CUDA_VERSION}"
            uv pip install -U "torch==${TORCH_VERSION}" --extra-index-url "${EXTRA_INDEX_URL}"

            for FLASH_ATTN_VERSION in "${FLASH_ATTN_VERSIONS[@]}"; do
                echo "-------------------------------------------"
                echo "Building Flash Attention for Python $PYTHON_VERSION, PyTorch $TORCH_VERSION, CUDA $CUDA_VERSION"
                echo "🚀 Speeding up build using $MAX_JOBS parallel jobs."
                echo "Starting build with the following versions:"
                echo "Flash Attention: $FLASH_ATTN_VERSION"
                echo "PyTorch: $TORCH_VERSION"
                echo "CUDA: $CUDA_VERSION"
                echo "-------------------------------------------"

                MATRIX_TORCH_VERSION=$(echo $TORCH_VERSION | awk -F \. {'print $1 "." $2'})
                MATRIX_PYTHON_VERSION=$(echo $PYTHON_VERSION | awk -F \. {'print $1 $2'})

                BUILD_DIR="${BASE_BUILD_DIR}/flash_attn-${FLASH_ATTN_VERSION}+${CUDA_VERSION}torch${TORCH_VERSION}-cp${MATRIX_PYTHON_VERSION}"
                echo "Setting up build directory at $BUILD_DIR..."

                if [ -d "$BUILD_DIR" ]; then
                    echo "Removing existing build directory $BUILD_DIR..."
                    rm -rf "$BUILD_DIR"
                fi
                mkdir -p "$BUILD_DIR"
                cd "$BUILD_DIR"

                echo "Cloning flash-attention repository..."
                git clone https://github.com/Dao-AILab/flash-attention.git -b "v$FLASH_ATTN_VERSION"
                cd flash-attention

                echo "Building wheel... (This may take several minutes)"
                FLASH_ATTENTION_FORCE_BUILD=TRUE uv run setup.py bdist_wheel
                echo "Renaming the wheel file..."
                BASE_WHEEL_NAME=$(basename $(ls dist/*.whl | head -n 1))
                NEW_WHEEL_NAME=$(echo $BASE_WHEEL_NAME | sed "s/-$FLASH_ATTN_VERSION-/-$FLASH_ATTN_VERSION+${CUDA_VERSION}torch${MATRIX_TORCH_VERSION}-/")
                mv -v "dist/$BASE_WHEEL_NAME" "${BASE_DIST_DIR}/$NEW_WHEEL_NAME"
                echo "-------------------------------------------"
                echo "✅ Build complete!"
                echo "Wheel file created at: ${BASE_DIST_DIR}/$NEW_WHEEL_NAME"
                echo ""

                cd ../..
            done
        done
    done
done
echo "All builds completed!"
echo "You can find the built wheel files in their respective build directories."
