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

Frameforge is pre-seeded if the config is empty:

| Field | Value |
| --- | --- |
| Name | Frameforge |
| Directory | `~/Documents/open-source/parse-video` |
| Command | `bun run start` |
| URL | `http://localhost:3456` |

## Notes

- Commands run via `/bin/zsh -lc 'exec …'` so your shell `PATH` (bun, node, etc.) is used
- Logs stream into the detail pane
- Quit from the menu bar ends managed processes first
