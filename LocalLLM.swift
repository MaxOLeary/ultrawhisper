import Foundation

/// llama.cpp + Llama 3.2 3B for meeting summaries. Whisper owns these two
/// one-time downloads now that Debrief is retired:
///   llama/   the llama.cpp release build (~11 MB); only llama-server is used
///   models/  Llama-3.2-3B-Instruct-Q4_K_M.gguf (2.0 GB)
/// If Debrief already fetched either one, it is cloned instead (APFS, instant).
/// No PRC models.
enum LocalLLM {
    static let llamaBuild = "b10639"
    static let llamaURL = URL(string:
        "https://github.com/ggml-org/llama.cpp/releases/download/b10639/llama-b10639-bin-macos-arm64.tar.gz")!
    static let ggufName = "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    static let ggufURL = URL(string:
        "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!
    static let ggufBytes: Int64 = 2_019_377_696
    static let ggufLabel = "Llama 3.2 3B"

    /// `baseDir` is `Config.dir` for the app; `--ensure-llm <dir>` points it elsewhere.
    static func llamaDir(baseDir: URL = Config.dir) -> URL {
        baseDir.appendingPathComponent("llama", isDirectory: true)
    }
    static func llamaServer(baseDir: URL = Config.dir) -> URL {
        llamaDir(baseDir: baseDir).appendingPathComponent("llama-server")
    }
    static func gguf(baseDir: URL = Config.dir) -> URL {
        baseDir.appendingPathComponent("models", isDirectory: true).appendingPathComponent(ggufName)
    }

    /// Debrief's copies, reused when present. Read-only; never written to.
    private static let debriefDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/debrief", isDirectory: true)
    private static var debriefLlamaDir: URL { debriefDir.appendingPathComponent("llama", isDirectory: true) }
    private static var debriefGguf: URL { debriefDir.appendingPathComponent("models/\(ggufName)") }

    enum Outcome { case ready; case failed(String) }

    /// One install at a time: a meeting that lands mid-download waits here
    /// for the first caller instead of starting a second download.
    private static let lock = NSLock()

    /// Synchronous. Call off the main thread. Ready when both files exist.
    /// `reuseDebrief` false skips the ~/.config/debrief clones (the test hook
    /// wants a real download).
    static func ensure(baseDir: URL = Config.dir, reuseDebrief: Bool = true,
                       onStatus: ((String) -> Void)? = nil) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let server = llamaServer(baseDir: baseDir)
        let model = gguf(baseDir: baseDir)
        if fm.fileExists(atPath: server.path) && fm.fileExists(atPath: model.path) { return .ready }

