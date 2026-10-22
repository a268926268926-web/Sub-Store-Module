#!/system/bin/sh
# ============================================================
# Sub-Store for Android - 自动更新公共函数
# 由 webui.sh / auto_update_daemon.sh / update_all.sh source
# 不依赖 cron、systemd 或 Python
# ============================================================

auto_update_init_paths() {
  AUTO_CONFIG_DIR="$sub_store_path/scripts"
  AUTO_CONFIG_FILE="$AUTO_CONFIG_DIR/auto_update.conf"
  AUTO_STATE_FILE="$AUTO_CONFIG_DIR/auto-update.state"
  AUTO_LOG_FILE="$run_path/auto-update.log"
  AUTO_ERROR_LOG="$run_path/auto-update_error.log"
  AUTO_JOB_PID_FILE="$run_path/auto-update-job.pid"
  AUTO_UPDATE_LOCK_DIR="$AUTO_CONFIG_DIR/update.lock"
  AUTO_JOB_LOCK_DIR="$AUTO_CONFIG_DIR/auto-update-job.lock"
  AUTO_DAEMON_LOCK_DIR="$AUTO_CONFIG_DIR/auto-update-daemon.lock"
}

auto_update_config_defaults() {
  AUTO_CFG_ENABLED=false
  AUTO_CFG_SCHEDULE=daily
  AUTO_CFG_INTERVAL_DAYS=7
  AUTO_CFG_WEEKDAY=1
  AUTO_CFG_HOUR=3
  AUTO_CFG_MINUTE=0
  AUTO_CFG_VALID=true
}

auto_update_valid_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}

auto_update_load_config() {
  auto_update_init_paths
  auto_update_config_defaults
  [ -f "$AUTO_CONFIG_FILE" ] || return 0

  while IFS='=' read -r _au_key _au_value || [ -n "$_au_key" ]; do
    _au_value=$(printf '%s' "$_au_value" | tr -d '\r')
    case "$_au_key" in
      ""|\#*) continue ;;
      enabled)
        case "$_au_value" in
          true|false) AUTO_CFG_ENABLED=$_au_value ;;
          *) AUTO_CFG_VALID=false ;;
        esac
        ;;
      schedule)
        case "$_au_value" in
          daily|weekly|interval_days) AUTO_CFG_SCHEDULE=$_au_value ;;
          *) AUTO_CFG_VALID=false ;;
        esac
        ;;
      interval_days)
        if auto_update_valid_int "$_au_value" 1 365; then
          AUTO_CFG_INTERVAL_DAYS=$_au_value
        else
          AUTO_CFG_VALID=false
        fi
        ;;
      weekday)
        if auto_update_valid_int "$_au_value" 0 6; then
          AUTO_CFG_WEEKDAY=$_au_value
        else
          AUTO_CFG_VALID=false
        fi
        ;;
      hour)
        if auto_update_valid_int "$_au_value" 0 23; then
          AUTO_CFG_HOUR=$_au_value
        else
          AUTO_CFG_VALID=false
        fi
        ;;
      minute)
        if auto_update_valid_int "$_au_value" 0 59; then
          AUTO_CFG_MINUTE=$_au_value
        else
          AUTO_CFG_VALID=false
        fi
        ;;
      version) : ;;
      *) : ;;
    esac
  done <"$AUTO_CONFIG_FILE"

  if [ "$AUTO_CFG_VALID" != "true" ]; then
    # Invalid persisted configuration is fail-closed.
    auto_update_config_defaults
    AUTO_CFG_VALID=false
  fi
}

auto_update_write_config() {  # enabled schedule interval_days weekday hour minute
  mkdir -p "$AUTO_CONFIG_DIR" 2>/dev/null || return 1
  _au_tmp="$AUTO_CONFIG_FILE.tmp.$$"
  (
    umask 077
    {
      echo "# Managed by Sub-Store WebUI. Changes are atomic."
      echo "version=1"
      echo "enabled=$1"
      echo "schedule=$2"
      echo "interval_days=$3"
      echo "weekday=$4"
      echo "hour=$5"
      echo "minute=$6"
    } >"$_au_tmp"
  ) || {
    rm -f "$_au_tmp" 2>/dev/null
    return 1
  }
  chmod 0600 "$_au_tmp" 2>/dev/null
  mv -f "$_au_tmp" "$AUTO_CONFIG_FILE" || {
    rm -f "$_au_tmp" 2>/dev/null
    return 1
  }
}

