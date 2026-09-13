# Installation Guide

## Automated Installation
```bash
git clone https://github.com/ignatius22/atlas.git /opt/atlas
cd /opt/atlas
sudo ./scripts/install.sh
```
The installer installs Atlas to `/opt/atlas`, sets up `/usr/local/bin/atlas`, copies systemd unit files to `/etc/systemd/system/`, and reloads systemd.

## Automated Scheduling: Systemd (Recommended)
Atlas uses native systemd timers as the authoritative, recommended production scheduler.

### Enable the 6-Hour Persistent Timer
To start and enable the timer on boot:
```bash
sudo systemctl enable --now atlas-backup.timer
```

### Inspect Timer State and Logs
```bash
systemctl list-timers atlas-backup.timer
systemctl status atlas-backup.timer
journalctl -u atlas-backup.service -n 100 --no-pager
```

> **Why Systemd Over Cron:** The systemd timer uses `Persistent=true`. If the VPS is powered off or undergoing maintenance during a scheduled 6-hour interval, systemd immediately executes the missed backup run upon system startup. Cron does not provide persistent catch-up after downtime, silently skipping backups until the next scheduled trigger.

### Cron (Fallback Only)
If your environment does not support systemd (e.g. lightweight non-systemd containers), configure a cron job as a fallback:
```cron
0 0,6,12,18 * * * root /opt/atlas/scripts/backup.sh --all && /opt/atlas/scripts/sync-offsite.sh --all >> /var/log/atlas-backup.log 2>&1
```
*Note: Cron is strictly a fallback; it will not trigger missed backups if the server was offline during a scheduled run time.*

## Manual Installation
1. Install system prerequisites:
   ```bash
   sudo apt-get update && sudo apt-get install -y age rclone python3-yaml docker.io
   ```
2. Symlink binary:
   ```bash
   sudo ln -sf /opt/atlas/bin/atlas /usr/local/bin/atlas
   ```
3. Install and activate systemd units manually:
   ```bash
   sudo cp /opt/atlas/systemd/atlas-backup.service /etc/systemd/system/
   sudo cp /opt/atlas/systemd/atlas-backup.timer /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now atlas-backup.timer
   ```

## Uninstallation
```bash
sudo /opt/atlas/scripts/uninstall.sh
```
