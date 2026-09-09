import Foundation

/// Reference-stable handle for one in-flight single-flight operation shared by concurrent
/// callers.
///
/// Swift actors are reentrant across `await`: memoizing only the completed result would let
/// simultaneous callers each pass the empty-memo check and start duplicate underlying requests.
/// Holding the operation as a single unstructured task means the first caller starts the work
/// and every later caller joins the same task instead of racing it. The shared task is
/// deliberately not tied to any waiter's task lifetime: waiter cancellation is honored after the
/// shared operation settles (each awaiting actor rethrows `CancellationError` for a cancelled
/// waiter), so cancellation propagates to the cancelled caller without duplicating requests or
/// discarding the shared outcome for callers that are still running. The class exists so `===`
/// can distinguish generations of in-flight work when bookkeeping.
final class HuggingFaceSingleFlight<Value: Sendable> {
    let task: Task<Value, any Error>

    init(task: Task<Value, any Error>) {
        self.task = task
    }
}
