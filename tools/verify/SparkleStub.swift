//
//  SparkleStub.swift
//  glance (tools/verify)
//
//  Typecheck-only stand-in for `Updater/UpdaterController.swift`, which imports Sparkle —
//  a SwiftPM dependency that `swiftc` can't resolve outside an Xcode build. `tools/verify/run.sh`
//  compiles the app with the real `Updater/` directory excluded and this file substituted, so the
//  other 65 source files can be typechecked with only the Command Line Tools installed.
//
//  This is NEVER part of the app target. It exists so a contributor without Xcode — or a CI runner —
//  can still catch type errors before opening a PR. Keep the surface below in sync with the real
//  `UpdaterController`'s public API; if a member is added there and not here, the typecheck fails
//  loudly at the call site, which is the intended signal rather than a silent divergence.
//

import Foundation
import Observation

@Observable
@MainActor
final class UpdaterController {
    private(set) var canCheckForUpdates = false
    var automaticallyChecksForUpdates: Bool = false
    var isPresentingUpdateUI: Bool { false }
    func start() {}
    func checkForUpdates() {}
}
