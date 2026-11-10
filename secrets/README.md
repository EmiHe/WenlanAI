# Secrets 使用说明

本目录用于存放 Docker Compose 运行时读取的敏感信息文件。

## 必需文件

1. `local_auth_password.txt`
   - 内容：本地管理员密码（仅一行）

## 快速创建（PowerShell）

```powershell
New-Item -ItemType Directory -Force secrets | Out-Null
Set-Content -Path secrets/local_auth_password.txt -Value "请替换为强密码"
```

## 快速创建（Linux/macOS）

```bash
mkdir -p secrets
chmod 700 secrets
echo "请替换为强密码" > secrets/local_auth_password.txt
chmod 644 secrets/local_auth_password.txt
```

为什么密码文件是 644 而不是 600：

- Compose 的文件型 secret 是把宿主机上的这个文件原样挂进容器（`/run/secrets/local_auth_password`），权限和属主都不变。
- 容器里的应用以非 root 用户 `appuser` 运行。文件设成 600、属主又是宿主机用户时，`appuser` 读不到，容器启动时会报「本地账户密码未配置」然后退出。
- 所以文件给 644，让容器能读；外层 `secrets/` 目录设成 700，挡住宿主机上的其他用户。

## 安全建议

- 不要将真实密码提交到 Git 仓库。
- 生产环境请使用高强度随机密码。
- 如密码泄露，请立即轮换并重启相关服务。
