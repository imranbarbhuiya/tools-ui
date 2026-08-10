# Tools UI

Menu bar process manager for local tools (PM2-style, tiny Mac app).

**Stack:** SwiftUI + SwiftPM (no Electron, no server).

## Install / rebuild

```bash
cd tools-ui
./scripts/package-app.sh
```

Installs to **`~/Applications/Tools UI.app`** (and keeps a copy in the repo).

## Launch

| Method | How |
| --- | --- |
| **Always** | Use **one** copy only: `~/Applications/Tools UI.app` |
| **Raycast app search** | Type **Tools UI** (after install + Raycast Application indexing on) |
| **Raycast script** | Add `scripts/raycast-open-tools-ui.sh` as a Script Command (always works) |
| **Terminal** | `open -a "Tools UI"` |
| **Dev** | `swift run --disable-sandbox` |

**Duplicate bolt icons?** You opened the app twice (old `ToolsUI.app` + new `Tools UI.app`). Quit both from the menu, then only open:

```bash
pkill -x ToolsUI || true
open -a "Tools UI"
```

Second `open` reuses the same instance (no second menu icon).

Menu bar only (accessory) — bolt icon; manager window when you need it.
## Use

1. **Open Manager…** from the menu bar
2. **Add** a service: name, working directory, command, optional URL
3. **Start / Stop** from the manager or the menu bar submenu
4. **Open URL** for browser tools (e.g. Frameforge → `http://localhost:3456`)

Config is saved at:

`~/Library/Application Support/ToolsUI/services.json`

## Adding things

The sidebar has three groups: **Services** (processes), **Docker** (containers this
app manages), and **Not managed** (containers Docker knows about that you have not
adopted yet — click `+` to take one over).

### Add from Folder…

Pick a project folder and Tools UI reads it to see how it wants to be started:

| Found | Offered |
| --- | --- |
| `compose.yaml` / `docker-compose.yml` | Each compose service becomes its own row |
| `Dockerfile` | Builds the image and runs the container; ports prefilled from `EXPOSE` |
| `package.json` | Runs a script — `bun`/`pnpm`/`yarn`/`npm` picked from the lockfile |

When docker config is present it is preselected and called out, but you can always
switch to **Command** and just run the dev script instead. Nothing in the folder is
modified.

### Add from Docker…

A catalog of packaged apps (Excalidraw, n8n, Uptime Kuma, Postgres, Redis, MinIO, …).
Pick one, confirm the host port, and it runs `docker pull` + `docker run -d` for you.
The **Any image** field takes `owner/image:tag`, pulls it, and reads the image's
`EXPOSE` list to prefill the port.

Containers are driven with the `docker` CLI. Quitting Tools UI leaves them running.

## Portless

For a **process**, portless spawns it and assigns the port:
`portless <name> <your command>`.

For a **container**, the port already exists, so Tools UI registers a static route
instead — `portless alias <name> <hostPort>` on start, removed on stop. Portless is
an HTTP proxy, so this only helps for ports that speak HTTP; a Postgres port gets
no useful hostname.

The URL shown in the UI is read from the live proxy (`portless list` and
`~/.portless/proxy.port`) rather than assumed, because portless falls back to an
unprivileged port when it cannot bind 443.

## Dependencies

A service can depend on any other service or container. Starting it starts each
dependency first, in order, and **waits for it to be ready**:

| Ready when | Meaning |
| --- | --- |
| Automatic | Container healthcheck if the image has one, else its published port accepting a connection. Processes do not wait unless a port is set. |
| Wait for TCP port | Poll until the port accepts a connection |
| Wait for HTTP response | Poll until a GET returns < 500 |
| Wait for container health | Poll `docker inspect` health status |
| Don't wait | Start immediately |

Cycles are rejected in the editor and broken at runtime.

## Environment overrides

Each service has two env lists:

- **Provides** — handed to every service that depends on it
- **Overrides** — applied to itself, winning over anything inherited

Values support tokens resolved against the *contributing* service:
`{{host}}`, `{{port}}`, `{{port:5432}}`, `{{url}}`, `{{name}}`.

So a Postgres container providing:

```
DATABASE_URL = postgres://postgres:postgres@{{host}}:{{port:5432}}/app
```

gives a dependent process `DATABASE_URL=postgres://postgres:postgres@127.0.0.1:55432/app`,
using whatever host port that container actually published. The editor's
**Resolved** row previews exactly what the service will receive.

## Notes

- Commands run via `/bin/zsh -lc 'exec …'` so your shell `PATH` (bun, node, etc.) is used
- Logs stream into the detail pane; container logs come from `docker logs -f`
- Quit from the menu bar ends managed processes but leaves containers running
