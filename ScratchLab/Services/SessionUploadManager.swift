import CryptoKit
import Foundation
import SwiftUI

struct SessionUploadConfiguration: Sendable {
    static let baseURLDefaultsKey = "ScratchLabUploadAPIBaseURL"
    static let defaultDJIDDefaultsKey = "scratchlabUploadDefaultDJID"

    let apiBaseURL: URL?
    let defaultHeaders: [String: String]

    static func current(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        processInfo: ProcessInfo = .processInfo
    ) -> SessionUploadConfiguration {
        let configuredString = [
            processInfo.environment["SCRATCHLAB_UPLOAD_API_BASE_URL"],
            defaults.string(forKey: baseURLDefaultsKey),
            bundle.object(forInfoDictionaryKey: baseURLDefaultsKey) as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        return SessionUploadConfiguration(
            apiBaseURL: configuredString.flatMap(URL.init(string:)),
            defaultHeaders: [:]
        )
    }

    var isConfigured: Bool {
        apiBaseURL != nil
    }
}

enum SessionUploadJobState: String, Codable, Sendable {
    case queued
    case preparing
    case requestingUploadURL
    case readyToUpload
    case uploading
    case uploadedAwaitingConfirmation
    case processing
    case completed
    case failedRetryable
    case failedTerminal
}

enum SessionUploadErrorCategory: String, Codable, Sendable {
    case unavailable
    case preparation
    case request
    case upload
    case confirmation
    case expired
    case archiveMissing
    case invalidResponse

    var userMessage: String {
        switch self {
        case .unavailable:
            return "Upload isn't available right now."
        case .preparation:
            return "Unable to prepare session."
        case .request:
            return "Unable to request upload."
        case .upload:
            return "Upload interrupted."
        case .confirmation:
            return "Unable to confirm upload."
        case .expired:
            return "Upload expired. Try again."
        case .archiveMissing:
            return "Unable to prepare session."
        case .invalidResponse:
            return "Upload failed."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .unavailable, .archiveMissing:
            return false
        case .preparation, .request, .upload, .confirmation, .expired, .invalidResponse:
            return true
        }
    }
}

struct SessionUploadJob: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let djID: String
    var sessionName: String
    var takeCount: Int
    var zipURL: URL
    var fileSizeBytes: Int64
    var sha256: String?
    var backendSessionID: String?
    var objectKey: String?
    var uploadURLString: String?
    var uploadHeaders: [String: String]
    var expiresAt: Date?
    var state: SessionUploadJobState
    var progressBytesSent: Int64
    var createdAt: Date
    var updatedAt: Date
    var retryCount: Int
    var nextRetryAt: Date?
    var lastErrorCategory: SessionUploadErrorCategory?
    var lastErrorDetail: String?
    var cloudBackedAt: Date?

    var formattedFileSize: String {
        guard fileSizeBytes > 0 else { return "Size pending" }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var progressFraction: Double? {
        guard fileSizeBytes > 0 else { return nil }
        switch state {
        case .completed:
            return 1
        case .uploading, .uploadedAwaitingConfirmation, .processing:
            return min(1, Double(progressBytesSent) / Double(fileSizeBytes))
        default:
            return nil
        }
    }

    var statusText: String {
        switch state {
        case .queued:
            return "Ready to upload"
        case .preparing:
            return "Preparing session"
        case .requestingUploadURL:
            return "Preparing upload"
        case .readyToUpload:
            return "Ready to upload"
        case .uploading:
            return "Uploading"
        case .uploadedAwaitingConfirmation:
            return "Upload complete"
        case .processing:
            return "Processing on server"
        case .completed:
            return "Upload complete"
        case .failedRetryable, .failedTerminal:
            return lastErrorDetail ?? lastErrorCategory?.userMessage ?? "Upload failed"
        }
    }

    var canRetry: Bool {
        switch state {
        case .failedRetryable, .uploadedAwaitingConfirmation, .processing:
            return true
        case .failedTerminal:
            return lastErrorCategory?.isRetryable == true
        default:
            return false
        }
    }
}

private struct SessionUploadPreparedArchive: Sendable {
    let localSessionID: String
    let sessionName: String
    let takeCount: Int
    let zipURL: URL
    let fileSizeBytes: Int64
    let sha256: String
    let createdAt: Date
}

private struct SessionUploadCreateRequest: Encodable {
    let djID: String
    let sessionName: String
    let fileSizeBytes: Int64
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case djID = "dj_id"
        case sessionName = "session_name"
        case fileSizeBytes = "file_size_bytes"
        case sha256
    }
}

