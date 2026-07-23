#!/bin/bash
# GLM Quota MenuBar — launch / install / uninstall
#   ./run.sh             手动启动（后台）
#   ./run.sh --install   安装 launchd 开机自启（自动把本机绝对路径写入 plist）
#   ./run.sh --uninstall 移除 launchd 开机自启

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 跑菜单栏脚本的 Python 解释器,需已安装 rumps。
# 用 conda/venv 时请改为对应路径,或导出 GLM_MENUBAR_PYTHON。
PYTHON="${GLM_MENUBAR_PYTHON:-$(command -v python3)}"
PLIST_NAME="com.lixiang.glm-quota-menubar.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

case "${1:-}" in
  --install)
    mkdir -p "$HOME/Library/LaunchAgents"
    # plist 是模板,用占位符避免硬编码路径;此处替换为本机实际路径
    sed -e "s|__PYTHON__|$PYTHON|g" \
        -e "s|__SCRIPT_DIR__|$SCRIPT_DIR|g" \
        "$PLIST_SRC" > "$PLIST_DST"
    # 先卸载旧实例再加载
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    echo "✅ 已安装 launchd 开机自启"
    echo "   python: $PYTHON"
    echo "   script: $SCRIPT_DIR/glm_quota_menubar.py"
    launchctl list | grep glm-quota-menubar
    ;;
  --uninstall)
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    rm -f "$PLIST_DST"
    echo "✅ 已移除 launchd 开机自启"
    ;;
  *)
    cd "$SCRIPT_DIR"
    nohup "$PYTHON" "$SCRIPT_DIR/glm_quota_menubar.py" > /tmp/glm-quota-menubar.log 2>&1 &
    echo "GLM Quota MenuBar started (PID $!)"
    echo "Log: /tmp/glm-quota-menubar.log"
    ;;
esac
