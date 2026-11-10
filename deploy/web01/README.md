# web01 部署：write.urai.uk

用 Docker 把文澜 AI 跑在 web01 上，宿主机 nginx 把 `write.urai.uk` 反代过去。
整套部署只动属于自己的东西，不影响服务器上的其他项目：

| 资源 | 本部署使用 | 说明 |
| --- | --- | --- |
| Compose 项目 | `wenlanai` | 所有命令都带 `-p wenlanai`，不会碰别的项目 |
| 容器 / 镜像 | `wenlanai` / `wenlanai:local` | 同名容器属于别的项目时脚本直接停下 |
| 网络 | `wenlanai_default` | 独立网络 |
| 数据卷 | `wenlanai_data`、`wenlanai_logs`、`wenlanai_embedding` | 作品数据库、日志、向量模型 |
| 端口 | `127.0.0.1:18080` 起第一个空闲端口 | 只监听本机，不对公网开放；选定后写进 `deploy/web01/.env` |
| nginx | 新增一个站点文件 `wenlanai-write.urai.uk.conf` | 先 `nginx -t` 再 `reload`，校验不过就还原；域名已被别的站点占用时不改动 |
| 资源 | 内存 ≤ 2G、CPU ≤ 2 核、进程数 ≤ 512 | 不会把整台机器拖慢 |

脚本不执行任何全局清理（`docker system prune` 之类），只删除本项目被替换下来的旧镜像。

## 首次部署

前提：web01 上已装好 Docker（带 `docker compose` 子命令）和 git；DNS 里 `write.urai.uk` 有一条 A 记录指向 web01 的公网 IP。

```bash
sudo mkdir -p /opt/wenlanai && sudo chown "$USER" /opt/wenlanai
git clone https://github.com/EmiHe/WenlanAI.git /opt/wenlanai
cd /opt/wenlanai
bash deploy/web01/deploy.sh
```

> 仓库是私有的话，clone 时需要 GitHub 账号的 token 或给 web01 配一个 deploy key。

脚本会依次：

1. 生成应用配置 `.env`（来自 `.env.example`）和管理员随机密码 `secrets/local_auth_password.txt`（已有就不动）
2. 挑一个空闲端口，判断用国内还是官方软件源，按机器配置定资源上限，写进 `deploy/web01/.env`
3. 构建镜像并启动容器（首次约 5–15 分钟）；容器首次启动时自动下载中文向量模型 bge-small-zh（约 95MB，走 hf-mirror.com / huggingface.co）
4. 配置 nginx 反代：
   - 已有覆盖 `write.urai.uk` 或 `*.urai.uk` 的 Let's Encrypt 证书 → 直接配 HTTPS
   - 否则装了 certbot → 用 webroot 方式申请证书（不改其他站点），自动续期
   - 都没有 → 先配 HTTP，按提示装 certbot / 修 DNS 后重跑脚本即可升级 HTTPS
5. 打印访问地址、管理员账号和密码（随机密码只显示这一次）

完成后打开 <https://write.urai.uk>，用 `admin` + 打印出来的密码登录。

## 配置 AI 接口

两种方式任选：

- 登录后在网页「设置」里填（每个账号单独配置，推荐）
- 编辑仓库根目录的 `.env`（`OPENAI_API_KEY`、`OPENAI_BASE_URL`、`DEFAULT_MODEL` 等），然后重跑 `bash deploy/web01/deploy.sh`

## 日常运维

```bash
cd /opt/wenlanai

# 更新到最新代码（数据卷保留）
git pull && bash deploy/web01/deploy.sh

# 看日志
docker logs -f wenlanai

# 重启 / 停止
docker compose -p wenlanai -f deploy/web01/docker-compose.yml --env-file deploy/web01/.env restart
docker compose -p wenlanai -f deploy/web01/docker-compose.yml --env-file deploy/web01/.env down

# 备份作品数据（生成 wenlanai-data-日期.tgz）
docker run --rm -v wenlanai_data:/data:ro -v "$PWD":/backup alpine \
  tar czf "/backup/wenlanai-data-$(date +%F).tgz" -C /data .
```

改管理员密码：登录后在网页里直接改；或者编辑 `secrets/local_auth_password.txt` 后执行上面的「重启」命令（只改这个文件时重跑部署脚本不会重建容器，新密码要重启才生效）。

## 可选参数

```bash
DOMAIN=write.urai.uk          # 反代域名（默认就是它）
WENLAN_MIRROR=cn|global       # 构建用国内源还是官方源（默认自动判断，只在首次生成 deploy/web01/.env 时用）
CERTBOT_EMAIL=you@example.com # 申请证书时登记邮箱（证书快过期时会收到提醒）
bash deploy/web01/deploy.sh --no-proxy   # 只起容器，不碰 nginx
```

端口、软件源、资源上限想改：编辑 `deploy/web01/.env` 后重跑脚本。

## 不是宿主机 nginx 的情况

- **宝塔面板**：脚本能识别，站点文件写到 `/www/server/panel/vhost/nginx/`（面板的网站列表里不会显示，但会生效）。
- **Caddy**：脚本不改现有 Caddyfile，会打印一段配置，手动加上后 `systemctl reload caddy`。
- **反代跑在 Docker 里（Nginx Proxy Manager / Traefik 等）**：它访问不到宿主机的 `127.0.0.1`。把 `deploy/web01/.env` 里的 `BIND_ADDR` 改成 docker0 网关（一般是 `172.17.0.1`），重跑脚本，再在反代里把 `write.urai.uk` 指向 `http://172.17.0.1:<端口>`。

不管哪种反代，都要关掉响应缓冲、把读超时调长（AI 生成走 SSE 流式输出）。

## 卸载

```bash
cd /opt/wenlanai
docker compose -p wenlanai -f deploy/web01/docker-compose.yml --env-file deploy/web01/.env down   # 加 -v 会连作品数据一起删
docker image rm wenlanai:local
sudo rm -f /etc/nginx/sites-enabled/wenlanai-write.urai.uk.conf /etc/nginx/sites-available/wenlanai-write.urai.uk.conf \
           /etc/nginx/conf.d/wenlanai-write.urai.uk.conf
sudo nginx -t && sudo systemctl reload nginx
```
