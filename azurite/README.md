# Azurite and Durable Functions Monitor in Docker Compose

`azurite.ps1` runs two containers from [compose.yaml](compose.yaml). It is option 2 of the [dev menu](../README.md).

- **[Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)**, the Azure Storage emulator. It serves Blob, Queue and Table storage on the standard emulator ports.
- **[Durable Functions Monitor](https://github.com/microsoft/DurableFunctionsMonitor)** (DfMon) on <http://localhost:7072>. It shows the Durable Functions task hubs of a storage account: orchestration and entity instances, their history, inputs and outputs. That account is Azurite by default, or [a real one](#using-a-real-storage-account) set in `.env`.

Needs Docker Desktop with Linux containers. Open it from the dev menu, or on its own from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\azurite\azurite.ps1
```

## Menu

Press an option's key; no Enter needed.

| Option | What it does |
|---|---|
| 1 Install | Runs `docker compose up`: downloads the images the first time, creates or starts both containers, and waits until Azurite and the monitor answer. When they are already running, it applies any change in `.env` or `compose.yaml`. |
| 2 Uninstall | Runs `docker compose down`: removes both containers. Your data stays. Optionally deletes the images. |
| 3 Open monitor | Opens Durable Functions Monitor in your default browser. |
| Q | Back to the dev menu, or quit when the script runs on its own. Esc does the same. |

The previous version of this script made the `azurite` container with `docker run`. Install and Uninstall replace that container; its data is kept.

## Connecting

| Service | Endpoint |
|---|---|
| Blob | `http://127.0.0.1:10000/devstoreaccount1` |
| Queue | `http://127.0.0.1:10001/devstoreaccount1` |
| Table | `http://127.0.0.1:10002/devstoreaccount1` |

Connection string: `UseDevelopmentStorage=true`. Tools that want the full form:

```
DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;QueueEndpoint=http://127.0.0.1:10001/devstoreaccount1;TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;
```

The account `devstoreaccount1` and its key are the same in every Azurite, so they are not secrets.

## Durable Functions Monitor

Run your Durable Functions app with `AzureWebJobsStorage` set to `UseDevelopmentStorage=true`, then open <http://localhost:7072> (option 3). The monitor lists every task hub it finds in the account and opens it straight away when there is only one.

- The instance list starts filtered to the last day. Clear the **From** date to see older instances.
- From an instance you can also suspend, resume, restart, rewind, terminate, raise events and purge.
- Sign-in is turned off (`DFM_NONCE` in compose.yaml), which is why the page shows *Anonymous*. That is fine because the port is only published on `127.0.0.1`.
- The monitor is itself a Functions app, so each monitor container leaves one small lock blob in the account, under `azure-webjobs-hosts/locks/`.
- It shows Durable Functions data only. To browse any blob, queue or table, use [Azure Storage Explorer](https://azure.microsoft.com/products/storage/storage-explorer/) and pick *Local storage emulator*.

## Data

Blobs, queues and tables are stored in `azurite\data` (git ignored), mounted at `/data` in the Azurite container. They survive uninstall and install. To start empty, uninstall, delete the folder, then install.

## Settings

The first run creates `.env` from [.env.example](.env.example). It is git ignored, because a real connection string holds the account's key.

| Variable | Default | What it does |
|---|---|---|
| `STORAGE_CONNECTION_STRING` | The Azurite container | The storage account the monitor shows. Not `UseDevelopmentStorage=true`: inside the monitor's container, that means the monitor itself. |

After changing `.env`, run option 1. Compose recreates only the monitor, and Azurite keeps running.

To change an image, a version or a port, edit `compose.yaml`; if you change a port, change it at the top of `azurite.ps1` too. Then run option 1. Azurite stays on the standard ports by default because `UseDevelopmentStorage=true` expects them.

### Using a real storage account

1. In `.env`, replace the `STORAGE_CONNECTION_STRING` value with the account's connection string, from the Azure portal: Storage account > Security + networking > Access keys.
2. Run option 1. While the monitor is set to anything but Azurite, the menu and the output of option 1 show the account's name in yellow and its Blob, Queue and Table endpoints. `Conn str` names the setting in `.env` instead of printing it, because it holds the key. Azurite's ports and data folder are listed last and marked as the separate local emulator. A connection string with no `AccountName`, like a SAS one, shows `account: see .env` and only the endpoints it sets.
3. To go back, delete `.env` and run option 1.

This only changes what the monitor shows. Azurite keeps running, and your apps keep using whatever connection string they are set to.

If the page says *Login failed. Failed to load the list of Task Hubs*, the monitor couldn't read that account. There is no login to fix: check the connection string and the account's firewall. `docker logs dfmon` has the details.

Before you do this with an account that matters:

- **The monitor can change data, and it has no sign-in.** Purge, terminate and rewind act on the real account, for anyone or anything on this PC that can reach port 7072. To make it view-only, add `DFM_MODE: ReadOnly` under the `dfmon` service's `environment` in `compose.yaml`.
- **It writes to the account.** Each monitor container leaves one small lock blob under `azure-webjobs-hosts/locks/`, and that blob container is created if the account doesn't have it.
- **It connects from this PC.** If the account's firewall limits access, your public IP has to be allowed.

## Good to know

- **Only this PC can reach it.** The ports are published on `127.0.0.1`, because anyone who reaches Azurite can use the well-known key.
- **Port already in use?** Ports 10000-10002 are probably held by another Azurite: the one Visual Studio starts for Azure Functions projects, the VS Code extension, or `npm` Azurite. Stop it, or uninstall this one.
- **Newer Azure SDKs work.** Azurite runs with `--skipApiVersionCheck`, so requests with an API version newer than it knows are accepted.
- **A PC or Docker restart keeps it.** Docker starts both containers again by itself.
- **Plain Docker Compose works too:** copy `.env.example` to `.env` first, then `docker compose -f azurite\compose.yaml up -d` / `down` / `logs`.
