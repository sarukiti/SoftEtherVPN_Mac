// system バイナリの薄い実行ラッパ。シェルを経由しない（引数は配列で渡す）ので
// PoC のクォート問題（host/port/user/pass に ' が混ざると壊れる）を構造的に排除する。

import Foundation

/// 確実に読めるファイルログ（unified log が拾えない環境向けの診断用）。
func HLog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let path = "/tmp/se-helper.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// 引数配列でコマンドを実行。タイムアウト（秒）超過時は SIGKILL。
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // パイプ満杯によるデッドロックを避けるため、待機前に読み出しを開始。
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "shell.read", attributes: .concurrent)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        HLog("RUN \(path) \(args.joined(separator: " "))")
        do { try p.run() } catch {
            HLog("SPAWN FAILED \(path): \(error.localizedDescription)")
            return CommandResult(status: -1, stdout: "", stderr: "spawn failed: \(error.localizedDescription)")
        }

        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchQueue(label: "shell.watchdog")
        var timedOut = false
        watchdog.asyncAfter(deadline: deadline) {
            if p.isRunning { timedOut = true; p.terminate(); kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        group.wait()

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        let status = timedOut ? -2 : p.terminationStatus
        HLog("DONE \(path) status=\(status)\(timedOut ? " (TIMEOUT)" : "")")
        if status != 0 {
            if !out.isEmpty {
                let trimmedOut = out.trimmingCharacters(in: .whitespacesAndNewlines)
                let sample = trimmedOut.count > 600 ? String(trimmedOut.suffix(600)) : trimmedOut
                HLog("  stdout: \(sample)")
            }
            if !err.isEmpty {
                let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
                let sample = trimmedErr.count > 600 ? String(trimmedErr.suffix(600)) : trimmedErr
                HLog("  stderr: \(sample)")
            }
        }
        return CommandResult(status: status,
                             stdout: out,
                             stderr: timedOut ? err + "\n(timed out)" : err)
    }

    /// stdout を trim して返す簡易版。
    static func out(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> String {
        run(path, args, timeout: timeout).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
