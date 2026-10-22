#!/system/bin/sh
# ============================================================
# 更新 http-meta (bundle + tpl.yaml + mihomo 内核)
#
# 用法: update_http_meta.sh [all|js|kernel|kernel-alpha]
#   all          默认: js + tpl.yaml + mihomo 内核(稳定版)
#   js           仅更新 http-meta.bundle.js + tpl.yaml
#   kernel       仅更新 mihomo 内核(稳定版)
#   kernel-alpha 仅更新 mihomo 内核(Prerelease-Alpha 预览版)
#
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

MODE=${1:-all}
BIN_DIR="$sub_store_path/bin"
HM_DIR="$BIN_DIR/http-meta"
KERNEL_FILE="$HM_DIR/http-meta"
KERNEL_VER_FILE="$HM_DIR/kernel_version"
JS_URL="https://github.com/xream/http-meta/releases/latest/download/http-meta.bundle.js"
TPL_URL="https://github.com/xream/http-meta/releases/latest/download/tpl.yaml"

mkdir -p "$HM_DIR"
updated=0

# ---------- http-meta.bundle.js ----------
update_js() {
  info "更新 http-meta.bundle.js ..."
  rm -f "$BIN_DIR/http-meta.bundle.js.new"
  if ! download "$JS_URL" "$BIN_DIR/http-meta.bundle.js.new"; then
    rm -f "$BIN_DIR/http-meta.bundle.js.new"
    err "http-meta.bundle.js 下载失败"
    return 1
  fi
  [ -s "$BIN_DIR/http-meta.bundle.js.new" ] || {
    rm -f "$BIN_DIR/http-meta.bundle.js.new"
    err "下载文件为空"
    return 1
  }
  target="$BIN_DIR/http-meta.bundle.js"
  old="$target.old"
  had_old=0
  rm -f "$old" 2>/dev/null
  if [ -f "$target" ]; then
    mv -f "$target" "$old" || {
      rm -f "$target.new"
      err "无法备份旧 http-meta.bundle.js"
      return 1
    }
    had_old=1
  fi
  if ! mv -f "$target.new" "$target"; then
    [ "$had_old" = "1" ] && mv -f "$old" "$target" 2>/dev/null
    err "替换 http-meta.bundle.js 失败"
    return 1
  fi
  chmod 644 "$target" 2>/dev/null
  info "http-meta.bundle.js 更新完成"
  updated=1
  return 0
}

# ---------- tpl.yaml ----------
update_tpl() {
  info "更新 tpl.yaml ..."
  rm -f "$HM_DIR/tpl.yaml.new"
  if ! download "$TPL_URL" "$HM_DIR/tpl.yaml.new"; then
    rm -f "$HM_DIR/tpl.yaml.new"
    err "tpl.yaml 下载失败"
    return 1
  fi
  [ -s "$HM_DIR/tpl.yaml.new" ] || {
    rm -f "$HM_DIR/tpl.yaml.new"
    err "下载文件为空"
    return 1
  }
  target="$HM_DIR/tpl.yaml"
  old="$target.old"
  had_old=0
  rm -f "$old" 2>/dev/null
  if [ -f "$target" ]; then
    mv -f "$target" "$old" || {
      rm -f "$target.new"
      err "无法备份旧 tpl.yaml"
      return 1
    }
    had_old=1
  fi
  if ! mv -f "$target.new" "$target"; then
    [ "$had_old" = "1" ] && mv -f "$old" "$target" 2>/dev/null
    err "替换 tpl.yaml 失败"
    return 1
  fi
  chmod 644 "$target" 2>/dev/null
  info "tpl.yaml 更新完成"
  updated=1
  return 0
}

# ---------- mihomo Android 资产后缀 ----------
mihomo_abi() {
  local abi
  abi=$(getprop ro.product.cpu.abi 2>/dev/null)
  case "$abi" in
    arm64-v8a)            echo arm64-v8 ;;
    armeabi-v7a|armeabi)  echo armv7 ;;
    x86_64)               echo amd64 ;;
    x86)                  echo 386 ;;
    *)
      # 兜底: 按内核架构判断
      case "$(uname -m 2>/dev/null)" in
        aarch64*) echo arm64-v8 ;;
        armv7*|arm*) echo armv7 ;;
        x86_64*)  echo amd64 ;;
        i386|i686|x86*) echo 386 ;;
        *) echo "" ;;
      esac
      ;;
  esac
}

