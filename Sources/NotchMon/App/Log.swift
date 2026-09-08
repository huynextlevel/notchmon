import Foundation
import OSLog

enum Log {
    private static let subsystem = "com.notchmon.app"
    static let usage = Logger(subsystem: subsystem, category: "usage")
    static let notch = Logger(subsystem: subsystem, category: "notch")
    static let app   = Logger(subsystem: subsystem, category: "app")
}
