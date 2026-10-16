import XCTest
@testable import sand

final class SSHProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let wait: Bool
    }

    var runCalls: [Call] = []
    var startCalls: [Call] = []
    var failureCodes: [Int32] = []

    func run(executable: String, arguments: [String], wait: Bool) async throws -> ProcessResult? {
        runCalls.append(Call(executable: executable, arguments: arguments, wait: wait))
        if !failureCodes.isEmpty {
            let code = failureCodes.removeFirst()
            throw ProcessRunnerError.failed(exitCode: code, stdout: "", stderr: "fixture", command: [executable])
        }
        return ProcessResult(stdout: "", stderr: "", exitCode: 0)
    }

    func start(executable: String, arguments: [String]) throws -> ProcessHandle {
        startCalls.append(Call(executable: executable, arguments: arguments, wait: false))
        return ProcessHandle(
            waitAsync: { ProcessResult(stdout: "", stderr: "", exitCode: 0) },
            terminate: {}
        )
    }
}

final class SSHClientTests: XCTestCase {
    func testStartBuildsSSHCommand() async throws {
        let runner = SSHProcessRunner()
        let ssh = SSHClient(
            processRunner: runner,
            host: "10.0.0.1",
            config: .init(user: "admin", password: "pw", port: 2222)
        )
        let handle = try ssh.start(command: "echo hi")
        _ = try await handle.waitAsync()
        let expected = SSHProcessRunner.Call(
            executable: "sshpass",
            arguments: [
                "-p", "pw",
                "ssh",
                "-o", "PreferredAuthentications=password",
                "-o", "PubkeyAuthentication=no",
                "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=6",
                "-p", "2222",
                "admin@10.0.0.1",
                "/bin/bash -lc 'echo hi'"
            ],
            wait: false
        )
        XCTAssertEqual(runner.startCalls.first, expected)
    }
}


extension SSHClientTests {
    func testCopyRetriesTransportFailureWithIdenticalIsolatedArguments() async throws {
        let runner = SSHProcessRunner()
        runner.failureCodes = [255, 255]
        let ssh = SSHClient(processRunner: runner, host: "192.0.2.1",
                            config: .init(user: "guest", password: "fixture", port: 22, isolated: true))
        _ = try await ssh.copy(localPath: "/tmp/verified.tar.gz", remotePath: "actions-runner.tar.gz")
        XCTAssertEqual(runner.runCalls.count, 3)
        XCTAssertTrue(runner.runCalls.allSatisfy { $0 == runner.runCalls[0] })
        XCTAssertTrue(runner.runCalls[0].arguments.contains("/dev/null"))
        XCTAssertTrue(runner.runCalls[0].arguments.contains("ForwardAgent=no"))
    }

    func testCopyStopsAfterThreeTransportAttempts() async throws {
        let runner = SSHProcessRunner()
        runner.failureCodes = [255, 255, 255, 255]
        let ssh = SSHClient(processRunner: runner, host: "192.0.2.1",
                            config: .init(user: "guest", password: "fixture", port: 22))
        do {
            _ = try await ssh.copy(localPath: "/tmp/verified.tar.gz", remotePath: "actions-runner.tar.gz")
            XCTFail("A persistent copy failure must remain a failure")
        } catch let error as ProcessRunnerError {
            guard case let .failed(code, _, _, _) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(code, 255)
        }
        XCTAssertEqual(runner.runCalls.count, 3)
    }

    func testCopyDoesNotRetryWrongPasswordOrOtherExitCodes() async throws {
        for code in [Int32(1), Int32(5)] {
            let runner = SSHProcessRunner()
            runner.failureCodes = [code]
            let ssh = SSHClient(processRunner: runner, host: "192.0.2.1",
                                config: .init(user: "guest", password: "fixture", port: 22))
            do {
                _ = try await ssh.copy(localPath: "/tmp/verified.tar.gz", remotePath: "actions-runner.tar.gz")
                XCTFail("A non-transport failure must remain a failure")
            } catch {}
            XCTAssertEqual(runner.runCalls.count, 1)
        }
    }
}
