<p align="center">
  <img src="assets/logo.png" alt="ADSBItalia Logo" width="380"/>
</p>

<h1 align="center">📡 ADSBItalia Feeder Client & Integration Scripts</h1>

<p align="center">
  <b>Official feeding scripts and multi-platform integration guide for the ADSBItalia flight tracking network.</b><br>
  Feed your local Beast 1090MHz ADS-B data and participate in high-precision Multilateration (MLAT).
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Network-ADSBItalia-blue.svg?style=flat-square" alt="Network"/>
  <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20Raspberry%20Pi%20%7C%20Docker-brightgreen.svg?style=flat-square" alt="Platform"/>
  <img src="https://img.shields.io/badge/License-GPL--3.0-orange.svg?style=flat-square" alt="License"/>
  <a href="https://discord.gg/2wFZgCVHYx"><img src="https://img.shields.io/badge/Discord-Join%20Community-5865F2.svg?style=flat-square&amp;logo=discord&amp;logoColor=white" alt="Discord"/></a>
  <a href="https://adsbitalia.it/status.html"><img src="https://img.shields.io/badge/Feeder%20Status-Live%20Check-success.svg?style=flat-square" alt="Status"/></a>
</p>

---

## 🌍 Overview / Panoramica

**ADSBItalia** is a collaborative global flight tracking network born in Italy and open to radio amateurs, aviation enthusiasts, and ADS-B stations worldwide. By feeding data to ADSBItalia, you help build a community-driven, non-commercial aircraft tracking mesh while keeping your existing local setup completely untouched.

* **Non-intrusive**: Feeds as a silent client alongside FlightAware, Flightradar24, RadarBox, and others.
* **Low Latency**: High-speed ingestion for raw ADS-B Mode-S Beast frames.
* **Native MLAT**: Seamless synchronisation with the high-performance native Rust MLAT cluster.

---

## 🚀 Choose Your Installation Method

Select the setup matching your receiver station:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     CHOOSE YOUR SETUP METHOD                            │
├──────────────────────────┬─────────────────────────┬────────────────────┤
│  1. Standalone Linux Host│  2. Docker Ultrafeeder  │  3. ADSB.im Image  │
│  (Raspberry Pi, DietPi,  │  (SDR-Enthusiasts stack,│  (Native 1-click in│
│   Debian, Ubuntu)        │   docker-compose)       │   Data Sharing)    │
└──────────────────────────┴─────────────────────────┴────────────────────┘
```

---

### Method 1: Native Linux Host (Raspberry Pi / Debian / Ubuntu)

Use this method if you already have a local decoder running on your host system (e.g. `readsb`, `dump1090-fa`, `dump1090-mutability`).

Run the one-line interactive installer:

```bash
curl -fsSL https://raw.githubusercontent.com/ADSBItalia/Feeding/main/install.sh -o install.sh && bash install.sh
```
*(Alternative GitHub source: `curl -fsSL https://raw.githubusercontent.com/ADSBItalia/Feeding/main/install.sh -o install.sh && bash install.sh`)*

#### What the installer does:
1. Detects your local Beast OUT stream (default: `127.0.0.1:30005`).
2. Prompts for station coordinates (Latitude, Longitude, Altitude) and station name.
3. Configures your **Local MLAT Return Port** (default: `33106`, fully customizable) so MLAT aircraft tracked by the network are fed back into your local decoder/map (`tar1090`, `readsb`, `dump1090`).
4. Automatically creates and enables systemd background services:
   - `adsbitalia-feed.service`: Forwards ADS-B Beast frames to `adsbitalia.it:31108`.
   - `adsbitalia-mlat.service`: Synchronizes with `mlat.adsbitalia.it:41113` via `mlat-client` and serves local MLAT return results.
5. Optionally installs a dedicated, high-speed local `tar1090` radar map with ADSBItalia styling.

> 💡 **Custom MLAT Return Port**: The installer automatically prompts you for your preferred local MLAT return port (default: `33106`). If you are running multiple receivers or custom decoders, you can specify any unused port (e.g. `30105`, `39008`). The installer configures `readsb` and `adsbitalia-mlat.service` to feed results directly into your local map.

---

### Method 2: Docker & Ultrafeeder (SDR-Enthusiasts Stack)

If you run the SDR-Enthusiasts **Ultrafeeder** container, **do NOT run `install.sh`**. Simply add ADSBItalia as an additional feeder target in your environment configuration (`docker-compose.yml` or `.env`):

