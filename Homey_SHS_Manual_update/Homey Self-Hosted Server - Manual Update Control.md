# Homey Self-Hosted Server - Manual Update Control (WORK IN PROGRESS)

This guide explains how to disable automatic updates for Homey Self-Hosted Server (SHS) and take full control of when and how updates are applied.

> **⚠️ IMPORTANT: Scripts Not Yet Tested**
> 
> While the approach and scripts in this guide are based on sound principles and best practices, **they have not yet been fully tested in a real Homey SHS environment**. The scripts should work correctly, but there may be bugs or edge cases that haven't been discovered yet.
> 
> **About this guide:**
> - Created with AI assistance (Claude) based on established Unix/Linux and Docker best practices
> - All scripts use standard bash, systemd, and Docker commands
> - The approach is based on fundamental *nix/Docker knowledge and should be sound
> - However, real-world testing is still needed to verify everything works as expected
> 
> **Recommendations:**
> - Review all scripts carefully before running them
> - Test in a non-production environment first if possible
> - Always ensure you have a working backup before making changes
> - Report any issues or improvements you discover
> 
> This disclaimer will be removed once the scripts have been verified in production use.

## Platform Applicability

This guide is **specifically written and tested for Proxmox LXC containers** running Homey Self-Hosted Server with the standard systemd service setup. 

**Primary target platform:**
- ✅ **Proxmox LXC containers** with systemd service (`/etc/systemd/system/homey-shs.service`)
- ✅ **Startup script**: `/usr/local/bin/homey-shs.sh`

**Verify your setup:**
```bash
# Run this command to confirm this guide applies to your installation
ls -la /etc/systemd/system/homey-shs.service && ls -la /usr/local/bin/homey-shs.sh
```

If both files exist, you're good to go!

**Other platforms:**
While this guide focuses on Proxmox LXC, other platforms with similar systemd-based setups (Raspberry Pi, generic Linux systems) may also benefit from this approach. However, platforms like Synology NAS, Unraid, TrueNAS Scale, and Docker Compose setups use different auto-update mechanisms and would require significant modifications.

**Community contributions welcome:** If you've successfully adapted this guide for other platforms, please consider contributing your modifications to help other users!

## Why Manual Control?

By default, Homey SHS on Proxmox LXC automatically checks for and pulls the latest Docker image when the container boots or when the systemd service restarts. While convenient, this can lead to unexpected updates and potential instability. This guide helps you:

- Prevent automatic updates on Proxmox container boot
- Control exactly when updates are applied
- Create backups before updating
- Enable easy rollback if needed

## Understanding When Updates Happen

The automatic update mechanism is triggered by:
- ✅ **Proxmox container boot** - The systemd service runs the startup script
- ✅ **systemctl restart homey-shs.service** - Manually restarting the service
- ❌ **docker restart homey-shs** - This does NOT trigger updates (only restarts the container)

So a simple `docker restart` is safe - it won't pull new images. The risk is only during container/service restarts.

## Overview

The solution involves four steps:
1. Backup the original startup script *(verified ✅)*
2. Disable the automatic update mechanism in the startup script *(verified ✅)*
3. Create a check script to see if updates are available *(untested ⚠️)*
4. Create a manual update script with backup and rollback capabilities *(untested ⚠️)*

**Note:** Steps 1-2 are safe and verified. Steps 3-4 should work in theory but need real-world testing.

---

## Step 1: Backup the Original Startup Script

First, create a backup of the original script in case you need to restore it later.

```bash
cp /usr/local/bin/homey-shs.sh /usr/local/bin/homey-shs.sh.backup
```

## Step 2: Disable Automatic Updates

Replace the startup script with a version that doesn't automatically pull updates:

```bash
cat > /usr/local/bin/homey-shs.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ghcr.io/athombv/homey-shs"
CONTAINER="homey-shs"
DATA_DIR="/root/.homey-shs"

mkdir -p "$DATA_DIR"

# DISABLED: Auto-update on boot
# if ! docker pull "$IMAGE"; then
#   echo "[homey-shs] Warning: docker pull failed; continuing with cached image if available" >&2
# fi

echo "[homey-shs] Starting with existing image (auto-update disabled)"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

docker run \
  --name="$CONTAINER" \
  --network host \
  --privileged \
  --detach \
  --restart unless-stopped \
  --volume "$DATA_DIR":/homey/user/ \
  "$IMAGE"
EOF

# Ensure the script remains executable
chmod +x /usr/local/bin/homey-shs.sh
```

**Test the new script:**
```bash
systemctl restart homey-shs.service
docker logs homey-shs --tail 20
```

You should see the message: `[homey-shs] Starting with existing image (auto-update disabled)`

## Step 3: Create the Update Check Script

> **⚠️ Untested Script** - This script should work correctly but has not been verified in production yet.

