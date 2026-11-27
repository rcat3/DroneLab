# The Windows app

What's been learned building the app for Windows (the `windows-app` branch), and what's still open.  The app is the same Flutter code as the Linux one; `app/windows/` is the runner, with the audio and voice-effect libraries built as DLLs (`dronelab_audio.dll`, `dronelab_fx.dll`).  `.github/workflows/windows.yml` builds a zip.

## What works

- It builds on a GitHub runner (Visual Studio 2022) and in a Windows 10 guest.  A guest needs the *Desktop development with C++* workload **and the ATL component** (the secure storage and notifications plugins include `atlstr.h`), Developer Mode (symbolic links for the plugins), Git and Flutter.
- Virtual units use loopback TCP, with the port and a token in `unit-N.ep` in `%LOCALAPPDATA%\DroneLab\units` (or `$XDG_RUNTIME_DIR/dronelab-units`).  There's no Windows build of the virtual unit yet.
- Pairing: Windows doesn't pair when the app first reads something encrypted, as Android does, so `windows_pairing.dart` asks for it through `universal_ble`.  Windows 10 shows that plugin's own small window for the code; Windows 11 shows the system's dialog.  The unit has to be allowing it (Settings, Paired Phones, Pair a phone).
- Direct comms, voice and the Remote tab work over Bluetooth, slowly (below).

## Windows and the unit's Bluetooth

Both of these were in `hal_ble.c`, and Android never hit them.  NimBLE tells the unit a phone has connected only after the controller has read the phone's features, and by then Windows has already done things Android does later.

- **Feature read refused.**  Windows answers the controller's read of its features with 0x1A (unsupported remote feature), and NimBLE reports that as the connection's status.  The unit took it for a failed connection, so it never knew the phone was there, and the pairing code was made but not shown, as the screen only shows one while a phone is connected.  A connection with that status is now accepted if the handle is live.
- **MTU reset.**  Windows asks for its MTU at once, so it's agreed before the connect event, which put it back to 23.  Answers went out 17 bytes at a time.  The connect event now reads the current MTU.

## Open: the link is slow and drops

On the same unit the Linux app takes under a second a request and about 4 s for the Remote screen, on Windows a request is about 1 s and the screen takes 20 s or more, and the link drops.

- `NimBLE: ble_att_svr_pkt rc=6` shows in the unit's log soon after connecting: `ble_hs_mbuf_l2cap_pkt()` couldn't get a buffer for an ATT reply, so the stack answers *insufficient resources*.  About 30 s later the log has `Phone disconnected (reason 531)`: Windows gives up on the link, which fits the 30 s ATT transaction timeout.  The app's own connect then often takes a minute (`Future not completed`, and `ConnectAsync ... Catastrophic failure`).
- 88 buffers are free at connect.  The pools are two (64 of 256 bytes, 24 of 320), and a request takes its buffer from one, so the total isn't the number to watch: a first attempt to hold notifications back when the total ran low never fired.  Logging each pool's free count once a second during a transfer is the next step.
- The unit asks for an event every 15 to 30 ms with 4 skipped.  Windows takes the longest, 30 ms, and the skipped events show as about 150 ms for each answer piece.  `rcat_hal_ble_peer_responsive()` asks for 15 ms and none skipped while the app is asking for things (not its routine `/api/state` and `/api/comm`), and relaxes after 10 s; the Remote screen's pieces went from 5 s to 2 s.  It costs radio time while the app's in use, and hasn't been measured on the battery.
- The app logs a board request that takes over a second or gets no answer, with how many pieces and bytes came (`board_link.dart`).  That's how the numbers above were found.

## Testing in a VirtualBox guest

- The guest has no D3D11, so Flutter can't make a surface.  Start the app with `FLUTTER_ENGINE_SWITCHES=1` and `FLUTTER_ENGINE_SWITCH_1=enable-software-rendering=true`.
- A USB Bluetooth adapter passed to the guest needs its Windows driver from Windows Update; the guest's Update API only works from a SYSTEM task, not over SSH.
- A GUI program started over SSH runs in session 0 and isn't seen: start it from a scheduled task that runs as the user, with *run only when logged on*.
- A Linux host's BlueZ reconnects to a unit it's bonded with, which then isn't there for the guest: `bluetoothctl remove` the unit after trying the Linux app.
- A unit's log is on its USB serial port, and shows only what happens while it's being read (`pyserial`, DTR on): `cat` shows nothing.

## Not done

The virtual unit for Windows (X11 to SDL, Winsock, no `eventfd`), pairing without a typed code, Wi-Fi join (`nmcli`), `--profile`, the Visual C++ runtime in the zip, a `tools/dl` target, and the Windows build in the release workflow.
