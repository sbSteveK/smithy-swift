/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: Apache-2.0.
 */

import Foundation
import enum Smithy.URIScheme
import struct Smithy.Attributes
import struct Smithy.SwiftLogger
import protocol Smithy.LogAgent
import enum Smithy.StreamError
import enum Smithy.ByteStreamError
import protocol SmithyHTTPAPI.HTTPClient
import struct SmithyHTTPAPI.Headers
import struct SmithyHTTPAPI.Endpoint
import enum SmithyHTTPAPI.ALPNProtocol
import class SmithyHTTPAPI.HTTPRequest
import class SmithyHTTPAPI.HTTPResponse
import enum SmithyHTTPAPI.HTTPStatusCode
import class SmithyChecksums.ChunkedStream
import class SmithyStreams.BufferedStream
import AwsCommonRuntimeKit
#if os(Linux)
import Glibc
#elseif !os(Windows)
import Darwin
#endif

public class CRTClientEngine: HTTPClient {
    public static let noOpCrtClientEngineTelemetry = HttpTelemetry(
        httpScope: "CRTClientEngine",
        telemetryProvider: DefaultTelemetry.provider
    )

    actor SerialExecutor {

        /// Stores the common properties of requests that should share a HTTP connection, such that requests
        /// with equal `ConnectionID` values should be pooled together.
        ///
        /// Used as a dictionary key for storing CRT connection managers once they have been created.
        /// When a new request is made, a connection manager is reused if it matches the request's scheme,
        /// host, and port.
        private struct ConnectionPoolID: Hashable {
            private let protocolType: URIScheme?
            private let host: String
            private let port: UInt16

            init(endpoint: Endpoint) {
                self.protocolType = endpoint.uri.scheme
                self.host = endpoint.uri.host
                self.port = endpoint.uri.port ?? endpoint.uri.defaultPort
            }
        }

        private var logger: LogAgent

        private let windowSize: Int
        fileprivate let maxConnectionsPerEndpoint: Int
        private let telemetry: HttpTelemetry
        private var connectionPools: [ConnectionPoolID: HTTPClientConnectionManager] = [:]
        private var http2ConnectionPools: [ConnectionPoolID: HTTP2StreamManager] = [:]
        private let sharedDefaultIO = SDKDefaultIO.shared
        private let connectTimeoutMs: UInt32?
        private let crtTLSOptions: CRTClientTLSOptions?
        private let socketTimeout: UInt32?

        init(config: CRTClientEngineConfig) {
            self.windowSize = config.windowSize
            self.maxConnectionsPerEndpoint = config.maxConnectionsPerEndpoint
            self.telemetry = config.telemetry
            self.logger = self.telemetry.loggerProvider.getLogger(name: "SerialExecutor")
            self.connectTimeoutMs = config.connectTimeoutMs
            self.crtTLSOptions = config.crtTlsOptions
            self.socketTimeout = config.socketTimeout
        }

        func getOrCreateConnectionPool(endpoint: Endpoint) throws -> HTTPClientConnectionManager {
            let poolID = ConnectionPoolID(endpoint: endpoint)
            guard let connectionPool = connectionPools[poolID] else {
                let newConnectionPool = try createConnectionPool(endpoint: endpoint)
                connectionPools[poolID] = newConnectionPool // save in dictionary
                return newConnectionPool
            }
            return connectionPool
        }

        func getOrCreateHTTP2ConnectionPool(endpoint: Endpoint) throws -> HTTP2StreamManager {
            let poolID = ConnectionPoolID(endpoint: endpoint)
            guard let connectionPool = http2ConnectionPools[poolID] else {
                let newConnectionPool = try createHTTP2ConnectionPool(endpoint: endpoint)
                http2ConnectionPools[poolID] = newConnectionPool // save in dictionary
                return newConnectionPool
            }
            return connectionPool
        }

        private func createConnectionPool(endpoint: Endpoint) throws -> HTTPClientConnectionManager {
            let tlsConnectionOptions = endpoint.uri.scheme == .https ? TLSConnectionOptions(
                context: self.crtTLSOptions?.resolveContext() ?? sharedDefaultIO.tlsContext,
                serverName: endpoint.uri.host
            ) : nil

            var socketOptions = SocketOptions(socketType: .stream)
#if os(iOS) || os(watchOS)
            socketOptions.connectTimeoutMs = self.connectTimeoutMs ?? 30_000
#else
            if let timeout = self.connectTimeoutMs {
                socketOptions.connectTimeoutMs = timeout
            }
#endif
            let httpMonitoringOptions = HTTPMonitoringOptions(
                minThroughputBytesPerSecond: 1,
                // Default to 60 seconds if no value was provided in config.
                allowableThroughputFailureInterval: socketTimeout ?? UInt32(60)
            )

            let options = HTTPClientConnectionOptions(
                clientBootstrap: sharedDefaultIO.clientBootstrap,
                hostName: endpoint.uri.host,
                initialWindowSize: windowSize,
                port: UInt32(endpoint.uri.port ?? endpoint.uri.defaultPort),
                proxyOptions: nil,
                socketOptions: socketOptions,
                tlsOptions: tlsConnectionOptions,
                monitoringOptions: httpMonitoringOptions,
                maxConnections: maxConnectionsPerEndpoint,
                enableManualWindowManagement: false
            ) // not using backpressure yet
            logger.debug("""
            Creating connection pool for \(String(describing: endpoint.uri.host)) \
            with max connections: \(maxConnectionsPerEndpoint)
            """)
            return try HTTPClientConnectionManager(options: options)
        }

        private func createHTTP2ConnectionPool(endpoint: Endpoint) throws -> HTTP2StreamManager {
            var socketOptions = SocketOptions(socketType: .stream)
#if os(iOS) || os(watchOS)
            socketOptions.connectTimeoutMs = self.connectTimeoutMs ?? 30_000
#else
            if let timeout = self.connectTimeoutMs {
                socketOptions.connectTimeoutMs = timeout
            }
#endif
            let tlsConnectionOptions = TLSConnectionOptions(
                context: self.crtTLSOptions?.resolveContext() ?? sharedDefaultIO.tlsContext,
                alpnList: [ALPNProtocol.http2.rawValue],
                serverName: endpoint.uri.host
            )

            let options = HTTP2StreamManagerOptions(
                clientBootstrap: sharedDefaultIO.clientBootstrap,
                hostName: endpoint.uri.host,
                port: UInt32(endpoint.uri.port ?? endpoint.uri.defaultPort),
                maxConnections: maxConnectionsPerEndpoint,
                socketOptions: socketOptions,
                tlsOptions: tlsConnectionOptions,
                enableStreamManualWindowManagement: false
            )
            logger.debug("""
            Creating connection pool for \(String(describing: endpoint.uri.host)) \
            with max connections: \(maxConnectionsPerEndpoint)
            """)

            return try HTTP2StreamManager(options: options)
        }
    }

