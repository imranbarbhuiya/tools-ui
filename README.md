# Tools UI

A native Mac cockpit for local services, Git worktrees, Portless routes and container logs.

**Stack:** SwiftUI + SwiftPM (no Electron, no server).

## Install / rebuild

```bash
cd tools-ui
./scripts/package-app.sh
```

Installs to **`~/Applications/Tools UI.app`** (and keeps a signed copy in the repo).
Use `./scripts/package-app.sh --no-install` to build without replacing the installed app.
The package includes the offline log parser and its license notice.

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

## Ports & processes

Choose **Ports & Processes…** from the menu bar or use the network button in the
manager toolbar. It shows every listening TCP port, the owning process and PID,
and the process's working directory and project folder when macOS exposes them.
and classifies it as a local service, a known port forward, or a system process.
System listeners are hidden by default and can be revealed from the window toolbar.
Forwarded rows distinguish **Uses remote** (`kubectl port-forward`, SSH `-L`/`-D`)
from **Publishes local** (Cloudflare Tunnel, ngrok, SSH `-R`, Tailscale Funnel/Serve).
Switch to **Developer processes** to find likely project runtimes even when they do
not listen on a port. System locations are excluded and package-manager wrappers
are collapsed to keep the list focused.
## Use

1. **Open Manager…** from the menu bar
2. **Add** a service: name, working directory, command, optional URL
3. **Start / Stop** from the manager or the menu bar submenu
4. **Open URL** for browser tools (e.g. Frameforge → `http://localhost:3456`)

Config is saved at:

`~/Library/Application Support/ToolsUI/services.json`

## Adding things

The sidebar groups services by **Checkouts** by default. Switch to **Kind** for
Services and Docker sections. **Not managed** lists containers you can adopt with `+`.

## Worktree cockpit

**Overview** groups managed services and externally started developer processes by
checkout. Each checkout shows its repository, branch (or detached revision), linked
worktree status, changed-file count, folder, CPU and resident memory. Search by
repository, branch, command or URL; filter to Running or Attention.

Git metadata refreshes every ten seconds; process resources and routes refresh while
a monitor window is open. Refresh forces a new checkout scan. Process CPU and memory
include descendants, with PIDs counted once per checkout. CPU can exceed 100% across
cores. Container resources use `docker stats --no-stream`; unavailable metrics are
not presented as zero on service details.

Routes started in other terminals appear alongside the checkout with an **Inspect**
action. Their output cannot be attached retroactively; logs are collected for
processes started by Tools UI and managed containers. Existing inspector windows
provide explicit controls for stopping external processes and pruning routes.

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

Choose **Portless Services…** from the menu bar to see routes started in any
terminal, including by agents outside Tools UI. The window shows the URL, app
port, project folder, owner PID, and whether the route is running, orphaned, or
a static alias. You can stop a live Portless owner, remove an alias, or run
`portless prune` for orphaned sessions. Stopping a Portless owner also stops
its other routes when it registered more than one hostname.

For a **process**, portless spawns it and assigns the port:
`portless run --name <name> <your command>`. Linked worktrees receive Portless's
branch prefix automatically. Use distinct base names such as `web.project` and
`api.project` for multiple services. Commands must honor Portless's `PORT` or its
injected framework flags.

For a **container**, the port already exists, so Tools UI registers a static route
instead — `portless alias <name> <hostPort>` on start, removed on stop. Portless is
an HTTP proxy, so this only helps for ports that speak HTTP; a Postgres port gets
no useful hostname.

Live URLs come from the route owner and proxy state. Before launch, `portless get
<name>` resolves the URL in the service's checkout, including worktree prefixes,
custom TLDs, proxy port and HTTP/HTTPS. Docker aliases use `--no-worktree`. The
`PORTLESS_STATE_DIR` override is supported. Aliases never use `--force`, and stopping
a container removes only an alias this app registered that still matches its route.

Portless HTTP readiness probes preserve the hostname and TLS certificate validation
while resolving the local proxy to loopback. This handles wildcard localhost names
that Foundation does not consistently resolve.

## Dependencies

A service can depend on any other service or container. Starting it starts each
dependency first, in order, and **waits for it to be ready**:

| Ready when | Meaning |
| --- | --- |
| Automatic | Container healthcheck if the image has one, else its published port accepting a connection. Portless processes wait for HTTP; other processes wait when a port is set. |
| Wait for TCP port | Poll until the port accepts a connection |
| Wait for HTTP response | Poll until a GET returns < 500 |
| Wait for container health | Poll `docker inspect` health status |
| Don't wait | Start immediately |

Cycles and missing dependencies are rejected at startup with a diagnostic. A failed
or exited dependency blocks its consumers. Timeouts report the dependency and the
URL, port or health check being waited on. Cancelling startup keeps the service
stopped, and dependency `{{url}}` exports are resolved before the consumer launches.

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

## Searchable logs

Open **All Logs…** from the toolbar or menu bar to search across services and
checkouts. Filter by service, checkout, stream and severity; pause the view while
collection continues, toggle Follow, copy output, or export text/JSON lines. Service
details and Full Log use the same timeline. Original lines remain available through
the disclosure control and context menu, and are always included in exports.

JSON (including numeric Pino levels), logfmt and standard severity headers use exact
parsers. Unfamiliar headers fall back to bundled `neural-logline` in JavaScriptCore:
no network, Node runtime or model download is required. Inferred rows are labelled;
plain output and stack frames stay intact. The model is trained/evaluated on
synthetic data, so inspect the original line when an inferred field looks wrong.

History is session-only and bounded to 6,000 total lines, 1,200 per service and
16,384 characters per line. Clearing a service clears both its raw and structured
history. Stdout and stderr are separate, and split UTF-8/chunked lines are preserved.

To update the bundled parser from the sibling `neural-logline` repository:

```bash
bun scripts/update-log-model.mjs [path/to/neural-logline]
```

The updater records the source version, weights hash and MIT license in the bundle.

## Validation

```bash
swift test --disable-sandbox
```

The tests cover real Git worktrees, detached/unborn checkouts, resource aggregation,
structured and inferred logs, Unicode chunks, process shutdown/restart, dependency
failures and cancellation. An optional HTTP integration test uses an already-running
Portless proxy and starts/stops its own uniquely named services:

```bash
TOOLSUI_HTTP_INTEGRATION=1 swift test --disable-sandbox
```

For an isolated preview, set `TOOLSUI_CONFIG_PATH` to a separate services JSON file
(no seeds are added), `TOOLSUI_NO_AUTOSTART=1` to suppress automatic starts, and
`TOOLSUI_OPEN_MANAGER=1` to show the manager at launch.

## Notes

- Commands run via `/bin/zsh -lc 'exec …'` with user tool dirs prepended to `PATH` (`~/.bun/bin`, Homebrew, Cargo, asdf) so GUI launches still find bun, node, and friends
- Logs stream into the detail pane; container logs come from `docker logs -f`
- Quit from the menu bar ends managed processes but leaves containers running
