#!/system/bin/sh
# ============================================================
# Sub-Store for Android - 受锁保护的聚合更新
# 用法: update_all.sh [all|sub-store]
# all=后端+前端+http-meta稳定版；sub-store=后端+前端
# 任一组件或最终重启失败时, 恢复更新前的组件快照
# ============================================================

SCRIPTS_DIR=$(dirname "$0")
. "$SCRIPTS_DIR/lib.sh"
load_config
. "$SCRIPTS_DIR/auto_update_lib.sh"
auto_update_init_paths

TARGET=${1:-all}
case "$TARGET" in
  all) UPDATE_LABEL="全部更新" ;;
  sub-store) UPDATE_LABEL="Sub-Store 前后端更新" ;;
  *)
    err "未知聚合更新目标: $TARGET"
    exit 1
    ;;
esac

LOCK_OWNED=0
if [ "${SUBSTORE_UPDATE_LOCK_HELD:-0}" != "1" ]; then
  if update_lock_acquire; then
    LOCK_OWNED=1
  else
    err "另一个更新任务正在运行"
    exit 3
  fi
fi

# The lock guarantees no other aggregate job is using an old snapshot.
for _ua_stale in "$AUTO_CONFIG_DIR"/update-rollback.*; do
  [ -d "$_ua_stale" ] && rm -rf "$_ua_stale" 2>/dev/null
done

BIN_DIR="$sub_store_path/bin"
ROLLBACK_DIR="$AUTO_CONFIG_DIR/update-rollback.$$"
ROLLBACK_MANIFEST="$ROLLBACK_DIR/manifest"
SNAPSHOT_READY=0
SERVICE_WAS_RUNNING=0

auto_update_respect_service() {
  [ "${AUTO_UPDATE_RESPECT_SERVICE:-0}" = "1" ] || return 0
  if auto_update_module_disabled; then
    err "模块已禁用，取消自动更新"
    return 1
  fi
  if ! service_running; then
    err "Sub-Store 已停止，取消自动更新"
    return 1
  fi
  return 0
}

