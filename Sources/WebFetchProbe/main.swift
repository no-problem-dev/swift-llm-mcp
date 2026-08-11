import Foundation
import LLMMCP
import LLMTool

// MARK: - web-fetch-probe entry point
//
// Runs WebToolKit.fetch against the real network over a corpus of roughly 100 varied URLs,
// classifies where and why each one fails, and writes a Markdown and JSON report.
//
// This talks to live sites, so results move with the internet: some failures are real
// regressions and some are a site changing its mind. That is what the diff subcommand and
// PROBE_BASELINE are for — a run is only meaningful against another run.
//
// Usage:
//   swift run web-fetch-probe                  # whole corpus, defaults
//   PROBE_TIMEOUT=15 PROBE_CONCURRENCY=8 swift run web-fetch-probe
//   PROBE_LIMIT=10 swift run web-fetch-probe   # first N entries, for a smoke test
//
// Reports are written relative to the current working directory, not the package, so run
// this from the package root.

func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

let reportsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("reports")

// MARK: - diff subcommand
//   swift run web-fetch-probe diff <before.json> <after.json>
// The regression gate. Compares two existing reports without touching the network, so it is
// fast and repeatable.
let argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "diff" {
    guard argv.count >= 3 else {
        FileHandle.standardError.write("usage: web-fetch-probe diff <before.json> <after.json>\n".data(using: .utf8)!)
        exit(2)
    }
    do {
        let md = try ReportDiff.diffMarkdown(beforePath: argv[1], afterPath: argv[2])
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        let outURL = reportsDir.appendingPathComponent("web-fetch-diff-\(formatter.string(from: Date())).md")
        try md.data(using: .utf8)!.write(to: outURL)
        print(md)
        print("\n📄 Diff: \(outURL.path)")
    } catch {
        FileHandle.standardError.write("diff 失敗: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

// MARK: - inspect subcommand
//   swift run web-fetch-probe inspect <url>
// Dumps one URL's full extraction to reports/inspect.json so the output can be read by eye.
// Overwrites that file on every call.
if argv.first == "inspect" {
    guard argv.count >= 2 else {
        FileHandle.standardError.write("usage: web-fetch-probe inspect <url>\n".data(using: .utf8)!)
        exit(2)
    }
    let urlString = argv[1]
    let toolkit = WebToolKit(timeout: 20)
    guard let fetch = toolkit.tool(named: "fetch") else { exit(1) }
    let inputDict: [String: Any] = ["url": urlString, "max_length": 1_000_000]
    let input = try? JSONSerialization.data(withJSONObject: inputDict)
    do {
        let toolResult = try await fetch.execute(with: input ?? Data())
        let json = toolResult.stringValue
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        let outURL = reportsDir.appendingPathComponent("inspect.json")
        try json.data(using: .utf8)!.write(to: outURL)
        print("📄 \(outURL.path) (\(json.count) bytes)")
    } catch {
        print("ERROR: \(error)")
    }
    exit(0)
}

let timeout = env("PROBE_TIMEOUT").flatMap(Double.init) ?? 20
let concurrency = env("PROBE_CONCURRENCY").flatMap(Int.init) ?? 8
let limit = env("PROBE_LIMIT").flatMap(Int.init)

var entries = Corpus.entries
if let limit { entries = Array(entries.prefix(limit)) }

// One timestamp for the whole run, so the JSON and Markdown reports share a filename stem.
let formatter = DateFormatter()
formatter.dateFormat = "yyyyMMdd-HHmmss"
let timestamp = formatter.string(from: Date())

FileHandle.standardError.write("""
🔍 web-fetch-probe
   URLs: \(entries.count) / timeout: \(Int(timeout))s / concurrency: \(concurrency)

""".data(using: .utf8)!)

let runner = ProbeRunner(timeout: timeout, maxConcurrency: concurrency)
let results = await runner.run(entries)

// Reports land in ./reports, which is created if it does not exist.
do {
    try ReportWriter.write(results, to: reportsDir, timestamp: timestamp)
} catch {
    FileHandle.standardError.write("レポート書き込み失敗: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// With PROBE_BASELINE set, diff this run against it automatically. A failed diff is
// reported on stderr but does not fail the run — the reports are already written.
if let baseline = env("PROBE_BASELINE") {
    let currentJSON = reportsDir.appendingPathComponent("web-fetch-probe-\(timestamp).json").path
    if let md = try? ReportDiff.diffMarkdown(beforePath: baseline, afterPath: currentJSON) {
        let diffURL = reportsDir.appendingPathComponent("web-fetch-diff-\(timestamp).md")
        try? md.data(using: .utf8)!.write(to: diffURL)
        print("📄 Diff vs baseline: \(diffURL.path)")
    } else {
        FileHandle.standardError.write("baseline diff 失敗（\(baseline) を確認）\n".data(using: .utf8)!)
    }
}

// Summary on stdout. Note that the exit status is 0 regardless of how many URLs failed;
// the regression gate is the diff, not this run.
let ok = results.filter { $0.layer == .ok }.count
let thin = results.filter { $0.layer == .okThinContent }.count
let fail = results.count - ok - thin
let unexpected = results.filter { !$0.matchedExpectation }.count
print("""

✅ 完了: \(results.count) URL
   ok=\(ok)  thin=\(thin)  fail=\(fail)  想定外=\(unexpected)
""")
