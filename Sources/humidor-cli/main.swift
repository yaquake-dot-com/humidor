// SPDX-License-Identifier: GPL-3.0-or-later
//
// Command line entry point. Runs the application in headless (no GUI) mode.

import Darwin
import Foundation
import HumidorCore

struct Arguments {
    var configFile: String?
    var userData: String?
    var bindIP: String?
    var port: Int?
    var rescan = false
    var isolated = false
}

func printUsage() {
    print("""
        usage: nicotine [-h] [-c file] [-u dir] [-b ip] [-l port] [-r] [-v]

        Command line client for the Soulseek peer-to-peer network

        options:
          -h, --help            show this help message and exit
          -c, --config file     use non-default configuration file
          -u, --user-data dir   alternative directory for user data and plugins
          -b, --bindip ip       bind sockets to the given IP (useful for VPN)
          -l, --port port       listen on the given port
          -r, --rescan          rescan shared files
          -v, --version         display version and exit

        Website: \(Application.websiteURL)
        """)
}

func parseArguments() -> Arguments {
    var arguments = Arguments()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()

    func value(for option: String) -> String {
        guard let value = iterator.next() else {
            print("nicotine: error: argument \(option): expected one argument")
            exit(2)
        }
        return value
    }

    while let argument = iterator.next() {
        switch argument {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "-v", "--version":
            print("\(Application.name) \(Application.version)")
            exit(0)
        case "-c", "--config":
            arguments.configFile = value(for: argument)
        case "-u", "--user-data":
            arguments.userData = value(for: argument)
        case "-b", "--bindip":
            arguments.bindIP = value(for: argument)
        case "-l", "--port":
            guard let port = Int(value(for: argument)) else {
                print("nicotine: error: argument \(argument): invalid int value")
                exit(2)
            }
            arguments.port = port
        case "-r", "--rescan":
            arguments.rescan = true
        case "--isolated":
            arguments.isolated = true
        case "-n", "--headless", "-s", "--hidden", "--ci-mode":
            // Always headless
            break
        default:
            print("nicotine: error: unrecognized arguments: \(argument)")
            exit(2)
        }
    }

    return arguments
}

/// Headless application, reacting to events that would otherwise show dialogs.
@MainActor
final class HeadlessApplication {

    init() {
        for level in [LogLevel.download, LogLevel.upload] {
            log.addLogLevel(level, isPermanent: false)
        }

        events.connect(.confirmQuit) { [self] in confirmQuit() }
        events.connect(.invalidPassword) { [self] in invalidPassword() }
        events.connect(.invalidUsername) { [self] in invalidPassword() }
        events.connect(.setup) { [self] in setup() }
        events.connect(.sharesUnavailable) { [self] shares in sharesUnavailable(shares) }
    }

    func run() {
        core.start()

        if config.server.autoConnectStartup {
            core.connect()
        }
    }

    private func confirmQuit() {
        cli.prompt(String(localized: "Do you really want to exit? [y/N] ")) { input in
            if input.lowercased().hasPrefix("y") {
                core.quit()
            }
        }
    }

    private func invalidPassword() {
        log.add(String(localized: "User \(config.server.login) already exists, and the password you entered is invalid."))
        log.add(String(localized: "Type /connect to log in with another username or password."))

        config.server.password = ""
    }

    private func setup() {
        log.add(String(localized: "To create a new Soulseek account, fill in your desired username and password. If you already have an account, fill in your existing login details."))

        cli.prompt(String(localized: "Username: ")) { username in
            if !username.isEmpty {
                config.server.login = username
            }

            cli.prompt(String(localized: "Password: "), isSilent: true) { password in
                config.server.password = password
                config.writeConfiguration()

                core.connect()
            }
        }
    }

    private func sharesUnavailable(_ shares: [SharedFolder]) {
        var message = String(localized: "The following shares are unavailable:") + "\n\n"

        for share in shares {
            message += "• \"\(share.virtualName)\" \(share.path)\n"
        }

        message += "\n" + String(localized: "Verify that external disks are mounted and folder permissions are correct.")
        message += "\n" + String(localized: "Retry rescan? [Y/n/force] ")

        cli.prompt(message) { input in
            let input = input.lowercased()

            if input.isEmpty || input.hasPrefix("y") {
                core.shares.rescanShares()
            } else if input.hasPrefix("f") {
                core.shares.rescanShares(force: true)
            }
        }
    }
}

let arguments = parseArguments()
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

MainActor.assumeIsolated {
    if let configFile = arguments.configFile {
        config.setConfigFile(configFile)
    }

    if let userData = arguments.userData {
        config.setDataFolder(userData)
    }

    core.cliInterfaceAddress = arguments.bindIP
    core.cliListenPort = arguments.port

    if arguments.rescan {
        core.initComponents(enabledComponents: [.cli, .shares], isolatedMode: arguments.isolated)

        var exitCode: Int32 = 0

        if core.shares.rescanShares(useThread: false) != true {
            log.add("--------------------------------------------------")
            log.add(String(localized: "Failed to scan shares. Please close other \(HumidorCore.Application.name) instances and try again."))
            exitCode = 1
        }

        core.quit()
        exit(exitCode)
    }

    core.initComponents(isolatedMode: arguments.isolated)

    // Shut down with exit code 0 (success) once everything has quit
    events.connect(.quit) {
        DispatchQueue.main.async {
            config.writeConfiguration()
            exit(0)
        }
    }

    // Quit gracefully on Ctrl+C and "kill"
    for signalType in [SIGINT, SIGTERM] {
        signal(signalType, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: signalType, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                core.quit(isTerminating: signalType == SIGTERM)
            }
        }
        source.resume()
        signalSources.append(source)
    }

    HeadlessApplication().run()
}

RunLoop.main.run()
