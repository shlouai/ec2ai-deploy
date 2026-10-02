# ec2ai-deploy

[English](README.md) | 简体中文

一条命令，把 [Open WebUI](https://github.com/open-webui/open-webui) 部署到你已有的
EC2 实例上，接入你的 LLM API Key，建立 SSH 隧道并在浏览器中打开。

```
cp deploy.conf.example deploy.conf   # 填写 EC2_HOST、SSH_KEY_PATH、LLM_API_KEY
./deploy-open-webui.sh               # 部署 + 隧道 + 打开浏览器
```

## 零基础用户手册

面向完全不懂技术的用户，从申请 OpenRouter Key、创建 EC2 实例到一键部署和日常使用，
全程手把手：[docs/manual/user-manual.zh-CN.pdf](docs/manual/user-manual.zh-CN.pdf)。
重新生成 PDF：`cd docs/manual && npm install && npm run build`（需要本机安装 Google Chrome）。

## 工作流程

1. 校验 `deploy.conf`（只允许 `KEY=value` 行）以及 SSH 密钥是否可读。
2. 通过 SSH 在实例上安装 Docker（如未安装，支持 Amazon Linux 2023 / 2、Ubuntu、Debian），
   写入权限为 600 的 `~/open-webui/.env`，拉取 Open WebUI 镜像，并以只监听实例本机
   `127.0.0.1:8080` 的方式启动容器。
3. 使用 SSH control socket 建立隧道 `localhost:3000 -> 实例:8080`，便于后续检查和关闭。
4. 通过隧道轮询健康检查端点，就绪后打开 `http://127.0.0.1:3000/`。

重复执行 `deploy` 会拉取最新镜像并重建容器。数据卷和会话密钥会保留，
账号和聊天记录不会丢失。

## 子命令

| 命令 | 作用 |
|------|------|
| `deploy`（默认） | 安装或升级，建立隧道，打开浏览器 |
| `tunnel` | 对已有部署重新建立隧道并打开浏览器 |
| `status` | 查看隧道状态和远端容器状态 |
| `logs` | 实时查看实例上的容器日志 |
| `down` | 关闭隧道。加 `--remote` 可同时删除容器（数据保留） |

选项：`-c FILE` 指定其他配置文件，`--dry-run` 只打印执行计划不实际连接（API Key 会被遮盖），
`--no-browser` 不打开浏览器。

## 配置项

必填：

| 键 | 说明 |
|----|------|
| `EC2_HOST` | 实例公网 DNS 或 IP |
| `SSH_KEY_PATH` | SSH 私钥路径，支持 `~` |
| `LLM_API_KEY` | LLM API Key |

可选（括号内为默认值）：

| 键 | 说明 |
|----|------|
| `EC2_USER` | SSH 用户名（`ec2-user`，Ubuntu 镜像用 `ubuntu`） |
| `SSH_PORT` | SSH 端口（`22`） |
| `SSH_EXTRA_OPTS` | 额外 ssh 参数，例如 `-o ProxyJump=bastion` |
| `LOCAL_PORT` | 本机监听端口（`3000`） |
| `REMOTE_PORT` | 实例回环端口（`8080`，不对外暴露） |
| `LLM_API_BASE_URL` | OpenAI 兼容接口地址（`https://api.openai.com/v1`） |
| `OPEN_WEBUI_IMAGE` | 镜像（`ghcr.io/open-webui/open-webui:main`，小磁盘用 `:main-slim`） |
| `WEBUI_NAME` | 界面显示的标题 |
| `DEFAULT_MODELS` | 新对话默认选中的模型，逗号分隔 |
| `RAG_EMBEDDING_MODEL` | RAG 用的 embedding 模型，OpenRouter 需带前缀如 `openai/text-embedding-3-small` |
| `HEALTH_TIMEOUT` | 等待首次启动的秒数（`300`） |

## 环境要求

- 本机：bash、ssh、curl。macOS 或 Linux。
- 实例：SSH 密钥登录，免密 sudo，可访问外网拉取镜像。除 SSH 外不需要开放任何入站端口。
- 磁盘：默认 `:main` 镜像约需 6 GB 可用空间。8 GB 根卷请设置
  `OPEN_WEBUI_IMAGE=ghcr.io/open-webui/open-webui:main-slim`（约 2 GB）。slim 镜像不含
  内置 embedding / whisper 模型，脚本会自动把 RAG embedding 和语音转文字指向你的
  OpenAI 兼容 API。脚本会在拉取前检查空间，不足时直接报错并给出提示。
- LLM 接口必须兼容 OpenAI 格式（OpenAI、经代理的 Azure、LiteLLM、vLLM、OpenRouter 等）。
  非 OpenAI 时请设置 `LLM_API_BASE_URL`，例如 OpenRouter 为 `https://openrouter.ai/api/v1`。
  OpenRouter 还需要设置 `RAG_EMBEDDING_MODEL=openai/text-embedding-3-small`（带厂商前缀），
  否则文档 RAG 会报模型不存在。

## 配置文件是唯一来源

容器以 `ENABLE_PERSISTENT_CONFIG=false` 运行，因此每次重跑 `deploy` 都会应用 `deploy.conf`
里的值。不加这一项的话，Open WebUI 会沿用首次启动时存进数据库的 LLM 地址和 Key，之后的修改
会被忽略。代价是管理后台里凡是有对应环境变量的设置（连接、默认模型、注册开关、RAG 设置）
在容器重启后会恢复为环境变量的值，这类设置请写到 `deploy.conf` 里。账号、聊天记录和
按模型的设置存在数据库中，不受影响。

## 首次登录

在界面中创建的第一个账号即为管理员。Open WebUI 默认开启登录认证；
由于应用只能通过你的隧道访问，不会暴露到公网。

## 排错

- 部署超时：隧道仍保持打开，执行 `./deploy-open-webui.sh logs` 查看容器日志。
  首次拉镜像和启动通常需要几分钟。
- 隧道建立失败：本机端口可能被占用，用 `lsof -i :3000` 检查，或修改 `LOCAL_PORT`。
- 提示不支持的发行版：在实例上手动安装 Docker 后重新执行即可。

## 安全说明

- API Key 只保存在本机的 `deploy.conf`（已 gitignore）和实例上的
  `~/open-webui/.env`（权限 600）。传输时通过 SSH 的 stdin，不会出现在远端命令行中。
- `StrictHostKeyChecking=accept-new`：首次连接信任主机密钥，之后密钥变化会直接报错。
