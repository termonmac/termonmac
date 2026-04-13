import Foundation

#if os(macOS)
setbuf(stdout, nil)
CLIRouter.run(CommandLine.arguments)
#else
import Darwin
exit(0)
#endif
