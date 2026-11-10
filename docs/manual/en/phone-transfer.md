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

### Which network LAN mode listens on

The "Network" menu above the QR code:

- **Automatic** (default): accept connections only on the interface of the default route (usually Wi-Fi); devices on other
  interfaces can't connect.
- **A specific interface**: when the Mac is on both Ethernet and Wi-Fi, shares its connection, or the phone and the Mac
  are both on a VPN such as Tailscale, pick that one.
- **All interfaces**: no restriction; connections are accepted on every interface, including VPNs and virtual adapters.

The choice is remembered; changing it makes a new QR code.

## Using it

1. Open the window, scan the QR code with the phone camera and open the page.
2. The Mac window shows "… wants to connect". Click **Allow** (only for devices you recognize).
3. **Phone → Mac**: on the phone page, tap a type button to pick files: Photos, Videos, Music, PDF, Word, Excel, PPT,
   Text, Archives, or All files (multiple selection everywhere; "Photos" opens the photo library, the others list only
   files of that type, and WPS formats count as Word / Excel / PPT). You can also type text. Files go to the receive folder (`~/Downloads/Baobox` by default); the window shows progress and
   "Show in Finder". **Images** get a thumbnail: click it for a large preview, or click "Copy" to put the image on the
   clipboard (it pastes into chat apps as an image).
4. **Mac → phone**: drag files into the window (or "Choose Files…"), or type text. In LAN mode the phone page lists
   the files with a "Download" button; in Internet mode files are pushed to the phone with a "Save" button. **Images**
   get a "View" button instead: it opens the image, and **long-pressing it saves it to Photos** (on iPhone, "Download"
   can only save to the Files app).

Every entry shows the time, and finished transfers also show how long they took, e.g.
`2.4 MB · Received · 5:30:12 PM · took 1.2 s`.

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
- Incoming files have limits so the phone side can't fill your disk: 10 GB per file, 20 GB per session (one QR code),
  and at least 2 GB must stay free. The phone shows the reason, and the Mac lists the file as refused; click
  New Session to send more.

Technical details: [docs/phone-transfer/](../../phone-transfer/TECH_DESIGN.md).
