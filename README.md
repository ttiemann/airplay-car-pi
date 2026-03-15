# airplay-car-pi

AirPlay receiver for car radios using Raspberry Pi boards and HiFiBerry DAC+ Zero.
This project is focused on quick boot, stable playback, and headless operation for automotive use.
It supports Wi-Fi-capable Raspberry Pi Zero boards with performance trade-offs on older models.

## Features

- AirPlay audio receiver on Raspberry Pi Zero family boards
- HiFiBerry DAC+ Zero audio output support
- Automated setup bootstrap via install script
- Installs Shairport Sync and required audio/network packages
- Configures Raspberry Pi boot settings for HiFiBerry DAC+ Zero when boot config is available
- Generates `/etc/shairport-sync.conf` with configurable defaults
- Enables and restarts `shairport-sync` automatically on systemd systems
- Includes `diagnose.sh` for post-install service/audio/network checks
- Boot-time optimizations for faster in-car availability

## Hardware

- Raspberry Pi Zero family board with built-in Wi-Fi
- HiFiBerry DAC+ Zero
- microSD card (16 GB or larger recommended)
- Stable 5V power supply suitable for vehicle use
- AUX input on car head unit or external amplifier

## Compatibility

- Raspberry Pi Zero boards with built-in Wi-Fi are supported.
- Performance depends on board generation, power stability, and background load.

## Software Requirements

- Raspberry Pi OS Lite (recommended)
- Internet connection for package installation
- SSH access (optional but recommended)

## Quick Start

1. Flash the microSD card with Raspberry Pi Imager:
    - Download: <https://www.raspberrypi.com/software/>
    - Device: your Raspberry Pi model
    - OS: Raspberry Pi OS Lite
    - Storage: your microSD card
2. In Raspberry Pi Imager, open Advanced Options and configure:
    - Username and password (required)
    - Hostname
    - Wi-Fi SSID/password (if applicable)
    - SSH (required)
3. Boot the Pi and confirm network access.
4. Get only the installer script:

```bash
curl -fsSL https://raw.githubusercontent.com/<your-user>/airplay-car-pi/main/install.sh -o install.sh
```

Alternative (from your local machine):

```bash
scp ./install.sh <username>@<pi-hostname-or-ip>:~/install.sh
```

Optional: also copy the diagnostic script:

```bash
scp ./diagnose.sh <username>@<pi-hostname-or-ip>:~/diagnose.sh
```

Optional: the diagnostic script can auto-detect your configured SSID (the one set in Raspberry Pi Imager) to classify client vs away/car mode.

5. Run the installer:

```bash
chmod +x install.sh
sudo ./install.sh
```

Optional custom values:

```bash
sudo AIRPLAY_DEVICE_NAME="Car AirPlay" AIRPLAY_BACKEND="alsa" ./install.sh
```

6. Reboot when prompted.

After reboot, verify the AirPlay receiver service:

```bash
sudo systemctl status shairport-sync --no-pager
chmod +x diagnose.sh
./diagnose.sh
```

First boot and package installation time may vary by board and storage speed.

## What The Installer Does

Current bootstrap actions:

- Runs `apt-get update`
- Runs `apt-get upgrade -y`
- Installs `alsa-utils`, `avahi-daemon`, `network-manager`, and `shairport-sync`
- Configures Raspberry Pi boot audio settings for HiFiBerry DAC+ Zero
- Generates `/etc/shairport-sync.conf` (with timestamped backup if it exists)
- Enables and restarts `shairport-sync` when systemd is available
- Installs a periodic home-vs-car mode detector timer

Supported environment variables:

- `AIRPLAY_DEVICE_NAME` (default: `AirPlay Car Pi`)
- `AIRPLAY_BACKEND` (default: `alsa`)
- `AIRPLAY_MIXER_CONTROL_NAME` (optional override; auto-detected if unset)
- `AIRPLAY_CAR_SUFFIX` (default: ` [CAR]`; appended to AirPlay name when away from home)
- `CAR_AP_SSID` (default: `AirPlay-Car-Pi`; Wi-Fi network name of the car hotspot)
- `CAR_AP_PASSWORD` (default: `airplaycarpi`; **change this** to a strong passphrase)
- `CAR_AP_IFACE` (default: `wlan0`)
- `CAR_AP_CHANNEL` (default: `6`)

