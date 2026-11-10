import Foundation

// `--record-landmarks` and `--replay` are development tools; everything else launches the
// menu bar app.
if CommandLine.arguments.contains("--record-landmarks") {
    exit(Recorder.run(arguments: CommandLine.arguments))
}
if CommandLine.arguments.contains("--replay") {
    exit(Replay.run(arguments: CommandLine.arguments))
}
WristFlowApp.main()