auto_update_state_defaults() {
  AUTO_LAST_RUN=""
  AUTO_LAST_FINISH=""
  AUTO_LAST_STATUS=never
  AUTO_LAST_RESULT=""
  AUTO_LAST_TRIGGER=""
  AUTO_NEXT_RUN=""
  AUTO_STATE_SIG=""
}

auto_update_load_state() {
  auto_update_state_defaults
  [ -f "$AUTO_STATE_FILE" ] || return 0
  while IFS='=' read -r _au_key _au_value || [ -n "$_au_key" ]; do
    _au_value=$(printf '%s' "$_au_value" | tr -d '\r')
    case "$_au_key" in
      LAST_RUN) AUTO_LAST_RUN=$_au_value ;;
      LAST_FINISH) AUTO_LAST_FINISH=$_au_value ;;
      LAST_STATUS) AUTO_LAST_STATUS=$_au_value ;;
      LAST_RESULT) AUTO_LAST_RESULT=$_au_value ;;
      LAST_TRIGGER) AUTO_LAST_TRIGGER=$_au_value ;;
      NEXT_RUN) AUTO_NEXT_RUN=$_au_value ;;
      SCHEDULE_SIG) AUTO_STATE_SIG=$_au_value ;;
    esac
  done <"$AUTO_STATE_FILE"
  case "$AUTO_LAST_STATUS" in
    never|queued|running|success|failed|skipped) : ;;
    *) AUTO_LAST_STATUS=never ;;
  esac
}

auto_update_sanitize() {
  printf '%s' "$1" | tr '\r\n' '  ' | cut -c 1-300
}

auto_update_save_state() {  # last_run last_finish last_status last_result last_trigger next_run sig
  mkdir -p "$AUTO_CONFIG_DIR" 2>/dev/null || return 1
  _au_tmp="$AUTO_STATE_FILE.tmp.$$"
  _au_result=$(auto_update_sanitize "$4")
  (
    umask 077
    {
      echo "LAST_RUN=$1"
      echo "LAST_FINISH=$2"
      echo "LAST_STATUS=$3"
      echo "LAST_RESULT=$_au_result"
      echo "LAST_TRIGGER=$5"
      echo "NEXT_RUN=$6"
      echo "SCHEDULE_SIG=$7"
    } >"$_au_tmp"
  ) || {
    rm -f "$_au_tmp" 2>/dev/null
    return 1
  }
  chmod 0600 "$_au_tmp" 2>/dev/null
  mv -f "$_au_tmp" "$AUTO_STATE_FILE" || {
    rm -f "$_au_tmp" 2>/dev/null
    return 1
  }
}

auto_update_schedule_sig() {
  _au_tz_offset=$(date '+%z' 2>/dev/null)
  printf '%s:%s:%s:%s:%s:%s' \
    "$AUTO_CFG_SCHEDULE" "$AUTO_CFG_INTERVAL_DAYS" "$AUTO_CFG_WEEKDAY" \
    "$AUTO_CFG_HOUR" "$AUTO_CFG_MINUTE" "${_au_tz_offset:-unknown}"
}

auto_update_persist_current_state() {
  auto_update_save_state \
    "$AUTO_LAST_RUN" "$AUTO_LAST_FINISH" "$AUTO_LAST_STATUS" \
    "$AUTO_LAST_RESULT" "$AUTO_LAST_TRIGGER" "$AUTO_NEXT_RUN" \
    "$AUTO_STATE_SIG"
}

auto_update_node_bin() {
  if [ -n "${AUTO_UPDATE_NODE_BIN:-}" ] && [ -x "$AUTO_UPDATE_NODE_BIN" ]; then
    printf '%s' "$AUTO_UPDATE_NODE_BIN"
    return 0
  fi
  if [ -x "$sub_store_path/bin/sub_store_node" ]; then
    printf '%s' "$sub_store_path/bin/sub_store_node"
    return 0
  fi
  command -v node 2>/dev/null
}

