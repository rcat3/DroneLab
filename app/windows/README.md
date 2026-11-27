# DroneLab for Windows

Unpack the zip and run `dronelab.exe`. Keep the folder together: the
`.dll` files and `data` folder beside it are part of the app.

It needs 64-bit Windows 10 or 11 with Bluetooth LE, and the Microsoft
Visual C++ Redistributable (most computers have it; if the app doesn't start,
install the "VC++ Redistributable x64" from Microsoft).

This is a first build: it talks to real units over Bluetooth. There's no
virtual unit on Windows yet.

## Building

On Windows with Visual Studio 2022 (the *Desktop development with C++*
workload), Flutter and Git, from this folder's parent (`app`), after
`git submodule update --init third_party/miniaudio`:

    flutter build windows --release

The result is in `build\windows\x64\runner\Release`. Turn on Developer Mode
(Settings, For developers) first: Flutter's plugins need symbolic links.
