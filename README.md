# airplay-car-pi

AirPlay receiver for car radios using Raspberry Pi boards and HiFiBerry DAC+ Zero.
This project is focused on quick boot, stable playback, and headless operation for automotive use.
It supports Wi-Fi-capable Raspberry Pi Zero boards with performance trade-offs on older models.

## Features

- AirPlay audio receiver on Raspberry Pi Zero family boards
- HiFiBerry DAC+ Zero audio output support
- Automated setup bootstrap via install script
- Installs Shairport Sync and required audio/network packages
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
	- Download: https://www.raspberrypi.com/software/
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

5. Run the installer:

```bash
chmod +x install.sh
sudo ./install.sh
```

Optional custom values:

```bash
sudo AIRPLAY_DEVICE_NAME="Car AirPlay" AIRPLAY_BACKEND="alsa" AIRPLAY_LATENCY="88200" ./install.sh
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
- Installs `alsa-utils`, `avahi-daemon`, and `shairport-sync`
- Validates `AIRPLAY_LATENCY`
- Generates `/etc/shairport-sync.conf` (with timestamped backup if it exists)
- Enables and restarts `shairport-sync` when systemd is available

Supported environment variables:

- `AIRPLAY_DEVICE_NAME` (default: `AirPlay Car Pi`)
- `AIRPLAY_BACKEND` (default: `alsa`)
- `AIRPLAY_LATENCY` (default: `88200`)

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
make deploy PI_USER=<username> PI_HOST=<pi-hostname-or-ip> PI_PATH=~
```

## Audio Notes

- Confirm the HiFiBerry overlay is enabled in `config.txt`.
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
