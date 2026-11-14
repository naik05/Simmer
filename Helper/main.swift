import Foundation

// SimmerHelper – the privileged launchd daemon of Simmer.
//
// Usage: SimmerHelper [--dry-run]
//
// Everything lives in `HelperDaemon` (HelperDaemon.swift). Keeping top-level code to this
// single call matters under Swift 6: closures written at the top level of main.swift are
// main-actor isolated, but the daemon's handlers run on private dispatch queues.
HelperDaemon.run(arguments: CommandLine.arguments)
