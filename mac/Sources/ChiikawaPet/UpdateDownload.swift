import Foundation

final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var destination: URL?
    private var maximumBytes: Int64 = 0
    private var redirects = 0
    private var failure: Error?

    static func fetch(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        let download = UpdateDownload()
        _ = try await download.start(url, destination: destination, maximumBytes: maximumBytes)
    }

    private func start(_ url: URL, destination: URL, maximumBytes: Int64) async throws -> URL {
        self.destination = destination
        self.maximumBytes = maximumBytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("ChiikawaPet-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue(url.host == "api.github.com" ? "application/vnd.github+json" : "application/octet-stream", forHTTPHeaderField: "Accept")
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, UpdateTrust.allowedDownloadURL(url) else {
            failure = UpdateFailure("The update redirected to an untrusted server.")
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            failure = UpdateFailure("The update download exceeds the allowed size.")
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard failure == nil, let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == 200, let destination else {
                throw failure ?? UpdateFailure("The update server did not return a successful response.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= maximumBytes else {
                throw UpdateFailure("The update download exceeds the allowed size.")
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let failure = failure ?? error {
            continuation?.resume(throwing: failure)
        } else if let destination, FileManager.default.fileExists(atPath: destination.path) {
            continuation?.resume(returning: destination)
        } else {
            continuation?.resume(throwing: UpdateFailure("The update download was not saved."))
        }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
