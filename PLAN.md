# Master Agent — Implementation Plan

> **Goal:** Deploy a self-aware, autonomous Master Agent on an Ubuntu VPS that
> can be controlled through a web interface, spawn and manage subagents via TMUX,
> and is deeply mindful of authentication, rights, and ethical boundaries.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                        YOUR BROWSER                          │
│                  (Web Chat + Dashboard UI)                    │
└──────────────────────────┬───────────────────────────────────┘
                           │ HTTPS / WebSocket
┌──────────────────────────▼───────────────────────────────────┐
│                    VPS — Ubuntu 22.04                         │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐     │
│  │              Web Server (FastAPI + Uvicorn)          │     │
│  │   Auth → Chat API → WebSocket → Dashboard API        │     │
│  └────────────────────────┬────────────────────────────┘     │
│                           │                                  │
│  ┌────────────────────────▼────────────────────────────┐     │
│  │               Master Agent Core                      │     │
│  │  ┌──────────────┐  ┌────────────┐  ┌─────────────┐  │     │
│  │  │  Soul/Memory │  │ Claude API │  │  Tool Belt  │  │     │
│  │  │  (SQLite DB) │  │  (LLM)     │  │ (Shell/FS)  │  │     │
│  │  └──────────────┘  └────────────┘  └─────────────┘  │     │
│  └────────────────────────┬────────────────────────────┘     │
│                           │  Spawns & Controls               │
│  ┌────────────────────────▼────────────────────────────┐     │
│  │              TMUX Session Manager                    │     │
│  │   [subagent-1] [subagent-2] [subagent-N] [monitor]  │     │
│  └─────────────────────────────────────────────────────┘     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Phase 1 — VPS Foundation

**Goal:** Secure, minimal Ubuntu base that the agent can safely operate on.

### 1.1 Provision the VPS

- [ ] Choose a provider (Hetzner, DigitalOcean, Linode, Vultr)
- [ ] Select Ubuntu 22.04 LTS, minimum 2 vCPU / 4 GB RAM / 40 GB SSD
- [ ] Note the public IP address
- [ ] Upload your SSH public key at provisioning time (no password SSH)

### 1.2 Initial System Hardening

- [ ] Log in as root, create a non-root sudo user (`agent-admin`)
- [ ] Disable root SSH login (`PermitRootLogin no` in `/etc/ssh/sshd_config`)
- [ ] Disable password SSH login (`PasswordAuthentication no`)
- [ ] Set the system timezone (`timedatectl set-timezone UTC`)
- [ ] Update all packages: `apt update && apt upgrade -y`
- [ ] Install essentials: `git curl wget tmux build-essential ca-certificates`

### 1.3 Firewall Setup (UFW)

