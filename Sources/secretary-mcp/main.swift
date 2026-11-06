import Foundation
import SecretaryKit

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var home: URL?
var index = 1
let arguments = CommandLine.arguments
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--home":
        index += 1
        guard index < arguments.count else { fail("--home requires a path") }
        home = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath, isDirectory: true)
    case "--version":
        print(PrivateSecretaryVersion.current)
        exit(0)
    case "--help", "-h":
        print("""
        secretary-mcp \(PrivateSecretaryVersion.current)
        Local MCP stdio server for Private Secretary.

        Usage: secretary-mcp [--home <dir>]

        Environment:
          PRIVATE_SECRETARY_HOME   Override ~/.private-secretary
        """)
        exit(0)
    default:
        fail("Unknown argument: \(argument)")
    }
    index += 1
}

let paths = AppPaths(home: home)
do {
    let config = try AppConfigLoader.loadOrCreate(paths: paths)
    let service = try MemoryService(paths: paths, config: config)
    PSLog.info("secretary-mcp \(PrivateSecretaryVersion.current) serving \(paths.databaseFile.path)")
    let router = MCPRouter(service: service)
    MCPStdioServer(router: router).run()
} catch {
    fail("secretary-mcp failed: \(error.localizedDescription)")
}
