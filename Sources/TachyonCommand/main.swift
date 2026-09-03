import Darwin
import Foundation
import TachyonCLI

let exitCode = TachyonCommandLine.run(arguments: Array(CommandLine.arguments.dropFirst()))
if exitCode != 0 { exit(exitCode) }
