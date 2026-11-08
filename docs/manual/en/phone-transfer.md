# Phone Transfer

[简体中文](../phone-transfer.md) · English

Menu bar → **Phone Transfer** → Open Phone Transfer…. Send files and text between your Mac and a phone.
**The phone doesn't need an app**: scan the QR code in the window with the camera and use the browser.

## Two modes

| | LAN | Internet |
|---|---|---|
| When | Phone and Mac on the same Wi-Fi | Phone on another network (cellular, Wi-Fi elsewhere) |
| Speed | Full Wi-Fi speed | Depends on both networks |
| Encryption | None (others on the same Wi-Fi could in theory listen) | End-to-end |
| Needs | Nothing, works offline | Internet access; signaling relayed by public services (encrypted) |

Switch modes at the top left of the window. The QR code changes, so scan again.

## Using it

1. Open the window, scan the QR code with the phone camera and open the page.
2. The Mac window shows "… wants to connect". Click **Allow** (only for devices you recognize).
3. **Phone → Mac**: tap "Choose files" or type text on the phone page. Files go to the receive folder
   (`~/Downloads/Baobox` by default); the window shows progress and "Show in Finder".
4. **Mac → phone**: drag files into the window (or "Choose Files…"), or type text. In LAN mode the phone page lists
   the files with a "Download" button; in Internet mode files are pushed to the phone with a "Save" button.

Closing the window ends the session: the LAN server stops, the internet connection closes and the QR code is void.
A QR code nobody scans expires after 10 minutes; click to refresh.

## If Internet mode can't connect

Internet mode uses UDP hole punching to connect the two devices directly and **does not use relay servers**.
When both networks are strict (say, the phone on a mobile carrier and the Mac on a corporate network) it can fail;
the window shows what it detected about both networks. Then:

- put the phone on the same Wi-Fi and switch to LAN mode;
- **connect the Mac to the phone's hotspot** and use LAN mode (always works);
- try another network.

Switching the phone page to the background may drop an internet connection; keep it in front while transferring.

## Settings

| Setting | Meaning |
|---|---|
| Receive folder | `~/Downloads/Baobox` by default |
| Copy received text to the clipboard automatically | Off by default |
| Phone page URL | The page the Internet-mode QR code opens; defaults to this project's GitHub Pages copy. Change it only if you host your own |

The "Open Phone Transfer" shortcut is unbound by default; set it in Settings → Shortcuts.

## Privacy

- LAN mode: a random token in the QR code plus approval on the Mac; unapproved devices get nothing.
- Internet mode: the session ID and key live only after the `#` in the QR code (browsers never send that part to a server).
  Connection setup is relayed by ntfy.sh / public MQTT brokers, encrypted with that key the whole way, so the relays can
  neither read nor forge it; files travel over an encrypted WebRTC channel directly between the two devices.
- No transfer history is kept; the list clears when you close the window (received files stay in the folder).

Technical details: [docs/phone-transfer/](../../phone-transfer/TECH_DESIGN.md).
