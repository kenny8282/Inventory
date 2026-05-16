# Backup & Restore

The system stores your inventory data on the Pi's SD card. SD cards do fail
eventually. The Backup & Restore feature lets you save a portable snapshot of
your data so you can recover from any disaster — a dead SD card, a fresh
install, an accidental Reset Everything click.

## What gets backed up

Everything in `/var/lib/gridfinity/`:

- **Inventory items** (the registry — every label you've ever issued, with
  its ID, text lines, dimensions, format, and timestamps)
- **Used IDs** (the set of IDs that have been issued, so the system never
  recycles one)
- **Label presets** (your custom tape and sheet formats)
- **App config** (QR mode, URL prefix, default dimensions, etc.)
- **Working queue rows** (currently-staged labels in the Label Maker and
  Printer tabs)

It does NOT back up:

- The application code itself (it lives in GitHub — that's its backup)
- The Pi's OS or system configuration
- USB-connected printer state

## Backup format

A single JSON file, schema `gridfinity-backup/v1`. Human-readable in any text
editor. Typical file size: a few KB to a few MB depending on how much
inventory you've built up.

Filename convention: `inv-backup-YYYY-MM-DD_HHMM.json` (using the Pi's
hostname as a prefix, so multiple Pis are distinguishable).

## How to back up

In the web UI: **Options tab → Backup & Restore panel**.

Three buttons:

### Download Backup

Click → the backup file downloads to whatever device you're using to view
the UI. Then upload that file anywhere you trust: email it to yourself,
drop it in OneDrive/Dropbox/iCloud, AirDrop to a phone, attach it in a chat,
keep multiple copies in different places. The file is completely portable.

This is the **primary** backup mechanism. It works on every device, requires
no extra hardware, and you control where the backup ends up.

### Save to USB Drive

Optional. Requires a USB drive plugged into the Pi, formatted ext4, with the
volume label `backup-ssd`. When present, the Pi auto-mounts it at
`/mnt/backup` and the "Save to USB Drive" button writes the backup file
directly to the drive — no browser download required.

If no drive is connected, the button is greyed out with a "Plug in a USB
drive to enable" tooltip.

### Restore from Backup

Click → file picker → pick a backup file → preview confirmation → restore.

**Restore is additive** (merge semantics):
- Items in the backup whose IDs are NOT in the current registry: ADDED
- Items in the backup whose IDs ARE in the current registry: SKIPPED
  (current data wins, never overwritten)
- Label presets in the backup with names NOT in the current presets: ADDED
- Label presets in the backup with names that match: SKIPPED

This means restoring is always safe — you can never lose data by restoring a
backup. The most common use case is "I lost my SD card, I have a backup
file, restore everything to a fresh Pi."

## Setting up the USB drive (one-time)

Skip this section if you don't want a USB drive — Download Backup works
without it.

Plug a USB drive into the Pi, then SSH in and run:

```bash
# Identify the drive — usually /dev/sda for a fresh USB device
lsblk
sudo blkid /dev/sda

# Wipe and reformat as ext4 with the required label
# WARNING: this destroys all data on the drive
sudo wipefs -a /dev/sda1 /dev/sda2 /dev/sda3 2>/dev/null || true
sudo wipefs -a /dev/sda
sudo parted /dev/sda --script -- mklabel gpt mkpart primary ext4 0% 100%
sudo partprobe /dev/sda
sudo mkfs.ext4 -L backup-ssd /dev/sda1

# Mount permanently
sudo mkdir -p /mnt/backup
echo 'LABEL=backup-ssd  /mnt/backup  ext4  defaults,nofail,x-systemd.device-timeout=10s  0  2' \
  | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /mnt/backup
sudo chown gridfinity:gridfinity /mnt/backup
```

Reboot once to verify the drive auto-mounts. Then reopen the Options tab in
the web UI — the "Save to USB Drive" button should be enabled.

The `nofail` option in fstab means if the drive is ever disconnected, the Pi
boots normally without it. You can plug it back in later and `sudo mount
/mnt/backup` to re-attach (or just reboot).

The `chown` step is important: the backend service runs as the `gridfinity`
user, which by default can't write to a mount point created by root. New
installs handle this automatically (install.sh sets the ownership when it
detects a backup-ssd drive).

## Disaster recovery procedure

**Scenario: SD card died, you have a backup file.**

1. Get a new SD card.
2. Flash a fresh Raspberry Pi OS image using the Imager. Apply the same
   user-data (SSH, WiFi, username `gridfinity`).
3. Boot the Pi. Wait for first-boot configuration to complete.
4. Run install.sh from the GitHub repo (same as the original install).
5. Once the web UI is reachable at `https://inv.local/`, go to Options tab →
   Backup & Restore → **Restore from Backup**. Upload the saved backup file.
6. Done. Your inventory is back.

If you also have the USB drive from the dead Pi: plug it into the new Pi
after install.sh completes. The drive will auto-mount at `/mnt/backup`. Pick
the most recent `inv-backup-*.json` file and restore from that.

## Recommended backup cadence

There's no automatic backup schedule built in. The system is intentionally
manual — backups happen when you click the button. Suggested practices:

- **After bulk-adding new items**: download a backup so you have an updated
  snapshot.
- **Before any major change**: download a backup before clicking Reset
  Everything, importing a large external file, or upgrading the Pi.
- **Periodically**: download a backup once a week or month, whatever feels
  right for how often you add labels.

If you want automatic backups (e.g. nightly to a network share), that's a
future cron-based extension. For now, the manual model is enough.

## Future: cloud sync

The `gridfinity-backup/v1` format is designed to feed any transport. A
future cloud sync feature will use the same backend endpoint
(`GET /api/system/backup`) and POST the result to a cloud provider. Restore
stays exactly the same — download from cloud, upload via Restore. No data
migration needed when cloud sync ships.