    public typealias StreamContinuation = CheckedContinuation<HTTPResponse, Error>
    private let telemetry: HttpTelemetry
    private var logger: LogAgent
    private let serialExecutor: SerialExecutor
    private let CONTENT_LENGTH_HEADER = "Content-Length"
    private let AWS_COMMON_RUNTIME = "AwsCommonRuntime"
    private let DEFAULT_STREAM_WINDOW_SIZE = 16 * 1024 * 1024 // 16 MB

    private let windowSize: Int
    private let maxConnectionsPerEndpoint: Int

    init(config: CRTClientEngineConfig = CRTClientEngineConfig()) {
        self.maxConnectionsPerEndpoint = config.maxConnectionsPerEndpoint
        self.windowSize = config.windowSize
        self.telemetry = config.telemetry
        self.logger = self.telemetry.loggerProvider.getLogger(name: "CRTClientEngine")
        self.serialExecutor = SerialExecutor(config: config)
    }

    public func send(request: HTTPRequest) async throws -> HTTPResponse {
        let telemetryContext = telemetry.contextManager.current()
        let tracer = telemetry.tracerProvider.getTracer(
            scope: telemetry.tracerScope,
            attributes: telemetry.tracerAttributes
        )
        let queuedStart = Date().timeIntervalSinceReferenceDate
        let span = tracer.createSpan(
            name: telemetry.spanName,
            initialAttributes: telemetry.spanAttributes,
            spanKind: .internal,
            parentContext: telemetryContext
        )
        defer {
            span.end()
        }

        let connectionMgr = try await serialExecutor.getOrCreateConnectionPool(endpoint: request.endpoint)
        let acquireConnectionStart = Date().timeIntervalSinceReferenceDate
        let connection = try await connectionMgr.acquireConnection()
        let acquireConnectionEnd = Date().timeIntervalSinceReferenceDate

        telemetry.connectionsAcquireDuration.record(
            value: acquireConnectionEnd - acquireConnectionStart,
            attributes: Attributes(),
            context: telemetryContext
        )
        telemetry.requestsQueuedDuration.record(
            value: acquireConnectionEnd - queuedStart,
            attributes: Attributes(),
            context: telemetryContext
        )

        updateHTTPMetrics(connectionMgr.fetchMetrics())

        switch connection.httpVersion {
        case .version_1_1:
            return try await handleHTTP1Request(
                connection: connection,
                request: request,
                telemetryContext: telemetryContext
            )
        case .version_2:
            return try await handleHTTP2Request(
                connection: connection,
                request: request,
                telemetryContext: telemetryContext
            )
        case .unknown:
            fatalError("Unknown HTTP version")
        }
    }

