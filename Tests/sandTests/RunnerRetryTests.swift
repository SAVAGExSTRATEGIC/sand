import XCTest
@testable import sand

private final class FailingCloneRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _clones = 0
    private var _deletes = 0
    var clones: Int { lock.withLock { _clones } }
    var deletes: Int { lock.withLock { _deletes } }

    func run(executable: String, arguments: [String], wait: Bool) async throws -> ProcessResult? {
        switch arguments.first {
        case "list":
            return ProcessResult(stdout: "[]", stderr: "", exitCode: 0)
        case "delete":
            lock.withLock { _deletes += 1 }
            throw ProcessRunnerError.failed(exitCode: 1, stdout: "", stderr: "does not exist", command: ["tart"] + arguments)
        case "clone":
            lock.withLock { _clones += 1 }
            throw ProcessRunnerError.failed(exitCode: 1, stdout: "", stderr: "boom", command: ["tart"] + arguments)
        default:
            return ProcessResult(stdout: "", stderr: "", exitCode: 0)
        }
    }

    func start(executable: String, arguments: [String]) throws -> ProcessHandle {
        ProcessHandle(waitAsync: { ProcessResult(stdout: "", stderr: "", exitCode: 0) }, terminate: {})
    }
}

final class RunnerRetryTests: XCTestCase {
    func testEndlessSlotRetriesThenStopsOnCancel() async throws {
        let fake = FailingCloneRunner()
        let logger = Logger(label: "test", minimumLevel: .critical)
        let tart = Tart(processRunner: fake, logger: logger)
        let vm = Config.VM(source: .init(type: .local, image: nil, name: "golden"), hardware: nil, mounts: [], cache: nil, run: .default, diskSizeGb: nil, ssh: .standard)
        let config = Config.RunnerConfig(name: "slot", vm: vm, provisioner: .init(type: .script, script: .init(run: "true"), github: nil), preRun: nil, postRun: nil, stopAfter: nil, healthCheck: nil)
        let runner = Runner(
            tart: tart, github: nil, provisioner: GitHubProvisioner(), runnerVersionResolver: GitHubRunnerVersionResolver(),
            runnerCache: RunnerCache(), config: config,
            shutdownCoordinator: VMShutdownCoordinator(destroyer: VMDestroyer(tart: tart, logger: logger), logger: logger),
            control: RunnerControl(), vmName: "slot", logLabel: "slot", logLevel: .critical, logSink: nil
        )
        let task = Task { try await runner.run() }
        // First clone at t=0, retry after the 1s backoff. Generous timeout for slow CI hosts.
        for _ in 0..<200 where fake.clones < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let clones = fake.clones
        XCTAssertGreaterThanOrEqual(clones, 2)
        XCTAssertGreaterThanOrEqual(fake.deletes, clones, "every clone is preceded by a leftover-VM delete")
        task.cancel()
        let started = Date()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        }
        // The pending backoff is 2s, so ending well before that means cancellation cut the sleep short.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(fake.clones, clones, "no further clone after cancel")
    }
}
