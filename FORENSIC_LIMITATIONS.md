# Forensic limitations

FSEvents is a filesystem activity journal, not an audit trail of responsible processes. Events can coalesce, be delayed, be dropped, or be unavailable after volume changes. Snapshots detect state differences but cannot prove causality, intent, or user identity. Stable resource identifiers help correlate renames/moves within observed snapshots only. No attribution is inferred.

File size changes are compared directly. Regular-file content hashes are collected by the polling watcher so same-size edits can be detected, but hashing can be costly for very large trees and is not a substitute for an immutable forensic acquisition. Directory byte sizes are filesystem metadata and should be interpreted as supporting evidence; child-node changes are the stronger directory-content signal.