auto_update_parse_config_json() {  # $1=base64(JSON); sets AUTO_NEW_* on success
  _au_node=$(auto_update_node_bin)
  if [ -z "$_au_node" ]; then
    AUTO_PARSE_ERROR="找不到可用的 Node 运行时"
    return 1
  fi

  _au_parsed=$(
    printf '%s' "$1" | base64 -d 2>/dev/null |
      AUTO_CUR_ENABLED="$AUTO_CFG_ENABLED" \
      AUTO_CUR_SCHEDULE="$AUTO_CFG_SCHEDULE" \
      AUTO_CUR_INTERVAL="$AUTO_CFG_INTERVAL_DAYS" \
      AUTO_CUR_WEEKDAY="$AUTO_CFG_WEEKDAY" \
      AUTO_CUR_HOUR="$AUTO_CFG_HOUR" \
      AUTO_CUR_MINUTE="$AUTO_CFG_MINUTE" \
      "$_au_node" -e '
        const fs = require("fs");
        const fail = (m) => { throw new Error(m); };
        let text = fs.readFileSync(0, "utf8");
        if (!text.trim()) fail("JSON 为空");
        const obj = JSON.parse(text);
        if (!obj || typeof obj !== "object" || Array.isArray(obj)) fail("配置必须是 JSON 对象");

        const env = process.env;
        const pick = (a, b, fallback) => a !== undefined ? a : (b !== undefined ? b : fallback);
        const enabled = pick(obj.enabled, undefined, env.AUTO_CUR_ENABLED === "true");
        if (typeof enabled !== "boolean") fail("enabled 必须是布尔值");

        const schedule = pick(obj.schedule, obj.frequency, env.AUTO_CUR_SCHEDULE);
        if (!["daily", "weekly", "interval_days"].includes(schedule)) {
          fail("schedule 必须是 daily、weekly 或 interval_days");
        }

        const asInt = (v, name) => {
          if (typeof v !== "number" || !Number.isInteger(v)) fail(name + " 必须是整数");
          return v;
        };
        const hour = asInt(pick(obj.hour, undefined, Number(env.AUTO_CUR_HOUR)), "hour");
        const minute = asInt(pick(obj.minute, undefined, Number(env.AUTO_CUR_MINUTE)), "minute");
        const intervalDays = asInt(
          pick(obj.intervalDays, obj.interval_days, Number(env.AUTO_CUR_INTERVAL)),
          "intervalDays"
        );
        const weekday = asInt(pick(obj.weekday, undefined, Number(env.AUTO_CUR_WEEKDAY)), "weekday");
        if (hour < 0 || hour > 23) fail("hour 必须在 0-23 之间");
        if (minute < 0 || minute > 59) fail("minute 必须在 0-59 之间");
        if (intervalDays < 1 || intervalDays > 365) fail("intervalDays 必须在 1-365 之间");
        if (weekday < 0 || weekday > 6) fail("weekday 必须在 0-6 之间 (0=周日)");

        process.stdout.write([
          enabled ? "true" : "false",
          schedule,
          String(intervalDays),
          String(weekday),
          String(hour),
          String(minute)
        ].join("\n") + "\n");
      ' 2>/dev/null
  )
  [ -n "$_au_parsed" ] || {
    AUTO_PARSE_ERROR="JSON 格式或字段校验失败"
    return 1
  }
  AUTO_NEW_ENABLED=$(printf '%s\n' "$_au_parsed" | sed -n '1p')
  AUTO_NEW_SCHEDULE=$(printf '%s\n' "$_au_parsed" | sed -n '2p')
  AUTO_NEW_INTERVAL_DAYS=$(printf '%s\n' "$_au_parsed" | sed -n '3p')
  AUTO_NEW_WEEKDAY=$(printf '%s\n' "$_au_parsed" | sed -n '4p')
  AUTO_NEW_HOUR=$(printf '%s\n' "$_au_parsed" | sed -n '5p')
  AUTO_NEW_MINUTE=$(printf '%s\n' "$_au_parsed" | sed -n '6p')
  return 0
}

auto_update_now() {
  case "${AUTO_UPDATE_NOW_OVERRIDE:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$AUTO_UPDATE_NOW_OVERRIDE" ;;
  esac
}

auto_update_iso() {
  [ -n "$1" ] || return 0
  date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null
}

auto_update_local_midnight() {
  _au_day=$(date -d "@$1" '+%Y-%m-%d' 2>/dev/null)
  date -d "$_au_day 00:00:00" '+%s' 2>/dev/null
}