The installer also sets up a systemd timer on the Pi that checks Wi-Fi mode automatically every 30 seconds. It auto-detects your configured SSID from Raspberry Pi network configuration (including Raspberry Pi Imager setup). In away/car mode it appends `AIRPLAY_CAR_SUFFIX` to the advertised AirPlay name, so you can detect mode directly from your phone without SSH access.

Example install with automatic mode labeling:

```bash
sudo AIRPLAY_DEVICE_NAME="Car AirPlay" CAR_AP_SSID="MyCar" CAR_AP_PASSWORD="mysecurepassword" ./install.sh
```

## Access Point in Car Mode

When the Pi is away from home Wi-Fi, a mode-check timer (every 30 s) automatically:

1. Calls `nmcli device wifi hotspot` to create a WPA2 access point on `wlan0`
2. NetworkManager handles `hostapd` and DHCP internally — no extra packages needed
3. Renames the AirPlay receiver to `<name> [CAR]` so you can see mode from any Apple device

When the Pi boots back on the home network, the hotspot is torn down and the Pi reconnects as a normal client.

Connect to the hotspot from your iPhone/Mac:

| Field    | Value |
|----------|-------|
| SSID     | `AirPlay-Car-Pi` (or your `CAR_AP_SSID`) |
| Password | `airplaycarpi` (or your `CAR_AP_PASSWORD`) |
| Pi IP    | `192.168.99.1` |

