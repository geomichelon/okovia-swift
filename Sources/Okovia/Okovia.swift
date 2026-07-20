// OkOvia Swift SDK — public umbrella module.
//
//     import Okovia
//
//     try Viking.start(
//         apiKey: "vik_ing_...",
//         projectID: "...",
//         endpoint: URL(string: "https://api.okovia.com")!
//     )
//
// `Okovia` re-exports the `Viking` module verbatim, so every public type
// (`Viking`, the LLM interceptors, the event store, etc.) is available
// under `import Okovia` — you don't also need `import Viking`. The
// historical `import Viking` keeps working unchanged for back-compat.
//
// OkOvia is the public brand; the implementation still lives in the
// `Viking` target, so the entry point remains `Viking.start(...)`.
@_exported import Viking
