# Gridfinity Label Forge + Inventory

Self-hosted workshop inventory system for a Raspberry Pi with optional Brother label printer support.

- **Label Forge** — design and print Gridfinity-style labels (12mm tape via Brother PT-H500/P700/E550W)
- **Inventory** — scan QR labels with your phone, track what's in which bin
- **Single-user** by default — runs on your home network, no auth, no cloud
- One-command install, runs entirely on the Pi

## What you need

- Raspberry Pi 4, Pi 5, or Pi Zero 2 W
- microSD card (16 GB+, Class 10)
- Brother PT-H500, PT-P700, PT-E550W or similar P-touch printer (optional but recommended)
- 12mm laminated tape (Brother TZe-231 or compatible)
- A device with a camera (phone) for the inventory app's QR scanning

## Install

1. Flash **Raspberry Pi OS Lite (64-bit)** to your SD card using the [Raspberry Pi Imager](https://www.raspberrypi.com/software/).  
   In the Imager's settings (gear icon), set:
   - **Hostname** — `gridfinity` (or whatever you like)
   - **Username + password** — your call
   - **WiFi network** — your home network
   - **Enable SSH** — yes, password authentication

2. Boot the Pi. Give it a couple of minutes to come online.

3. SSH in from your laptop:

   ```bash
   ssh kenny8282@gridfinity.local
   ```

4. Run the installer:

   ```bash
   curl -sSL https://raw.githubusercontent.com/kenny8282/Inventory/main/install.sh | sudo bash
   ```

   The installer takes about 10 minutes on a Pi 4. It will:
   - Install nginx, Python, build tools
   - Build [ptouch-print](https://github.com/clarkewd/ptouch-print) from source
   - Set up USB permissions for the Brother printer
   - Generate a self-signed TLS certificate
   - Install the backend as a systemd service
   - Drop the web apps into nginx

5. When it's done, plug in your Brother printer (USB).

6. Open `https://gridfinity.local/` (or your custom hostname) in any browser on the same network.

## First visit — the TLS warning

The Pi serves over HTTPS using a self-signed certificate. The first time you open the site on a device, the browser will warn that it can't verify the cert.

**This is expected — your data is encrypted, but the browser doesn't recognize the Pi as a trusted authority.**

- **Chrome / Edge:** click **Advanced** → **Proceed to gridfinity.local (unsafe)**
- **Firefox:** click **Advanced** → **Accept the Risk and Continue**
- **Safari (Mac):** click **Show Details** → **visit this website**
- **iOS Safari:** tap **Show Details** → **visit this website**
- **Android Chrome:** tap **Advanced** → **Proceed to ...**

The browser remembers your choice. You'll only do this once per device.

## Daily use

### Printing labels (Label Forge)

`https://gridfinity.local/forge/`

- Choose a label format (Gridfinity bin, full-width bin tab, custom)
- Add rows with up to 3 lines of text each
- Each row gets a unique 5-character ID and a QR code
- Print single labels, batches, or sheets to paper

### Tracking inventory

`https://gridfinity.local/inventory/`

- Scan a QR with your phone camera — auto-detects after holding it in the box for ~0.8 seconds
- Mark a new label as a **Container** (a Gridfinity bin) or **Bin** (a storage location)
- Containers get filed into bins with hierarchical locations: Property → Room → Spot

## Upkeep

```bash
# Check that everything is running
sudo systemctl status gridfinity-backend
sudo systemctl status nginx

# Watch live logs
sudo journalctl -u gridfinity-backend -f

# Update to the latest version
sudo bash /opt/gridfinity/update.sh
```

## Troubleshooting

### Printer doesn't print

```bash
# Is it visible to the system?
lsusb | grep -i brother

# Can ptouch-print see it?
ptouch-print --info
```

If `ptouch-print` says "permission denied", you might still need to log out and log back in for the `plugdev` group to take effect, or restart the Pi.

### Camera doesn't work in the inventory app

Mobile browsers require HTTPS for camera access. If you're getting "camera blocked" or no permission prompt, make sure you accepted the certificate warning (see above) — the camera won't work if you bypass the cert error.

### Backend won't start

```bash
sudo journalctl -u gridfinity-backend -n 50 --no-pager
```

The last few lines usually point at the problem (port conflict, Python syntax error from a bad pull, missing dependency).

## Uninstall

```bash
sudo bash /opt/gridfinity/uninstall.sh
```

This stops the service, removes nginx config, removes web files, and removes `/opt/gridfinity`. **Your data in `/var/lib/gridfinity/` is preserved by default** — pass `--purge` to delete it too.

## License

MIT