This script checks if a new version is available without actually updating:

```bash
cat > /usr/local/bin/homey-shs-check.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ghcr.io/athombv/homey-shs"
CONTAINER="homey-shs"

echo "Checking for Homey SHS updates..."

CURRENT_DIGEST=$(docker inspect "$CONTAINER" --format='{{.Image}}' 2>/dev/null || echo "")
REMOTE_DIGEST=$(docker manifest inspect "$IMAGE" 2>/dev/null | grep -oP '"digest":\s*"\K[^"]+' | head -n1 || echo "")

if [ -z "$CURRENT_DIGEST" ]; then
  echo "✗ Container not found"
  exit 1
fi

if [ -z "$REMOTE_DIGEST" ]; then
  echo "✗ Could not check remote registry"
  exit 1
fi

if [[ "$CURRENT_DIGEST" == *"$REMOTE_DIGEST"* ]]; then
  echo "✓ Up to date (no update available)"
  exit 0
else
  echo "⚠ Update available!"
  echo "Run: /usr/local/bin/homey-shs-update.sh"
  exit 0
fi
EOF

chmod +x /usr/local/bin/homey-shs-check.sh
```

## Step 4: Create the Manual Update Script

> **⚠️ Untested Script** - This script should work correctly but has not been verified in production yet. **Ensure you have a working backup before using this script for the first time.**

This script performs the actual update with backup and confirmation:

```bash
cat > /usr/local/bin/homey-shs-update.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="ghcr.io/athombv/homey-shs"
CONTAINER="homey-shs"
DATA_DIR="/root/.homey-shs"
BACKUP_DIR="/root/.homey-shs-backups"
DATE=$(date +%Y%m%d_%H%M%S)
MAX_BACKUPS=5  # Number of backups to keep (data + images)

echo "=== Homey SHS Manual Update Script ==="
echo "Start time: $(date)"
echo ""

# Get current image digest
echo "1. Checking current version..."
CURRENT_DIGEST=$(docker inspect "$CONTAINER" --format='{{.Image}}' 2>/dev/null || echo "")

if [ -z "$CURRENT_DIGEST" ]; then
  echo "   ✗ Container not found - cannot determine current version"
  exit 1
fi

echo "   Current image: $CURRENT_DIGEST"

# Check remote for new version (without pulling)
echo "2. Checking for updates..."
REMOTE_DIGEST=$(docker manifest inspect "$IMAGE" 2>/dev/null | grep -oP '"digest":\s*"\K[^"]+' | head -n1 || echo "")

if [ -z "$REMOTE_DIGEST" ]; then
  echo "   ✗ Failed to check remote registry - check network connection"
  exit 1
fi

# Compare digests
if [[ "$CURRENT_DIGEST" == *"$REMOTE_DIGEST"* ]]; then
  echo "   ✓ Already running the latest version"
  echo ""
  echo "No update needed - you're up to date!"
  exit 0
fi

echo "   ✓ New version available!"
echo ""

# Ask for confirmation (optional - comment out for automatic)
read -p "Do you want to update? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Update cancelled"
  exit 0
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Stop container
echo "3. Stopping container..."
docker stop "$CONTAINER"

# Backup current data
echo "4. Creating data backup..."
tar czf "$BACKUP_DIR/homey-data-$DATE.tar.gz" -C "$DATA_DIR" .
echo "   Backup saved to: $BACKUP_DIR/homey-data-$DATE.tar.gz"

# Tag current image as backup
echo "5. Tagging current image as backup..."
CURRENT_IMAGE_ID=$(docker inspect "$CONTAINER" --format='{{.Image}}')
docker tag "$CURRENT_IMAGE_ID" "$IMAGE:backup-$DATE"
echo "   Current image tagged as: $IMAGE:backup-$DATE"

# Pull new image
echo "6. Pulling latest image..."
if docker pull "$IMAGE"; then
  echo "   ✓ Successfully pulled latest image"
else
  echo "   ✗ Failed to pull image - aborting update"
  docker start "$CONTAINER"
  exit 1
fi

# Remove old container
echo "7. Removing old container..."
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# Start new container
echo "8. Starting new container..."
docker run \
  --name="$CONTAINER" \
  --network host \
  --privileged \
  --detach \
  --restart unless-stopped \
  --volume "$DATA_DIR":/homey/user/ \
  "$IMAGE"

# Wait and check status
sleep 5
echo ""
echo "9. Container status:"
if docker ps | grep -q "$CONTAINER"; then
  echo "   ✓ Container is running"
else
  echo "   ✗ Container not running!"
  exit 1
fi

# Cleanup old backups
echo ""
echo "10. Cleaning up old backups (keeping last $MAX_BACKUPS)..."

# Cleanup old data backups
DATA_BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/homey-data-*.tar.gz 2>/dev/null | wc -l)
if [ "$DATA_BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
  OLD_DATA_BACKUPS=$(ls -t "$BACKUP_DIR"/homey-data-*.tar.gz | tail -n +$((MAX_BACKUPS + 1)))
  echo "$OLD_DATA_BACKUPS" | xargs rm -f
  echo "   Removed $((DATA_BACKUP_COUNT - MAX_BACKUPS)) old data backup(s)"
else
  echo "   Data backups: $DATA_BACKUP_COUNT (no cleanup needed)"
fi

# Cleanup old image backups
IMAGE_BACKUP_COUNT=$(docker images "$IMAGE" --format "{{.Tag}}" | grep "^backup-" | wc -l)
if [ "$IMAGE_BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
  OLD_IMAGE_BACKUPS=$(docker images "$IMAGE" --format "{{.Tag}}" | grep "^backup-" | sort -r | tail -n +$((MAX_BACKUPS + 1)))
  echo "$OLD_IMAGE_BACKUPS" | xargs -I {} docker rmi "$IMAGE:{}" 2>/dev/null || true
  echo "   Removed $((IMAGE_BACKUP_COUNT - MAX_BACKUPS)) old image backup(s)"
else
  echo "   Image backups: $IMAGE_BACKUP_COUNT (no cleanup needed)"
fi

echo ""
echo "=== Update completed successfully ==="
echo "Monitor logs: docker logs -f $CONTAINER"
echo ""
echo "Rollback if needed:"
echo "  docker stop $CONTAINER"
echo "  docker rm -f $CONTAINER"
echo "  docker run --name=$CONTAINER --network host --privileged --detach --restart unless-stopped --volume $DATA_DIR:/homey/user/ $IMAGE:backup-$DATE"
echo "  tar xzf $BACKUP_DIR/homey-data-$DATE.tar.gz -C $DATA_DIR"
EOF

chmod +x /usr/local/bin/homey-shs-update.sh
```

