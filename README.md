# paperclip-selfhost

[![CI](https://github.com/artenl/paperclip-selfhost/actions/workflows/ci.yml/badge.svg)](https://github.com/artenl/paperclip-selfhost/actions/workflows/ci.yml)

Run [Paperclip](https://github.com/paperclipai/paperclip) 24/7 in Docker on your
Claude subscription, with one command. The agents stay signed in for a year instead
of being logged out every 8 hours.

```sh
curl -fsSL https://raw.githubusercontent.com/artenl/paperclip-selfhost/main/install.sh | sudo bash
```

The installer asks two questions (how you reach Paperclip, and whether to set up
the Claude token now) and does everything else:

- installs Docker if needed;
- starts Paperclip (pinned version), Postgres 17 and HTTPS with automatic certificates;
- restarts everything after a crash or a reboot, and backs up daily;
- adds a `paperclip` command for everything afterwards.

> Unofficial community project, not affiliated with Paperclip or Anthropic. It uses
> the official Paperclip Docker image, unmodified.

## Why: the 8-hour logout

When you connect a **Claude subscription** in Paperclip (stable releases up to at
least 2026.1005.0), Paperclip runs `claude auth login` and keeps only the access token
it returns. That token expires after about 8 hours, and Paperclip discards the refresh
token that would renew it. So every 8 hours, every agent fails with `401` /
*"terminal access failure"* until someone reconnects by hand.

This setup uses `claude setup-token` instead: Claude Code's official way to run on a
subscription without anyone at the keyboard. Its token is **valid for one year** and
needs no refresh. It is given to Paperclip's server, and every agent uses it.

## Requirements

- A Linux server with root access: a VPS, a home server or a VM. Tested on Ubuntu
  24.04; any distribution that [get.docker.com](https://get.docker.com) supports
  should work. Docker is installed for you if missing.
- 4 GB RAM recommended (2 GB minimum) and 15 GB of free disk. The Paperclip image
  alone takes about 8 GB once unpacked.
- A Claude Pro or Max subscription.
- For HTTPS: ports 80 and 443 reachable, and a domain pointing to the server. No
  domain? The installer offers `<your-ip>.sslip.io`, which works with no DNS setup.

## Install options

Run the command above and answer the questions, or pass the answers up front:

```sh
# HTTPS on your domain (its DNS A record must point to this server)
curl -fsSL https://raw.githubusercontent.com/artenl/paperclip-selfhost/main/install.sh | sudo bash -s -- --domain paperclip.example.com

# No domain, private network only: plain HTTP on port 3100
curl -fsSL https://raw.githubusercontent.com/artenl/paperclip-selfhost/main/install.sh | sudo bash -s -- --local
```

| Option | Meaning |
|---|---|
| `--domain <name>` | HTTPS on this domain |
| `--local` | No domain; plain HTTP on port 3100. Use it only on a network you trust. |
| `--port <n>` | Port for `--local` (default 3100) |
| `--version <v>` | Paperclip version to pin (default: the version this project is tested with) |
| `--yes` | Never prompt (needs `--domain` or `--local`) |
| `--skip-token` | Don't ask for the Claude token during install |

Everything goes to `/opt/paperclip` (set `PAPERCLIP_DIR` to change it). For an
unattended install, pass the token in the environment:
`... | sudo CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-... bash -s -- --domain x.example.com --yes`.

Prefer to read before running? Download
[`install.sh`](install.sh), inspect it, then run `sudo bash install.sh`.

## After install

**1. The Claude token.** The installer offers this step; run `paperclip token` to do it
later or again.

1. A sign-in link appears. Open it in your browser, signed in to the Claude account
   whose subscription the agents should use, and approve.
2. Paste the code the page shows back into the terminal.
3. The terminal prints `Your OAuth token (valid for 1 year):` and a token starting
   with `sk-ant-oat01-`. Copy all of it and paste it when asked. Input is hidden; a
   line break added by the terminal is fine.

The script then has Claude answer "OK" through the agents' setup to prove it works.
Already ran `claude setup-token` elsewhere? Use `paperclip token --paste`.

**2. Your admin account.** Open the invite link the installer printed (or run
`paperclip invite` again) and create your account. Then close account creation to
strangers:

```sh
paperclip signups off
```

**3. Agents.** In onboarding and for every new agent, at **Connect a model**:

- Click **Claude**, then **Connect**. Ignore the line *"This environment does not
  support browser sign-in"*. Paperclip then checks the server's token and moves on.
- Do **not** click "Use API key instead". That bills Anthropic API usage instead of
  your subscription.

> **The one rule:** never connect a **Claude subscription** account under
> Apps → Connections, and never attach one to an agent. An attached connection
> overrides the server token and brings back the 8-hour expiry.

## Commands

| Command | What it does |
|---|---|
| `paperclip status` | Containers, URL, version, days left on the token, last backup |
| `paperclip check` | Proves the agents' Claude login works right now |
| `paperclip token` | Creates or replaces the Claude token |
| `paperclip invite` | One-time link to create the first admin account |
| `paperclip signups off` / `on` | Closes or reopens account creation (open it while a teammate accepts an invite) |
| `paperclip logs` | Follows Paperclip's logs |
| `paperclip restart` / `stop` / `start` | What they say |
| `paperclip backup` | Backs up now (it also runs every night at 03:17) |
| `paperclip update` | Shows your Paperclip version and the latest stable one |
| `paperclip update <version>` | Backs up, upgrades, and rolls back if Paperclip fails to start |
| `paperclip remove-old <dir>` | Archives and stops another Paperclip Docker Compose stack, for example one from a hosting template |
| `paperclip uninstall` | Removes the containers, schedule and command; keeps your data |

**Once a year:** the token expires 365 days after you create it. `paperclip status`
counts down and warns at 30 days. Run `paperclip token` before then.

**Updates are manual on purpose.** Paperclip is pinned, so it never changes under you.
Read the [release notes](https://github.com/paperclipai/paperclip/releases), then
`paperclip update <version>`. To update this project's scripts, run the install
command again; your settings and data are kept.

## Backups and restore

Every night, `/opt/paperclip/backups/` receives a database dump, an archive of
Paperclip's files (its secrets key included) and a copy of the settings. The newest 7
of each are kept. Copy them off the server now and then.

To restore:

```sh
cd /opt/paperclip
paperclip stop
(cd deploy && docker compose up -d db)
(cd deploy && docker compose exec -T db pg_restore -U paperclip -d paperclip --clean --if-exists --no-owner) < backups/paperclip-db-<date>.dump
tar -xzf backups/paperclip-files-<date>.tar.gz -C deploy/data   # only if files were lost
paperclip start
```

## Troubleshooting

- **Agents fail with 401, "terminal access failure" or "login required".** Run
  `paperclip check`.
  - If the check fails, the token was revoked or has expired. Run `paperclip token`.
  - If the check passes, that agent has a Claude connection attached. Remove it (see
    *The one rule* above).
- **Agents pause with a quota or "limit" message.** That is your plan's usage limit,
  not a logout. Paperclip waits for the reset and carries on. Several agents running
  around the clock can reach Pro/Max limits.
- **HTTPS does not come up.** `paperclip status` shows whether the domain resolves to
  the server. Open ports 80 and 443 in your provider's firewall, then wait a minute;
  Caddy retries the certificate on its own.
- **"Ports 80/443 already in use".** Another web server or reverse proxy holds them.
  Stop it, or install with `--local`. An older Paperclip stack can be retired with
  `paperclip remove-old <its folder>`.

## How it works

`deploy/docker-compose.yml` runs three containers: Postgres, the official
`ghcr.io/paperclipai/paperclip` image, and Caddy (HTTPS mode only). The Claude token
is passed to Paperclip as `CLAUDE_CODE_OAUTH_TOKEN`. Paperclip's Claude Code adapter
uses that variable for any agent that has no AI connection attached, so all agents
share one token that never needs refreshing.

Both modes run Paperclip with `PAPERCLIP_DEPLOYMENT_EXPOSURE=public`. That turns off
Paperclip's own Claude sign-in, which is the one that stores 8-hour tokens. It also
disables local stdio MCP connectors; remote (HTTP) MCP connectors still work. If you
need stdio connectors, set `PAPERCLIP_EXPOSURE=private` in `deploy/.env` and run
`paperclip restart`, but then avoid Paperclip's "Sign in with Claude" button.

Settings and secrets live in `/opt/paperclip/deploy/.env`, readable by root only.
Paperclip's port 3100 listens only on the server itself in HTTPS mode; Caddy is the
way in.

Tested with Paperclip 2026.1005.0 and Claude Code 2.1.291. CI installs the stack from
scratch with the one-line command on every change.

## License

[MIT](LICENSE)
