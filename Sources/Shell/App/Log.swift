import OSLog

/// Per-area loggers under the app's subsystem, so Console.app and
/// `log stream --predicate 'subsystem == "app.bethesdalabs.Shell"'` can filter by category.
enum Log {
    static let subsystem = "app.bethesdalabs.Shell"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let claude = Logger(subsystem: subsystem, category: "claude")
    static let git = Logger(subsystem: subsystem, category: "git")
    static let control = Logger(subsystem: subsystem, category: "control")
    static let process = Logger(subsystem: subsystem, category: "process")
    static let intelligence = Logger(subsystem: subsystem, category: "intelligence")
    static let update = Logger(subsystem: subsystem, category: "update")
}