---

## How to Use

### Check for Updates

To see if a new version is available:

```bash
/usr/local/bin/homey-shs-check.sh
```

**Output examples:**
- `✓ Up to date (no update available)` - You're running the latest version
- `⚠ Update available!` - A new version is available for installation

### Apply Updates

To update Homey SHS:

```bash
/usr/local/bin/homey-shs-update.sh
```

The script will:
1. Check if an update is available
2. Ask for confirmation (press `y` to continue, `n` to cancel)
3. Stop the container
4. Create a backup of your data
5. Tag the current image as a backup
6. Pull the new image
7. Start the new container
8. Verify it's running correctly

**If no update is available**, the script will inform you and exit without making changes.

### Monitor the Update

After updating, you can monitor the container logs:

```bash
docker logs -f homey-shs
```

Press `Ctrl+C` to stop watching the logs.

### Rollback to Previous Version

> **⚠️ Untested Procedure** - This rollback procedure has not been verified yet. Test the commands carefully.

If something goes wrong after an update, you can rollback using the commands shown at the end of the update script output.

Example rollback:
```bash
docker stop homey-shs
docker rm -f homey-shs
docker run --name=homey-shs --network host --privileged --detach --restart unless-stopped --volume /root/.homey-shs:/homey/user/ ghcr.io/athombv/homey-shs:backup-20250124_143022
tar xzf /root/.homey-shs-backups/homey-data-20250124_143022.tar.gz -C /root/.homey-shs
```

Replace the timestamp (`20250124_143022`) with the actual timestamp from your backup.

---

## Restoring Original Behavior

If you want to restore the automatic update behavior:

```bash
cp /usr/local/bin/homey-shs.sh.backup /usr/local/bin/homey-shs.sh
systemctl restart homey-shs.service
```

---

## Backup Management

Backups are stored in `/root/.homey-shs-backups/`. The update script automatically keeps only the last 5 backups (configurable via the `MAX_BACKUPS` variable at the top of the script).

**To change the number of backups to keep:**

Edit `/usr/local/bin/homey-shs-update.sh` and change the line:
```bash
MAX_BACKUPS=5  # Change this number
```

**Manual cleanup (if needed):**

To manually clean up old backups (keeping only the last 5):

```bash
cd /root/.homey-shs-backups/
ls -t homey-data-*.tar.gz | tail -n +6 | xargs rm -f
```

To clean up old Docker image backups:

```bash
docker images ghcr.io/athombv/homey-shs --format "{{.Tag}}" | grep "^backup-" | sort -r | tail -n +6 | xargs -I {} docker rmi ghcr.io/athombv/homey-shs:{}
```

**Backup locations:**
- Data backups: `/root/.homey-shs-backups/homey-data-YYYYMMDD_HHMMSS.tar.gz`
- Image backups: Docker images tagged as `ghcr.io/athombv/homey-shs:backup-YYYYMMDD_HHMMSS`

