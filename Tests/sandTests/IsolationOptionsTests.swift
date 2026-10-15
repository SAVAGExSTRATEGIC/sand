import Foundation
import Testing
@testable import sand

struct IsolationOptionsTests {
    @Test func softnetRulesPreserveDirectionalArguments() throws {
        let runner = MockProcessRunner()
        let tart = makeTart(runner)
        let options = Tart.RunOptions(directoryMounts: [], noAudio: true, noGraphics: true,
            noClipboard: true, nested: false,
            softnet: .init(allow: ["in @host"], block: ["out @host", "in 0.0.0.0/0", "out 10.0.0.0/8"]))
        _ = try tart.run(name: "isolated", options: options)
        #expect(runner.startCalls.first?.arguments == ["run", "isolated", "--no-graphics", "--no-audio",
            "--no-clipboard", "--net-softnet", "--net-softnet-allow=in @host",
            "--net-softnet-block=out @host,in 0.0.0.0/0,out 10.0.0.0/8"])
    }

    @Test func isolatedSSHAndSCPNeverLoadAmbientConfig() async throws {
        let runner = SSHProcessRunner()
        let client = SSHClient(processRunner: runner, host: "192.168.64.2",
            config: .init(user: "admin", password: "fixture", port: 22, isolated: true))
        _ = try await client.exec(command: "true")
        _ = try await client.copy(localPath: "/tmp/fixture", remotePath: "/tmp/fixture")
        _ = try client.start(command: "true")
        for call in runner.runCalls + runner.startCalls {
            for option in ["ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes",
                           "PermitLocalCommand=no", "ProxyCommand=none", "ProxyJump=none",
                           "ControlMaster=no", "ControlPath=none", "IdentityAgent=none"] {
                #expect(call.arguments.contains(option))
            }
            #expect(Array(call.arguments[3...6]) == ["-F", "/dev/null", "-o", "ForwardAgent=no"])
        }
    }

    @Test func isolatedFixtureLoadsExplicitPolicy() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sample_isolated_config.yml")
        let config = try Config.load(path: fixture.path)
        let vm = try #require(config.runners.first?.vm)
        #expect(vm.run.softnet?.allow == ["in @host"])
        #expect(vm.run.softnet?.block.contains("out @host") == true)
        #expect(vm.ssh.isolated)
        #expect(vm.mounts.isEmpty)
        #expect(vm.cache == nil)
        #expect(vm.run.noClipboard)
        #expect(ConfigValidator().validate(config).isEmpty)
    }
}