private struct SessionUploadCreateResponse: Decodable {
    let sessionID: String
    let objectKey: String
    let uploadURL: String
    let expiresAt: Date
    let uploadHeaders: [String: String]?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case objectKey = "object_key"
        case uploadURL = "upload_url"
        case expiresAt = "expires_at"
        case uploadHeaders = "upload_headers"
    }
}

private struct SessionUploadCompleteRequest: Encodable {
    let bytesUploaded: Int64
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case bytesUploaded = "bytes_uploaded"
        case sha256
    }
}

private struct SessionUploadStatusResponse: Decodable {
    let sessionID: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state
    }
}

private enum SessionUploadServiceError: Error {
    case notConfigured
    case invalidRequest
    case invalidResponse
}

private struct SessionUploadAPIClient {
    let configuration: SessionUploadConfiguration
    var urlSession: URLSession = .shared

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func createUploadSession(
        djID: String,
        sessionName: String,
        fileSizeBytes: Int64,
        sha256: String
    ) async throws -> SessionUploadCreateResponse {
        let requestBody = SessionUploadCreateRequest(
            djID: djID,
            sessionName: sessionName,
            fileSizeBytes: fileSizeBytes,
            sha256: sha256
        )
        let request = try makeRequest(
            path: "/upload-sessions",
            method: "POST",
            body: encoder.encode(requestBody)
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw SessionUploadServiceError.invalidResponse
        }
        return try decoder.decode(SessionUploadCreateResponse.self, from: data)
    }

    func completeUpload(
        backendSessionID: String,
        bytesUploaded: Int64,
        sha256: String
    ) async throws {
        let requestBody = SessionUploadCompleteRequest(bytesUploaded: bytesUploaded, sha256: sha256)
        let request = try makeRequest(
            path: "/upload-sessions/\(backendSessionID)/complete",
            method: "POST",
            body: encoder.encode(requestBody)
        )

        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw SessionUploadServiceError.invalidResponse
        }
    }

    func fetchStatus(backendSessionID: String) async throws -> SessionUploadStatusResponse {
        let request = try makeRequest(
            path: "/upload-sessions/\(backendSessionID)/status",
            method: "GET",
            body: nil
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw SessionUploadServiceError.invalidResponse
        }
        return try decoder.decode(SessionUploadStatusResponse.self, from: data)
    }

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard let baseURL = configuration.apiBaseURL else {
            throw SessionUploadServiceError.notConfigured
        }
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appendingPathComponent(trimmedPath)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        configuration.defaultHeaders.forEach { header, value in
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }
}

