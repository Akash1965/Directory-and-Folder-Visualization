# Privacy, attribution, and entitlements

ChangeLink reports `UNKNOWN` unless an external, authorized source proves a process identity. Neither FSEvents, timestamps, file ownership, nor path names identify the process responsible for a change. The package never fabricates attribution.

A sandboxed app needs user-selected file read access and security-scoped bookmarks for folders. Notifications require the appropriate macOS notification entitlement. Full Disk Access, if needed for protected folders, must be granted by the user in System Settings; it is not an entitlement this project can silently acquire. Store WhatsApp credentials in a secure secret store, not `.env` or source.
