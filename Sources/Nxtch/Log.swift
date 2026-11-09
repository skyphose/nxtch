import os

/// Low-volume event log (state changes only, never per-frame). Read it with:
///   /usr/bin/log stream --predicate 'subsystem == "dev.nxtch.app"'
enum Log {
    static let notch = Logger(subsystem: "dev.nxtch.app", category: "notch")
    static let shelf = Logger(subsystem: "dev.nxtch.app", category: "shelf")
    static let clipboard = Logger(subsystem: "dev.nxtch.app", category: "clipboard")
}
