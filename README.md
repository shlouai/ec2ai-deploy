# ec2ai-deploy

English | [简体中文](README.zh-CN.md)

One command to put [Open WebUI](https://github.com/open-webui/open-webui) on an
EC2 instance you already own, wire it to your LLM API key, tunnel to it over SSH
and open it in your browser.

```
cp deploy.conf.example deploy.conf   # fill in EC2_HOST, SSH_KEY_PATH, LLM_API_KEY
./deploy-open-webui.sh               # deploy + tunnel + browser
```

## User manual (Chinese)

A step-by-step guide for non-technical users in mainland China (covering OpenRouter
sign-up, EC2 setup, deployment and day-to-day use) is distributed separately from
this repository.

## What it does

1. Validates `deploy.conf` (plain `KEY=value` only) and your SSH key.
2. Over SSH, installs Docker if missing (Amazon Linux 2023 / 2, Ubuntu, Debian),
   writes `~/open-webui/.env` on the instance with mode 600, pulls the Open WebUI
   image and starts it bound to `127.0.0.1:8080` on the instance only.
3. Opens an SSH tunnel `localhost:3000 -> instance:8080` using an SSH control
   socket, so it can be checked and closed later.
4. Polls the health endpoint through the tunnel, then opens `http://127.0.0.1:3000/`.

Re-running `deploy` pulls the latest image and recreates the container. The
data volume and the session secret are preserved, so accounts and chats survive.

## Commands

| Command | Effect |
|---------|--------|
| `deploy` (default) | Install or upgrade, open tunnel, open browser |
| `tunnel` | Reopen the tunnel to an existing deployment and open browser |
| `status` | Tunnel state and remote container state |
| `logs` | Tail container logs on the instance |
| `down` | Close the tunnel. Add `--remote` to also remove the container (data kept) |

Options: `-c FILE` to use another config, `--dry-run` to print the plan without
connecting (API key masked), `--no-browser`.

## Requirements

- Local: bash, ssh, curl. macOS, Linux, or Windows (Git Bash).
- Instance: SSH key auth, passwordless sudo, outbound internet to pull the image.
  No inbound ports beyond SSH are needed.
- Disk: the default `:main` image needs about 6 GB free. On an 8 GB root volume set
  `OPEN_WEBUI_IMAGE=ghcr.io/open-webui/open-webui:main-slim` (about 2 GB). The slim
  image has no bundled embedding / whisper models, so the script points RAG embeddings
  and speech-to-text at your OpenAI-compatible API instead. The script checks free
  space before pulling and fails early with this hint.
- LLM endpoint must be OpenAI-compatible (OpenAI, Azure via proxy, LiteLLM, vLLM,
  OpenRouter, etc.). Set `LLM_API_BASE_URL` for anything other than OpenAI, e.g.
  `https://openrouter.ai/api/v1` for OpenRouter. OpenRouter also needs
  `RAG_EMBEDDING_MODEL=openai/text-embedding-3-small` (vendor-prefixed name) for
  document RAG to work.

## Windows

Windows 10/11 is supported through [Git Bash](https://gitforwindows.org/) (the
shell that ships with Git for Windows). Open a Git Bash window — not PowerShell
or CMD — and run the script there. Windows ignores Unix file permissions, so
there is no `chmod` step for the SSH key or the script. The browser opens
automatically via the Windows `start` command. The manual PDF also builds on
Windows: `build.mjs` auto-detects Chrome or Edge.

## Config is the source of truth

The container runs with `ENABLE_PERSISTENT_CONFIG=false`, so every re-run of
`deploy` applies what is in `deploy.conf`. Without it Open WebUI keeps the LLM
URL and key it saw on first boot and ignores later changes. The flip side: admin
panel settings that have an environment-variable equivalent (connections, default
models, signup toggle, RAG settings) reset to the env values whenever the
container restarts. Put such settings in `deploy.conf` instead. Accounts, chats,
and per-model settings live in the database and are unaffected.

## First login

The first account created in the UI becomes the admin. Open WebUI keeps auth on;
since the app is reachable only through your tunnel, nothing is exposed publicly.

## Security notes

- Your API key lives in `deploy.conf` (gitignored) locally and in
  `~/open-webui/.env` (mode 600) on the instance. It is sent over SSH stdin,
  never on the remote command line.
- `StrictHostKeyChecking=accept-new`: first connection trusts the host key, any
  later change fails loudly.
