import Foundation
import Combine
@MainActor private final class Gate {
    var waiting: CheckedContinuation<Void, Error>?
    func hold() async throws { try await withCheckedThrowingContinuation { waiting = $0 } }
    func release() { let value = waiting; waiting = nil; value?.resume() }
}
@main private struct Tests {
    @MainActor static func main() async throws {
        let batch = MultipleProjectOpening(), gate = Gate()
        let urls = (1...5).map { URL(fileURLWithPath: "/tmp/order-\($0).jl") }
        var started: [URL] = []
        batch.open(urls + [urls[0]]) { url in started.append(url); try await gate.hold() }
        func settle() async throws { for _ in 0..<10 { await Task.yield() };try await Task.sleep(nanoseconds: 1_000_000) }
        for index in urls.indices {
            try await settle()
            precondition(started == Array(urls.prefix(index + 1)), "Only the current project may prepare media/audio")
            precondition(batch.total == 5 && batch.completed == index && batch.current == urls[index])
            batch.open([URL(fileURLWithPath: "/tmp/extra.jl")]) { _ in fatalError("A running batch must reject another opening request") }
            gate.release()
        }
        try await settle()
        precondition(!batch.running && batch.completed == 5 && batch.error.isEmpty)
        started = []
        batch.open(urls) { url in
            started.append(url)
            if url == urls[1] { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey:"Broken project"]) }
        }
        try await settle()
        precondition(started == Array(urls.prefix(2)) && batch.completed == 1 && !batch.running && batch.error == "Broken project", "A failed opening must stop the queue and retain completed tabs")
        print("MULTIPLE_PROJECTS_ORDER_1_TO_5_SEQUENTIAL_PROGRESS_DEDUPLICATION_AND_ERROR_OK")
    }
}
