# Installation

Requires macOS 13+ and Swift 5.9+.

## Get a clickable app icon (one-time build)

```sh
cd ~/Desktop/"SWE Project" && bash Scripts/build-app.sh
```

This compiles Change-Link, creates `Change-Link.app` (with its icon) in the project folder, copies it to `~/Applications`, and opens it. After that, launch it by double-clicking the icon, from Spotlight, or from the Dock — no Terminal needed. Re-run the command only after changing the source code.

If macOS says the app can't be opened because it is from an unidentified developer, right-click the icon and choose **Open** once.

## Developer commands

`swift run ChangeLinkSelfTest`, `swift test`, and `swift run ChangeLinkApp` still work. Use `Scripts/install-launchagent.sh` only after reviewing its working directory and permissions.
