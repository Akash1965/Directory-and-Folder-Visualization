# Installation

Requires macOS 13+ and Swift 5.9+. Run `swift run ChangeLinkSelfTest`, then `swift test`. To build and open the visible SwiftUI application, run:

```sh
./Scripts/open-app.sh
```

This creates `ChangeLink.app` in the project directory and opens it with Finder/LaunchServices. Build a signed app bundle in Xcode for deployment. Use `Scripts/install-launchagent.sh` only after reviewing its working directory and permissions.
