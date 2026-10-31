# SQL Server in Docker

`sqlserver.ps1` runs SQL Server in Docker on `localhost,1433` and keeps your databases in a folder on your PC.

Needs Docker Desktop with Linux containers. Start the menu with:

```powershell
powershell -ExecutionPolicy Bypass -File .\sqlserver.ps1
```

The first run creates `.env` with a random `sa` password.

## Menu

| Option | What it does |
|---|---|
| 1 Install | Creates the container (if it isn't running) and attaches every `.mdf` in the databases folder. |
| 2 Uninstall | Stops SQL Server cleanly and removes the container. Your database files stay. Optionally deletes the image. |
| 3 Reload | Destroys the container, builds a new one with the current `.env` settings, and attaches every `.mdf` in the databases folder. |
| 4 Restore | Lists the `.bak` files in the backup folder, restores the one you pick under a name you choose. |
| Q | Quit. |

## Folders

Created inside `MSSQL_DIR`:

| Folder | Path in container | Holds |
|---|---|---|
| `databases\` | `/var/opt/mssql/databases` | All your databases. New databases (created in SSMS or by T-SQL) and restored ones are written here, and every change goes straight into these files. Drop `.mdf`/`.ldf` files here, then run option 3. |
| `backup\` | `/var/opt/mssql/backup` | `.bak` files for option 4. Also the default target of `BACKUP DATABASE`. |
| `log\` | `/var/opt/mssql/log` | SQL Server error logs. |

The system databases (`master`, `model`, `msdb`, `tempdb`) stay inside the container and start fresh every time option 1 or 3 creates it.

## .env settings

Changes take effect the next time the container is created: run option 3, or option 1 if SQL Server isn't running.

| Variable | Default | What it does |
|---|---|---|
| `SA_PASSWORD` | random | Password for the `sa` login. 8+ characters, using 3 of: upper case, lower case, digits, symbols. Don't use spaces or double quotes. |
| `SQL_PORT` | `1433` | Port on your PC. Connect to `localhost,<port>`. Change it if a local SQL Server already uses 1433. |
| `CONTAINER_NAME` | `sqlserver` | Name of the Docker container, also used as the server name. |
| `SQL_IMAGE` | `mcr.microsoft.com/mssql/server:2022-latest` | SQL Server version. Other tags: `2025-latest`, `2019-latest`, or a pinned build from the image's tag list. A newer version can open databases from an older one, never the reverse. |
| `MSSQL_PID` | `Developer` | Edition to run, or a product key. See [SQL Server editions](#sql-server-editions). |
| `MSSQL_DIR` | `./mssql` | Folder on your PC that is mounted into the container. Either relative to the script's folder (`./mssql`, `..\sql-data`) or absolute (`D:\SQL Data`, `D:/SQL Data`). Paths with spaces work, with or without quotes. |

## SQL Server editions

Values for `MSSQL_PID`. Limits are for SQL Server 2022, the default image; newer versions raise some of them.

| Edition | Cost | Meant for | Limits |
|---|---|---|---|
| `Developer` | Free | Development and testing only, not production | None: every Enterprise feature |
| `Express` | Free | Small production apps | 10 GB per database, 1 socket or 4 cores, about 1.4 GB of memory for data, no SQL Agent |
| `Standard` | Paid license | Production | Up to 24 cores and 128 GB of memory for data, fewer high-end features |
| `Enterprise` | Paid license (server + CALs) | Production | All features, but uses at most 20 cores |
| `EnterpriseCore` | Paid license (per core) | Production | All features, no core limit |
| `Evaluation` | Free for 180 days | Trying Enterprise | All features, stops working after 180 days |

- The paid editions only tell SQL Server which edition to run as. You need a license you own to use them. A product key instead of a name runs the edition that key belongs to.
- A database over an edition's limit won't attach or restore, for example one over 10 GB on Express.
- To switch, change `MSSQL_PID` and run option 3. Your databases come back under the new edition.

## Good to know

- **The database name comes from inside the `.mdf`**, not from its file name. The matching `.ldf` is found by the name the `.mdf` remembers, or by `<name>_log.ldf` / `<name>.ldf`. If no `.ldf` is found, SQL Server builds a new log, which only works if the database was shut down cleanly.
- **Files are used in place while SQL Server runs.** Don't delete, replace or copy them then: run option 2 first, make your change, then option 1. Removing a database's files and running option 3 removes that database.
- **Anything kept in master/msdb starts over with each new container:** logins other than `sa`, SQL Agent jobs, server settings, linked servers. Database users tied to old logins become orphaned.
- **A PC or Docker restart doesn't create a new container.** Docker restarts the same container with the password it was created with, and your databases stay attached.
- Connection string: `Server=localhost,1433;User Id=sa;Password=<SA_PASSWORD>;TrustServerCertificate=True`
