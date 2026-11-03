# Azurite and Durable Functions Monitor in Docker Compose

`azurite.ps1` runs two containers from [compose.yaml](compose.yaml). It is option 2 of the [dev menu](../README.md).

- **[Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)**, the Azure Storage emulator. It serves Blob, Queue and Table storage on the standard emulator ports.
- **[Durable Functions Monitor](https://github.com/microsoft/DurableFunctionsMonitor)** (DfMon) on <http://localhost:7072>. It shows the Durable Functions task hubs stored in Azurite: orchestration and entity instances, their history, inputs and outputs.

Needs Docker Desktop with Linux containers. Open it from the dev menu, or on its own from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\azurite\azurite.ps1
```

## Menu

Press an option's key; no Enter needed.

| Option | What it does |
|---|---|
| 1 Install | Runs `docker compose up`: downloads the images the first time, creates or starts both containers, and waits until Azurite and the monitor answer. |
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

Run your Durable Functions app with `AzureWebJobsStorage` set to `UseDevelopmentStorage=true`, then open <http://localhost:7072> (option 3). The monitor lists every task hub it finds in Azurite and opens it straight away when there is only one.

- The instance list starts filtered to the last day. Clear the **From** date to see older instances.
- From an instance you can also suspend, resume, restart, rewind, terminate, raise events and purge.
- Sign-in is turned off (`DFM_NONCE` in compose.yaml), which is why the page shows *Anonymous*. That is fine because the port is only published on `127.0.0.1`.
- The monitor is itself a Functions app, so it keeps a few small housekeeping blobs in Azurite, under `azure-webjobs-hosts` and `azure-webjobs-secrets`.
- It shows Durable Functions data only. To browse any blob, queue or table, use [Azure Storage Explorer](https://azure.microsoft.com/products/storage/storage-explorer/) and pick *Local storage emulator*.

## Data

Blobs, queues and tables are stored in `azurite\data` (git ignored), mounted at `/data` in the Azurite container. They survive uninstall and install. To start empty, uninstall, delete the folder, then install.

## Settings

There is no `.env`. Azurite runs on the standard ports, which `UseDevelopmentStorage=true` expects. To change an image, a version or a port, edit `compose.yaml`; if you change a port, change it at the top of `azurite.ps1` too. Then run option 2 and option 1.

## Good to know

- **Only this PC can reach it.** The ports are published on `127.0.0.1`, because anyone who reaches Azurite can use the well-known key.
- **Port already in use?** Ports 10000-10002 are probably held by another Azurite: the one Visual Studio starts for Azure Functions projects, the VS Code extension, or `npm` Azurite. Stop it, or uninstall this one.
- **Newer Azure SDKs work.** Azurite runs with `--skipApiVersionCheck`, so requests with an API version newer than it knows are accepted.
- **A PC or Docker restart keeps it.** Docker starts both containers again by itself.
- **Plain Docker Compose works too:** `docker compose -f azurite\compose.yaml up -d` / `down` / `logs`.
