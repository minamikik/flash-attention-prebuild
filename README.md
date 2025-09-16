# Flash Attention Build Environment

## Usage

### Build the Docker image
```bash
docker build --tag minamik/flash-attention-prebuild:latest .
```

### Run the Docker container
```bash
docker run \
--rm -it \
--cpus="64" \
-v "$(pwd -W):/workspace" \
minamik/flash-attention-prebuild:latest bash build.sh
```
