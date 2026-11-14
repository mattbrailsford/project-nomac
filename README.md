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

Then open **http://localhost:8080** and use Easy Setup to choose Wikipedia, Kiwix collections and Kolibri courses.

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
- **Wikipedia, Kiwix collections, Kolibri:** choose these in NOMAD's Easy Setup or Content pages. Each one shows its size before you download.

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
| `macos-host` | Apple Silicon macOS, stock bash 3.2 | config and secrets handling, Homebrew Ollama as a launchd job, model download and reply, plist validity, the updater job reacting to NOMAD's request file (and rejecting a malicious one), disk report from real macOS `df` |
| `e2e-arm64` | arm64 Linux with Docker | builds NOMAD's previous release for arm64 and starts it; connects native Ollama; lists and chats with two models through NOMAD; checks the disk report; downloads a UK map extract; updates to the latest release via NOMAD's own Update API; rolls back |

GitHub's Mac runners can't run Docker, so OrbStack and the containers on an actual Mac are only covered by the arm64 Linux job, which runs the same images. Run `./nomac doctor` after installing on your Mac.

## Known limitations

- **Unofficial.** A new upstream release can break something Mac-specific. Use `./nomac rollback` and open an issue here.
- **Emulated images:** any app image without an arm64 build runs under Rosetta and is slower. `./nomac doctor` lists which images these are.
- **Benchmark and GPU readouts:** these reflect the Linux VM, not the Mac, so scores aren't comparable with Linux machines.
- **Creator Packs:** hidden. They need a key that only official upstream images have.
- **Sleep:** the Mac must be awake during the update window.

## License

Project NOMAD is © Crosstalk Solutions, LLC, licensed under Apache-2.0. This repository contains no upstream code; NOMAD is downloaded and built from upstream at install time.
