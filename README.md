# MoveMate

Move users' files from an old Windows PC to a new one: over the network, a direct Ethernet cable (or Wi-Fi), an
external drive, or a server offload (optionally AES-256 encrypted).

Profiles, browser bookmarks, Sticky Notes, wallpaper, mapped drives/printers list, application inventory, printer
carry-over, an Installers list, and a walk-away mode with screen lock.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in)
- An admin login on both PCs

## Getting started

1. Download the latest release zip (or **Code > Download ZIP**).
2. If Windows blocks the scripts after downloading: right-click the zip > **Properties** > **Unblock**, then unzip.
3. Unzip anywhere - a flash drive, or an IT-only network share.
4. Double-click `MoveMate.cmd` and approve UAC.

Help: the **Help** button (F1) in MoveMate, or [HOW-TO.txt](HOW-TO.txt).

These are plain PowerShell scripts - read them before you run them.

## Dashboard

`extras\Migration Dashboard.html` reads the `MigrationStats.csv` that MoveMate writes. MoveMate copies it into the IT
person's Migration Reports folder with each report it sends - double-click it there for stats and charts. It works
offline and nothing leaves the browser.

## Privacy

Logs are written to `MoveMate\logs`. They list users' file names, so don't share that folder. Restore keys for
encrypted uploads are saved in `MoveMate\keys` - keep them private.

## Layout

```
MoveMate.cmd        launcher
HOW-TO.txt          help (also shown in the app)
scripts\            the tool (Migrate-UserFiles.ps1 = UI, MigrateCore.ps1 = engine, helpers)
extras\             dashboard, installers list (installers.csv) and an installers\ folder for local setup files
```

## License

[MIT](LICENSE)

Like MoveMate? [Buy me a coffee](https://www.buymeacoffee.com/printerjammed) - printer test pages:
[paperjammed.net](https://paperjammed.net/)
