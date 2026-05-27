import Foundation
import os

extension Logger {
    public static let app        = Logger(subsystem: "world.questable.mumblur", category: "app")
    public static let hotkey     = Logger(subsystem: "world.questable.mumblur", category: "hotkey")
    public static let audio      = Logger(subsystem: "world.questable.mumblur", category: "audio")
    public static let transcribe = Logger(subsystem: "world.questable.mumblur", category: "transcribe")
    public static let paste      = Logger(subsystem: "world.questable.mumblur", category: "paste")
    public static let runner     = Logger(subsystem: "world.questable.mumblur", category: "runner")
    public static let perms      = Logger(subsystem: "world.questable.mumblur", category: "perms")
}
