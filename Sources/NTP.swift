//
//  NTP.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/9/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import CTrueTime
import Foundation
import Result

public enum SNTPClientError: ErrorType {
    case UnresolvableHost(underlyingError: CFStreamError?)
    case ConnectionError(underlyingError: NSError?)
    case InvalidResponse
}

public struct ReferenceTime {
    public let time: NSDate
    public let uptime: timeval
    let serverResponse: ntp_packet_t?
    let startTime: timeval?
    public init(time: NSDate, uptime: timeval) {
        self.init(time: time, uptime: uptime, serverResponse: nil, startTime: nil)
    }

    init(time: NSDate, uptime: timeval, serverResponse: ntp_packet_t?, startTime: timeval?) {
        self.time = time
        self.uptime = uptime
        self.serverResponse = serverResponse
        self.startTime = startTime
    }
}

public extension ReferenceTime {
    func now() -> NSDate {
        let currentUptime = timeval.uptime()
        let interval = NSTimeInterval(milliseconds: currentUptime.milliseconds -
                                                    uptime.milliseconds)
        return time.dateByAddingTimeInterval(interval)
    }
}

public typealias ReferenceTimeResult = Result<ReferenceTime, SNTPClientError>
public typealias ReferenceTimeCallback = ReferenceTimeResult -> Void

@objc public final class SNTPClient: NSObject {
    public static let sharedInstance = SNTPClient()
    public let timeout: NSTimeInterval
    public let maxRetries: Int
    public let maxConnections: Int
    required public init(timeout: NSTimeInterval = defaultTimeout,
                         maxRetries: Int = defaultMaxRetries,
                         maxConnections: Int = defaultMaxConnections) {
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.maxConnections = maxConnections
    }

    public func start(hostURLs hostURLs: [NSURL]) {
        reachability.callbackQueue = queue
        reachability.callback = { [weak self] status in
            guard let strongSelf = self else { return }
            switch status {
                case .NotReachable:
                    debugLog("Network unreachable")
                    strongSelf.stopQueue()
                case .ReachableViaWWAN, .ReachableViaWiFi:
                    debugLog("Network reachable")
                    dispatch_async(strongSelf.queue) {
                        strongSelf.startQueue(hostURLs: hostURLs)
                    }
            }
        }

        reachability.startMonitoring()
    }

    public func pause() {
        reachability.stopMonitoring()
        dispatch_async(queue, stopQueue)
    }

    public func retrieveReferenceTime(
        queue callbackQueue: dispatch_queue_t = dispatch_get_main_queue(),
        callback: ReferenceTimeCallback
    ) {
        dispatch_async(queue) {
            guard let referenceTime = self.referenceTime else {
                if !self.reachability.online {
                    dispatch_async(callbackQueue) {
                        callback(.Failure(.ConnectionError(underlyingError: .offlineError)))
                    }
                } else {
                    self.callbacks.append((callbackQueue, callback))
                    if self.results.count == self.hosts.count && !self.hosts.isEmpty {
                        self.startQueue(hostURLs: self.hostURLs) // Retry if we failed last time.
                    }
                }
                return
            }

            dispatch_async(callbackQueue) {
                callback(.Success(referenceTime))
            }
        }
    }

    private let queue: dispatch_queue_t = dispatch_queue_create("com.instacart.sntp-client", nil)
    private let reachability = Reachability()
    private var callbacks: [(dispatch_queue_t, ReferenceTimeCallback)] = []
    private var connections: [SNTPConnection] = []
    private var hostURLs: [NSURL] = []
    private var hosts: [SNTPHost] = []
    private var referenceTime: ReferenceTime?
    private var results: [ReferenceTimeResult] = []
    private var startTime: NSTimeInterval?
}

// MARK: - Objective-C Bridging

@objc public final class NTPReferenceTime: NSObject {
    public init(_ referenceTime: ReferenceTime) {
        self.underlyingValue = referenceTime
    }

    public let underlyingValue: ReferenceTime
    public var time: NSDate { return underlyingValue.time }
    public var uptime: timeval { return underlyingValue.uptime }
    public func now() -> NSDate { return underlyingValue.now() }
}

extension SNTPClient {
    @objc public func retrieveReferenceTime(success success: NTPReferenceTime -> Void,
                                            failure: (NSError -> Void)?) {
        retrieveReferenceTime(success: success,
                              failure: failure,
                              onQueue: dispatch_get_main_queue())
    }

