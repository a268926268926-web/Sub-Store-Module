#!/system/bin/sh
# ============================================================
# 更新 Sub-Store 后端 (sub-store.bundle.js)
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
URL="https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js"
TMP="$BIN_DIR/sub-store.bundle.js.new"

current=$(cat "$BIN_DIR/backend_version" 2>/dev/null || echo unknown)
info "Sub-Store 后端当前版本: $current"

rm -f "$TMP"
info "下载最新后端 ..."
if ! download "$URL" "$TMP"; then
  rm -f "$TMP"
  err "后端下载失败"
  exit 1
fi
[ -s "$TMP" ] || { rm -f "$TMP"; err "下载文件为空"; exit 1; }

new=$(sed -n 's/.*SUB_STORE_BACKEND_VERSION: //p' "$TMP" | head -n 1)
if [ -z "$new" ]; then
  rm -f "$TMP"
  err "无法识别版本号"
  exit 1
fi
info "Sub-Store 后端最新版本: $new"

if [ "$current" = "$new" ]; then
  rm -f "$TMP"
  info "已是最新版本, 无需更新"
  exit 0
fi

# 完整性检查 (正常 bundle 约 3MB)
size=$(wc -c < "$TMP")
if [ "$size" -lt 100000 ]; then
  rm -f "$TMP"
  err "下载文件异常 (大小: $size)"
  exit 1
fi

TARGET="$BIN_DIR/sub-store.bundle.js"
OLD="$TARGET.old"
VERSION_FILE="$BIN_DIR/backend_version"
VERSION_OLD="$VERSION_FILE.old"
had_old=0
rm -f "$OLD" 2>/dev/null
if [ -f "$TARGET" ]; then
  mv -f "$TARGET" "$OLD" || {
    rm -f "$TMP"
    err "无法备份旧后端文件"
    exit 1
  }
  had_old=1
fi
if ! mv -f "$TMP" "$TARGET"; then
  [ "$had_old" = "1" ] && mv -f "$OLD" "$TARGET" 2>/dev/null
  err "替换后端文件失败"
  exit 1
fi
# 低权限用户 (shell, uid 2000) 需要可读; 下载文件可能因 umask 是 600
chmod 644 "$TARGET" 2>/dev/null
cp -f "$VERSION_FILE" "$VERSION_OLD" 2>/dev/null || rm -f "$VERSION_OLD" 2>/dev/null
if ! echo "$new" > "$VERSION_FILE"; then
  rm -f "$TARGET"
  [ "$had_old" = "1" ] && mv -f "$OLD" "$TARGET" 2>/dev/null
  [ -f "$VERSION_OLD" ] && mv -f "$VERSION_OLD" "$VERSION_FILE" 2>/dev/null
  err "写入后端版本文件失败"
  exit 1
fi
info "后端已更新到 $new"

if [ "$NO_RESTART" != "1" ]; then
  info "重启服务 ..."
  if ! restart_service; then
    err "重启失败，正在恢复旧后端"
    rm -f "$TARGET"
    [ "$had_old" = "1" ] && mv -f "$OLD" "$TARGET" 2>/dev/null
    if [ -f "$VERSION_OLD" ]; then
      mv -f "$VERSION_OLD" "$VERSION_FILE" 2>/dev/null
    else
      rm -f "$VERSION_FILE" 2>/dev/null
    fi
    restart_service || true
    exit 1
  fi
fi
