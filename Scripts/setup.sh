#!/bin/bash
set -e

echo "=== BlazingVoice3 Setup ==="

# 1. Clone and build llama.cpp
if [ ! -d "vendor/llama.cpp" ]; then
    echo "[1/3] Cloning llama.cpp..."
    git clone https://github.com/ggml-org/llama.cpp vendor/llama.cpp
else
    echo "[1/3] llama.cpp already exists, updating..."
    cd vendor/llama.cpp && git pull && cd ../..
fi

echo "[2/3] Building llama.cpp with Metal..."
cd vendor/llama.cpp
cmake -B build \
    -DGGML_METAL=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build build --config Release -j$(sysctl -n hw.ncpu)
cd ../..

echo "[3/3] Building BlazingVoice3..."
swift build

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Run with: swift run BlazingVoice3"
echo ""
echo "Or build release: swift build -c release"
echo ""