private enum SessionUploadFileHasher {
    static func sha256Hex(for fileURL: URL) throws -> String {
        guard let inputStream = InputStream(url: fileURL) else {
            throw SessionUploadServiceError.invalidRequest
        }

        inputStream.open()
        defer { inputStream.close() }

        var hasher = SHA256()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while inputStream.hasBytesAvailable {
            let readCount = inputStream.read(buffer, maxLength: bufferSize)
            if readCount < 0 {
                throw inputStream.streamError ?? SessionUploadServiceError.invalidResponse
            }
            if readCount == 0 {
                break
            }
            hasher.update(data: Data(bytes: buffer, count: readCount))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class SessionUploadBackgroundEvents {
    static let shared = SessionUploadBackgroundEvents()

    private var completionHandlers: [String: () -> Void] = [:]

    func register(identifier: String, completionHandler: @escaping () -> Void) {
        completionHandlers[identifier] = completionHandler
    }

    func finish(identifier: String?) {
        guard let identifier, let completionHandler = completionHandlers.removeValue(forKey: identifier) else {
            return
        }
        completionHandler()
    }
}

@MainActor
final class SessionUploadManager: NSObject, ObservableObject {
    @Published private(set) var jobs: [SessionUploadJob] = []
    @Published private(set) var isUploadAvailable: Bool
    @Published private(set) var availabilityMessage: String?

    private let configuration: SessionUploadConfiguration
    private let fileManager = FileManager.default
    private let archiveBuilder = SessionArchiveBuilder()
    private let apiClient: SessionUploadAPIClient
    private var uploadSession: URLSession!
    private var persistWorkItem: DispatchWorkItem?
    private var retryWorkItems: [String: DispatchWorkItem] = [:]
    private var activeTaskIDs: Set<String> = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        configuration: SessionUploadConfiguration = .current(),
        activateImmediately: Bool = true
    ) {
        self.configuration = configuration
        self.apiClient = SessionUploadAPIClient(configuration: configuration)
        self.isUploadAvailable = configuration.isConfigured
        self.availabilityMessage = configuration.isConfigured
            ? nil
            : "Cloud upload isn't available in this build."
        super.init()
        let sessionConfiguration = activateImmediately
            ? Self.makeUploadSessionConfiguration()
            : URLSessionConfiguration.ephemeral
        self.uploadSession = URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: nil
        )
        if activateImmediately {
            loadPersistedJobs()
            refresh()
        }
    }

    func refresh() {
        reconcileOutstandingTasks()
        retryDueJobsIfNeeded()
    }

    func job(for localSessionID: String?) -> SessionUploadJob? {
        guard let localSessionID else { return nil }
        return jobs.first(where: { $0.id == localSessionID })
    }

    func startUpload(for source: SessionExportSource, djID: String? = nil) {
        guard isUploadAvailable else { return }

        let resolvedDJID = resolvedDJID(explicit: djID)
        Task {
            do {
                if let report = await Task.detached(priority: .userInitiated, operation: {
                    SessionArchiveBuilder().validationReport(for: source)
                }).value {
                    recordFailure(
                        localSessionID: fallbackLocalSessionID(for: source),
                        sessionName: fallbackSessionName(for: source),
                        djID: resolvedDJID,
                        category: .preparation,
                        detail: report.summaryText
                    )
                    return
                }

                let preparedArchive = try await prepareArchive(for: source, djID: resolvedDJID)
                guard job(for: preparedArchive.localSessionID)?.state != .completed else { return }
                await requestUploadSessionAndStart(localSessionID: preparedArchive.localSessionID)
            } catch let serviceError as SessionUploadServiceError {
                let category: SessionUploadErrorCategory
                switch serviceError {
                case .notConfigured:
                    category = .unavailable
                case .invalidRequest, .invalidResponse:
                    category = .preparation
                }
                recordFailure(
                    localSessionID: fallbackLocalSessionID(for: source),
                    sessionName: fallbackSessionName(for: source),
                    djID: resolvedDJID,
                    category: category,
                    detail: category.userMessage
                )
            } catch {
                print("Session upload preparation failed: \(error)")
                recordFailure(
                    localSessionID: fallbackLocalSessionID(for: source),
                    sessionName: fallbackSessionName(for: source),
                    djID: resolvedDJID,
                    category: .preparation,
                    detail: SessionUploadErrorCategory.preparation.userMessage
                )
            }
        }
    }

    func retry(localSessionID: String) {
        retryWorkItems[localSessionID]?.cancel()
        retryWorkItems[localSessionID] = nil

        guard let job = job(for: localSessionID) else { return }
        guard isUploadAvailable else { return }

        switch job.state {
        case .uploadedAwaitingConfirmation, .processing:
            Task {
                await confirmUpload(localSessionID: localSessionID)
            }
        case .uploading:
            guard !activeTaskIDs.contains(localSessionID) else { return }
            fallthrough
        case .queued, .readyToUpload, .failedRetryable, .failedTerminal:
            Task {
                if uploadURLHasExpired(for: job) {
                    await requestUploadSessionAndStart(localSessionID: localSessionID)
                } else if job.uploadURLString != nil {
                    beginUpload(for: localSessionID)
                } else {
                    await requestUploadSessionAndStart(localSessionID: localSessionID)
                }
            }
        case .requestingUploadURL:
            Task {
                await requestUploadSessionAndStart(localSessionID: localSessionID)
            }
        case .preparing:
            break
        case .completed:
            break
        }
    }

    private func prepareArchive(for source: SessionExportSource, djID: String) async throws -> SessionUploadPreparedArchive {
        let package = try await Task.detached(priority: .userInitiated) {
            try SessionArchiveBuilder().preparePackage(from: source)
        }.value

        let localSessionID = package.metadata.sessionID
        let existingJob = job(for: localSessionID)
        let jobDirectory = try uploadJobDirectoryURL(for: localSessionID, createIfNeeded: true)
        let archiveURL = archiveBuilder.archiveURL(for: package.metadata, in: jobDirectory)

        var preparedJob = existingJob ?? SessionUploadJob(
            id: localSessionID,
            djID: djID,
            sessionName: package.metadata.sessionName,
            takeCount: package.takes.count,
            zipURL: archiveURL,
            fileSizeBytes: 0,
            sha256: nil,
            backendSessionID: nil,
            objectKey: nil,
            uploadURLString: nil,
            uploadHeaders: [:],
            expiresAt: nil,
            state: .queued,
            progressBytesSent: 0,
            createdAt: package.metadata.createdAt,
            updatedAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCategory: nil,
            lastErrorDetail: nil,
            cloudBackedAt: nil
        )
        preparedJob.sessionName = package.metadata.sessionName
        preparedJob.takeCount = package.takes.count
        preparedJob.zipURL = archiveURL
        preparedJob.state = .preparing
        preparedJob.lastErrorCategory = nil
        preparedJob.lastErrorDetail = nil
        upsertJob(preparedJob)

        if fileManager.fileExists(atPath: archiveURL.path) {
            let fileSize = fileSize(for: archiveURL)
            let checksum: String
            if let existingChecksum = preparedJob.sha256 {
                checksum = existingChecksum
            } else {
                checksum = try await Task.detached(priority: .utility) {
                    try SessionUploadFileHasher.sha256Hex(for: archiveURL)
                }.value
            }

            preparedJob.fileSizeBytes = fileSize
            preparedJob.sha256 = checksum
            preparedJob.state = .queued
            upsertJob(preparedJob)

            return SessionUploadPreparedArchive(
                localSessionID: localSessionID,
                sessionName: package.metadata.sessionName,
                takeCount: package.takes.count,
                zipURL: archiveURL,
                fileSizeBytes: fileSize,
                sha256: checksum,
                createdAt: package.metadata.createdAt
            )
        }

        let archiveResult = try await Task.detached(priority: .userInitiated) {
            try SessionArchiveBuilder().createArchive(from: package, in: jobDirectory)
        }.value

        let checksum = try await Task.detached(priority: .utility) {
            try SessionUploadFileHasher.sha256Hex(for: archiveResult.archiveURL)
        }.value

        preparedJob.fileSizeBytes = archiveResult.archiveSizeBytes
        preparedJob.sha256 = checksum
        preparedJob.state = .queued
        upsertJob(preparedJob)

        return SessionUploadPreparedArchive(
            localSessionID: localSessionID,
            sessionName: package.metadata.sessionName,
            takeCount: package.takes.count,
            zipURL: archiveResult.archiveURL,
            fileSizeBytes: archiveResult.archiveSizeBytes,
            sha256: checksum,
            createdAt: package.metadata.createdAt
        )
    }

    private func requestUploadSessionAndStart(localSessionID: String) async {
        guard var existingJob = job(for: localSessionID) else { return }
        guard isUploadAvailable else { return }
        guard fileManager.fileExists(atPath: existingJob.zipURL.path) else {
            markFailure(localSessionID: localSessionID, category: .archiveMissing, autoRetry: false)
            return
        }
        guard let sha256 = existingJob.sha256 else {
            markFailure(localSessionID: localSessionID, category: .preparation, autoRetry: false)
            return
        }

        existingJob.state = .requestingUploadURL
        existingJob.lastErrorCategory = nil
        existingJob.lastErrorDetail = nil
        existingJob.progressBytesSent = 0
        existingJob.nextRetryAt = nil
        upsertJob(existingJob)

        do {
            let response = try await apiClient.createUploadSession(
                djID: existingJob.djID,
                sessionName: existingJob.sessionName,
                fileSizeBytes: existingJob.fileSizeBytes,
                sha256: sha256
            )
            existingJob.backendSessionID = response.sessionID
            existingJob.objectKey = response.objectKey
            existingJob.uploadURLString = response.uploadURL
            existingJob.uploadHeaders = response.uploadHeaders ?? [:]
            existingJob.expiresAt = response.expiresAt
            existingJob.state = .readyToUpload
            existingJob.retryCount = 0
            existingJob.nextRetryAt = nil
            existingJob.lastErrorCategory = nil
            existingJob.lastErrorDetail = nil
            upsertJob(existingJob)

            beginUpload(for: localSessionID)
        } catch {
            print("Unable to request upload session for \(localSessionID): \(error)")
            markFailure(localSessionID: localSessionID, category: .request, autoRetry: true)
        }
    }

    private func beginUpload(for localSessionID: String) {
        guard !activeTaskIDs.contains(localSessionID) else { return }
        guard var existingJob = job(for: localSessionID) else { return }
        guard fileManager.fileExists(atPath: existingJob.zipURL.path) else {
            markFailure(localSessionID: localSessionID, category: .archiveMissing, autoRetry: false)
            return
        }
        guard let uploadURLString = existingJob.uploadURLString,
              let uploadURL = URL(string: uploadURLString) else {
            Task {
                await requestUploadSessionAndStart(localSessionID: localSessionID)
            }
            return
        }
        guard !uploadURLHasExpired(for: existingJob) else {
            clearUploadAuthorization(for: localSessionID)
            Task {
                await requestUploadSessionAndStart(localSessionID: localSessionID)
            }
            return
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        existingJob.uploadHeaders.forEach { header, value in
            request.setValue(value, forHTTPHeaderField: header)
        }

        let uploadTask = uploadSession.uploadTask(with: request, fromFile: existingJob.zipURL)
        uploadTask.taskDescription = localSessionID
        activeTaskIDs.insert(localSessionID)
        existingJob.state = .uploading
        existingJob.lastErrorCategory = nil
        existingJob.lastErrorDetail = nil
        existingJob.progressBytesSent = 0
        upsertJob(existingJob)
        uploadTask.resume()
    }

    private func confirmUpload(localSessionID: String) async {
        guard var existingJob = job(for: localSessionID) else { return }
        guard let backendSessionID = existingJob.backendSessionID,
              let sha256 = existingJob.sha256 else {
            markFailure(localSessionID: localSessionID, category: .confirmation, autoRetry: false)
            return
        }

        existingJob.state = .processing
        existingJob.progressBytesSent = existingJob.fileSizeBytes
        upsertJob(existingJob)

        do {
            try await apiClient.completeUpload(
                backendSessionID: backendSessionID,
                bytesUploaded: existingJob.fileSizeBytes,
                sha256: sha256
            )
            existingJob.state = .completed
            existingJob.cloudBackedAt = Date()
            existingJob.lastErrorCategory = nil
            existingJob.lastErrorDetail = nil
            existingJob.progressBytesSent = existingJob.fileSizeBytes
            existingJob.retryCount = 0
            existingJob.nextRetryAt = nil
            upsertJob(existingJob)
        } catch {
            print("Unable to confirm upload for \(localSessionID): \(error)")
            markFailure(localSessionID: localSessionID, category: .confirmation, autoRetry: true)
        }
    }

    private func recordFailure(
        localSessionID: String,
        sessionName: String,
        djID: String,
        category: SessionUploadErrorCategory,
        detail: String? = nil
    ) {
        let jobDirectory: URL
        do {
            jobDirectory = try uploadJobDirectoryURL(for: localSessionID, createIfNeeded: true)
        } catch {
            return
        }
        let archiveURL = jobDirectory.appendingPathComponent("session.zip")
        let failedJob = SessionUploadJob(
            id: localSessionID,
            djID: djID,
            sessionName: sessionName,
            takeCount: 0,
            zipURL: archiveURL,
            fileSizeBytes: 0,
            sha256: nil,
            backendSessionID: nil,
            objectKey: nil,
            uploadURLString: nil,
            uploadHeaders: [:],
            expiresAt: nil,
            state: category.isRetryable ? .failedRetryable : .failedTerminal,
            progressBytesSent: 0,
            createdAt: Date(),
            updatedAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCategory: category,
            lastErrorDetail: detail,
            cloudBackedAt: nil
        )
        upsertJob(failedJob)
    }

    private func markFailure(localSessionID: String, category: SessionUploadErrorCategory, autoRetry: Bool) {
        guard var existingJob = job(for: localSessionID) else { return }

        activeTaskIDs.remove(localSessionID)
        existingJob.state = category.isRetryable ? .failedRetryable : .failedTerminal
        existingJob.lastErrorCategory = category
        if existingJob.lastErrorDetail == nil {
            existingJob.lastErrorDetail = category.userMessage
        }
        existingJob.progressBytesSent = 0
        existingJob.retryCount += autoRetry && category.isRetryable ? 1 : 0
        upsertJob(existingJob)

        guard autoRetry,
              category.isRetryable,
              existingJob.retryCount <= 2 else {
            return
        }

        if category == .expired {
            clearUploadAuthorization(for: localSessionID)
        }

        scheduleRetry(localSessionID: localSessionID, after: retryDelay(forAttempt: existingJob.retryCount))
    }

    private func scheduleRetry(localSessionID: String, after delay: TimeInterval) {
        retryWorkItems[localSessionID]?.cancel()

        guard var existingJob = job(for: localSessionID) else { return }
        existingJob.nextRetryAt = Date().addingTimeInterval(delay)
        upsertJob(existingJob)

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.retry(localSessionID: localSessionID)
            }
        }
        retryWorkItems[localSessionID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func retryDueJobsIfNeeded() {
        let now = Date()
        for job in jobs where job.canRetry {
            guard let nextRetryAt = job.nextRetryAt, nextRetryAt <= now else { continue }
            retry(localSessionID: job.id)
        }
    }

    private func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 5
        case 2: return 15
        default: return 30
        }
    }

