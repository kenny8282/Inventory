# Inventory + Label Forge — Quick Start

Your Raspberry Pi inventory & label-making system.

## Plug it in

1. Insert the included SD card into the Pi
2. Plug in the power supply (USB-C for Pi 4/5)
3. **Wait about 5 minutes** the first time — the Pi sets itself up on first boot. It may reboot once during this process.

## Connect it to your home WiFi

After the initial 5 minutes, the Pi will broadcast its own WiFi network so you can configure it.

1. On your phone, open WiFi settings
2. Connect to: **`Inv-Setup`** (no password needed)
3. A setup page should pop up automatically — if not, open a browser and go to `http://10.41.0.1/`
4. Select your home WiFi network from the list
5. Enter your home WiFi password
6. Tap **Connect**
7. The Pi will join your WiFi and the `Inv-Setup` network will disappear

## Use it

Reconnect your phone to your normal home WiFi, then open in any browser:

**[https://inv.local/](https://inv.local/)**

The first time you visit, your browser will warn about the security certificate. This is normal — the Pi runs its own private certificate. Click **Advanced → Proceed**, then it'll remember for next time.

## Plug in the printer (when ready)

When you're ready to print labels, plug the Brother PT-H500 (or compatible) into any USB port on the Pi. It'll be auto-detected. Make sure the printer's switch is in the **E** position.

## Troubleshooting

**Pi not appearing on my network after setup?**
- Wait a full 5 minutes — first boot is slow.
- Look for `Inv-Setup` WiFi on your phone. If it's there, restart the connect step above.
- Reboot the Pi (unplug power, plug back in).

**"Site can't be reached"?**
- Make sure your phone is back on your home WiFi, not still on `Inv-Setup`.
- Try the raw IP instead: open your router's admin page, find the Pi's IP, visit `https://<IP>/`.

**Browser warning about the certificate?**
- Expected. Click "Advanced" or "Show details" → "Proceed" or "Continue anyway". Each device asks once.

## Need help?

Contact Kenny.
