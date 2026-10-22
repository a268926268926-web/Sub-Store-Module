#!/system/bin/sh
# ============================================================
# 更新 Sub-Store 前端 (dist.zip)
# 设置 NO_RESTART=1 时跳过服务重启 (由调用方统一重启)
# ============================================================

SCRIPTS_DIR=$(dirname "$0")
. "$SCRIPTS_DIR/lib.sh"
load_config
. "$SCRIPTS_DIR/auto_update_lib.sh"
auto_update_init_paths
if ! update_lock_acquire; then
  err "另一个更新任务正在运行"
  exit 3
fi
trap update_lock_release EXIT
if [ "${AUTO_UPDATE_DETACHED:-0}" = "1" ]; then
  trap '' HUP
else
  trap 'update_lock_release; exit 129' HUP
fi
trap 'update_lock_release; exit 130' INT
trap 'update_lock_release; exit 143' TERM

BIN_DIR="$sub_store_path/bin"
URL="https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest/download/dist.zip"
TMP_ZIP="$BIN_DIR/frontend.new.zip"
TMP_DIR="$BIN_DIR/frontend.new"

current=$(cat "$BIN_DIR/frontend_version" 2>/dev/null || echo unknown)
info "Sub-Store 前端当前版本: $current"

rm -f "$TMP_ZIP"
rm -rf "$TMP_DIR"
info "下载最新前端 ..."
if ! download "$URL" "$TMP_ZIP"; then
  rm -f "$TMP_ZIP"
  err "前端下载失败"
  exit 1
fi
[ -s "$TMP_ZIP" ] || { rm -f "$TMP_ZIP"; err "下载文件为空"; exit 1; }

if ! unzip -q "$TMP_ZIP" -d "$TMP_DIR"; then
  rm -f "$TMP_ZIP"
  rm -rf "$TMP_DIR"
  err "解压失败"
  exit 1
fi
rm -f "$TMP_ZIP"

new=$(sed -n 's/.*<meta name="version" content="\([^"]*\)".*/\1/p' "$TMP_DIR/dist/index.html" 2>/dev/null | head -n 1)
if [ -z "$new" ]; then
  rm -rf "$TMP_DIR"
  err "无法识别版本号"
  exit 1
fi
info "Sub-Store 前端最新版本: $new"

if [ "$current" = "$new" ]; then
  rm -rf "$TMP_DIR"
  info "已是最新版本, 无需更新"
  exit 0
fi

# 原子替换
TARGET="$BIN_DIR/frontend"
OLD="$BIN_DIR/frontend.old"
VERSION_FILE="$BIN_DIR/frontend_version"
VERSION_OLD="$VERSION_FILE.old"
had_old=0
rm -rf "$OLD"
if [ -d "$TARGET" ]; then
  mv "$TARGET" "$OLD" || {
    rm -rf "$TMP_DIR"
    err "无法备份旧前端目录"
    exit 1
  }
  had_old=1
fi
if ! mv "$TMP_DIR/dist" "$TARGET"; then
  [ "$had_old" = "1" ] && mv "$OLD" "$TARGET" 2>/dev/null
  rm -rf "$TMP_DIR"
  err "替换前端目录失败"
  exit 1
fi
rm -rf "$TMP_DIR"
# 低权限用户需要可读 (unzip 可能受 umask 影响)
chmod -R a+rX "$TARGET" 2>/dev/null
cp -f "$VERSION_FILE" "$VERSION_OLD" 2>/dev/null || rm -f "$VERSION_OLD" 2>/dev/null
if ! echo "$new" > "$VERSION_FILE"; then
  rm -rf "$TARGET"
  [ "$had_old" = "1" ] && mv "$OLD" "$TARGET" 2>/dev/null
  [ -f "$VERSION_OLD" ] && mv -f "$VERSION_OLD" "$VERSION_FILE" 2>/dev/null
  err "写入前端版本文件失败"
  exit 1
fi
info "前端已更新到 $new"

if [ "$NO_RESTART" != "1" ]; then
  info "重启服务 ..."
  if ! restart_service; then
    err "重启失败，正在恢复旧前端"
    rm -rf "$TARGET"
    [ "$had_old" = "1" ] && mv "$OLD" "$TARGET" 2>/dev/null
    if [ -f "$VERSION_OLD" ]; then
      mv -f "$VERSION_OLD" "$VERSION_FILE" 2>/dev/null
    else
      rm -f "$VERSION_FILE" 2>/dev/null
    fi
    restart_service || true
    exit 1
  fi
fi
