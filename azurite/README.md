# Azurite in Docker

`azurite.ps1` runs [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite), the Azure Storage emulator, in Docker. It serves Blob, Queue and Table storage on the standard emulator ports. It is option 2 of the [dev menu](../README.md).

Needs Docker Desktop with Linux containers. Open it from the dev menu, or on its own from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\azurite\azurite.ps1
```

## Menu

Press an option's key; no Enter needed.

| Option | What it does |
|---|---|
| 1 Install | Downloads the image the first time, creates the container and waits until Blob, Queue and Table answer. If the container exists but is stopped, starts it. |
| 2 Uninstall | Removes the container. Your data stays. Optionally deletes the image. |
| Q | Back to the dev menu, or quit when the script runs on its own. Esc does the same. |

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

## Data

Blobs, queues and tables are stored in `azurite\data` (git ignored), mounted at `/data` in the container. They survive uninstall and install. To start empty, uninstall, delete the folder, then install.

## Settings

There is no `.env`. Azurite runs on the standard ports, which `UseDevelopmentStorage=true` expects. To change the container name, image or ports, edit `$Container`, `$Image` and `$Ports` at the top of `azurite.ps1`, then uninstall and install.

## Good to know

- **Only this PC can reach it.** The ports are published on `127.0.0.1`, because anyone who reaches Azurite can use the well-known key.
- **Port already in use?** Another Azurite is probably running: the one Visual Studio starts for Azure Functions projects, the VS Code extension, or `npm` Azurite. Stop it, or uninstall this one.
- **Newer Azure SDKs work.** The container runs with `--skipApiVersionCheck`, so requests with an API version newer than this Azurite knows are accepted.
- **A PC or Docker restart keeps it.** Docker starts the container again by itself.
