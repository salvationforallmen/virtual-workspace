#!/bin/bash
# Self-Healing 512GB Cache for Codespaces
# Survives stops, crashes, and rebuilds

set -e

CACHE_MOUNT="/workspaces/build-cache"
PERSISTENT_MANIFEST="/workspaces/.cache-manifest"
TARGET_SIZE="512G"

echo "🔍 [Cache Manager] Searching for 512GB disk..."

# Find the 512GB disk
DISK=$(lsblk -o NAME,SIZE --nodeps | grep "$TARGET_SIZE" | awk '{print $1}' | head -n1)
if [ -z "$DISK" ]; then
    echo "❌ No 512GB disk found. Using /tmp fallback."
    CACHE_MOUNT="/tmp/build-cache"
    sudo mkdir -p "$CACHE_MOUNT"
    sudo chown $(whoami):$(whoami) "$CACHE_MOUNT"
    exit 0
fi

RAW_DEVICE="/dev/$DISK"
echo "✅ Found disk: $RAW_DEVICE"

# Check if already mounted
if mount | grep -q "$CACHE_MOUNT"; then
    echo "✅ Cache already mounted at $CACHE_MOUNT"
    exit 0
fi

# Find available loop device
LOOP=$(sudo losetup -f)
echo "📎 Using loop device: $LOOP"

# Check if loop device exists and is attached
if sudo losetup $LOOP 2>/dev/null | grep -q "$RAW_DEVICE"; then
    echo "🔄 Loop device already attached"
else
    # Attach raw disk to loop device
    sudo losetup $LOOP $RAW_DEVICE
fi

# Check if filesystem exists on loop device
if ! sudo blkid $LOOP 2>/dev/null | grep -q 'LABEL="TURBOCACHE"'; then
    echo "🆕 Formatting $LOOP with label TURBOCACHE..."
    sudo mkfs.ext4 -F -m 0 -L TURBOCACHE $LOOP
fi

# Mount
sudo mkdir -p "$CACHE_MOUNT"
sudo mount $LOOP "$CACHE_MOUNT"
sudo chown -R $(whoami):$(whoami) "$CACHE_MOUNT"
echo "🎉 Mounted at $CACHE_MOUNT (via $LOOP -> $RAW_DEVICE)"

# --- RESTORATION LOGIC (Reads from persistent 32GB drive) ---
echo "📋 Checking restoration manifests..."

# 1. APT package cache
if [ -f "$PERSISTENT_MANIFEST/packages.list" ]; then
    echo "📦 Restoring APT packages..."
    sudo mkdir -p "$CACHE_MOUNT/apt-archives"
    sudo apt-get update -qq 2>/dev/null || true
    xargs -a "$PERSISTENT_MANIFEST/packages.list" sudo apt-get install -y -d -qq -o Dir::Cache::Archives="$CACHE_MOUNT/apt-archives" 2>/dev/null || true
    sudo rm -f /var/cache/apt/archives
    sudo ln -sf "$CACHE_MOUNT/apt-archives" /var/cache/apt/archives
    echo "   ✓ APT cache restored"
fi

# 2. Docker images
if [ -f "$PERSISTENT_MANIFEST/docker-images.list" ]; then
    echo "🐳 Restoring Docker images..."
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "$CACHE_MOUNT/docker" /etc/docker/daemon.json; then
        echo "{\"data-root\": \"$CACHE_MOUNT/docker\"}" | sudo tee /etc/docker/daemon.json > /dev/null
        sudo systemctl restart docker
    fi
    while read -r IMAGE; do
        [[ -z "$IMAGE" || "$IMAGE" =~ ^# ]] && continue
        echo "  -> $IMAGE"
        docker pull "$IMAGE" 2>/dev/null || echo "      (skipped)"
    done < "$PERSISTENT_MANIFEST/docker-images.list"
    echo "   ✓ Docker ready"
fi

# 3. Large downloads
if [ -f "$PERSISTENT_MANIFEST/downloads.txt" ]; then
    echo "🌐 Restoring downloads..."
    while read -r URL; do
        [[ -z "$URL" || "$URL" =~ ^# ]] && continue
        FILENAME=$(basename "$URL")
        if [ ! -f "$CACHE_MOUNT/$FILENAME" ]; then
            echo "  -> $FILENAME"
            wget -q -P "$CACHE_MOUNT" "$URL" 2>/dev/null || echo "      (skipped)"
        else
            echo "  -> $FILENAME (exists)"
        fi
    done < "$PERSISTENT_MANIFEST/downloads.txt"
    echo "   ✓ Downloads ready"
fi

echo "✅ [Cache Manager] 512GB Turbo Cache ready at $CACHE_MOUNT"
echo "   Size: $(df -h $CACHE_MOUNT | tail -1 | awk '{print $2}')"
