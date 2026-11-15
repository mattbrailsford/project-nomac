# project-nomac

Run [Project NOMAD](https://github.com/Crosstalk-Solutions/project-nomad) — the offline knowledge server (Wikipedia via Kiwix, Kolibri courses, offline maps, notes, local AI) — on an **Apple Silicon Mac**, with the local LLM running natively on the Mac's GPU.

Built and sized for an **M1 Mac mini, 16 GB RAM, 256 GB SSD**, with optional external SSD storage.

This is a thin wrapper, not a fork. Upstream NOMAD is downloaded and built from source at a pinned release; this repo only adds what macOS needs.

## What's different from the Linux install

| Upstream (Linux) | nomac (macOS) |
|---|---|
| `install_nomad.sh` (apt, systemd, x86-64 only) | `./nomac install` (Homebrew, launchd) |
| Prebuilt amd64 admin image | Built locally for arm64 from the upstream release |
| Ollama in a container (NVIDIA/AMD GPU) | Ollama runs **natively** for Metal GPU acceleration; NOMAD uses it through its "remote Ollama" setting |
| `updater` sidecar pulls new images | A launchd job answers NOMAD's update requests by rebuilding from source, so the **Update button and auto-update in NOMAD still work** |
| `disk-collector` sidecar reads `/proc` | A launchd job writes the same disk report from macOS `df` |
| Data in `/opt/project-nomad` | Content in `STORAGE_PATH` (internal or external SSD); database in `~/.nomac` |

## Install

Requirements: macOS on Apple Silicon, [Homebrew](https://brew.sh), and an internet connection during install.

```bash
git clone https://github.com/mattbrailsford/project-nomac.git
cd project-nomac
./nomac install
```

On first run it asks where to store content and which map countries to download, then saves your answers to `nomac.conf`. It then:

1. Installs `git`, `jq`, `ollama` and **OrbStack** (a lightweight Docker runtime; set `DOCKER_RUNTIME=colima` for a fully open-source option). If a Docker runtime is already running, it uses that instead.
2. Starts Ollama as a login item and downloads your models plus `nomic-embed-text` (needed for NOMAD's knowledge base).
3. Builds NOMAD for arm64 (5–15 minutes the first time) and starts it.
4. Connects NOMAD's AI Assistant to Ollama and starts your map download.
5. Offers to stop the Mac from sleeping so NOMAD stays reachable and overnight updates can run.

Then open **http://localhost:8080**. The library from your profile is already downloading (see [Preparedness setup](#preparedness-setup)); add Kolibri courses or anything else in NOMAD's Easy Setup.

Re-running `./nomac install` is safe. It keeps your passwords, data and downloads, and applies any changes you made to `nomac.conf`.

## Choosing what to download

Settings live in `nomac.conf` (start from [`nomac.conf.example`](nomac.conf.example)):

```bash
STORAGE_PATH="$HOME/ProjectNomad"   # or "/Volumes/NomadSSD/nomad"
MAP_COUNTRIES="GB"                  # ISO country codes: "GB IE"
MAP_MAX_ZOOM=14                     # 15 = street level, largest
MODELS="llama3.1:8b"                # Ollama models to download at install
```

- **Maps:** each country is cut from the world map, so you only download the countries you list. Add more later with `./nomac maps IE --zoom 13` or from NOMAD's Maps page.
- **Library and apps:** `PROFILE`, `WIKIPEDIA`, `LIBRARY` and `APPS` (see [Preparedness setup](#preparedness-setup)). You can also add anything from the full Kiwix catalog, Kolibri courses and more apps in NOMAD's UI.

### Fitting a 256 GB Mac

After macOS, apps, Docker and two AI models, about **140–160 GB** is realistically left for content. Keep at least 30 GB free; `MIN_FREE_GB` sets the warning threshold.

| Content (English) | Approx. size |
|---|---|
| Wikipedia, full with images | ~110 GB (an external SSD is recommended) |
| Wikipedia, no images | ~50 GB |
| Wikipedia, top/mini editions | 1–15 GB |
| UK map extract, zoom 14–15 | a few GB |
| Khan Academy (Kolibri) | a few GB up to 100 GB+ depending on subjects |

### Using an external SSD

Set `STORAGE_PATH="/Volumes/<Drive>/nomad"`, format the drive as APFS, and run `./nomac install`. To move existing content: run `./nomac stop --all`, copy the folder to the SSD, update `STORAGE_PATH`, then run `./nomac install`.

The database and settings stay on the internal drive. If the SSD is unplugged, the content apps fail to start rather than writing to the wrong disk. Plug it back in and run `./nomac start`.

## Preparedness setup

The default `PROFILE="prepper"` turns NOMAD into a grid-down reference. Everything comes from NOMAD's own curated collections and is downloaded through NOMAD, so the UI shows it and content auto-update keeps it current.

| Set | What's in it | Approx. size |
|---|---|---|
| Wikipedia, no images (`all-nopic`) | General reference | 53 GB |
| Medicine, comprehensive | Field and emergency medicine library, NHS medicines guide, CDC travel health, military medicine handbook, MedlinePlus, WikiMed, the FDA drug-label database (used by NOMAD's drug reference) | 7 GB |
| Survival, standard | Water, food preparation and knots guides, Ready.gov, outdoors and amateur-radio Q&A, prepping video series | 10 GB |
| DIY, comprehensive | iFixit repair guides, DIY, woodworking and car mechanics Q&A | 6 GB |
| Agriculture, standard | Gardening and cooking Q&A, recipe collections | 1 GB |
| Education, essential | Wikibooks (textbooks and manuals) | 3 GB |
| Apps | Kiwix, Notes, Meshtastic (off-grid mesh messaging with LoRa radios), Calibre-Web (ebooks and PDFs, e.g. *Where There Is No Doctor*), Vaultwarden (passwords and records), Homebox (supplies inventory), File Browser | small |

About **80 GB** in total, which fits a 256 GB Mac. `./nomac content --dry-run` shows the plan, what's already downloaded, and whether it fits; nothing downloads if it won't fit. Change any part in `nomac.conf` (`WIKIPEDIA`, `LIBRARY`, `APPS`), for example `WIKIPEDIA="all-maxi"` with images once content is on the SSD.

### Staying up through outages

`./nomac power` (offered during install) sets the Mac to:
- never sleep (the display still can);
- start up by itself when power returns;
- open OrbStack at login.

**Automatic login also matters.** Ollama and Docker run as your user, so after a power cut nothing starts until someone logs in. Turn on automatic login in System Settings → Users & Groups. macOS doesn't allow automatic login with FileVault on, so it's a trade-off: FileVault protects the data if the Mac is stolen, while automatic login means NOMAD returns unattended. `./nomac drill` reports which you have.

Also worth having:
- A UPS or LiFePO4 power station; an M1 mini draws about 7 W idle and under 40 W at full load.
- A USB-powered travel router so phones can connect when the home network is down.
- Printed copies of first aid and water treatment.

### Drill

```bash
./nomac drill
```

Run it monthly with the internet unplugged. It checks:
- NOMAD and Ollama respond;
- each essential reference opens in the library;
- general Wikipedia is present;
- your map extract exists;
- the AI answers a real question through NOMAD, and how long it takes;
- the knowledge-base search model is present;
- every configured app is running;
- there's enough free space;
- power-cut readiness: auto-restart, sleep, UPS detected, automatic login.

### Phone backup

```bash
./nomac export-phone                 # → ~/Desktop/NOMAD-for-phone, up to 20 GB
./nomac export-phone /Volumes/USB --max-gb 8
```

This copies the essential references, most important first, plus the largest Wikipedia edition that fits. They open in the free Kiwix app on iPhone, iPad or Android with no Mac and no internet; the folder's `README.txt` explains how to load them. For maps on the phone, use Organic Maps with the UK downloaded in that app.

## AI models

- **Switching models:** use the model dropdown in NOMAD's chat. It remembers your last choice.
- **Adding or removing models:** use NOMAD's AI settings, or `./nomac models pull qwen3:8b` / `./nomac models rm <name>`.
- **Memory:** one model is loaded at a time and is unloaded after 10 idle minutes (`OLLAMA_KEEP_ALIVE`). On 16 GB, stay at about **8B parameters, 4-bit** (about 5 GB each). Larger models run but swap.
- **LAN exposure:** Ollama listens on `0.0.0.0:11434` so the NOMAD container can reach it, which also makes it reachable from your network. NOMAD itself has no login either; keep both on a trusted network.

## Updates

NOMAD's own automatic updates work as upstream designed. Turn them on in **Settings → Updates** and choose a time window:

| Update type | What happens on the Mac |
|---|---|
| **Content** (Wikipedia/ZIM files, collections) | Downloaded by NOMAD (unchanged from upstream) |
| **Apps** (Kiwix, Kolibri, Qdrant, …) | Pulled by NOMAD (unchanged from upstream) |
| **NOMAD core** | NOMAD asks for the update; the Mac rebuilds the arm64 image from that release, restarts, upgrades Ollama via Homebrew (`AUTO_UPGRADE_OLLAMA`) and removes old images |

Each update runs only inside its window and only when online. When offline, updates are skipped quietly. Installed models are never changed.

From the terminal: `./nomac update --check`, `./nomac update`, `./nomac update 1.35.1`. If an update goes wrong, `./nomac rollback` returns to the previous version (database migrations are not undone).

## Commands

```
./nomac install | start | stop [--all] | restart
./nomac status        # versions, containers, loaded model, disk usage
./nomac doctor        # checks wiring and shows which containers are arm64 vs emulated
./nomac update [--check|VERSION] | rollback
./nomac models [list|pull NAME|rm NAME]
./nomac maps GB [IE ...] [--zoom N]
./nomac content [--dry-run]   # download the library/apps in nomac.conf
./nomac drill         # readiness check, run with the internet unplugged
./nomac power         # never sleep, restart after power cuts
./nomac export-phone [DIR] [--max-gb N]
./nomac logs [admin|kiwix|ollama|updater|update]
./nomac cleanup       # remove old images and build cache
./nomac uninstall
```

## Where things live

| Path | Contents |
|---|---|
| `STORAGE_PATH` | Offline content: ZIM files, maps, Kolibri, notes, uploads |
| `~/.nomac/` | `.env` (generated secrets), database, Redis, upstream source, logs, update hand-off folder |
| `~/.ollama/models` | AI models (or `OLLAMA_MODELS_DIR`) |
| `~/Library/LaunchAgents/com.nomac.*.plist` | Ollama, updater, disk-info jobs |

## Testing

GitHub Actions ([`.github/workflows/test.yml`](.github/workflows/test.yml)) runs on every push and weekly to catch upstream releases that break the port:

| Job | Runner | Covers |
|---|---|---|
| `lint` | Ubuntu | shellcheck, compose file validity |
| `macos-host` | Apple Silicon macOS, stock bash 3.2 | config and secrets handling, Homebrew Ollama as a launchd job, model download and reply, plist validity, the updater job reacting to NOMAD's request file (and rejecting a malicious one), disk report from real macOS `df`, the prepper library plan, phone export, power/login checks |
| `e2e-arm64` | arm64 Linux with Docker | builds NOMAD's previous release for arm64 and starts it; connects native Ollama; lists and chats with two models through NOMAD; checks the disk report; downloads a UK map extract; applies a small library and apps preset; runs the drill and the phone export; updates to the latest release via NOMAD's own Update API; rolls back |

GitHub's Mac runners can't run Docker, so OrbStack and the containers on an actual Mac are only covered by the arm64 Linux job, which runs the same images. Run `./nomac doctor` after installing on your Mac.

## Known limitations

- **Unofficial.** A new upstream release can break something Mac-specific. Use `./nomac rollback` and open an issue here.
- **Emulated images:** any app image without an arm64 build runs under Rosetta and is slower. `./nomac doctor` lists which images these are.
- **Benchmark and GPU readouts:** these reflect the Linux VM, not the Mac, so scores aren't comparable with Linux machines.
- **Creator Packs:** hidden. They need a key that only official upstream images have.
- **Sleep:** the Mac must be awake during the update window.

## License

This repository is licensed under the [Apache License 2.0](LICENSE).

Project NOMAD is © Crosstalk Solutions, LLC, also under Apache-2.0. This repository contains no upstream code; NOMAD is downloaded and built from upstream at install time. Content that NOMAD downloads (Wikipedia, Kiwix collections, maps, Creator Packs) has its own licenses.
