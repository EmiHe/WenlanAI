#!/usr/bin/env bash
# 文澜 AI · web01 一键部署（Docker + 宿主机 nginx 反代 write.urai.uk）
#
# 用法（在 web01 上、仓库任意目录执行均可）：
#   bash deploy/web01/deploy.sh               # 首次部署 / 更新（git pull 之后再跑一次即可）
#   bash deploy/web01/deploy.sh --no-proxy    # 只起容器，不动 nginx
#
# 可选环境变量：
#   DOMAIN=write.urai.uk     反代域名
#   WENLAN_MIRROR=cn|global  构建镜像用国内源还是官方源（默认自动判断）
#   CERTBOT_EMAIL=you@x.com  申请 HTTPS 证书时登记的邮箱（不填也能申请）
#
# 对服务器上其他项目的影响控制在最小：
#   - 只创建 / 替换 wenlanai 这个 Compose 项目里的东西（容器 wenlanai、镜像 wenlanai:local、
#     网络 wenlanai_default、数据卷 wenlanai_*）；容器名 / 域名已被别的项目占用时直接停下，不碰它
#   - 端口只绑 127.0.0.1，自动挑一个没人用的端口（默认从 18080 起），选定后写进 deploy/web01/.env 固定下来
#   - 不执行任何全局清理（docker system/image/builder prune），只删本项目被替换掉的旧镜像
#   - nginx 只新增一个 write.urai.uk 的站点文件；先 nginx -t 校验，失败就还原，绝不 restart，只 reload
set -euo pipefail

DOMAIN="${DOMAIN:-write.urai.uk}"
PROJECT="wenlanai"
CONTAINER="wenlanai"
IMAGE="wenlanai:local"
SITE_NAME="wenlanai-${DOMAIN}"
ACME_ROOT="/var/www/wenlanai-acme"
HEALTH_TIMEOUT=420

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
DEPLOY_ENV="$SCRIPT_DIR/.env"
APP_ENV="$REPO_ROOT/.env"
SECRET_FILE="$REPO_ROOT/secrets/local_auth_password.txt"

SETUP_PROXY=1
for arg in "$@"; do
  case "$arg" in
    --no-proxy) SETUP_PROXY=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg（可用：--no-proxy）" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;32m[文澜部署]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[文澜部署] ⚠️ %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[文澜部署] ❌ %s\033[0m\n' "$*" >&2; exit 1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "需要 root 权限（或 sudo）来配置 nginx"
  SUDO="sudo"
fi

# ---------------------------------------------------------------- Docker
command -v docker >/dev/null 2>&1 || die "未安装 Docker"
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if [ -n "$SUDO" ] && sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    die "连不上 Docker（守护进程没起，或当前用户没有权限）"
  fi
fi
"${DOCKER[@]}" compose version >/dev/null 2>&1 \
  || die "需要 Docker Compose v2（docker compose 子命令）；旧的 docker-compose v1 不支持"

compose() {
  "${DOCKER[@]}" compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$DEPLOY_ENV" "$@"
}

# 同名容器属于别的项目 → 停下，不碰
existing_project="$("${DOCKER[@]}" inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$CONTAINER" 2>/dev/null || true)"
if "${DOCKER[@]}" inspect "$CONTAINER" >/dev/null 2>&1 && [ "$existing_project" != "$PROJECT" ]; then
  die "服务器上已有一个叫 $CONTAINER 的容器且不属于本部署（项目：${existing_project:-无}），为了不影响它，已停止"
fi

# ---------------------------------------------------------------- 应用配置
cd "$REPO_ROOT"

if [ ! -f "$APP_ENV" ]; then
  cp .env.example "$APP_ENV"
  sed -i 's/^DEBUG=.*/DEBUG=false/' "$APP_ENV"
  chmod 600 "$APP_ENV"
  log "已生成应用配置 .env（AI 接口可以之后在网页「设置」里填，或编辑 $APP_ENV 后重跑本脚本）"
fi

