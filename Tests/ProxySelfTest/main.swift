import Foundation
import HarborProxyTestSupport

@main
struct HarborProxySelfTest {
    static func main() async throws {
        let checks = HarborGatewayChecks()
        if CommandLine.arguments.dropFirst().first == "--stress" {
            let rounds = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 10
            try await checks.resourceStress(rounds: rounds)
            return
        }
        if CommandLine.arguments.dropFirst().first == "--soak-seconds" {
            guard let seconds = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) else { exit(64) }
            try await checks.resourceSoak(seconds: seconds)
            return
        }
        let start = ContinuousClock.now
        try await checks.switchesOneHundredTimesWithoutReplacingEntry()
        print("PASS: 100 route switches on fixed entry; final connection counts zero")
        try await checks.oldFlowDrainsAndSuspendedGatewayNeverRoutes()
        print("PASS: old flow drain, suspended route rejection, recursive route rejection")
        try await checks.httpAndSOCKSProtocols()
        print("PASS: ordinary HTTP, CONNECT, SOCKS5 CONNECT and recursive destination rejection")
        try await checks.udpAssociationAndRelease()
        print("PASS: UDP relay, source isolation, malformed packet rejection, port release and fixed entry rebind")
        print("Elapsed: \(start.duration(to: .now))")
    }
}