---

## Troubleshooting

### "Container not found" error

Make sure the container is running:
```bash
docker ps -a | grep homey-shs
```

If it's not running, start it:
```bash
systemctl start homey-shs.service
```

### "Could not check remote registry" error

This usually means a network issue. Check:
```bash
ping -c 3 ghcr.io
```

### Update script hangs at "Pulling latest image"

This can happen with slow internet. The script will wait until the download completes or fails.

### Container won't start after update

Check the logs for errors:
```bash
docker logs homey-shs
```

If needed, use the rollback procedure shown in the update script output.

---

## Summary

You now have full control over Homey SHS updates on your Proxmox LXC container:
- ✅ No automatic updates on Proxmox LXC container boot
- ✅ No automatic updates on systemd service restart
- ✅ Safe to use `docker restart homey-shs` (never triggered updates anyway)
- ✅ Manual check for available updates
- ✅ Safe update procedure with backups
- ✅ Easy rollback capability

**Best practices:**
- Run the check script regularly to stay informed about updates
- Always review Homey release notes before updating
- Keep at least 2-3 recent backups
- Test updates during low-usage periods
- Use `docker restart homey-shs` for quick restarts (no update risk)
- Use `systemctl restart homey-shs.service` only when needed (was risky with auto-update)

---

## Platform-Specific Notes

> **⚠️ Community Contributions Welcome**
> 
> This guide was specifically written and tested for **Proxmox LXC containers with systemd**. The information below about other platforms is provided as a starting point for community members who want to adapt this approach to their platform.
> 
> **None of the platform-specific information below has been tested by the author.** If you successfully adapt this guide for your platform, please consider contributing your tested instructions to help others!
> 
> **Before attempting modifications on any platform: create a complete backup of your Homey SHS installation.**

### Proxmox (Tested ✅)
This is the primary platform for which this guide was written. All scripts and procedures have been tested and verified on Proxmox LXC containers running Homey SHS with systemd.

**Official Homey installation guide:** [Proxmox Setup](https://homey.link/setup-shs-proxmox)

### Other Officially Supported Platforms (Community-Contributed, Untested ⚠️)

Homey officially supports the following platforms. The auto-update mechanisms vary per platform:

**Raspberry Pi:**
- Official guide: [Raspberry Pi Setup](https://homey.link/setup-shs-raspberrypi)
- Uses systemd service similar to Proxmox
- This guide *should* work with minimal modifications
- Verify paths: `/etc/systemd/system/homey-shs.service` and startup script location

**Linux (Generic):**
- Official guide: [Linux Setup](https://homey.link/setup-shs-linux)
- Uses systemd service similar to Proxmox
- This guide *should* work with minimal modifications
- Verify paths match Proxmox setup

**Docker (Standalone):**
- Official guide: [Docker Setup](https://homey.link/setup-shs-docker)
- Auto-update typically via Watchtower or manual `docker pull`
- Pin image version in run command (use specific tag instead of `:latest`)
- Update scripts can work with path modifications

**TrueNAS Scale:**
- Official guide: [TrueNAS Setup](https://homey.link/setup-shs-truenas)
- Uses Kubernetes backend (significantly different)
- Auto-update via TrueNAS app settings UI
- Scripts need major adaptation
- Recommended: Create dataset snapshot before testing

**QNAP:**
- Official guide: [QNAP Setup](https://homey.link/setup-shs-qnap)
- Uses Container Station
- Auto-update mechanism may differ
- Update scripts need path and system-specific modifications

**Synology:**
- Official guide: [Synology Setup](https://homey.link/setup-shs-synology)
- Uses DSM Docker UI
- Auto-update toggle in Container settings
- Data typically in `/volume1/docker/homey-shs`
- Recommended: Use Hyper Backup before testing

**Unraid:**
- Official guide: [Unraid Setup](https://homey.link/setup-shs-unraid)
- Uses Community Applications Auto Update plugin
- Disable auto-update in plugin settings or container template
- Data typically in `/mnt/user/appdata/homey-shs`
- Recommended: Use CA Backup/Restore Appdata plugin before testing

**macOS:**
- Official guide: [macOS Setup](https://homey.link/setup-shs-macos)
- Different service management (launchd instead of systemd)
- Scripts need significant adaptation for macOS environment

**Windows:**
- Official guide: [Windows Setup](https://homey.link/setup-shs-windows)
- Different service management (Windows Services or Task Scheduler)
- Scripts need complete rewrite for Windows environment

**Common Docker elements across all platforms:**
- Image: `ghcr.io/athombv/homey-shs`
- Network mode: `host`
- Privileged mode: required for Zigbee/Z-Wave dongles (when using Homey Bridge)
- Container mount: data directory → `/homey/user/`
- Default data location: `~/.homey-shs/` (varies per platform)