auto_update_next_epoch() {  # $1=base epoch
  _au_base=$1
  case "$_au_base" in
    ''|*[!0-9]*) _au_base=$(auto_update_now) ;;
  esac
  _au_midnight=$(auto_update_local_midnight "$_au_base")
  [ -n "$_au_midnight" ] || return 1
  _au_tod=$((AUTO_CFG_HOUR * 3600 + AUTO_CFG_MINUTE * 60))

  case "$AUTO_CFG_SCHEDULE" in
    daily)
      _au_next=$((_au_midnight + _au_tod))
      [ "$_au_next" -gt "$_au_base" ] || _au_next=$((_au_next + 86400))
      ;;
    weekly)
      _au_day=$(date -d "@$_au_base" '+%w' 2>/dev/null)
      [ -n "$_au_day" ] || _au_day=0
      _au_days=$((AUTO_CFG_WEEKDAY - _au_day))
      [ "$_au_days" -ge 0 ] || _au_days=$((_au_days + 7))
      _au_next=$((_au_midnight + _au_days * 86400 + _au_tod))
      [ "$_au_next" -gt "$_au_base" ] || _au_next=$((_au_next + 7 * 86400))
      ;;
    interval_days)
      _au_step=$((AUTO_CFG_INTERVAL_DAYS * 86400))
      _au_next=$((_au_midnight + _au_step + _au_tod))
      _au_guard=0
      while [ "$_au_next" -le "$_au_base" ] && [ "$_au_guard" -lt 1000 ]; do
        _au_next=$((_au_next + _au_step))
        _au_guard=$((_au_guard + 1))
      done
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$_au_next"
}

auto_update_ensure_next() {
  [ "$AUTO_CFG_ENABLED" = "true" ] || return 0
  _au_now=$(auto_update_now)
  _au_sig=$(auto_update_schedule_sig)
  case "$AUTO_NEXT_RUN" in
    ''|*[!0-9]*) _au_need_next=1 ;;
    *) _au_need_next=0 ;;
  esac
  [ "$AUTO_STATE_SIG" = "$_au_sig" ] || _au_need_next=1
  [ "$_au_need_next" -eq 0 ] && return 0

  _au_base=$_au_now
  if [ "$AUTO_CFG_SCHEDULE" = "interval_days" ]; then
    case "$AUTO_LAST_RUN" in
      ''|*[!0-9]*) : ;;
      *) _au_base=$AUTO_LAST_RUN ;;
    esac
  fi
  AUTO_NEXT_RUN=$(auto_update_next_epoch "$_au_base") || AUTO_NEXT_RUN=""
  AUTO_STATE_SIG=$_au_sig
  auto_update_persist_current_state
}

update_lock_acquire() {
  [ "${SUBSTORE_UPDATE_LOCK_HELD:-0}" = "1" ] && return 0
  auto_update_init_paths
  pid_lock_acquire "$AUTO_UPDATE_LOCK_DIR"
}

update_lock_release() {
  [ "${SUBSTORE_UPDATE_LOCK_HELD:-0}" = "1" ] && return 0
  [ -n "${AUTO_UPDATE_LOCK_DIR:-}" ] || return 0
  pid_lock_release "$AUTO_UPDATE_LOCK_DIR"
}

update_lock_active() {
  auto_update_init_paths
  pid_lock_active "$AUTO_UPDATE_LOCK_DIR"
}

auto_update_job_running() {
  auto_update_init_paths
  pid_lock_active "$AUTO_JOB_LOCK_DIR"
}

auto_update_daemon_running() {
  auto_update_init_paths
  pid_lock_active "$AUTO_DAEMON_LOCK_DIR"
}

auto_update_module_disabled() {
  [ -f "$(dirname "$SCRIPTS_DIR")/disable" ]
}

auto_update_rotate_log() {
  mkdir -p "$run_path" 2>/dev/null
  # Keep logs from the current and previous two automatic runs.
  for _au_file in "$AUTO_LOG_FILE" "$AUTO_ERROR_LOG"; do
    [ -f "$_au_file" ] || continue
    rm -f "$_au_file.2" 2>/dev/null
    mv -f "$_au_file.1" "$_au_file.2" 2>/dev/null
    mv -f "$_au_file" "$_au_file.1" 2>/dev/null
    : >"$_au_file"
  done
  _au_daemon_log="$run_path/auto-update-daemon.log"
  if [ -f "$_au_daemon_log" ]; then
    _au_size=$(wc -c <"$_au_daemon_log" 2>/dev/null || echo 0)
    if [ "$_au_size" -gt 1048576 ]; then
      mv -f "$_au_daemon_log.1" "$_au_daemon_log.2" 2>/dev/null
      mv -f "$_au_daemon_log" "$_au_daemon_log.1" 2>/dev/null
      : >"$_au_daemon_log"
    fi
  fi
}

