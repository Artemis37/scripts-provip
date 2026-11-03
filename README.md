# Artemis37 dev menu

`dev.ps1` is one menu for the dev tools in this repository. Each tool runs in Docker and has its own menu. Start it with:

```powershell
powershell -ExecutionPolicy Bypass -File .\dev.ps1
```

Press a key to pick an option; no Enter needed. Q (or Esc) inside a tool comes back here, Q here quits.

Needs Docker Desktop with Linux containers.

## Modules

| Key | Module | What it does | Details |
|---|---|---|---|
| 1 | SQL Server | SQL Server on `localhost,1433`. Databases are kept in a folder on your PC; restore `.bak` files from the menu. | [sqlserver/README.md](sqlserver/README.md) |
| 2 | Azurite | Azure Storage emulator: Blob, Queue and Table on ports 10000-10002, `UseDevelopmentStorage=true`. | [azurite/README.md](azurite/README.md) |

## Layout

Each module keeps its script, its settings (`.env`, when it has any) and its data in its own folder, so they don't mix. `common.ps1` holds the helpers the menus share: key input, colored output, Docker checks.

To add a module, create a folder with its script and README, then add a line to `$Modules` in `dev.ps1`. The dev menu runs the script with `-FromDevMenu`, so the script should accept that switch and return when Q is pressed.
