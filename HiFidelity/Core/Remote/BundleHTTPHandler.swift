//
//  BundleHTTPHandler.swift
//  HiFidelity
//
//  Static-file HTTP handler that reads a single file from `Bundle.main`.
//  Avoids FlyingFox's `.directory(_:)` (which is CWD-relative) — sandbox
//  CWDs are unstable and we want a clean Bundle-rooted lookup.
//

import Foundation
import FlyingFox

struct BundleHTTPHandler: HTTPHandler {
    let resourceName: String
    let resourceExtension: String
    let subdirectory: String
    let contentType: String
    let cacheControl: String

    init(
        resourceName: String,
        resourceExtension: String,
        subdirectory: String,
        contentType: String,
        cacheControl: String = "public, max-age=3600"
    ) {
        self.resourceName = resourceName
        self.resourceExtension = resourceExtension
        self.subdirectory = subdirectory
        self.contentType = contentType
        self.cacheControl = cacheControl
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Try the namespaced lookup first (folder reference layout) and
        // fall back to a flat lookup (synchronized group flattens
        // resources). Both are valid Xcode resource layouts.
        let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: subdirectory
        ) ?? Bundle.main.url(
            forResource: resourceName,
            withExtension: resourceExtension
        )
        guard let url else {
            Logger.error("BundleHTTPHandler: missing \(subdirectory)/\(resourceName).\(resourceExtension)")
            return HTTPResponse(statusCode: .notFound)
        }
        do {
            let data = try Data(contentsOf: url)
            let headers: HTTPHeaders = [
                .contentType: contentType,
                HTTPHeader("Cache-Control"): cacheControl
            ]
            return HTTPResponse(statusCode: .ok, headers: headers, body: data)
        } catch {
            Logger.error("BundleHTTPHandler: read failed for \(url.lastPathComponent): \(error)")
            return HTTPResponse(statusCode: .internalServerError)
        }
    }
}