auto_update_last_error() {
  _au_detail=$(grep -h '\[Error\]' "$AUTO_LOG_FILE" "$AUTO_ERROR_LOG" 2>/dev/null | tail -n 1)
  [ -n "$_au_detail" ] || _au_detail=$(tail -n 1 "$AUTO_ERROR_LOG" 2>/dev/null)
  [ -n "$_au_detail" ] || _au_detail=$(tail -n 1 "$AUTO_LOG_FILE" 2>/dev/null)
  printf '%s' "$_au_detail"
}

auto_update_print_log() {
  if [ -f "$AUTO_LOG_FILE" ]; then
    tail -n 200 "$AUTO_LOG_FILE"
  fi
  if [ -s "$AUTO_ERROR_LOG" ]; then
    echo "[Error] --- auto-update_error.log ---"
    tail -n 50 "$AUTO_ERROR_LOG"
  fi
}

auto_update_finish() {  # $1=status $2=result
  auto_update_load_state
  AUTO_LAST_FINISH=$(auto_update_now)
  AUTO_LAST_STATUS=$1
  AUTO_LAST_RESULT=$(auto_update_sanitize "$2")
  AUTO_STATE_SIG=$(auto_update_schedule_sig)
  auto_update_persist_current_state
}

auto_update_spawn_job() {  # $1=scheduled|manual
  auto_update_rotate_log
  if command -v nohup >/dev/null 2>&1; then
    nohup sh "$SCRIPTS_DIR/auto_update_daemon.sh" execute "$1" \
      >>"$AUTO_LOG_FILE" 2>>"$AUTO_ERROR_LOG" </dev/null &
  else
    sh "$SCRIPTS_DIR/auto_update_daemon.sh" execute "$1" \
      >>"$AUTO_LOG_FILE" 2>>"$AUTO_ERROR_LOG" </dev/null &
  fi
  _au_job_pid=$!
  printf '%s\n' "$_au_job_pid" >"$AUTO_JOB_PID_FILE"
  return 0
}

auto_update_start_due() {
  _au_now=$1
  if update_lock_active || auto_update_job_running; then
    AUTO_NEXT_RUN=$((_au_now + 300))
    AUTO_LAST_STATUS=skipped
    AUTO_LAST_RESULT="另一个更新任务正在运行，5 分钟后重试"
    AUTO_STATE_SIG=$(auto_update_schedule_sig)
    auto_update_persist_current_state
    return 0
  fi

  AUTO_NEXT_RUN=$(auto_update_next_epoch "$_au_now") || AUTO_NEXT_RUN=""
  AUTO_LAST_RUN=$_au_now
  AUTO_LAST_FINISH=""
  AUTO_LAST_STATUS=running
  AUTO_LAST_RESULT="定时更新已启动"
  AUTO_LAST_TRIGGER=scheduled
  AUTO_STATE_SIG=$(auto_update_schedule_sig)
  if ! auto_update_persist_current_state; then
    return 1
  fi
  if ! auto_update_spawn_job scheduled; then
    auto_update_finish failed "无法启动定时更新进程"
    return 1
  fi
  return 0
}