    @objc public func retrieveReferenceTime(success success: NTPReferenceTime -> Void,
                                            failure: (NSError -> Void)?,
                                            onQueue queue: dispatch_queue_t) {
        retrieveReferenceTime(queue: queue) { result in
            switch result {
                case let .Success(time):
                    success(NTPReferenceTime(time))
                case let .Failure(error):
                    failure?(error.bridged)
            }
        }
    }
}

private let bridgedErrorDomain = "com.instacart.TrueTimeErrorDomain"
private extension SNTPClientError {
    var bridged: NSError {
        switch self {
            case let .ConnectionError(underlyingError):
                if let underlyingError = underlyingError {
                    return underlyingError
                }
            default:
                break
        }

        let (code, description) = metadata
        return NSError(domain: bridgedErrorDomain,
                       code: code,
                       userInfo: [NSLocalizedDescriptionKey: description])
    }

    var metadata: (Int, String) {
        switch self {
            case .UnresolvableHost:
                return (1, "Unresolvable host name.")
            case .ConnectionError:
                return (2, "Failed connecting to NTP server.")
            case .InvalidResponse:
                return (3, "Unexpected response from NTP server. Try again later.")
        }
    }
}

// MARK: -

private extension SNTPClient {
    var unresolvedHosts: [SNTPHost] {
        return hosts.filter { !$0.isResolved }
    }

    func startQueue(hostURLs hostURLs: [NSURL]) {
        guard self.hostURLs != hostURLs && referenceTime == nil else {
            let started = referenceTime == nil
            debugLog("Already \(started ? "started" : "finished")")
            return
        }

        debugLog("Starting queue with hosts: \(hostURLs)")
        self.hostURLs = hostURLs
        startTime = CFAbsoluteTimeGetCurrent()
        hosts = hostURLs.map { url in  SNTPHost(hostURL: url,
                                                timeout: timeout,
                                                maxRetries: maxRetries,
                                                onComplete: hostCallback,
                                                callbackQueue: queue) }
        throttleHosts()
    }

    func stopQueue() {
        debugLog("Stopping queue")
        hosts.forEach { $0.stop() }
        connections.forEach { $0.close() }
        connections = []
        hostURLs = []
        hosts = []
        results = []
        startTime = nil
    }

    func throttleHosts() -> Bool {
        let isEligible = { [unowned self] (host: SNTPHost) in host.attempts < self.maxRetries }
        let eligibleHosts = unresolvedHosts.filter(isEligible)
        let activeHosts = Array(eligibleHosts[0..<min(maxConnections, eligibleHosts.count)])
        activeHosts.filter { !$0.isStarted }.forEach { $0.resolve() }
        return hosts.contains(isEligible)
    }

    func throttleConnections() {
        let eligibleConnections = connections.filter { $0.attempts < maxRetries }
        let activeConnections = Array(eligibleConnections[0..<min(maxConnections,
                                                                  eligibleConnections.count)])
        activeConnections.filter { !$0.isStarted }.forEach {
            $0.start(self.queue, onComplete: self.connectionCallback)
        }
        debugLog("Starting connections: \(activeConnections) (total: \(connections.count))")
    }

    func hostCallback(result: SNTPHostResult) {
        switch result {
            case let .Success(connections):
                self.connections += connections
                throttleConnections()
            case let .Failure(error):
                debugLog("Got error resolving host, trying next one. \(error)")
                if !throttleHosts() {
                    finish(.Failure(error))
                }
        }
    }

    func connectionCallback(result: ReferenceTimeResult) {
        results.append(result)
        switch result {
            case let .Success(referenceTime):
                self.referenceTime = referenceTime
                fallthrough
            case .Failure where results.count == connections.count && unresolvedHosts.isEmpty:
                self.finish(result)
            default:
                break
        }
    }

    func finish(result: ReferenceTimeResult) {
        dispatch_async(queue) {
            guard !self.hosts.isEmpty else {
                return // Guard against race condition where we receive two times at once.
            }

            let endTime = CFAbsoluteTimeGetCurrent()
            debugLog("\(self.results.count) results: \(self.results)")
            debugLog("Took \(endTime - self.startTime!)s")
            self.callbacks.forEach { (queue, callback) in
                dispatch_async(queue) {
                    callback(result)
                }
            }

            self.callbacks = []
            switch result {
                case .Success: self.stopQueue()
                default: break
            }
        }
    }
}

private let defaultMaxConnections: Int = 3
private let defaultMaxRetries: Int = 5
private let defaultTimeout: NSTimeInterval = 30
