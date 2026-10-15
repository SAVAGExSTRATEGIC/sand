import Foundation

struct SSHClient {
    let processRunner: ProcessRunning
    let host: String
    let config: Config.SSH

    static let connectionOptions = [
        "-o", "PreferredAuthentications=password",
        "-o", "PubkeyAuthentication=no",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=6"
    ]

    // Do not load user/system SSH config or inherit forwarding for isolated guests.
    static let isolatedOptions = [
        "-F", "/dev/null",
        "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
        "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
        "-o", "ProxyCommand=none", "-o", "ProxyJump=none",
        "-o", "ControlMaster=no", "-o", "ControlPath=none",
        "-o", "IdentityAgent=none"
    ]

    private var options: [String] {
        (config.isolated ? Self.isolatedOptions : []) + Self.connectionOptions
    }

    func exec(command: String) async throws -> ProcessResult? {
        return try await processRunner.run(
            executable: "sshpass",
            arguments: sshArguments(command: command),
            wait: true
        )
    }

    func start(command: String) throws -> ProcessHandle {
        return try processRunner.start(
            executable: "sshpass",
            arguments: sshArguments(command: command)
        )
    }

    func copy(localPath: String, remotePath: String) async throws -> ProcessResult? {
        return try await processRunner.run(
            executable: "sshpass",
            arguments: ["-p", config.password, "scp"] + options + [
                "-P", String(config.port),
                localPath,
                "\(config.user)@\(host):\(remotePath)"
            ],
            wait: true
        )
    }

    func checkConnection() async throws {
        _ = try await exec(command: "true")
    }

    private func sshArguments(command: String) -> [String] {
        let escaped = command.replacingOccurrences(of: "'", with: "'\"'\"'")
        return ["-p", config.password, "ssh"] + options + [
            "-p", String(config.port),
            "\(config.user)@\(host)",
            "/bin/bash -lc '\(escaped)'"
        ]
    }
}