auto_update_execute() {  # $1=scheduled|manual
  _au_trigger=$1
  auto_update_init_paths
  auto_update_load_config
  auto_update_load_state
  _AUTO_JOB_ACTIVE=0

  if ! pid_lock_acquire "$AUTO_JOB_LOCK_DIR"; then
    auto_update_finish failed "更新任务互斥锁被占用"
    return 3
  fi
  if ! update_lock_acquire; then
    pid_lock_release "$AUTO_JOB_LOCK_DIR"
    auto_update_finish failed "另一个更新任务正在运行"
    return 3
  fi

  _AUTO_JOB_ACTIVE=1
  auto_update_job_cleanup() {
    _au_rc=$?
    if [ "$_AUTO_JOB_ACTIVE" = "1" ]; then
      auto_update_finish failed "自动更新异常中止 (退出码 $_au_rc)"
    fi
    update_lock_release
    pid_lock_release "$AUTO_JOB_LOCK_DIR"
    trap - EXIT HUP INT TERM
    exit "$_au_rc"
  }
  trap auto_update_job_cleanup EXIT
  trap '' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ "$_au_trigger" = "scheduled" ]; then
    if auto_update_module_disabled; then
      auto_update_finish skipped "模块已禁用，跳过定时更新"
      _AUTO_JOB_ACTIVE=0
      return 0
    fi
    if ! service_running; then
      auto_update_finish skipped "Sub-Store 已停止，跳过定时更新"
      _AUTO_JOB_ACTIVE=0
      return 0
    fi
  fi

  _au_now=$(auto_update_now)
  AUTO_LAST_RUN=$_au_now
  AUTO_LAST_STATUS=running
  AUTO_LAST_RESULT="正在执行稳定渠道全部更新"
  AUTO_LAST_TRIGGER=$_au_trigger
  AUTO_STATE_SIG=$(auto_update_schedule_sig)
  if ! auto_update_persist_current_state; then
    auto_update_finish failed "无法持久化自动更新运行状态"
    _AUTO_JOB_ACTIVE=0
    return 1
  fi

  SUBSTORE_UPDATE_LOCK_HELD=1 AUTO_UPDATE_RESPECT_SERVICE=1 AUTO_UPDATE_DETACHED=1 \
    sh "$SCRIPTS_DIR/update_all.sh" all
  _au_rc=$?
  tail -n 50 "$run_path/run.log" >>"$AUTO_LOG_FILE" 2>/dev/null
  if [ "$_au_rc" -eq 0 ]; then
    auto_update_finish success "全部更新成功"
  else
    _au_detail=$(auto_update_last_error)
    [ -n "$_au_detail" ] || _au_detail="全部更新失败 (退出码 $_au_rc)"
    auto_update_finish failed "$_au_detail"
  fi
  _AUTO_JOB_ACTIVE=0
  return "$_au_rc"
}

auto_update_status_json() {
  auto_update_load_config
  auto_update_load_state
  auto_update_ensure_next

  if [ "$AUTO_CFG_ENABLED" = "true" ]; then _au_enabled=true; else _au_enabled=false; fi
  if [ "$AUTO_CFG_VALID" = "true" ]; then _au_cfg_valid=true; else _au_cfg_valid=false; fi
  if auto_update_daemon_running; then _au_daemon=true; else _au_daemon=false; fi
  if auto_update_job_running || update_lock_active; then _au_running=true; else _au_running=false; fi
  if [ "$AUTO_LAST_STATUS" = "running" ]; then _au_state_running=true; else _au_state_running=false; fi

  case "$AUTO_LAST_RUN" in
    ''|*[!0-9]*) _au_last_run=null ;;
    *)
      _au_tmp_iso=$(auto_update_iso "$AUTO_LAST_RUN")
      [ -n "$_au_tmp_iso" ] && _au_last_run="\"$(json_escape "$_au_tmp_iso")\"" || _au_last_run=null
      ;;
  esac
  case "$AUTO_LAST_FINISH" in
    ''|*[!0-9]*) _au_last_finish=null ;;
    *)
      _au_tmp_iso=$(auto_update_iso "$AUTO_LAST_FINISH")
      [ -n "$_au_tmp_iso" ] && _au_last_finish="\"$(json_escape "$_au_tmp_iso")\"" || _au_last_finish=null
      ;;
  esac
  case "$AUTO_NEXT_RUN" in
    ''|*[!0-9]*) _au_next=null ;;
    *)
      if [ "$AUTO_CFG_ENABLED" = "true" ]; then
        _au_tmp_iso=$(auto_update_iso "$AUTO_NEXT_RUN")
        [ -n "$_au_tmp_iso" ] && _au_next="\"$(json_escape "$_au_tmp_iso")\"" || _au_next=null
      else
        _au_next=null
      fi
      ;;
  esac

  printf '{'
  if [ -n "${AUTO_STATUS_ERROR:-}" ]; then
    printf '"success":false,'
    if [ "${AUTO_STATUS_SAVED:-false}" = "true" ]; then
      printf '"saved":true,'
    else
      printf '"saved":false,'
    fi
    printf '"error":"%s",' "$(json_escape "$AUTO_STATUS_ERROR")"
  elif [ "${AUTO_STATUS_SAVED:-false}" = "true" ]; then
    printf '"success":true,"saved":true,'
  else
    printf '"success":true,'
  fi
  printf '"enabled":%s,' "$_au_enabled"
  printf '"schedule":"%s",' "$(json_escape "$AUTO_CFG_SCHEDULE")"
  printf '"hour":%s,' "$AUTO_CFG_HOUR"
  printf '"minute":%s,' "$AUTO_CFG_MINUTE"
  printf '"intervalDays":%s,' "$AUTO_CFG_INTERVAL_DAYS"
  printf '"weekday":%s,' "$AUTO_CFG_WEEKDAY"
  printf '"configValid":%s,' "$_au_cfg_valid"
  printf '"running":%s,' "$_au_running"
  printf '"stateRunning":%s,' "$_au_state_running"
  printf '"lastRun":%s,' "$_au_last_run"
  printf '"lastFinish":%s,' "$_au_last_finish"
  printf '"lastStatus":"%s",' "$(json_escape "$AUTO_LAST_STATUS")"
  printf '"lastResult":"%s",' "$(json_escape "$AUTO_LAST_RESULT")"
  printf '"lastTrigger":"%s",' "$(json_escape "$AUTO_LAST_TRIGGER")"
  printf '"nextRun":%s,' "$_au_next"
  printf '"daemonRunning":%s,' "$_au_daemon"
  printf '"updateRunning":%s' "$_au_running"
  printf '}\n'
}

