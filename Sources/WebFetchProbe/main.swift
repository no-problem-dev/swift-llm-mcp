import Foundation
import LLMMCP
import LLMTool

// MARK: - web-fetch-probe entry point
//
// swift-llm-mcp の WebToolKit.fetch を実ネットワークに対して走らせ、
// 100 件規模の多様な URL がどの層で・どんな理由で失敗するかを分類して
// Markdown + JSON レポートを生成する計測ハーネス。
//
// 使い方:
//   swift run web-fetch-probe                  # 全コーパス、デフォルト設定
//   PROBE_TIMEOUT=15 PROBE_CONCURRENCY=8 swift run web-fetch-probe
//   PROBE_LIMIT=10 swift run web-fetch-probe   # 先頭 N 件だけ（動作確認用）

func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }

let reportsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("reports")

// MARK: - diff サブコマンド
//   swift run web-fetch-probe diff <before.json> <after.json>
// ネットワークを叩かず、既存 2 レポートの差分のみ出力する回帰ゲート。
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

// MARK: - inspect サブコマンド
//   swift run web-fetch-probe inspect <url>
// 単一 URL の抽出結果（全文）をファイルにダンプし、品質を目視確認する。
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

// タイムスタンプは外部から渡す（Date() を使うが executable なので問題なし）
let formatter = DateFormatter()
formatter.dateFormat = "yyyyMMdd-HHmmss"
let timestamp = formatter.string(from: Date())

FileHandle.standardError.write("""
🔍 web-fetch-probe
   URLs: \(entries.count) / timeout: \(Int(timeout))s / concurrency: \(concurrency)

""".data(using: .utf8)!)

let runner = ProbeRunner(timeout: timeout, maxConcurrency: concurrency)
let results = await runner.run(entries)

// レポート出力先: パッケージ直下の reports/
do {
    try ReportWriter.write(results, to: reportsDir, timestamp: timestamp)
} catch {
    FileHandle.standardError.write("レポート書き込み失敗: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// PROBE_BASELINE が指定されていれば、今回の結果と自動 diff（回帰ゲート）
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

// コンソールにも要約を出す
let ok = results.filter { $0.layer == .ok }.count
let thin = results.filter { $0.layer == .okThinContent }.count
let fail = results.count - ok - thin
let unexpected = results.filter { !$0.matchedExpectation }.count
print("""

✅ 完了: \(results.count) URL
   ok=\(ok)  thin=\(thin)  fail=\(fail)  想定外=\(unexpected)
""")
