import Foundation

// A guest launch request runs that app in this process and never returns. Without
// one (or if the app couldn't load) iContain's own UI starts.
ICRunPendingGuest(CommandLine.argc, CommandLine.unsafeArgv, nil)
iContainApp.main()