auto_update_json_error() {
  printf '{"success":false,"saved":false,"accepted":false,"error":"%s"}\n' \
    "$(json_escape "$1")"
}

auto_update_config_error_json() {
  AUTO_STATUS_ERROR=$1
  auto_update_status_json
}

auto_update_config_command() {
  auto_update_init_paths
  auto_update_load_config
  auto_update_load_state
  if ! auto_update_parse_config_json "$1"; then
    auto_update_config_error_json "${AUTO_PARSE_ERROR:-配置校验失败}"
    return 1
  fi
  if ! auto_update_write_config \
    "$AUTO_NEW_ENABLED" "$AUTO_NEW_SCHEDULE" "$AUTO_NEW_INTERVAL_DAYS" \
    "$AUTO_NEW_WEEKDAY" "$AUTO_NEW_HOUR" "$AUTO_NEW_MINUTE"; then
    auto_update_config_error_json "无法写入 $AUTO_CONFIG_FILE"
    return 1
  fi

  auto_update_load_config
  _au_now=$(auto_update_now)
  AUTO_NEXT_RUN=$(auto_update_next_epoch "$_au_now") || AUTO_NEXT_RUN=""
  AUTO_STATE_SIG=$(auto_update_schedule_sig)
  if ! auto_update_persist_current_state; then
    AUTO_STATUS_SAVED=true
    auto_update_config_error_json "配置已保存，但无法写入自动更新状态"
    return 1
  fi
  if [ "$AUTO_CFG_ENABLED" = "true" ]; then
    if ! auto_update_daemon_start; then
      AUTO_STATUS_SAVED=true
      auto_update_config_error_json "配置已保存，但自动更新调度器启动失败"
      return 1
    fi
  else
    auto_update_daemon_stop
  fi
  AUTO_STATUS_SAVED=true
  auto_update_status_json
}

auto_update_run_now_json() {
  auto_update_init_paths
  auto_update_load_config
  auto_update_load_state
  if auto_update_module_disabled; then
    auto_update_json_error "模块已禁用，无法立即执行更新"
    return 1
  fi
  if update_lock_active || auto_update_job_running; then
    auto_update_json_error "另一个更新任务正在运行"
    return 1
  fi

  _au_now=$(auto_update_now)
  AUTO_LAST_RUN=$_au_now
  AUTO_LAST_FINISH=""
  AUTO_LAST_STATUS=running
  AUTO_LAST_RESULT="已请求立即执行稳定渠道全部更新"
  AUTO_LAST_TRIGGER=manual
  AUTO_STATE_SIG=$(auto_update_schedule_sig)
  if ! auto_update_persist_current_state; then
    auto_update_json_error "无法写入自动更新状态"
    return 1
  fi
  if ! auto_update_spawn_job manual; then
    auto_update_finish failed "无法启动立即更新进程"
    auto_update_json_error "无法启动立即更新进程"
    return 1
  fi
  printf '{"success":true,"accepted":true,"queued":true,"pid":%s,"message":"%s"}\n' \
    "$_au_job_pid" "$(json_escape "立即更新已开始")"
}

