#!/bin/bash
# GLM Quota MenuBar (Swift) — launch / install / uninstall
#   ./run.sh             手动启动(后台)
#   ./run.sh --install   安装 launchd 开机自启(自动把本机绝对路径写入 plist)
#   ./run.sh --uninstall 移除 launchd 开机自启

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$SCRIPT_DIR/swift"
BINARY="$SWIFT_DIR/.build/glm-quota-menubar"
PLIST_NAME="com.lixiang.glm-quota-menubar.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# 编译 Swift 二进制(spm 在当前 macOS beta 上有问题,直接用 swiftc)
build() {
    echo "Building GlmQuotaMenubar..."
    mkdir -p "$SWIFT_DIR/.build"
    swiftc -framework AppKit -o "$BINARY" "$SWIFT_DIR"/Sources/GlmQuotaMenubar/*.swift
}

build_if_needed() {
    # 二进制缺失,或任一 Swift 源码比二进制新 → 重新编译。
    # 否则 run.sh 会一直复用旧二进制,改代码后重跑也不生效。
    if [ ! -f "$BINARY" ] || find "$SWIFT_DIR/Sources/GlmQuotaMenubar" -name '*.swift' -newer "$BINARY" -print -quit | grep -q .; then
        build
    fi
}

case "${1:-}" in
  --install)
    build_if_needed
    mkdir -p "$HOME/Library/LaunchAgents"
    # plist 是模板,占位符替换为本机实际绝对路径——launchd 不展开 ~ 和环境变量
    sed -e "s|__BINARY__|$BINARY|g" "$PLIST_SRC" > "$PLIST_DST"
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    # bootout 异步释放 label,立刻 bootstrap 会报 "Input/output error"
    sleep 2
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    echo "✅ 已安装 launchd 开机自启"
    echo "   binary: $BINARY"
    launchctl list | grep glm-quota-menubar
    ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "✅ 已移除 launchd 开机自启"
    ;;
  *)
    build_if_needed
    cd "$SCRIPT_DIR"
    nohup "$BINARY" > /tmp/glm-quota-menubar.log 2>&1 &
    echo "GLM Quota MenuBar started (PID $!)"
    echo "Log: /tmp/glm-quota-menubar.log"
    ;;
esac