    private func uploadURLHasExpired(for job: SessionUploadJob) -> Bool {
        guard let expiresAt = job.expiresAt else { return true }
        return expiresAt <= Date().addingTimeInterval(15)
    }

    private func clearUploadAuthorization(for localSessionID: String) {
        guard var existingJob = job(for: localSessionID) else { return }
        existingJob.backendSessionID = nil
        existingJob.objectKey = nil
        existingJob.uploadURLString = nil
        existingJob.uploadHeaders = [:]
        existingJob.expiresAt = nil
        upsertJob(existingJob)
    }

    private func handleUploadTaskCompletion(
        localSessionID: String,
        statusCode: Int?,
        didError: Bool,
        retryableError: Bool
    ) {
        activeTaskIDs.remove(localSessionID)

        guard let statusCode else {
            if didError {
                markFailure(localSessionID: localSessionID, category: .upload, autoRetry: true)
            } else {
                markFailure(localSessionID: localSessionID, category: .invalidResponse, autoRetry: true)
            }
            return
        }

        if didError {
            if retryableError {
                markFailure(localSessionID: localSessionID, category: .upload, autoRetry: true)
            } else {
                markFailure(localSessionID: localSessionID, category: .upload, autoRetry: false)
            }
            return
        }

        guard 200..<300 ~= statusCode else {
            if statusCode == 401 || statusCode == 403 || statusCode == 408 || statusCode == 409 {
                clearUploadAuthorization(for: localSessionID)
                markFailure(localSessionID: localSessionID, category: .expired, autoRetry: true)
            } else if statusCode >= 500 {
                markFailure(localSessionID: localSessionID, category: .upload, autoRetry: true)
            } else {
                markFailure(localSessionID: localSessionID, category: .invalidResponse, autoRetry: false)
            }
            return
        }

        guard var existingJob = job(for: localSessionID) else { return }
        existingJob.state = .uploadedAwaitingConfirmation
        existingJob.progressBytesSent = existingJob.fileSizeBytes
        existingJob.lastErrorCategory = nil
        existingJob.lastErrorDetail = nil
        upsertJob(existingJob)

        Task {
            await confirmUpload(localSessionID: localSessionID)
        }
    }

