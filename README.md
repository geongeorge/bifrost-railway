# Bifrost on Railway

A Railway-ready build of [Bifrost](https://github.com/maximhq/bifrost), the open-source
AI gateway that puts 20+ model providers behind one OpenAI-compatible API.

This repo is a thin layer over the official `maximhq/bifrost` image. It exists because
three things cannot be expressed as Railway variables:

| Added | Why |
|---|---|
| `config.json` | Bifrost's stores, admin auth and plugins live in a JSON document. Baking it in means a fresh deploy is password-protected from its first request, rather than after someone remembers to enable auth. |
| A boot-time Postgres bootstrap | Bifrost needs a UTF8 database created from `template0` and a role that owns it. Railway's managed Postgres hands out the superuser and a `railway` database instead. |
| `railway-entrypoint.sh` | Runs that bootstrap, sizes `GOMEMLIMIT` from the container's cgroup, then execs the image's own entrypoint unchanged. |

Everything else — providers, virtual keys, budgets, MCP servers — is configured from
the dashboard after deploy and stored in Postgres.

## Topology

| Service | Public | Purpose |
|---|---|---|
| `bifrost` | yes | Gateway, dashboard and management API on port 8080 |
| `Postgres` | no | `config_store` and `logs_store` (Bifrost requires PostgreSQL 16+) |
| `Redis` | no | `vector_store` backing the semantic-cache plugin |
| `bifrost-logs` bucket | no | Request/response log payloads, offloaded from Postgres |

Ships at one replica: OSS Bifrost has no cluster mode, so budget and rate-limit
counters are per-process and a second replica would silently double every limit.

## Variables

| Variable | Required | Notes |
|---|---|---|
| `BIFROST_ADMIN_USERNAME` | yes | Dashboard login |
| `BIFROST_ADMIN_PASSWORD` | yes | Dashboard login |
| `BIFROST_SETUP_TOKEN` | yes | Bootstrap secret for creating the first admin account |
| `BIFROST_ENCRYPTION_KEY` | yes | Encrypts stored provider keys. **Must stay stable** — changing it makes existing encrypted values unreadable |
| `BIFROST_EXTERNAL_URL` | yes | Public base URL, used as the OAuth `redirect_uri` against upstream MCP servers |
| `PG_ADMIN_URL` | yes | Superuser URL, used only by the boot-time bootstrap |
| `PG_HOST` | yes | Private hostname of the Postgres service |
| `PG_PASSWORD` | yes | Password for the scoped role this repo creates |
| `S3_BUCKET`, `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | yes | Log payload storage |
| `REDIS_ADDR`, `REDIS_PASSWORD` | yes | Vector store |
| `PG_USER` | no | Scoped role name, default `bifrost` |
| `PG_SSL_MODE` | no | Default `require`; set `disable` for a Postgres without TLS |
| `PG_BOOTSTRAP` | no | Set `0` when pointing at an external Postgres whose role and database already exist |
| `GOMEMLIMIT` | no | Derived from the container's memory limit when unset |

Provider API keys are **not** set here — add them in the dashboard, or reference them
from `config.json` with `env.YOUR_KEY_NAME`.

## Auth

Authentication is on from the first boot and covers two separate surfaces:

- **Dashboard and management API** — the admin username and password. An
  unauthenticated `GET /api/providers` answers `401`.
- **Inference (`/v1/*`)** — a virtual key, because `client.enforce_auth_on_inference`
  is `true`. Admin credentials deliberately do **not** work here; an unauthenticated
  call answers `401 virtual_key_required`.

So the first thing to do after deploying is issue a virtual key under
**Governance → Virtual Keys**, then send it as `x-bf-vk`:

```bash
curl -X POST https://<your-domain>/v1/chat/completions \
  -H "x-bf-vk: $YOUR_VIRTUAL_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}'
```

Give each key a budget and a rate limit while you are there — they are the only thing
standing between a leaked key and your provider bill.

## Licence

Bifrost is licensed by Maxim AI; see [upstream](https://github.com/maximhq/bifrost).
This packaging is provided as-is.
