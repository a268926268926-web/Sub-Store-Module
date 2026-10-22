#!/system/bin/sh
# ============================================================
# Sub-Store for Android - 持久自动更新调度器
# 用法: auto_update_daemon.sh {run|start|stop|status|execute}
# ============================================================

SCRIPTS_DIR=$(dirname "$0")
. "$SCRIPTS_DIR/lib.sh"
load_config
. "$SCRIPTS_DIR/auto_update_lib.sh"
auto_update_init_paths

case "${1:-run}" in
  run)
    auto_update_daemon_run
    ;;
  start)
    auto_update_load_config
    if [ "$AUTO_CFG_ENABLED" != "true" ] || [ "$AUTO_CFG_VALID" != "true" ]; then
      echo "disabled"
      exit 0
    fi
    auto_update_daemon_start
    if auto_update_daemon_running; then
      echo "running"
    else
      echo "stopped"
      exit 1
    fi
    ;;
  stop)
    auto_update_daemon_stop
    ;;
  status)
    if auto_update_daemon_running; then
      echo "running"
    else
      echo "stopped"
    fi
    ;;
  execute)
    auto_update_execute "${2:-manual}"
    ;;
  *)
    echo "用法: $0 {run|start|stop|status|execute [scheduled|manual]}"
    exit 1
    ;;
esac
