#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[MuMuAINovel] $1"
}

err() {
  echo "[MuMuAINovel] ❌ $1" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "未检测到命令: $1"
    exit 1
  fi
}

log "检查 Docker 环境"
require_cmd docker
require_cmd curl
if ! docker compose version >/dev/null 2>&1; then
  err "未检测到 docker compose 插件，请升级 Docker Desktop"
  exit 1
fi

# 向量（记忆检索）模型不是必需的：backend/embedding/ 里有模型就随镜像打包；没有则由容器首次启动时自动下载
shopt -s nullglob
embedding_models=(backend/embedding/models--*/)
shopt -u nullglob
if [ "${#embedding_models[@]}" -gt 0 ]; then
  log "向量模型：backend/embedding/ 里已有模型，会打包进镜像，容器启动时不用再下载"
  for model_dir in "${embedding_models[@]}"; do
    log "  - $(basename "$model_dir")"
  done
else
  log "向量模型：backend/embedding/ 里没有模型，容器首次启动时会自动下载中文模型 bge-small-zh（约 95MB）"
  log "  下载失败也照常启动，只是暂时没有语义检索；之后可在「设置 → 记忆检索」里重新下载"
fi

if [ ! -f .env ]; then
  if [ ! -f .env.example ]; then
    err "缺少 .env.example，无法初始化 .env"
    exit 1
  fi
  cp .env.example .env
  log "已从 .env.example 生成 .env，请按需修改后重新执行"
fi

mkdir -p secrets

if [ ! -f secrets/local_auth_password.txt ]; then
  echo "CHANGE_ME_LOCAL_AUTH_PASSWORD" > secrets/local_auth_password.txt
  err "已生成占位密码文件 secrets/local_auth_password.txt，请编辑为强密码后重新执行"
  exit 1
fi

# 剥离 UTF-8 BOM + 所有空白字符（兼容 Windows Notepad 编辑过的文件）
local_pwd="$(LC_ALL=C sed '1s/^\xef\xbb\xbf//' secrets/local_auth_password.txt | tr -d '[:space:]')"
if [ -z "$local_pwd" ]; then
  err "secrets/local_auth_password.txt 内容为空，请填入强密码"
  exit 1
fi
if [[ "$local_pwd" == CHANGE_ME* ]]; then
  err "检测到默认占位密码，请修改 secrets/local_auth_password.txt 后再部署"
  exit 1
fi

app_port="$(grep -E '^APP_PORT=' .env | tail -n 1 | cut -d'=' -f2- | tr -d '\r\n\"' || true)"
app_port="${app_port:-8000}"
health_url="http://localhost:${app_port}/health/ready"

log "启动容器（首次构建可能需要 5-10 分钟）"
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build

# 首次启动可能要先下载向量模型（约 95MB，下载源不通时三个源各等 30 秒超时），所以多等一会儿；
# 容器退出 / 反复重启就不用干等，直接打出日志
health_timeout=420
container_name="mumuainovel"
log "等待服务就绪（最多 $((health_timeout / 60)) 分钟，首次启动可能要下载向量模型）"
log "  看启动进度：docker compose logs -f ${container_name}"
deadline=$((SECONDS + health_timeout))
# 本机自检不走代理：设了 HTTP(S)_PROXY 时别把 localhost 的请求发给代理
until curl -fsS -m 5 --noproxy '*' -o /dev/null "$health_url" 2>/dev/null; do
  state="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo missing)"
  if [ "$state" != "running" ] || [ "$SECONDS" -ge "$deadline" ]; then
    if [ "$state" != "running" ]; then
      err "容器没有正常运行（状态：${state}），最近的日志："
    else
      err "服务未在 $((health_timeout / 60)) 分钟内就绪，最近的日志："
    fi
    docker logs --tail 60 "$container_name" >&2 || true
    echo "请执行以下命令继续排查：" >&2
    echo "  docker compose logs -f ${container_name}" >&2
    exit 1
  fi
  sleep 5
done

log "✅ 部署成功，访问地址: http://localhost:${app_port}"