# ---------- mihomo 稳定版 tag: GitHub API 优先, 失败回退 version.txt ----------
mihomo_stable_tag() {
  local tag
  tag=$(fetch_text "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  if [ -z "$tag" ]; then
    # releases/latest/download 自动指向最新稳定版
    tag=$(fetch_text "https://github.com/MetaCubeX/mihomo/releases/latest/download/version.txt" \
      | tr -d '\r\n')
  fi
  echo "$tag"
}

# ---------- mihomo 预览版 tag (Prerelease-Alpha/version.txt) ----------
mihomo_alpha_tag() {
  fetch_text "https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/version.txt" \
    | tr -d '\r\n'
}

# ---------- mihomo 内核 ----------
update_kernel() {  # $1=stable|alpha
  local branch=$1 abi tag url cur
  abi=$(mihomo_abi)
  if [ -z "$abi" ]; then
    err "无法识别 CPU 架构"
    return 1
  fi
  info "mihomo 架构: $abi"

  if [ "$branch" = "alpha" ]; then
    tag=$(mihomo_alpha_tag)
    if [ -z "$tag" ]; then
      err "获取 mihomo 预览版版本号失败"
      return 1
    fi
    url="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/mihomo-android-${abi}-${tag}.gz"
    info "mihomo 预览版: $tag"
  else
    tag=$(mihomo_stable_tag)
    if [ -z "$tag" ]; then
      err "获取 mihomo 稳定版版本号失败"
      return 1
    fi
    url="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-android-${abi}-${tag}.gz"
    info "mihomo 稳定版: $tag"
  fi

  cur=$(cat "$KERNEL_VER_FILE" 2>/dev/null || echo unknown)
  info "当前内核版本: $cur"
  if [ "$cur" = "$tag" ]; then
    info "内核已是最新 ($tag), 无需更新"
    return 0
  fi

  info "下载 mihomo 内核 (约 17MB, 请耐心等待) ..."
  rm -f "$HM_DIR/http-meta.gz" "$KERNEL_FILE.new"
  if ! download "$url" "$HM_DIR/http-meta.gz"; then
    rm -f "$HM_DIR/http-meta.gz"
    err "内核下载失败"
    return 1
  fi
  [ -s "$HM_DIR/http-meta.gz" ] || {
    rm -f "$HM_DIR/http-meta.gz"
    err "下载文件为空"
    return 1
  }

  if ! gunzip -c "$HM_DIR/http-meta.gz" > "$KERNEL_FILE.new" 2>/dev/null; then
    rm -f "$HM_DIR/http-meta.gz" "$KERNEL_FILE.new"
    err "内核解压失败"
    return 1
  fi
  rm -f "$HM_DIR/http-meta.gz"
  chmod 755 "$KERNEL_FILE.new"
  had_old=0
  rm -f "$KERNEL_FILE.old" 2>/dev/null
  if [ -f "$KERNEL_FILE" ]; then
    mv -f "$KERNEL_FILE" "$KERNEL_FILE.old" || {
      rm -f "$KERNEL_FILE.new"
      err "无法备份旧 mihomo 内核"
      return 1
    }
    had_old=1
  fi
  if ! mv -f "$KERNEL_FILE.new" "$KERNEL_FILE"; then
    [ "$had_old" = "1" ] && mv -f "$KERNEL_FILE.old" "$KERNEL_FILE" 2>/dev/null
    err "替换 mihomo 内核失败"
    return 1
  fi
  chmod 755 "$KERNEL_FILE" 2>/dev/null
  cp -f "$KERNEL_VER_FILE" "$KERNEL_VER_FILE.old" 2>/dev/null || rm -f "$KERNEL_VER_FILE.old" 2>/dev/null
  if ! echo "$tag" > "$KERNEL_VER_FILE"; then
    rm -f "$KERNEL_FILE"
    [ "$had_old" = "1" ] && mv -f "$KERNEL_FILE.old" "$KERNEL_FILE" 2>/dev/null
    [ -f "$KERNEL_VER_FILE.old" ] && mv -f "$KERNEL_VER_FILE.old" "$KERNEL_VER_FILE" 2>/dev/null
    err "写入内核版本文件失败"
    return 1
  fi
  info "mihomo 内核已更新: $tag"
  updated=1
  return 0
}

# ---------- 分发 ----------
case "$MODE" in
  js)
    update_js || exit 1
    update_tpl || exit 1
    ;;
  kernel)
    update_kernel stable || exit 1
    ;;
  kernel-alpha)
    update_kernel alpha || exit 1
    ;;
  all|*)
    update_js || exit 1
    update_tpl || exit 1
    update_kernel stable || exit 1
    ;;
esac

if [ "$updated" = "1" ] && [ "$NO_RESTART" != "1" ]; then
  info "重启服务 ..."
  restart_service
fi

info "http-meta 处理完成"