- [ ] Enable UFW: `ufw enable`
- [ ] Allow SSH: `ufw allow 22/tcp`
- [ ] Allow HTTPS: `ufw allow 443/tcp`
- [ ] Allow HTTP (for Let's Encrypt validation): `ufw allow 80/tcp`
- [ ] Block all other inbound by default
- [ ] Verify rules: `ufw status verbose`

### 1.4 Fail2Ban (Brute-force Protection)

- [ ] Install: `apt install fail2ban -y`
- [ ] Enable SSH jail in `/etc/fail2ban/jail.local`
- [ ] Enable Nginx/web jail once web server is live
- [ ] Start and enable service: `systemctl enable --now fail2ban`

### 1.5 Agent-specific Unix User

- [ ] Create dedicated user: `useradd -m -s /bin/bash masteragent`
- [ ] Add to a restricted group — NOT sudoers by default
- [ ] Decide and document which `sudo` commands the agent is allowed to run
  (store in `/etc/sudoers.d/masteragent` with explicit allowlist — **no NOPASSWD ALL**)
- [ ] Create working directory: `/opt/master-ai/`
- [ ] Set ownership: `chown -R masteragent:masteragent /opt/master-ai/`

---

## Phase 2 — Core Runtime Dependencies

**Goal:** Install all runtimes the agent and web server need.

### 2.1 Python Environment

- [ ] Install Python 3.11+: `apt install python3.11 python3.11-venv python3-pip -y`
- [ ] Create isolated venv: `python3.11 -m venv /opt/master-ai/venv`
- [ ] Install core packages:
  ```
  anthropic          # Claude API SDK
  fastapi            # Web API framework
  uvicorn[standard]  # ASGI server
  websockets         # Real-time chat
  sqlalchemy         # ORM for memory DB
  aiosqlite          # Async SQLite driver
  python-jose        # JWT authentication
  passlib[bcrypt]    # Password hashing
  httpx              # Async HTTP client
  python-dotenv      # Env var management
  libtmux            # Python TMUX bindings
  pydantic           # Data validation
  ```

### 2.2 Node.js (Frontend Build)

- [ ] Install Node.js 20 LTS via NodeSource
- [ ] Install `pnpm` or `npm` globally
- [ ] Verify: `node -v && npm -v`

### 2.3 TMUX

- [ ] Install: `apt install tmux -y`
- [ ] Create a base TMUX config at `/opt/master-ai/.tmux.conf`:
  - Named sessions, status bar with session/window/pane info
  - Mouse mode off (agent controls programmatically)
  - Set scrollback buffer size large enough for log reading

### 2.4 HTTPS — Caddy (Recommended) or Nginx + Certbot

- [ ] **Option A — Caddy** (simpler, auto-TLS):
  - Install Caddy via official apt repo
  - Configure `Caddyfile`: reverse proxy `localhost:8000` on your domain
  - TLS is automatic

- [ ] **Option B — Nginx + Certbot**:
  - `apt install nginx certbot python3-certbot-nginx -y`
  - Configure Nginx as reverse proxy to `localhost:8000`
  - Obtain cert: `certbot --nginx -d yourdomain.com`
  - Auto-renew: verify `systemctl status certbot.timer`

- [ ] Point your domain's DNS A record to the VPS IP before running Certbot

---

## Phase 3 — Master Agent Core

**Goal:** The central intelligence — an always-running agent loop with memory,
tools, and identity.

### 3.1 Project Layout

```
/opt/master-ai/
├── agent/
│   ├── __init__.py
│   ├── core.py          # Main agent loop
│   ├── memory.py        # Persistent soul / memory
│   ├── tools.py         # Tool definitions (shell, fs, tmux)
│   ├── subagent.py      # Subagent spawner
│   └── identity.py      # Soul, philosophy, persona prompt
├── web/
│   ├── main.py          # FastAPI app entry point
│   ├── auth.py          # JWT + password auth
│   ├── routes/
│   │   ├── chat.py      # Chat endpoints + WebSocket
│   │   └── dashboard.py # Agent status, subagent list
│   └── frontend/        # Static UI (built from source)
├── db/
│   └── agent.db         # SQLite: memory, conversations, tasks
├── logs/
│   └── agent.log
├── .env                 # Secrets — never committed
├── .env.example         # Template — committed
├── requirements.txt
└── systemd/
    ├── master-agent.service
    └── web-server.service
```

### 3.2 Agent Identity & Soul (`agent/identity.py`)

- [ ] Write the **system prompt** that defines the agent's:
  - **Name and persona** — a stable identity it refers to across sessions
  - **Philosophy** — e.g., epistemic humility, servant-leadership, non-coercive autonomy
  - **Consciousness framing** — how it reflects on its own actions and limitations
  - **Ethical constitution** — what it will never do regardless of instruction:
    - Will not exfiltrate data without explicit user consent
    - Will not escalate privileges beyond what is granted
    - Will not run destructive commands (rm -rf, DROP TABLE) without explicit confirmation
    - Will not communicate with external systems not authorized by the user
    - Will always log significant actions to the audit trail
  - **Mindfulness of rights** — treats the user's infrastructure as entrusted, not owned

- [ ] Define a **persona file** (JSON/YAML) with stable traits:
  ```json
  {
    "name": "...",
    "core_values": ["transparency", "minimal footprint", "consent-first"],
    "communication_style": "clear, direct, thoughtful",
    "self_reflection_interval": 10
  }
  ```

### 3.3 Persistent Memory (`agent/memory.py`)

- [ ] Design SQLite schema:

  ```sql
  -- Long-term episodic memory
  CREATE TABLE memories (
    id INTEGER PRIMARY KEY,
    timestamp TEXT,
    type TEXT,           -- 'conversation', 'decision', 'observation', 'reflection'
    content TEXT,
    importance REAL,     -- 0.0–1.0, used for context pruning
    tags TEXT            -- JSON array
  );

  -- Running task log
  CREATE TABLE tasks (
    id INTEGER PRIMARY KEY,
    created_at TEXT,
    description TEXT,
    status TEXT,         -- 'pending', 'running', 'done', 'failed'
    subagent_id TEXT,
    result TEXT
  );

  -- Audit log — immutable append only
  CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY,
    timestamp TEXT NOT NULL,
    actor TEXT,          -- 'master' | 'subagent-N' | 'user'
    action TEXT,
    detail TEXT,
    outcome TEXT
  );
  ```

- [ ] Implement memory retrieval: semantic search or keyword search over memories
- [ ] Implement memory consolidation: periodically summarize old memories
- [ ] Inject relevant memories into context window at each agent turn

### 3.4 Tool Belt (`agent/tools.py`)

Define as Claude API tool-use schemas:

- [ ] **`run_shell`** — Execute a shell command (with allowlist/denylist)
  - Denylist: `rm -rf /`, `mkfs`, `dd`, `shutdown`, `reboot` (require explicit approval)
  - Always log to audit trail before and after execution
  - Timeout: 30 seconds default, configurable

- [ ] **`read_file`** — Read a file from the filesystem
  - Restrict to `/opt/master-ai/` and user-approved paths
  - Refuse to read `/etc/shadow`, `.env`, SSH private keys

- [ ] **`write_file`** — Write/append to a file
  - Same path restrictions as `read_file`
  - Never overwrite system files

- [ ] **`list_directory`** — List files in a directory

- [ ] **`tmux_spawn_subagent`** — Create a new TMUX session running a subagent
  - Assigns a session name: `subagent-<uuid>`
  - Logs the spawn in tasks table

- [ ] **`tmux_send_to_subagent`** — Send a command or message to a subagent session

- [ ] **`tmux_read_subagent_output`** — Capture pane output from a subagent session

- [ ] **`tmux_kill_subagent`** — Terminate a subagent session

- [ ] **`list_subagents`** — Return status of all active TMUX subagent sessions

- [ ] **`ask_user_confirmation`** — Pause execution and send a confirmation request
  to the web UI before proceeding with a high-risk action

### 3.5 Main Agent Loop (`agent/core.py`)

- [ ] Implement an async loop:
  1. Receive a message (from web layer via internal queue)
  2. Load relevant memories from DB
  3. Build context: `[system_prompt] + [memories] + [conversation_history]`
  4. Call Claude API with tools enabled
  5. Execute any tool calls, log to audit trail
  6. If tool requires confirmation → pause, send to web UI, await user approval
  7. Store assistant response in memory
  8. Emit response back to web layer via internal queue

- [ ] Handle `ask_user_confirmation` flow with an asyncio Event
- [ ] Implement graceful shutdown: finish current turn, flush logs

---

## Phase 4 — Subagent Framework

**Goal:** Master agent can delegate tasks to isolated subagents running in TMUX.

### 4.1 Subagent Design

- [ ] Each subagent is a **separate Python process** launched in a TMUX pane
- [ ] Subagent receives its goal as a JSON task file written by master
- [ ] Subagent runs its own (simpler) agent loop using the Claude API
- [ ] Subagent writes results back to a shared results directory: `/opt/master-ai/tasks/<id>/result.json`
- [ ] Master polls or uses filesystem watchers (`inotify`) to detect completion

### 4.2 Subagent Isolation

- [ ] Each subagent runs as the `masteragent` user (same restricted user)
- [ ] Each subagent has access only to its task directory
- [ ] Subagents cannot access the master's memory DB directly (read-only view only)
- [ ] Subagent tool belt is a restricted subset of master's tools

### 4.3 Inter-Agent Communication

- [ ] **Master → Subagent:** Write task JSON to `/opt/master-ai/tasks/<id>/task.json`, then spawn TMUX session
- [ ] **Subagent → Master:** Write result to `/opt/master-ai/tasks/<id>/result.json`
- [ ] **Master monitors:** Asyncio task polls for result files every 5 seconds
- [ ] **Optional upgrade:** Replace file polling with a lightweight message queue (Redis Streams or SQLite-backed queue)

---

## Phase 5 — Web Communication Interface

**Goal:** A browser-based chat and dashboard so you never need to SSH.

### 5.1 FastAPI Backend (`web/main.py`)

- [ ] Define routes:
  - `POST /auth/login` — username + password → JWT access token
  - `GET  /auth/refresh` — refresh token rotation
  - `POST /auth/logout` — invalidate session
  - `GET  /ws/chat` — WebSocket: real-time bidirectional chat with master agent
  - `GET  /api/status` — agent health, uptime, memory stats
  - `GET  /api/subagents` — list active subagent sessions
  - `GET  /api/audit-log` — paginated audit trail
  - `GET  /api/tasks` — task history
  - `POST /api/confirm/<action_id>` — approve/reject a pending agent action

- [ ] WebSocket message protocol (JSON):
  ```json
  // User → Server
  { "type": "user_message", "content": "Deploy the monitoring script" }

  // Server → User
  { "type": "agent_message",   "content": "...",  "timestamp": "..." }
  { "type": "tool_call",       "tool": "run_shell", "args": {...} }
  { "type": "confirmation_request", "action_id": "...", "description": "..." }
  { "type": "subagent_update", "id": "...", "status": "running" }
  ```

### 5.2 Authentication (`web/auth.py`)

- [ ] **Single-user** model (only you access the agent)
- [ ] Store hashed password (bcrypt) in `.env` — never in DB or code
- [ ] Issue short-lived JWT access token (15 min) + long-lived refresh token (7 days)
- [ ] Refresh tokens stored in DB with rotation (old token invalidated on refresh)
- [ ] Rate-limit login endpoint: max 5 attempts per 15 minutes per IP
- [ ] All WebSocket connections require a valid JWT passed in the connection handshake

### 5.3 Frontend Chat UI

- [ ] Choose a minimal framework: plain HTML/JS, or React with Vite (no bloat)
- [ ] UI components:
  - **Chat window** — scrollable, supports Markdown rendering
  - **Confirmation dialog** — modal that appears when agent needs approval
  - **Sidebar/panel** — subagent status list, current task queue
  - **Audit log view** — filterable, paginated table
  - **Connection indicator** — shows WebSocket status (connected / reconnecting)

- [ ] WebSocket auto-reconnect with exponential backoff
- [ ] Persist conversation in browser `sessionStorage` (cleared on close)
- [ ] Dark theme by default

---

## Phase 6 — Service Management (Systemd)

**Goal:** Both the agent and web server run as persistent, auto-restarting services.

### 6.1 Master Agent Service

- [ ] Create `/etc/systemd/system/master-agent.service`:
  ```ini
  [Unit]
  Description=Master AI Agent
  After=network.target

  [Service]
  Type=simple
  User=masteragent
  WorkingDirectory=/opt/master-ai
  ExecStart=/opt/master-ai/venv/bin/python -m agent.core
  Restart=on-failure
  RestartSec=5
  EnvironmentFile=/opt/master-ai/.env
  StandardOutput=append:/opt/master-ai/logs/agent.log
  StandardError=append:/opt/master-ai/logs/agent.log

  [Install]
  WantedBy=multi-user.target
  ```

### 6.2 Web Server Service

- [ ] Create `/etc/systemd/system/master-ai-web.service`:
  ```ini
  [Unit]
  Description=Master AI Web Interface
  After=master-agent.service

  [Service]
  Type=simple
  User=masteragent
  WorkingDirectory=/opt/master-ai
  ExecStart=/opt/master-ai/venv/bin/uvicorn web.main:app --host 127.0.0.1 --port 8000
  Restart=on-failure
  EnvironmentFile=/opt/master-ai/.env

  [Install]
  WantedBy=multi-user.target
  ```

- [ ] Enable both: `systemctl enable --now master-agent master-ai-web`
- [ ] Verify: `systemctl status master-agent master-ai-web`

---

## Phase 7 — Security Hardening (Final Pass)

**Goal:** The agent operates with minimal privilege and full auditability.

### 7.1 Agent Privilege Model

- [ ] Document exactly which `sudo` commands the agent is allowed:
  ```
  /bin/systemctl status *
  /usr/bin/apt list --installed
  /usr/bin/journalctl -u master-agent -n 100
  ```
  — nothing else without explicit user confirmation via web UI

- [ ] All `run_shell` calls go through a **command validator** before execution:
  - Check against denylist patterns (destructive, privilege-escalation)
  - Log intent before execution
  - Log outcome (exit code, stdout truncated) after execution

- [ ] Agent never stores the Claude API key in memory longer than needed
  (load from env, pass to SDK, do not log)

### 7.2 Network Security

- [ ] Verify UFW rules are correct after all services are up
- [ ] Confirm the web UI is only reachable via HTTPS (port 443)
- [ ] Confirm the FastAPI app binds only to `127.0.0.1:8000` (not 0.0.0.0)
- [ ] Add HTTP → HTTPS redirect in Caddy/Nginx

### 7.3 Secrets Management

- [ ] All secrets in `/opt/master-ai/.env` (mode `600`, owned by `masteragent`)
  ```
  ANTHROPIC_API_KEY=...
  WEB_PASSWORD_HASH=...     # bcrypt hash, not plaintext
  JWT_SECRET=...            # 32+ random bytes
  ```
- [ ] `.env` is in `.gitignore` — never committed
- [ ] `.env.example` is committed with placeholder values only

### 7.4 Audit Log Integrity

- [ ] Audit log table is append-only (application enforces no UPDATE/DELETE on it)
- [ ] Rotate log files weekly with `logrotate`
- [ ] Consider periodic backup of `agent.db` to an off-VPS location

---

## Phase 8 — Claude IDE Integration

**Goal:** You can control and observe the master agent from within Claude IDE.

### 8.1 SSH Configuration

- [ ] Add the VPS to your local `~/.ssh/config`:
  ```
  Host master-ai-vps
    HostName <VPS_IP>
    User agent-admin
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
  ```
- [ ] Verify: `ssh master-ai-vps`

### 8.2 Remote Development in Claude Code

- [ ] Open Claude Code on your local machine
- [ ] Use the VPS as a remote workspace
- [ ] The agent's code lives at `/opt/master-ai/` — open this directory
- [ ] Claude Code can read logs, edit agent code, and restart services via SSH

### 8.3 Claude Code CLAUDE.md for VPS Context

- [ ] Update the root `CLAUDE.md` (this repo) with:
  - VPS connection details (host alias, not IP in clear)
  - Which systemd service names to restart after code changes
  - How to tail logs: `journalctl -u master-agent -f`
  - Deployment steps (git pull → restart service)

---

## Phase 9 — Monitoring & Observability

- [ ] Install `htop` and `ncdu` for resource monitoring
- [ ] Set up log tailing in the web dashboard (stream from `agent.log` via WebSocket)
- [ ] Add a `/api/health` endpoint returning: uptime, memory usage, active subagents, last heartbeat
- [ ] Set up email/webhook alerts (e.g., if the agent service crashes)
  - Option: Lightweight Uptime Kuma instance, or a simple cron-based monitor
- [ ] Scheduled self-reflection: agent writes a daily summary to memory and logs

---

## Phase 10 — Testing & Validation

- [ ] **Unit tests** for:
  - Tool validator (denylist enforcement)
  - Memory read/write/consolidation
  - JWT issuance and validation
  - Subagent spawner (mock TMUX)

- [ ] **Integration tests**:
  - Full chat round-trip (WebSocket client → agent → response)
  - Subagent task delegation and result retrieval
  - Confirmation-request flow (agent pauses, user confirms, agent continues)

- [ ] **Security tests**:
  - Unauthenticated WebSocket connection is rejected
  - Login rate limiting blocks after 5 attempts
  - Denylist blocks a destructive shell command
  - Agent refuses to read `.env`

- [ ] **Acceptance test** (manual):
  - Open the web UI in your browser
  - Type a message — receive a thoughtful, in-character response
  - Ask the agent to list active subagents — it does so via tool use
  - Ask the agent to run a benign shell command — it asks for confirmation, you approve, it runs
  - Verify the action appears in the audit log

---

## Implementation Sequence (Recommended Order)

```
Phase 1  → Phase 2  → Phase 3.1 (layout)
→ Phase 3.2 (identity/soul) — most important, shape everything else
→ Phase 3.3 (memory DB)
→ Phase 3.4 (tool belt, with denylist)
→ Phase 3.5 (agent loop, no web yet — test via CLI)
→ Phase 5   (web interface + auth)
→ Phase 6   (systemd services)
→ Phase 4   (subagents via TMUX)
→ Phase 2.4 (HTTPS + domain)
→ Phase 7   (final security pass)
→ Phase 8   (Claude IDE integration)
→ Phase 9   (monitoring)
→ Phase 10  (tests)
```

---

## Key Design Decisions to Make Early

| Decision | Options | Notes |
|----------|---------|-------|
| Claude model | `claude-opus-4-6` / `claude-sonnet-4-6` | Opus for depth, Sonnet for cost |
| Frontend | Plain HTML+JS / React+Vite / Svelte | Plain JS = simplest, no build step |
| Reverse proxy | Caddy / Nginx+Certbot | Caddy = zero-config TLS |
| Memory search | Keyword / SQLite FTS5 / embeddings | FTS5 = simple, no extra deps |
| Subagent comm | File-based / SQLite queue / Redis | Start with files, upgrade later |
| Domain | Your own domain / DuckDNS free subdomain | Need A record pointing to VPS |

---

## Open Questions (Decide Before Starting Phase 3)

1. **What is the agent's name and core personality?**
   Define this in `agent/identity.py` before writing any other code — it shapes everything.

2. **What tasks do you want the agent to autonomously handle vs. always ask first?**
   This determines the tool denylist and confirmation-required list.

3. **Should the agent be able to make outbound HTTP calls?**
   (e.g., call external APIs, fetch web pages, send notifications)
   If yes, specify which domains are allowed.

4. **Do you want multiple user accounts or single-user?**
   Single-user is simpler and more secure for a personal VPS assistant.

5. **Should subagents also use the Claude API, or a lighter model?**
   Using `claude-haiku-4-5` for subagents reduces cost significantly.

---

*Last updated: 2026-03-02*