```yaml
ULTRAFEEDER_CONFIG:
  - adsb,adsbitalia.it,31108,beast_reduce_plus_out
  - mlat,mlat.adsbitalia.it,41113,39008
```

Or pass via environment variable:
```env
ULTRAFEEDER_CONFIG="adsb,adsbitalia.it,31108,beast_reduce_plus_out;mlat,mlat.adsbitalia.it,41113,39008;"
```

*Note: The trailing value `39008` is the local container port where Ultrafeeder receives MLAT return traffic. Ensure it does not conflict with other MLAT sources.*

---

### Method 3: ADSB.im Feeder Image (Native 1-Click Integration)

Starting with ADSB.im **v3.0.13 or newer**, ADSBItalia is natively integrated into the ADSB.im web interface! You do not need to run any scripts, open the Expert section, or paste manual arguments.

1. Open your **ADSB.im** web dashboard.
2. Navigate to the **Data Sharing** page.
3. Locate **ADSBItalia** in the aggregator list.
4. Check the box for **ADSBItalia** and click **Save** / **Apply**.

ADSB.im automatically handles both the ADS-B Beast feed and the dedicated MLAT synchronization connections in the background.

---

## 📡 Network & Port Reference

| Port | Protocol | Direction | Description |
| :---: | :---: | :---: | :--- |
| **`30005`** | TCP | Inbound (Local) | Default local Beast OUT port from readsb/dump1090. |
| **`31108`** | TCP | Outbound | Primary ADSBItalia ADS-B Beast ingestion server. |
| **`41113`** | TCP | Outbound | High-performance ADSBItalia MLAT server. |
| **`33106`** | TCP | Localhost | Local MLAT results return port (Standalone Linux). |
| **`39008`** | TCP | Container | Local MLAT results return port (Ultrafeeder / ADSB.im). |

---

## 🔍 Checking Your Feeder Status

Once connected, check your receiver's live connection and MLAT synchronization status on our public dashboard:

👉 **[https://adsbitalia.it/status.html](https://adsbitalia.it/status.html)**

The status page provides real-time verification of:
- Public IP & Feeder Station Name
- ADS-B connection state & raw message rate
- MLAT client synchronization & peer count
- Uptime and last ping timestamp

### 🔔 Feeder Email Alerts & Weekly/Monthly Digests
Want instant email notifications if your receiver goes offline or loses MLAT synchronization, plus weekly performance summaries and monthly radar milestone reports?
- **Classic Linux Installer (`install.sh`)**: Prompts for an optional email during setup and subscribes your station automatically.
- **Docker Ultrafeeder & ADSB.im**: Open **[https://adsbitalia.it/status.html](https://adsbitalia.it/status.html)** from any device on your local network. Your station is automatically detected via your public IP, letting you register your email with a single click.

---

## 🛠️ Management & Useful Commands

### Service Status & Logs (Linux Standalone)
```bash
# Check service status
sudo systemctl status adsbitalia-feed.service
sudo systemctl status adsbitalia-mlat.service

# View live real-time logs
sudo journalctl -u adsbitalia-feed.service -f
sudo journalctl -u adsbitalia-mlat.service -f

# Verify active connections
ss -tnp | grep -E '31108|41113'
```

### Updating Station Details
To update your station coordinates, altitude, or feeder name on a standalone Linux install:
```bash
curl -fsSL https://raw.githubusercontent.com/ADSBItalia/Feeding/main/update.sh -o update.sh && bash update.sh
```

### Uninstallation
To completely remove ADSBItalia services and the MLAT environment from your host system:
```bash
curl -fsSL https://raw.githubusercontent.com/ADSBItalia/Feeding/main/uninstall.sh | sudo bash
```
*(Your underlying `readsb` or `dump1090` decoder and feeds to other networks will remain completely untouched).*

---

## 💬 Community & Support

* 🌐 **Official Website**: [https://adsbitalia.it](https://adsbitalia.it)
* 💬 **Discord Server**: [Join our Discord](https://discord.gg/2wFZgCVHYx)
* 🗺️ **Live Map**: [https://adsbitalia.it/tar1090/](https://adsbitalia.it/tar1090/)
* 📩 **Contact**: [https://adsbitalia.it/contatti.html](https://adsbitalia.it/contatti.html)

---

<p align="center">
  <sub>ADSBItalia Community &copy; 2026. Made with ❤️ for open aviation tracking.</sub>
</p>