    private func handleUploadProgress(localSessionID: String, totalBytesSent: Int64) {
        guard var existingJob = job(for: localSessionID) else { return }
        existingJob.state = .uploading
        existingJob.progressBytesSent = totalBytesSent
        upsertJob(existingJob, persistImmediately: false)
    }

    private func resolvedDJID(explicit: String?) -> String {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let stored = UserDefaults.standard.string(forKey: SessionUploadConfiguration.defaultDJIDDefaultsKey),
           !stored.isEmpty {
            return stored
        }

        let newDJID = "dj_\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(newDJID, forKey: SessionUploadConfiguration.defaultDJIDDefaultsKey)
        return newDJID
    }

    private func fallbackLocalSessionID(for source: SessionExportSource) -> String {
        switch source {
        case .package(let package):
            return package.metadata.sessionID
        case .localRecordingSession(let lastRecordingURL, _, _):
            let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: lastRecordingURL)
            if let sidecar = try? decodeSidecar(at: sidecarURL) {
                return sidecar.sessionID
            }
            return lastRecordingURL.deletingPathExtension().lastPathComponent
        }
    }

    private func fallbackSessionName(for source: SessionExportSource) -> String {
        switch source {
        case .package(let package):
            return package.metadata.sessionName
        case .localRecordingSession(_, let sessionName, _):
            return sessionName
        }
    }

    private func decodeSidecar(at url: URL) throws -> CaptureCore.LocalRecordingSidecar {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data)
    }

    private func fileSize(for fileURL: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func uploadsRootDirectoryURL(createIfNeeded: Bool) throws -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let rootURL = baseURL.appendingPathComponent("ScratchLabUploads", isDirectory: true)
        if createIfNeeded {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        return rootURL
    }

    private func uploadJobDirectoryURL(for localSessionID: String, createIfNeeded: Bool) throws -> URL {
        let rootURL = try uploadsRootDirectoryURL(createIfNeeded: createIfNeeded)
        let directoryURL = rootURL.appendingPathComponent(localSessionID, isDirectory: true)
        if createIfNeeded {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    private func jobFileURL(for localSessionID: String, createIfNeeded: Bool) throws -> URL {
        try uploadJobDirectoryURL(for: localSessionID, createIfNeeded: createIfNeeded)
            .appendingPathComponent("job.json")
    }

    private func loadPersistedJobs() {
        guard let rootURL = try? uploadsRootDirectoryURL(createIfNeeded: true),
              let contents = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            jobs = []
            return
        }

        jobs = contents.compactMap { directoryURL in
            guard let resourceValues = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory == true else {
                return nil
            }
            let jobFileURL = directoryURL.appendingPathComponent("job.json")
            guard let data = try? Data(contentsOf: jobFileURL),
                  let job = try? decoder.decode(SessionUploadJob.self, from: data) else {
                return nil
            }
            return job
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistJob(_ job: SessionUploadJob) {
        guard let jobFileURL = try? jobFileURL(for: job.id, createIfNeeded: true),
              let data = try? encoder.encode(job) else {
            return
        }
        try? data.write(to: jobFileURL, options: .atomic)
    }

    private func schedulePersistJobs() {
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.jobs.forEach(self.persistJob(_:))
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func upsertJob(_ job: SessionUploadJob, persistImmediately: Bool = true) {
        var updatedJob = job
        updatedJob.updatedAt = Date()

        if let existingIndex = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[existingIndex] = updatedJob
        } else {
            jobs.append(updatedJob)
        }
        jobs.sort { $0.updatedAt > $1.updatedAt }

        if persistImmediately {
            persistJob(updatedJob)
        } else {
            schedulePersistJobs()
        }
    }

    private func reconcileOutstandingTasks() {
        uploadSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                self.activeTaskIDs = Set(tasks.compactMap(\.taskDescription))

                for task in tasks {
                    guard let localSessionID = task.taskDescription,
                          var existingJob = self.job(for: localSessionID) else {
                        continue
                    }

                    if task.countOfBytesSent > 0 {
                        existingJob.progressBytesSent = max(existingJob.progressBytesSent, task.countOfBytesSent)
                    }

                    switch task.state {
                    case .running, .suspended:
                        existingJob.state = .uploading
                    case .completed:
                        break
                    case .canceling:
                        existingJob.state = .failedRetryable
                        existingJob.lastErrorCategory = .upload
                    @unknown default:
                        break
                    }
                    self.upsertJob(existingJob, persistImmediately: false)
                }
            }
        }
    }

    private static func makeUploadSessionConfiguration() -> URLSessionConfiguration {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.machelpnz.scratchlab"
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(bundleIdentifier).session-upload")
        configuration.isDiscretionary = false
        #if canImport(UIKit)
        configuration.sessionSendsLaunchEvents = true
        #endif
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        return configuration
    }

    nonisolated private static func isRetryableUploadError(_ error: Error?) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code)
    }
}

extension SessionUploadManager: URLSessionTaskDelegate, URLSessionDataDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let localSessionID = task.taskDescription else { return }
        Task { @MainActor in
            self.handleUploadProgress(localSessionID: localSessionID, totalBytesSent: totalBytesSent)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let localSessionID = task.taskDescription else { return }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let retryableError = SessionUploadManager.isRetryableUploadError(error)
        if let error {
            print("Upload task failed for \(localSessionID): \(error)")
        }
        Task { @MainActor in
            self.handleUploadTaskCompletion(
                localSessionID: localSessionID,
                statusCode: statusCode,
                didError: error != nil,
                retryableError: retryableError
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            SessionUploadBackgroundEvents.shared.finish(identifier: session.configuration.identifier)
        }
    }
}