    // Forces an Http2 request that uses CRT's `HTTP2StreamManager`.
    // This may be removed or improved as part of SRA work and CRT adapting to SRA for HTTP.
    func executeHTTP2Request(request: HTTPRequest) async throws -> HTTPResponse {
        let telemetryContext = telemetry.contextManager.current()
        let tracer = telemetry.tracerProvider.getTracer(
            scope: telemetry.tracerScope,
            attributes: telemetry.tracerAttributes)
        do {
            // START - smithy.client.http.requests.queued_duration
            let queuedStart = Date().timeIntervalSinceReferenceDate
            let span = tracer.createSpan(
                name: telemetry.spanName,
                initialAttributes: telemetry.spanAttributes,
                spanKind: SpanKind.internal,
                parentContext: telemetryContext)
            defer {
                span.end()
            }
            let connectionMgr = try await serialExecutor.getOrCreateHTTP2ConnectionPool(endpoint: request.endpoint)

            self.logger.debug("Using HTTP/2 connection")
            let crtRequest = try request.toHttp2Request()

            return try await withCheckedThrowingContinuation { (continuation: StreamContinuation) in
                let wrappedContinuation = ContinuationWrapper(continuation)
                let requestOptions = self.makeHttpRequestStreamOptions(
                    request: crtRequest,
                    continuation: wrappedContinuation,
                    http2ManualDataWrites: true,
                    serverAddress: CRTClientEngine.makeServerAddress(request: request)
                )
                let telemetry = self.telemetry
                let logger = self.logger
                let serialExecutor = self.serialExecutor
                Task { @Sendable in
                    let stream: HTTP2Stream
                    var acquireConnectionEnd: TimeInterval
                    do {
                        // START - smithy.client.http.connections.acquire_duration
                        let acquireConnectionStart = Date().timeIntervalSinceReferenceDate
                        stream = try await connectionMgr.acquireStream(requestOptions: requestOptions)
                        acquireConnectionEnd = Date().timeIntervalSinceReferenceDate
                        telemetry.connectionsAcquireDuration.record(
                            value: acquireConnectionEnd - acquireConnectionStart,
                            attributes: Attributes(),
                            context: telemetryContext)
                        // END - smithy.client.http.connections.acquire_duration
                        let queuedEnd = acquireConnectionEnd
                        telemetry.requestsQueuedDuration.record(
                            value: queuedEnd - queuedStart,
                            attributes: Attributes(),
                            context: telemetryContext)
                        // END - smithy.client.http.requests.queued_duration
                    } catch {
                        logger.error(error.localizedDescription)
                        wrappedContinuation.resume(throwing: error)
                        return
                    }

                    let connectionsLimit = serialExecutor.maxConnectionsPerEndpoint
                    let connectionMgrMetrics = connectionMgr.fetchMetrics()
                    telemetry.updateHTTPMetricsUsage { httpMetricsUsage in
                        // TICK - smithy.client.http.connections.limit
                        httpMetricsUsage.connectionsLimit = connectionsLimit

                        // TICK - smithy.client.http.connections.usage
                        httpMetricsUsage.idleConnections = connectionMgrMetrics.availableConcurrency
                        httpMetricsUsage.acquiredConnections = connectionMgrMetrics.leasedConcurrency

                        // TICK - smithy.client.http.requests.usage
                        httpMetricsUsage.inflightRequests = connectionMgrMetrics.leasedConcurrency
                        httpMetricsUsage.queuedRequests = connectionMgrMetrics.pendingConcurrencyAcquires
                    }

                    // At this point, continuation is resumed when the initial headers are received
                    // it is now safe to write the body
                    // writing is done in a separate task to avoid blocking the continuation
                    // START - smithy.client.http.connections.uptime
                    do {
                        // DURATION - smithy.client.http.connections.uptime
                        let connectionUptimeStart = acquireConnectionEnd
                        defer {
                            telemetry.connectionsUptime.record(
                                value: Date().timeIntervalSinceReferenceDate - connectionUptimeStart,
                                attributes: Attributes(),
                                context: telemetryContext)
                        }
                        // TICK - smithy.client.http.bytes_sent
                        try await stream.write(
                            body: request.body,
                            telemetry: telemetry,
                            serverAddress: CRTClientEngine.makeServerAddress(request: request))
                    } catch {
                        logger.error(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func updateHTTPMetrics(_ metrics: HTTPClientConnectionManagerMetrics) {
        let connectionsLimit = serialExecutor.maxConnectionsPerEndpoint
        telemetry.updateHTTPMetricsUsage { httpMetricsUsage in
            httpMetricsUsage.connectionsLimit = connectionsLimit
            httpMetricsUsage.idleConnections = metrics.availableConcurrency
            httpMetricsUsage.acquiredConnections = metrics.leasedConcurrency
            httpMetricsUsage.inflightRequests = metrics.leasedConcurrency
            httpMetricsUsage.queuedRequests = metrics.pendingConcurrencyAcquires
        }
    }

    private func handleHTTP1Request(
        connection: HTTPClientConnection,
        request: HTTPRequest,
        telemetryContext: TelemetryContext
    ) async throws -> HTTPResponse {
        logger.debug("Using HTTP/1.1 connection")
        let crtRequest = try request.toHttpRequest()
        let serverAddress = Self.makeServerAddress(request: request)

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: StreamError.connectionReleased("Engine released"))
                return
            }

            let wrappedContinuation = ContinuationWrapper(continuation)

            do {
                let requestOptions = self.makeHttpRequestStreamOptions(
                    request: crtRequest,
                    continuation: wrappedContinuation,
                    serverAddress: serverAddress
                )

                let stream = try connection.makeRequest(requestOptions: requestOptions)
                try stream.activate()

                if request.isChunked {
                    let logger = self.logger
                    let telemetry = self.telemetry

                    Task { @Sendable in
                        do {

                            try await CRTClientEngine.sendChunkedBody(
                                using: stream,
                                request: request,
                                logger: logger,
                                telemetry: telemetry,
                                serverAddress: serverAddress
                            )
                        } catch {
                            logger.error("Chunked streaming error: \(error.localizedDescription)")
                            wrappedContinuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                self.logger.error("Request setup error: \(error.localizedDescription)")
                wrappedContinuation.resume(throwing: error)
            }
        }
    }

    private func handleHTTP2Request(
        connection: HTTPClientConnection,
        request: HTTPRequest,
        telemetryContext: TelemetryContext
    ) async throws -> HTTPResponse {
        self.logger.debug("Using HTTP/2 connection")
        let crtRequest = try request.toHttp2Request()
        return try await withCheckedThrowingContinuation { (continuation: StreamContinuation) in
            let wrappedContinuation = ContinuationWrapper(continuation)
            let requestOptions = self.makeHttpRequestStreamOptions(
                request: crtRequest,
                continuation: wrappedContinuation,
                http2ManualDataWrites: true,
                serverAddress: CRTClientEngine.makeServerAddress(request: request)
            )
            do {
                guard let stream = try connection.makeRequest(requestOptions: requestOptions) as? HTTP2Stream else {
                    throw StreamError.notSupported("HTTP2Stream expected for HTTP/2 connection!")
                }
                try stream.activate()

                let telemetry = self.telemetry
                let logger = self.logger

                Task { @Sendable in
                    do {
                        try await stream.write(
                            body: request.body,
                            telemetry: telemetry,
                            serverAddress: CRTClientEngine.makeServerAddress(request: request)
                        )
                    } catch {
                        logger.error(error.localizedDescription)
                    }
                }
            } catch {
                self.logger.error(error.localizedDescription)
                wrappedContinuation.resume(throwing: error)
                return
            }
        }
    }

    private static func sendChunkedBody(
        using stream: HTTPStream,
        request: HTTPRequest,
        logger: LogAgent,
        telemetry: HttpTelemetry,
        serverAddress: String
    ) async throws {
        guard let http1Stream = stream as? HTTP1Stream else {
            throw StreamError.notSupported("HTTP1Stream should be used with an HTTP/1.1 connection!")
        }

        let body = request.body
        guard case .stream(let stream) = body, stream.isEligibleForChunkedStreaming else {
            throw ByteStreamError.invalidStreamTypeForChunkedBody(
                "The stream is not eligible for chunked streaming or is not a stream type!"
            )
        }

        guard let chunkedStream = stream as? ChunkedStream else {
            throw ByteStreamError.streamDoesNotConformToChunkedStream(
                "Stream does not conform to ChunkedStream! Type is \(stream)."
            )
        }

        var hasMoreChunks = true
        while hasMoreChunks {
            hasMoreChunks = try await chunkedStream.chunkedReader.processNextChunk()
            let currentChunk = chunkedStream.chunkedReader.getCurrentChunk()
            let currentChunkBodyIsEmpty = chunkedStream.chunkedReader.getCurrentChunkBody().isEmpty

            if !hasMoreChunks || currentChunkBodyIsEmpty {
                let finalChunk = try await chunkedStream.chunkedReader.getFinalChunk()
                try await http1Stream.writeChunk(chunk: finalChunk, endOfStream: true)

                var bytesSentAttributes = Attributes()
                bytesSentAttributes.set(
                    key: HttpMetricsAttributesKeys.serverAddress,
                    value: serverAddress
                )
                telemetry.bytesSent.add(
                    value: finalChunk.count,
                    attributes: bytesSentAttributes,
                    context: telemetry.contextManager.current()
                )
                break
            } else {
                try await http1Stream.writeChunk(chunk: currentChunk, endOfStream: false)

                var bytesSentAttributes = Attributes()
                bytesSentAttributes.set(
                    key: HttpMetricsAttributesKeys.serverAddress,
                    value: serverAddress
                )
                telemetry.bytesSent.add(
                    value: currentChunk.count,
                    attributes: bytesSentAttributes,
                    context: telemetry.contextManager.current()
                )
            }
        }
    }

    /// Creates a `HTTPRequestOptions` object that can be used to make a HTTP request
    /// - Parameters:
    ///   - request: The `HTTPRequestBase` object that contains the request information
    ///   - continuation: The wrapped continuation that will be resumed when the request is complete
    ///   - http2ManualDataWrites: Whether or not the request is using HTTP/2 manual data writes, defaults to `false`
    ///     If set to false, HTTP/2 manual data writes will be disabled and result in a runtime error on writing on the
    ///     HTTP/2 stream
    ///     If set to true, HTTP/2 manual data writes will be enabled, which will allow the manual writing on the HTTP/2
    ///     stream. Also, if the request body is specified, the body will be first written to the stream followed by
    ///     the manual writes.
    /// - Returns: A `HTTPRequestOptions` object that can be used to make a HTTP request
    private func makeHttpRequestStreamOptions(
        request: HTTPRequestBase,
        continuation: ContinuationWrapper<HTTPResponse>,
        http2ManualDataWrites: Bool = false,
        serverAddress: String
    ) -> HTTPRequestOptions {
        let response = HTTPResponse()
        let stream = BufferedStream()

        let makeStatusCode: (UInt32) -> HTTPStatusCode = { statusCode in
            HTTPStatusCode(rawValue: Int(statusCode)) ?? .notFound
        }

        var bytesReceivedAttributes = Attributes()
        bytesReceivedAttributes.set(key: HttpMetricsAttributesKeys.serverAddress, value: serverAddress)

        var requestOptions = HTTPRequestOptions(request: request) { statusCode, headers in
            self.logger.debug("Interim response received")
            response.statusCode = makeStatusCode(statusCode)
            response.headers.addAll(headers: Headers(httpHeaders: headers))
        } onResponse: { statusCode, headers in
            self.logger.debug("Main headers received")
            response.statusCode = makeStatusCode(statusCode)
            response.headers.addAll(headers: Headers(httpHeaders: headers))

            // resume the continuation as soon as we have all the initial headers
            // this allows callers to start reading the response as it comes in
            // instead of waiting for the entire response to be received
            continuation.resume(returning: response)
        } onIncomingBody: { bodyChunk in
            self.logger.debug("Body chunk received")
            do {
                try stream.write(contentsOf: bodyChunk)
                self.telemetry.bytesReceived.add(
                    value: bodyChunk.count,
                    attributes: bytesReceivedAttributes,
                    context: self.telemetry.contextManager.current())
            } catch {
                self.logger.error("Failed to write to stream: \(error)")
            }
        } onTrailer: { headers in
            self.logger.debug("Trailer headers received")
            response.headers.addAll(headers: Headers(httpHeaders: headers))
        } onStreamComplete: { result in
            self.logger.debug("Request/response completed")
            switch result {
            case .success(let statusCode):
                response.statusCode = makeStatusCode(statusCode)
                stream.close()
            case .failure(let error):
                self.logger.error("Response encountered an error: \(error)")
                stream.closeWithError(error)
                continuation.resume(throwing: error)
            }
        }

        requestOptions.http2ManualDataWrites = http2ManualDataWrites

        response.body = .stream(stream)
        return requestOptions
    }

    private static func makeServerAddress(request: HTTPRequest) -> String {
        let address = request.destination.host
        if let port = request.destination.port {
            return "\(address):\(port)"
        } else {
            return address
        }
    }

    // Guaranteed to be safe in concurrent environments due to use of locks
    final class ContinuationWrapper<Response: Sendable>: @unchecked Sendable {

        private var continuation: CheckedContinuation<Response, Error>?
        private let lock = NSLock()

        init(_ cont: CheckedContinuation<Response, Error>) {
            self.continuation = cont
        }

        func resume(returning value: Response) {
            take()?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            take()?.resume(throwing: error)
        }

        /// Fetch the continuation exactly once. Returns the current value under
        /// a lock, then sets it to `nil` so later callers get nothing.
        private func take() -> CheckedContinuation<Response, Error>? {
            lock.lock()
            defer { continuation = nil; lock.unlock() }
            let pendingContinuation = continuation
            return pendingContinuation
        }
    }
}