auto_update_daemon_start() {
  auto_update_init_paths
  mkdir -p "$run_path" 2>/dev/null
  auto_update_load_config
  if [ "$AUTO_CFG_ENABLED" != "true" ] || [ "$AUTO_CFG_VALID" != "true" ]; then
    return 0
  fi
  auto_update_daemon_running && return 0
  if command -v nohup >/dev/null 2>&1; then
    nohup sh "$SCRIPTS_DIR/auto_update_daemon.sh" run \
      >>"$run_path/auto-update-daemon.log" 2>&1 </dev/null &
  else
    sh "$SCRIPTS_DIR/auto_update_daemon.sh" run \
      >>"$run_path/auto-update-daemon.log" 2>&1 </dev/null &
  fi
  _au_i=0
  while [ "$_au_i" -lt 30 ]; do
    auto_update_daemon_running && return 0
    sleep 0.1
    _au_i=$((_au_i + 1))
  done
  return 1
}

auto_update_daemon_stop() {
  auto_update_init_paths
  _au_pid=""
  if [ ! -f "$AUTO_DAEMON_LOCK_DIR/owner" ]; then
    rm -rf "$AUTO_DAEMON_LOCK_DIR" 2>/dev/null
    return 0
  fi
  read -r _au_pid _au_start <"$AUTO_DAEMON_LOCK_DIR/owner" 2>/dev/null || true
  case "$_au_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if pid_lock_owner_alive "$AUTO_DAEMON_LOCK_DIR"; then
    kill -15 "$_au_pid" 2>/dev/null
    _au_i=0
    while kill -0 "$_au_pid" 2>/dev/null && [ "$_au_i" -lt 20 ]; do
      sleep 0.1
      _au_i=$((_au_i + 1))
    done
    if kill -0 "$_au_pid" 2>/dev/null; then
      kill -9 "$_au_pid" 2>/dev/null
    fi
  fi
  rm -rf "$AUTO_DAEMON_LOCK_DIR" 2>/dev/null
}

auto_update_daemon_run() {
  auto_update_init_paths
  if ! pid_lock_acquire "$AUTO_DAEMON_LOCK_DIR"; then
    return 0
  fi
  trap 'pid_lock_release "$AUTO_DAEMON_LOCK_DIR"' EXIT
  trap '' HUP
  trap 'exit 0' INT TERM

  while :; do
    auto_update_load_config
    auto_update_load_state
    _au_now=$(auto_update_now)

    if [ "$AUTO_LAST_STATUS" = "running" ] \
      && ! auto_update_job_running && ! update_lock_active; then
      AUTO_LAST_STATUS=failed
      AUTO_LAST_RESULT="检测到上一次自动更新异常中断"
      AUTO_LAST_FINISH=$_au_now
      auto_update_persist_current_state
    fi

    if [ "$AUTO_CFG_ENABLED" = "true" ] && [ "$AUTO_CFG_VALID" = "true" ]; then
      auto_update_ensure_next
      case "$AUTO_NEXT_RUN" in
        ''|*[!0-9]*) : ;;
        *)
          if [ "$_au_now" -ge "$AUTO_NEXT_RUN" ]; then
            if auto_update_module_disabled; then
              AUTO_NEXT_RUN=$(auto_update_next_epoch "$_au_now")
              AUTO_LAST_STATUS=skipped
              AUTO_LAST_RESULT="模块已禁用，跳过定时更新"
              AUTO_STATE_SIG=$(auto_update_schedule_sig)
              auto_update_persist_current_state
            elif ! service_running; then
              AUTO_NEXT_RUN=$(auto_update_next_epoch "$_au_now")
              AUTO_LAST_STATUS=skipped
              AUTO_LAST_RESULT="Sub-Store 已停止，跳过定时更新"
              AUTO_STATE_SIG=$(auto_update_schedule_sig)
              auto_update_persist_current_state
            else
              auto_update_start_due "$_au_now"
            fi
          fi
          ;;
      esac
    fi
    sleep "${AUTO_UPDATE_POLL_SECONDS:-60}"
  done
}
