# Testing

Run `swift run ChangeLinkSelfTest` for a deterministic test executable on the supplied Command Line Tools image. It covers create, delete, modify, stable-ID rename, hidden-file traversal, content hashing, SQLite persistence, and mock WhatsApp delivery. `swift test` also builds the conditional XCTest target; on a full Xcode installation, XCTest methods cover the same cases. The supplied Command Line Tools image may omit the XCTest runtime, so a zero-test `swift test` result is not treated as the only validation signal.
