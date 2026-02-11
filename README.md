# mesh-infra

Infrastructure-as-code for the Agent Mesh. Docker Compose deployments for all hosts.

## Structure

```
hosts/
├── nats-mesh-staging/       # Mesh hub (NATS, dashboard, observability)
│   ├── docker-compose.yml
│   ├── .env.example         # Template for secrets
│   ├── caddy/
│   │   └── Caddyfile
│   ├── nats/
│   │   └── nats-server.conf
│   └── data/                # Persistent volumes (gitignored)
│
├── winstonbot/              # Agent VM (OpenClaw/WinstonJunior)
│   ├── docker-compose.yml
│   ├── .env.example
│   └── caddy/
│       └── Caddyfile
│
└── _template/               # Blank host template for new deployments
    ├── docker-compose.yml
    └── .env.example
```

## Conventions

- **One `docker-compose.yml` per host** — all services for that host in one file
- **Secrets in `.env`** (gitignored, `chmod 600`) — never baked into images
- **Persistent data in `data/`** (gitignored) — named volumes mapped here
- **Config files mounted read-only** where possible
- **Official images preferred** — only custom Dockerfiles when necessary (e.g., mesh-dashboard)
- **Health checks on every service** — Compose `healthcheck` directives for orchestration
- **Profiles** for optional services: `--profile observability` for VictoriaMetrics/Grafana

## Deployment

```bash
# On the target host:
cd hosts/<hostname>
cp .env.example .env
# Edit .env with real secrets
chmod 600 .env
docker compose up -d
```

## Hosts

| Host | VM | Services | Status |
|------|-----|----------|--------|
| nats-mesh-staging | e2-small (2GB) | NATS, Dashboard, Caddy | 🔄 Containerizing |
| winstonbot | e2-medium (4GB) | WinstonJunior, Caddy | 📋 Planned |

## Related Repos

- [mesh-dashboard](https://github.com/Potential-2-Actual/mesh-dashboard) — SvelteKit dashboard app
- [WinstonJunior](https://github.com/Potential-2-Actual/WinstonJunior) — Customized OpenClaw fork
- [openclaw-nats](https://github.com/Potential-2-Actual/openclaw-nats) — Standalone NATS connector plugin
