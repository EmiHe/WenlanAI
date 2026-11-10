#!/bin/sh
set -eu

# 从 *_FILE 环境变量指向的文件读取 secret 值并导出对应变量。
# 兼容 Windows Notepad 编辑过的密码文件：剥离 UTF-8 BOM、CR/LF、所有空白字符。
read_secret() {
  var_name="$1"
  file_var="${var_name}_FILE"
  eval "file_path=\${$file_var:-}"

  if [ -n "$file_path" ] && [ -f "$file_path" ]; then
    value="$(LC_ALL=C sed '1s/^\xef\xbb\xbf//' "$file_path" | tr -d '[:space:]')"
    export "$var_name=$value"
  fi
}

read_secret LOCAL_AUTH_PASSWORD

: "${DATABASE_URL:=sqlite+aiosqlite:///./data/mumuai.db}"
export DATABASE_URL

if [ "${LOCAL_AUTH_ENABLED:-true}" != "false" ] && [ -z "${LOCAL_AUTH_PASSWORD:-}" ]; then
  cat >&2 <<'EOF'
================================================================
[MuMuAINovel] ❌ 本地账户密码未配置
================================================================

LOCAL_AUTH_ENABLED=true，但未读取到 LOCAL_AUTH_PASSWORD。

请检查：
  1. secrets/local_auth_password.txt 是否存在且非空
  2. 文件内容是否仅包含密码（无多余空行）
  3. 如不需要本地账户，请在 .env 中设置 LOCAL_AUTH_ENABLED=false

================================================================
EOF
  exit 1
fi

mkdir -p /app/data /app/logs

# 向量（记忆检索）模型：/app/embedding 里一个模型都没有时，首次启动自动下载默认中文模型 bge-small-zh（约 95MB，
# 依次试 HF_ENDPOINT → hf-mirror.com → huggingface.co）。下载失败不阻止启动：应用以「无语义检索」降级模式运行
# （召回只用人物 / 关键词），之后可在「设置 → 记忆检索」里重新下载；失败后一天内重启不再重试。
# 构建镜像前把模型放进 backend/embedding/（如 QQ 群里的模型包）则不会下载；EMBEDDING_AUTO_DOWNLOAD=false 关闭自动下载。
if [ "${EMBEDDING_AUTO_DOWNLOAD:-true}" != "false" ]; then
  python - <<'PY' || echo "[MuMuAINovel] ⚠️ 向量模型检查出错，跳过（应用照常启动）" >&2
import sys

from app.services import embedding_bootstrap as eb


def log(level, message):
    print(f"[MuMuAINovel] {message}", file=sys.stderr, flush=True)


if eb.model_present():
    sys.exit(0)
if eb.has_recent_failure():
    log("WARNING", "⚠️ 未找到向量模型，上次自动下载失败还不到一天，本次跳过；可在「设置 → 记忆检索」里手动下载")
    sys.exit(0)
eb.ensure_embedding_model(log)
PY
fi

exec "$@"