snapshot_entry() {
  _ua_rel=$1
  case "$_ua_rel" in
    *[\;\&\|\`\$]*)
      err "非法快照路径: $_ua_rel"
      return 1
      ;;
  esac
  _ua_parent=$(dirname "$_ua_rel")
  if [ -e "$BIN_DIR/$_ua_rel" ]; then
    mkdir -p "$ROLLBACK_DIR/files/$_ua_parent" 2>/dev/null || return 1
    cp -R "$BIN_DIR/$_ua_rel" "$ROLLBACK_DIR/files/$_ua_rel" 2>/dev/null || return 1
    printf 'present %s\n' "$_ua_rel" >>"$ROLLBACK_MANIFEST" || return 1
  else
    mkdir -p "$ROLLBACK_DIR/absent/$_ua_parent" 2>/dev/null || return 1
    printf 'absent %s\n' "$_ua_rel" >>"$ROLLBACK_MANIFEST" || return 1
  fi
}

create_snapshot() {
  rm -rf "$ROLLBACK_DIR" 2>/dev/null
  mkdir -p "$ROLLBACK_DIR/files" "$ROLLBACK_DIR/absent" 2>/dev/null || return 1
  : >"$ROLLBACK_MANIFEST" || return 1
  snapshot_entry "sub-store.bundle.js" || return 1
  snapshot_entry "backend_version" || return 1
  snapshot_entry "frontend" || return 1
  snapshot_entry "frontend_version" || return 1
  if [ "$TARGET" = "all" ]; then
    snapshot_entry "http-meta.bundle.js" || return 1
    snapshot_entry "http-meta/tpl.yaml" || return 1
    snapshot_entry "http-meta/http-meta" || return 1
    snapshot_entry "http-meta/kernel_version" || return 1
  fi
  SNAPSHOT_READY=1
}

restore_snapshot() {
  [ "$SNAPSHOT_READY" = "1" ] || return 1
  _ua_restore_failed=0
  info "检测到更新失败，正在恢复更新前组件 ..."
  while read -r _ua_kind _ua_rel; do
    case "$_ua_kind:$_ua_rel" in
      present:*)
        mkdir -p "$BIN_DIR/$(dirname "$_ua_rel")" 2>/dev/null || {
          _ua_restore_failed=1
          continue
        }
        _ua_restore_tmp="$BIN_DIR/$_ua_rel.restore.$$"
        rm -rf "$_ua_restore_tmp" 2>/dev/null
        if ! cp -R "$ROLLBACK_DIR/files/$_ua_rel" "$_ua_restore_tmp" 2>/dev/null; then
          _ua_restore_failed=1
          continue
        fi
        if ! rm -rf "$BIN_DIR/$_ua_rel" 2>/dev/null; then
          _ua_restore_failed=1
          rm -rf "$_ua_restore_tmp" 2>/dev/null
          continue
        fi
        if ! mv "$_ua_restore_tmp" "$BIN_DIR/$_ua_rel" 2>/dev/null; then
          _ua_restore_failed=1
          rm -rf "$_ua_restore_tmp" 2>/dev/null
        fi
        ;;
      absent:*)
        rm -rf "$BIN_DIR/$_ua_rel" 2>/dev/null || _ua_restore_failed=1
        ;;
    esac
  done <"$ROLLBACK_MANIFEST"
  if [ "$_ua_restore_failed" -eq 0 ]; then
    info "组件回滚完成"
    return 0
  fi
  err "组件回滚未完全成功，请检查 $BIN_DIR"
  return 1
}

cleanup_update_all() {
  _ua_rc=$?
  if [ "$_ua_rc" -ne 0 ] && [ "$SNAPSHOT_READY" = "1" ]; then
    restore_snapshot || true
    # If the service was running before the attempt, bring it back on old files.
    if [ "$SERVICE_WAS_RUNNING" = "1" ] && ! auto_update_module_disabled; then
      restart_service || true
    fi
  fi
  rm -rf "$ROLLBACK_DIR" 2>/dev/null
  if [ "$LOCK_OWNED" = "1" ]; then
    update_lock_release
  fi
  trap - EXIT HUP INT TERM
  exit "$_ua_rc"
}

trap cleanup_update_all EXIT
if [ "${AUTO_UPDATE_DETACHED:-0}" = "1" ]; then
  trap '' HUP
else
  trap 'exit 129' HUP
fi
trap 'exit 130' INT
trap 'exit 143' TERM

auto_update_respect_service || exit 1
service_running && SERVICE_WAS_RUNNING=1

if ! create_snapshot; then
  err "创建更新回滚快照失败，已取消更新"
  exit 1
fi

info "开始受锁保护的稳定渠道${UPDATE_LABEL}"
NO_RESTART=1 SUBSTORE_UPDATE_LOCK_HELD=1 AUTO_UPDATE_DETACHED="${AUTO_UPDATE_DETACHED:-0}" \
  sh "$SCRIPTS_DIR/update_backend.sh" || exit 1
auto_update_respect_service || exit 1

NO_RESTART=1 SUBSTORE_UPDATE_LOCK_HELD=1 AUTO_UPDATE_DETACHED="${AUTO_UPDATE_DETACHED:-0}" \
  sh "$SCRIPTS_DIR/update_frontend.sh" || exit 1
auto_update_respect_service || exit 1

if [ "$TARGET" = "all" ]; then
  # "all" always uses the stable kernel channel; Alpha is only manual/split.
  NO_RESTART=1 SUBSTORE_UPDATE_LOCK_HELD=1 AUTO_UPDATE_DETACHED="${AUTO_UPDATE_DETACHED:-0}" \
    sh "$SCRIPTS_DIR/update_http_meta.sh" all || exit 1
  auto_update_respect_service || exit 1
fi

info "重启服务 ..."
if ! restart_service; then
  err "更新后重启服务失败"
  exit 1
fi
sleep 2
if ! service_running; then
  err "更新后服务未能保持运行"
  exit 1
fi

info "${UPDATE_LABEL}完成"
exit 0