GENERATED_PASSWORD=""
mkdir -p "$REPO_ROOT/secrets"
chmod 700 "$REPO_ROOT/secrets"
# 容器里以非 root 用户读这个文件（Compose 文件型 secret 是原样挂载），所以文件要 644；外层目录 700 挡住宿主机上的其他用户。
# （按 secrets/README.md 设成 600 的话，容器里读不到密码会起不来，这里顺手改回 644）
fix_secret_mode() { chmod 644 "$SECRET_FILE" 2>/dev/null || $SUDO chmod 644 "$SECRET_FILE"; }
current_pwd=""
if [ -f "$SECRET_FILE" ]; then
  [ -r "$SECRET_FILE" ] || fix_secret_mode
  current_pwd="$(LC_ALL=C sed '1s/^\xef\xbb\xbf//' "$SECRET_FILE" | tr -d '[:space:]' || true)"
fi
if [ -z "$current_pwd" ] || [[ "$current_pwd" == CHANGE_ME* ]] || [[ "$current_pwd" == 请替换* ]]; then
  GENERATED_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)"
  [ ${#GENERATED_PASSWORD} -eq 20 ] || die "生成随机密码失败"
  printf '%s\n' "$GENERATED_PASSWORD" > "$SECRET_FILE"
  log "已生成管理员随机密码（保存在 $SECRET_FILE）"
fi
fix_secret_mode

# ---------------------------------------------------------------- 部署参数（端口 / 镜像源 / 资源上限）
# 注意：开了 pipefail，`大量输出 | grep -q` 会因 grep 提前退出、前一个命令收到 SIGPIPE 而误判，所以都先存进变量再 grep
port_in_use() {
  local p="$1" listening="" published=""
  if command -v ss >/dev/null 2>&1; then
    listening="$(ss -Hltn 2>/dev/null | awk '{print $4}' || true)"
  elif command -v netstat >/dev/null 2>&1; then
    listening="$(netstat -ltn 2>/dev/null | awk '{print $4}' || true)"
  fi
  grep -Eq "[:.]${p}\$" <<<"$listening" && return 0
  published="$("${DOCKER[@]}" ps -a --format '{{.Ports}}' 2>/dev/null || true)"
  grep -Eq "[:]${p}->" <<<"$published" && return 0
  return 1
}

if [ ! -f "$DEPLOY_ENV" ]; then
  port=18080
  while port_in_use "$port"; do
    port=$((port + 1))
    [ "$port" -lt 18200 ] || die "18080-18199 端口都被占用了，请在 $DEPLOY_ENV 里手动指定 HOST_PORT"
  done

  mirror="${WENLAN_MIRROR:-}"
  if [ -z "$mirror" ]; then
    if curl -fsS -m 6 -o /dev/null https://www.google.com 2>/dev/null; then mirror=global; else mirror=cn; fi
  fi
  if [ "$mirror" = "global" ]; then
    npm_registry="https://registry.npmjs.org"; pip_index="https://pypi.org/simple/"; debian_mirror=""
  else
    npm_registry="https://registry.npmmirror.com"; pip_index="https://mirrors.aliyun.com/pypi/simple/"; debian_mirror="mirrors.aliyun.com"
  fi

  cpus="$(nproc 2>/dev/null || echo 1)"
  if [ "$cpus" -ge 2 ]; then cpu_limit="2.0"; else cpu_limit="1.0"; fi
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)"
  if [ "$mem_mb" -ge 3072 ]; then mem_limit="2g"; else mem_limit="1536m"; fi
  [ "$mem_mb" -ge 2000 ] || warn "这台机器内存只有 ${mem_mb}MB，向量模型 + PyTorch 需要 1GB 左右，可能会吃紧"

  cat > "$DEPLOY_ENV" <<EOF
# web01 部署参数（deploy.sh 首次运行时生成；改完重跑 deploy.sh 生效）
# 宿主机上监听的地址和端口（只给 nginx 用，不对公网开放）
BIND_ADDR=127.0.0.1
HOST_PORT=$port
# 构建镜像用的软件源（$mirror）
NPM_REGISTRY=$npm_registry
PIP_INDEX_URL=$pip_index
DEBIAN_MIRROR=$debian_mirror
# 容器资源上限
MEM_LIMIT=$mem_limit
CPU_LIMIT=$cpu_limit
EOF
  log "部署参数已写入 $DEPLOY_ENV（端口 $port，软件源 $mirror）"
fi

set -a
# shellcheck disable=SC1090
. "$DEPLOY_ENV"
set +a
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
HOST_PORT="${HOST_PORT:-18080}"
UPSTREAM_HOST="$BIND_ADDR"
[ "$UPSTREAM_HOST" = "0.0.0.0" ] && UPSTREAM_HOST="127.0.0.1"

# 端口被别的程序占了（不是本项目容器）→ 停下
if port_in_use "$HOST_PORT"; then
  own_ports="$("${DOCKER[@]}" ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Ports}}' 2>/dev/null || true)"
  if ! grep -Eq "[:]${HOST_PORT}->" <<<"$own_ports"; then
    die "端口 $HOST_PORT 已被其他程序占用；请修改 $DEPLOY_ENV 里的 HOST_PORT 后重跑"
  fi
fi

# 磁盘空间提醒（首次构建镜像约需 6-8GB）
docker_root="$("${DOCKER[@]}" info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
free_mb="$($SUDO df -Pm "$docker_root" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
if [ -n "$free_mb" ] && [ "$free_mb" -gt 0 ] && [ "$free_mb" -lt 8000 ]; then
  warn "Docker 所在磁盘只剩 ${free_mb}MB，构建镜像可能空间不够"
fi

# ---------------------------------------------------------------- 构建并启动
old_image_id="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"

log "构建镜像并启动容器（首次构建要下载 PyTorch 等依赖，约 5-15 分钟）…"
compose up -d --build --remove-orphans

new_image_id="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
if [ -n "$old_image_id" ] && [ "$old_image_id" != "$new_image_id" ]; then
  # 只在没有任何容器还引用它时才删（containerd 镜像存储下，层没变时容器可能仍指向旧 ID）
  in_use="$("${DOCKER[@]}" ps -aq --no-trunc | xargs -r "${DOCKER[@]}" inspect -f '{{.Image}}' 2>/dev/null || true)"
  if ! grep -qxF "$old_image_id" <<<"$in_use"; then
    "${DOCKER[@]}" image rm "$old_image_id" >/dev/null 2>&1 && log "已删除本项目被替换下来的旧镜像" || true
  fi
fi

log "等待服务就绪（首次启动会下载约 95MB 的向量模型）…"
health_url="http://${UPSTREAM_HOST}:${HOST_PORT}/health/ready"
deadline=$((SECONDS + HEALTH_TIMEOUT))
# 本机自检一律 --noproxy：服务器上设了 HTTPS_PROXY 时别把 127.0.0.1 / 本站域名的请求发给代理
until curl -fsS -m 5 --noproxy '*' -o /dev/null "$health_url" 2>/dev/null; do
  state="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
  if [ "$state" != "running" ] || [ "$SECONDS" -ge "$deadline" ]; then
    "${DOCKER[@]}" logs --tail 60 "$CONTAINER" >&2 || true
    die "服务没有正常启动（容器状态：$state），上面是最近的日志；排查：${DOCKER[*]} logs -f $CONTAINER"
  fi
  sleep 5
done
log "✅ 容器已就绪：$health_url"

# ---------------------------------------------------------------- 反向代理
PROXY_RESULT="未配置（--no-proxy）"
SITE_URL="http://${UPSTREAM_HOST}:${HOST_PORT}（仅本机）"

proxy_snippet() {
  cat <<EOF
  上游地址：http://${UPSTREAM_HOST}:${HOST_PORT}
  注意：AI 生成用的是 SSE 流式输出，反代要关掉缓冲（nginx: proxy_buffering off）并把读超时调长（如 3600s）。
  Caddy 示例：
    ${DOMAIN} {
        reverse_proxy ${UPSTREAM_HOST}:${HOST_PORT} {
            flush_interval -1
        }
    }
  反代程序本身跑在 Docker 里（Nginx Proxy Manager / Traefik 等）时，它访问不到宿主机的 127.0.0.1：
  把 $DEPLOY_ENV 里的 BIND_ADDR 改成 docker0 网关地址（通常 172.17.0.1）重跑本脚本，再让反代指向 http://172.17.0.1:${HOST_PORT}
EOF
}

NGINX_BIN=""
NGINX_SITE_FILE=""
NGINX_ENABLE_LINK=""
detect_nginx() {
  if [ -x /www/server/nginx/sbin/nginx ] && [ -d /www/server/panel/vhost/nginx ]; then
    # 宝塔面板：站点配置放在 vhost/nginx/*.conf
    NGINX_BIN=/www/server/nginx/sbin/nginx
    NGINX_SITE_FILE="/www/server/panel/vhost/nginx/${SITE_NAME}.conf"
  elif command -v nginx >/dev/null 2>&1 && [ -d /etc/nginx ]; then
    NGINX_BIN="$(command -v nginx)"
    if [ -d /etc/nginx/sites-enabled ] && grep -Rqs "sites-enabled" /etc/nginx/nginx.conf; then
      NGINX_SITE_FILE="/etc/nginx/sites-available/${SITE_NAME}.conf"
      NGINX_ENABLE_LINK="/etc/nginx/sites-enabled/${SITE_NAME}.conf"
    else
      NGINX_SITE_FILE="/etc/nginx/conf.d/${SITE_NAME}.conf"
    fi
  else
    return 1
  fi
}

nginx_reload() {
  if [ "$NGINX_BIN" != "/www/server/nginx/sbin/nginx" ] && command -v systemctl >/dev/null 2>&1 \
     && $SUDO systemctl is-active --quiet nginx 2>/dev/null; then
    $SUDO systemctl reload nginx
  else
    $SUDO "$NGINX_BIN" -s reload
  fi
}

# 找一张覆盖本域名且未过期的现成证书（Let's Encrypt 目录：本域名单独的证书，或 *.urai.uk 通配证书）
find_cert() {
  local parent="${DOMAIN#*.}" dirs dir crt text
  # live 目录只有 root 能读，通配符展开也得走 sudo
  dirs="$($SUDO find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true)"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    crt="${dir}/fullchain.pem"
    $SUDO test -f "$crt" || continue
    $SUDO openssl x509 -in "$crt" -noout -checkend 86400 >/dev/null 2>&1 || continue
    text="$($SUDO openssl x509 -in "$crt" -noout -text 2>/dev/null || true)"
    if grep -Eq "DNS:(${DOMAIN//./\\.}|\*\.${parent//./\\.})(,|\$| )" <<<"$text"; then
      CERT_FULLCHAIN="$crt"
      CERT_KEY="${dir}/privkey.pem"
      return 0
    fi
  done <<<"$dirs"
  return 1
}

nginx_dump() { $SUDO "$NGINX_BIN" -T 2>/dev/null || true; }

write_site_conf() {
  local mode="$1" listen6_80="" listen6_443="" tmp dump
  # 只有现有站点已经在用 IPv6 监听时才加，免得在关了 IPv6 的机器上 nginx -t 失败
  dump="$(nginx_dump)"
  if grep -Eq 'listen[[:space:]]+\[::\]:80' <<<"$dump"; then listen6_80="    listen [::]:80;"; fi
  if grep -Eq 'listen[[:space:]]+\[::\]:443' <<<"$dump"; then listen6_443="    listen [::]:443 ssl;"; fi
  tmp="$(mktemp)"
  {
    echo "# ${DOMAIN} → 文澜 AI（Docker 容器 ${CONTAINER}，上游 ${UPSTREAM_HOST}:${HOST_PORT}）"
    echo "# 由 deploy/web01/deploy.sh 生成，重跑脚本会覆盖；请勿手改"
    echo "server {"
    echo "    listen 80;"
    [ -n "$listen6_80" ] && echo "$listen6_80"
    echo "    server_name ${DOMAIN};"
    echo ""
    echo "    location ^~ /.well-known/acme-challenge/ {"
    echo "        root ${ACME_ROOT};"
    echo "        default_type text/plain;"
    echo "    }"
    echo ""
    if [ "$mode" = "https" ]; then
      echo "    location / {"
      echo "        return 301 https://\$host\$request_uri;"
      echo "    }"
      echo "}"
      echo ""
      echo "server {"
      echo "    listen 443 ssl;"
      [ -n "$listen6_443" ] && echo "$listen6_443"
      echo "    server_name ${DOMAIN};"
      echo ""
      echo "    ssl_certificate     ${CERT_FULLCHAIN};"
      echo "    ssl_certificate_key ${CERT_KEY};"
      echo "    ssl_protocols TLSv1.2 TLSv1.3;"
      echo "    ssl_session_timeout 1d;"
      echo ""
    fi
    cat <<EOF
    client_max_body_size 100m;

    location / {
        proxy_pass http://${UPSTREAM_HOST}:${HOST_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";

        # AI 生成走 SSE 流式输出：关缓冲、拉长超时，否则会一次性憋到最后才显示或中途断开
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
  } > "$tmp"

  local backup=""
  if $SUDO test -f "$NGINX_SITE_FILE"; then
    backup="$(mktemp)"
    $SUDO cp "$NGINX_SITE_FILE" "$backup"
  fi
  $SUDO mkdir -p "$(dirname "$NGINX_SITE_FILE")"
  $SUDO install -m 644 "$tmp" "$NGINX_SITE_FILE"
  rm -f "$tmp"
  [ -n "$NGINX_ENABLE_LINK" ] && $SUDO ln -sfn "$NGINX_SITE_FILE" "$NGINX_ENABLE_LINK"

  if ! $SUDO "$NGINX_BIN" -t >/dev/null 2>&1; then
    $SUDO "$NGINX_BIN" -t || true
    if [ -n "$backup" ]; then
      $SUDO install -m 644 "$backup" "$NGINX_SITE_FILE"
    else
      $SUDO rm -f "$NGINX_SITE_FILE"
      [ -n "$NGINX_ENABLE_LINK" ] && $SUDO rm -f "$NGINX_ENABLE_LINK"
    fi
    [ -n "$backup" ] && rm -f "$backup"
    die "nginx 配置校验没通过，已还原，nginx 没有重载（其他站点不受影响）。容器已在 ${UPSTREAM_HOST}:${HOST_PORT} 运行"
  fi
  [ -n "$backup" ] && rm -f "$backup"
  nginx_reload
}

if [ "$SETUP_PROXY" -eq 1 ]; then
  if detect_nginx; then
    log "检测到 nginx（$NGINX_BIN），站点文件：$NGINX_SITE_FILE"

    # 域名已被别的站点配置占用 → 停下，不碰
    # （nginx -T 里本项目的文件可能以 sites-enabled 软链路径出现，两个路径都算自己的）
    conflict="$(nginx_dump | awk -v d="$DOMAIN" -v own="$NGINX_SITE_FILE" -v own2="${NGINX_ENABLE_LINK:-$NGINX_SITE_FILE}" '
      /^# configuration file / { f = $4; sub(/:$/, "", f); next }
      /server_name/ {
        line = $0; sub(/#.*/, "", line)
        n = split(line, parts, /[[:space:];]+/)
        for (i = 1; i <= n; i++) if (parts[i] == d && f != own && f != own2) print f
      }' | head -n 1 || true)"
    if [ -n "$conflict" ]; then
      die "nginx 里已有站点使用 ${DOMAIN}（$conflict），为避免影响它，没有改动 nginx。容器已在 ${UPSTREAM_HOST}:${HOST_PORT} 运行"
    fi

    $SUDO mkdir -p "$ACME_ROOT"
    CERT_FULLCHAIN=""; CERT_KEY=""
    if find_cert; then
      log "使用已有证书：$CERT_FULLCHAIN"
      write_site_conf https
      PROXY_RESULT="nginx + HTTPS（已有证书）"
      SITE_URL="https://${DOMAIN}"
    else
      write_site_conf http
      PROXY_RESULT="nginx（仅 HTTP）"
      SITE_URL="http://${DOMAIN}"
      if ! getent ahosts "$DOMAIN" >/dev/null 2>&1; then
        warn "${DOMAIN} 还解析不到：请先在 DNS 里加一条 A 记录指向 web01 的公网 IP，生效后重跑本脚本自动申请 HTTPS 证书"
      elif ! command -v certbot >/dev/null 2>&1; then
        warn "没有 certbot，暂时只有 HTTP。安装 certbot（apt install certbot / yum install certbot）后重跑本脚本即可自动申请证书"
      else
        log "申请 Let's Encrypt 证书（webroot 方式，不改动其他站点）…"
        email_args=(--register-unsafely-without-email)
        [ -n "${CERTBOT_EMAIL:-}" ] && email_args=(-m "$CERTBOT_EMAIL")
        reload_hook="$NGINX_BIN -s reload"
        if $SUDO certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
             --non-interactive --agree-tos --keep-until-expiring "${email_args[@]}" \
             --deploy-hook "$reload_hook"; then
          if find_cert; then
            write_site_conf https
            PROXY_RESULT="nginx + HTTPS（Let's Encrypt，自动续期）"
            SITE_URL="https://${DOMAIN}"
          fi
        else
          warn "证书申请失败（常见原因：DNS 没指到这台机器、80 端口被防火墙 / 云安全组挡住、Cloudflare 强制 HTTPS）。暂时只有 HTTP，问题解决后重跑本脚本即可"
        fi
      fi
    fi

    # 经 nginx 自检
    if [[ "$SITE_URL" == https://* ]]; then
      check_cmd=(curl -fsS -m 10 -k --noproxy '*' -o /dev/null --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/health/ready")
    else
      check_cmd=(curl -fsS -m 10 --noproxy '*' -o /dev/null -H "Host: ${DOMAIN}" "http://127.0.0.1/health/ready")
    fi
    # nginx -s reload 是异步的，新 worker 接管前可能还是旧配置，多试几次
    proxied_ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if "${check_cmd[@]}" 2>/dev/null; then proxied_ok=1; break; fi
      sleep 1
    done
    if [ "$proxied_ok" -eq 1 ]; then
      log "✅ 经 nginx 访问正常"
    else
      warn "经 nginx 本机自检没通过（nginx 可能只监听在特定 IP 上），请用浏览器打开 $SITE_URL 确认"
    fi
  elif command -v caddy >/dev/null 2>&1; then
    PROXY_RESULT="检测到 Caddy，需要手动加一段配置"
    warn "检测到 Caddy，为避免改动现有 Caddyfile，请手动添加下面的站点后 systemctl reload caddy："
    proxy_snippet >&2
  else
    PROXY_RESULT="没检测到宿主机上的 nginx / Caddy，需要手动配置反代"
    warn "宿主机上没有 nginx / Caddy。请在现有的反向代理里为 ${DOMAIN} 加一条转发："
    proxy_snippet >&2
  fi
fi

# ---------------------------------------------------------------- 结果
admin_user="$(grep -E '^LOCAL_AUTH_USERNAME=' "$APP_ENV" | tail -n 1 | cut -d= -f2- | tr -d '\r"' || true)"
cat <<EOF

================================================================
 文澜 AI 部署完成
================================================================
 访问地址：$SITE_URL
 反向代理：$PROXY_RESULT
 容器端口：${UPSTREAM_HOST}:${HOST_PORT}（只监听本机）
 管理员账号：${admin_user:-admin}
EOF
if [ -n "$GENERATED_PASSWORD" ]; then
  echo " 管理员密码：$GENERATED_PASSWORD   ← 只显示这一次，已保存在 secrets/local_auth_password.txt"
else
  echo " 管理员密码：cat $SECRET_FILE"
fi
cat <<EOF

 常用命令（都只作用于本项目）：
   查看日志：${DOCKER[*]} logs -f $CONTAINER
   重启    ：${DOCKER[*]} compose -p $PROJECT -f deploy/web01/docker-compose.yml --env-file deploy/web01/.env restart
   停止    ：${DOCKER[*]} compose -p $PROJECT -f deploy/web01/docker-compose.yml --env-file deploy/web01/.env down
   更新    ：git pull && bash deploy/web01/deploy.sh
================================================================
EOF