Then open the AirPlay output selector and choose your receiver — it will show the `[CAR]` suffix.
```

## Usage

On iPhone, iPad, or macOS:

1. Open the AirPlay output selector.
2. Select your Raspberry Pi receiver name.
3. Start playback.

## Service Management

Use these commands to manage and inspect the service:

```bash
sudo systemctl status shairport-sync --no-pager
sudo systemctl restart shairport-sync
sudo journalctl -u shairport-sync -f
```

To classify current network mode in diagnostics:

```bash
./diagnose.sh
```

- `CONFIGURED_SSID`: connected to your configured SSID — client mode, no hotspot
- `AWAY`: configured SSID not found — hotspot active, AirPlay name has `[CAR]` suffix

If your service name differs, replace `shairport-sync` with the installed unit name.

## Docker Test

Use Docker for quick installer validation in a clean Debian Trixie environment.

```bash
docker build -t airplay-car-pi-test .
docker run --rm -it airplay-car-pi-test
```

Run container diagnostics after install:

```bash
make diagnose-container
```

This validates installer flow and package installation, but not real audio output or full systemd behavior on Raspberry Pi hardware.

## Makefile Stages

Use the Makefile for repeatable checks and tests:

```bash
make help
make test
```

Useful targets:

- `make check` (shell syntax)
- `make unit` (isolated installer unit tests)
- `make integration-airplay` (real sender flow test on target hardware)
- `make perf` (regression/performance tests on target hardware)
- `make security` (shellcheck all scripts, secret scan, trivy CVE scan, gitleaks)
- `make changelog VERSION=vX.Y.Z` (generate release changelog into `dist/`)
- `make package VERSION=vX.Y.Z` (build release tar.gz/zip/checksums into `dist/`)
- `make release-prep VERSION=vX.Y.Z` (generate changelog and package artifacts together)
- `make tag-release VERSION=vX.Y.Z` (create an annotated git tag locally)
- `make build` (Docker image)
- `make run` (installer in container)
- `make rerun` (idempotency check)
- `make diagnose-container` (run `diagnose.sh` in Docker after install)
- `make verify-packages` (post-install package validation)
- `make test-no-network` (negative test)
- `make copy-scripts` (copy `install.sh` and `diagnose.sh` to Pi)
- `make remote-install` (run installer on Pi over SSH)
- `make remote-diagnose` (run diagnostics on Pi over SSH)
- `make deploy` (copy + install + diagnose in one command)

Example deploy from Mac:

```bash
make deploy PI_USER=<username> PI_HOST=<pi-hostname-or-ip>
```

If you need an explicit path, use a remote Linux path such as:

```bash
make deploy PI_USER=<username> PI_HOST=<pi-hostname-or-ip> PI_PATH=/home/<username>
```

Real AirPlay sender integration test:

```bash
make integration-airplay PI_USER=<username> PI_HOST=<pi-hostname-or-ip> AIRPLAY_INTEGRATION_TIMEOUT=120
```

When prompted, start playback from a real sender (iPhone, iPad, or macOS) to the receiver. The test passes when an active AirPlay session is detected on the receiver ports.

## Releases

Local release preparation:

```bash
make release-prep VERSION=v0.1.0
```

This creates the following in `dist/`:

- `CHANGELOG-v0.1.0.md`
- `airplay-car-pi-v0.1.0.tar.gz`
- `airplay-car-pi-v0.1.0.zip`
- `airplay-car-pi-v0.1.0.sha256`

Create a local annotated tag:

```bash
make tag-release VERSION=v0.1.0
```

After you push a `v*` tag to GitHub, the `Release` workflow will:

- generate the changelog from git history
- package the repository into tar.gz and zip artifacts
- upload the packaged files as workflow artifacts
- create a GitHub Release and attach the assets

CI matrix coverage:

- The `Matrix Compatibility` workflow runs on each push/PR and validates combinations of:
  - Raspberry Pi Zero W profile (`linux/arm/v6`) with Debian Bookworm and Trixie base images
  - Raspberry Pi Zero 2 W profile (`linux/arm64`) with Debian Bookworm and Trixie base images
- For each matrix profile, it builds a compatibility image, runs shell/unit checks, and validates release scripts.

## Promotion And Rollback

Recommended promotion order:

- `dev` -> `staging` -> `prod`

Create three GitHub Environments named `dev`, `staging`, and `prod`.
Store these environment-specific secrets in each one:

- `PI_HOST`
- `PI_USER`
- `PI_PATH`
- `PI_SSH_KEY`

Promotion workflow:

- Run the `Promote` workflow manually.
- Choose a released tag such as `v0.1.0`.
- Choose the target environment (`dev`, `staging`, or `prod`).
- The workflow will create a rollback snapshot on the target Pi, deploy the selected release, and run diagnostics.
- For `staging`, it also runs `make perf` after deployment.

Local rollback snapshot commands:

```bash
make backup-remote PI_USER=<username> PI_HOST=<pi-hostname-or-ip> PI_PATH=/home/<username>
make rollback-remote PI_USER=<username> PI_HOST=<pi-hostname-or-ip> PI_PATH=/home/<username> SNAPSHOT_ID=<timestamp>
```

Rollback strategy:

- `restore-snapshot`: restore `/etc/shairport-sync.conf`, the Raspberry Pi boot config, and the last deployed scripts from a saved snapshot on the Pi.
- `redeploy-tag`: redeploy an older tagged release to the target environment.

Rollback workflow:

- Run the `Rollback` workflow manually.
- Choose the target environment.
- Choose either `restore-snapshot` or `redeploy-tag`.
- Provide `snapshot_id` for snapshot restore, or `version` for tag redeploy.

## Audio Notes

- The installer attempts to set `dtparam=audio=off` and `dtoverlay=hifiberry-dac` in the Raspberry Pi boot config.
- Reboot is required after boot config changes so the DAC overlay loads.
- Verify output device selection in ALSA/PipeWire depending on your setup.
- Use a ground loop isolator if alternator noise is present.
- Prefer lower background load for the most stable playback.

## Real Pi Verification

Run the bundled diagnostic script first:

```bash
chmod +x diagnose.sh
./diagnose.sh
```

Then run these manual checks on the Raspberry Pi after installation and reboot:

```bash
sudo systemctl status shairport-sync --no-pager
sudo systemctl is-enabled shairport-sync
aplay -l
sudo journalctl -u shairport-sync -n 100 --no-pager
```

Expected result:

- `shairport-sync` is active and enabled.
- Your audio device appears in `aplay -l` output.
- The HiFiBerry DAC is detected by `diagnose.sh` or visible in `aplay -l` output.
- `journalctl` shows normal startup without repeated errors.

## Troubleshooting

- Receiver not visible in AirPlay list:
  - Check that the Pi and phone are on the same network.
  - Verify the service is running.
  - Reboot the Pi and retry.

- Audio crackling or stutter:
  - Check power stability.
  - Reduce Wi-Fi interference.
  - Confirm CPU load is not saturated.
  - Disable unnecessary services to free CPU.

- Raspberry Pi Zero board does not show up on network:
  - Confirm onboard Wi-Fi is enabled and country is set.
  - Verify DHCP assigned an IP address.
  - Check link status before troubleshooting AirPlay service.

- No audio output:
  - Confirm wiring from DAC to car input.
  - Verify mixer/output levels.
  - Check logs with `journalctl`.

## Project Goals

- Fast startup suitable for short trips
- Reliable reconnect behavior
- Minimal maintenance after install

## License

This repository is licensed under the terms of the [LICENSE](LICENSE) file.
