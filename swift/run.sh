#!/bin/bash
# GLM Quota MenuBar (Swift) — launch / install / uninstall
#   ./run.sh             手动启动(后台)
#   ./run.sh --install   安装 launchd 开机自启
#   ./run.sh --uninstall 移除 launchd 开机自启

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/.build/glm-quota-menubar"
PLIST_NAME="com.lixiang.glm-quota-menubar.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Build if needed (uses swiftc directly because SPM is broken on this macOS beta)
if [ ! -f "$BINARY" ]; then
    echo "Building GlmQuotaMenubar..."
    mkdir -p "$SCRIPT_DIR/.build"
    swiftc -framework AppKit -o "$BINARY" "$SCRIPT_DIR"/Sources/GlmQuotaMenubar/*.swift
fi

case "${1:-}" in
  --install)
    mkdir -p "$HOME/Library/LaunchAgents"
    sed -e "s|__BINARY__|$BINARY|g" \
        -e "s|__LOG__|/tmp/glm-quota-menubar.log|g" \
        "$PLIST_SRC" > "$PLIST_DST"
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    # bootout 异步释放 label,立刻 bootstrap 会报 "Input/output error"
    sleep 2
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    echo "✅ Installed launchd auto-start"
    echo "   binary: $BINARY"
    launchctl list | grep glm-quota-menubar
    ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "✅ Removed launchd auto-start"
    ;;
  *)
    cd "$SCRIPT_DIR"
    nohup "$BINARY" > /tmp/glm-quota-menubar.log 2>&1 &
    echo "GLM Quota MenuBar started (PID $!)"
    echo "Log: /tmp/glm-quota-menubar.log"
    ;;
esac