        if !fm.fileExists(atPath: server.path) {
            if let err = installServer(into: llamaDir(baseDir: baseDir), reuse: reuseDebrief, onStatus: onStatus) {
                return .failed(err)
            }
        }
        if !fm.fileExists(atPath: model.path) {
            if let err = installModel(at: model, reuse: reuseDebrief, onStatus: onStatus) {
                return .failed(err)
            }
        }
        return .ready
    }

    // MARK: Engine (llama-server + dylibs)

    /// nil on success, else a one-line error.
    private static func installServer(into dir: URL, reuse: Bool, onStatus: ((String) -> Void)?) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = dir.appendingPathComponent("llama-server")

        if reuse, fm.fileExists(atPath: debriefLlamaDir.appendingPathComponent("llama-server").path) {
            onStatus?("Copying AI engine…")
            if let err = copyDirectoryContents(from: debriefLlamaDir, to: dir) {
                NSLog("Whisper: could not reuse Debrief's llama build: \(err)")
            } else if fm.fileExists(atPath: server.path) {
                NSLog("Whisper: reused Debrief's copy of llama.cpp")
                onStatus?("Reused Debrief's copy of the AI engine")
                return nil
            }
        }

        let tar = dir.appendingPathComponent(".download.tar")
        NSLog("Whisper: downloading llama.cpp \(llamaBuild)")
        if let err = download(llamaURL, to: tar, expectedBytes: 0, onProgress: { pct, _, _ in
            onStatus?("Downloading AI engine \(pct)%")
        }) {
            return err
        }
        defer { try? fm.removeItem(at: tar) }
        onStatus?("Unpacking AI engine…")
        let (_, tarErr, tarCode) = run("/usr/bin/tar", ["-xf", tar.path, "--strip-components=1", "-C", dir.path])
        if tarCode != 0 {
            return "tar failed (\(tarCode)): \(tarErr.suffix(300))"
        }
        // Strip quarantine so Gatekeeper does not block a binary we fetched ourselves.
        _ = run("/usr/bin/xattr", ["-cr", dir.path])
        guard fm.fileExists(atPath: server.path) else {
            return "llama-server was not in the downloaded build"
        }
        NSLog("Whisper: llama.cpp ready at \(dir.path)")
        return nil
    }

    // MARK: Model (GGUF)

    private static func installModel(at dest: URL, reuse: Bool, onStatus: ((String) -> Void)?) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        if reuse, fm.fileExists(atPath: debriefGguf.path) {
            onStatus?("Copying \(ggufLabel)…")
            do {
                try fm.copyItem(at: debriefGguf, to: dest)
                if fileSize(dest) == ggufBytes {
                    NSLog("Whisper: reused Debrief's copy of \(ggufName)")
                    onStatus?("Reused Debrief's copy of \(ggufLabel)")
                    return nil
                }
                NSLog("Whisper: Debrief's \(ggufName) has the wrong size, downloading instead")
                try? fm.removeItem(at: dest)
            } catch {
                NSLog("Whisper: could not reuse Debrief's \(ggufName): \(error)")
                try? fm.removeItem(at: dest)
            }
        }

        NSLog("Whisper: downloading \(ggufName)")
        if let err = download(ggufURL, to: dest, expectedBytes: ggufBytes, onProgress: { pct, _, total in
            let gb = String(format: "%.1f", Double(total) / 1e9)
            onStatus?("Downloading \(ggufLabel) \(pct)% of \(gb) GB")
        }) {
            return err
        }
        guard fileSize(dest) == ggufBytes else {
            let got = fileSize(dest)
            try? fm.removeItem(at: dest)
            return "\(ggufName) is \(got) bytes, expected \(ggufBytes)"
        }
        NSLog("Whisper: \(ggufName) ready")
        return nil
    }

    // MARK: Download (streams to dest.part, renames on success)

    /// nil on success, else a one-line error. Only the `.part` file is
    /// removed on failure, so a killed download never leaves a half file
    /// that looks complete. `expectedBytes` 0 means trust content-length.
    private static func download(_ url: URL, to dest: URL, expectedBytes: Int64,
                                 onProgress: @escaping (Int, Int64, Int64) -> Void) -> String? {
        let fm = FileManager.default
        let part = URL(fileURLWithPath: dest.path + ".part")
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else {
            return "Could not create \(part.lastPathComponent)"
        }
        let sink = DownloadSink(handle: handle, expectedBytes: expectedBytes, onProgress: onProgress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60           // idle gap between bytes
        config.timeoutIntervalForResource = 6 * 60 * 60 // whole transfer
        let session = URLSession(configuration: config, delegate: sink, delegateQueue: nil)
        session.dataTask(with: url).resume()
        sink.done.wait()
        session.finishTasksAndInvalidate()
        try? handle.close()

        if let err = sink.error {
            try? fm.removeItem(at: part)
            return err
        }
        let total = sink.total > 0 ? sink.total : expectedBytes
        if total > 0 && sink.received < total {
            try? fm.removeItem(at: part)
            return "Download of \(dest.lastPathComponent) stopped early (\(sink.received) of \(total) bytes)"
        }
        do {
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
        } catch {
            try? fm.removeItem(at: part)
            return "Could not move \(part.lastPathComponent) into place: \(error)"
        }
        return nil
    }

    /// URLSession delegate that appends every chunk to the .part file and
    /// reports whole-percent progress. Everything runs on the session's queue;
    /// `done` releases the caller when the task completes either way.
    private final class DownloadSink: NSObject, URLSessionDataDelegate {
        let handle: FileHandle
        let expectedBytes: Int64
        let onProgress: (Int, Int64, Int64) -> Void
        let done = DispatchSemaphore(value: 0)
        var total: Int64 = 0
        var received: Int64 = 0
        var error: String?
        private var lastPct = -1

        init(handle: FileHandle, expectedBytes: Int64, onProgress: @escaping (Int, Int64, Int64) -> Void) {
            self.handle = handle
            self.expectedBytes = expectedBytes
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                error = "Download failed (HTTP \(status)) for \(dataTask.originalRequest?.url?.absoluteString ?? "?")"
                completionHandler(.cancel)
                return
            }
            let length = response.expectedContentLength
            total = length > 0 ? length : expectedBytes
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                self.error = "Could not write the download: \(error)"
                dataTask.cancel()
                return
            }
            received += Int64(data.count)
            guard total > 0 else { return }
            let pct = Int(received * 100 / total)
            if pct != lastPct {
                lastPct = pct
                onProgress(pct, received, total)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
            if let err, error == nil {
                error = "Download failed: \(err.localizedDescription)"
            }
            done.signal()
        }
    }

    // MARK: Helpers

    /// Copies each entry of `src` into `dst`, skipping ones already there and
    /// dotfiles (a leftover .download.tar). Symlinks stay symlinks. On APFS
    /// this clones, so 50 MB of dylibs costs no space and no time.
    private static func copyDirectoryContents(from src: URL, to dst: URL) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: src.path) else {
            return "cannot list \(src.path)"
        }
        for name in names where !name.hasPrefix(".") {
            let to = dst.appendingPathComponent(name)
            if fm.fileExists(atPath: to.path) || (try? to.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                continue
            }
            do {
                try fm.copyItem(at: src.appendingPathComponent(name), to: to)
            } catch {
                return "\(name): \(error)"
            }
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private static func run(_ exe: String, _ args: [String]) -> (String, String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ("", "\(error)", -1) }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (o, e, p.terminationStatus)
    }
}
