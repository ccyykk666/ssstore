import Dispatch
import Foundation
import UpdateCore
import Vapor

extension Installer {
    func payloadResponse(for request: Request, path: URL) async throws -> Response {
        let headers: HTTPHeaders = ["Content-Type": "application/octet-stream", "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if request.method == .HEAD {
            // Do not construct or consume a file body for appstored's probes.
            var headHeaders = headers
            headHeaders.replaceOrAdd(name: "Content-Length", value: String(payloadSize))
            logger.info("Local install [\(id)]: payload HEAD probe; size=\(payloadSize), no bytes streamed")
            return Response(status: .ok, version: request.version, headersNoUpdate: headHeaders, body: .empty)
        }

        // Retain Vapor's proven Range, conditional request and file-header logic.
        // Its lazy body has not opened a file yet; replace it with a measured one.
        let response = try await request.fileio.asyncStreamFile(at: path.path, chunkSize: 64 * 1024)
        for (name, value) in headers { response.headers.replaceOrAdd(name: name, value: value) }
        let length = Int64(response.headers.first(name: "Content-Length") ?? "") ?? -1
        let tracker = InstallTransferCoverage(totalBytes: payloadSize)
        guard let range = tracker.responseRange(method: request.method.rawValue, status: Int(response.status.code),
            contentLength: length, contentRange: response.headers.first(name: "Content-Range")) else { return response }
        let generation = await payloadGeneration()
        let responseID = UUID()
        response.body = .init(asyncStream: { stream in
            var cursor = range.lowerBound
            var lastReport: UInt64 = 0
            let started = await self.beginPayloadResponse(responseID, generation: generation)
            guard started else { try? await stream.write(.error(CancellationError())); return }
            logger.info("Local install [\(self.id)]: payload GET begin response=\(responseID) range=\(range.lowerBound)-\(range.upperBound - 1)")
            do {
                let chunks = try await request.fileio.readFile(at: path.path, chunkSize: 64 * 1024,
                    offset: range.lowerBound, byteCount: Int(range.upperBound - range.lowerBound))
                do {
                    for try await chunk in chunks {
                        let count = Int64(chunk.readableBytes)
                        try await stream.writeBuffer(chunk)
                        cursor += count
                        let now = DispatchTime.now().uptimeNanoseconds
                        if now - lastReport >= 200_000_000 || cursor == range.upperBound {
                            await self.recordPayloadWrite(range.lowerBound..<cursor, generation: generation)
                            lastReport = now
                        }
                    }
                    try? await chunks.closeHandle()
                } catch {
                    try? await chunks.closeHandle()
                    throw error
                }
                guard cursor == range.upperBound else { throw Abort(.internalServerError, reason: "Incomplete IPA file read") }
                // The last successful byte write already updates completion. A
                // late end/close callback cannot leave the system activity stuck.
                try await stream.write(.end)
                await self.endPayloadResponse(responseID, generation: generation)
                logger.info("Local install [\(self.id)]: payload response drained response=\(responseID) bytes=\(cursor - range.lowerBound)")
            } catch {
                // Preserve successful prefixes if the client cancels or retries.
                await self.recordPayloadWrite(range.lowerBound..<cursor, generation: generation)
                await self.endPayloadResponse(responseID, generation: generation)
                let details = DiagnosticLog.errorDetails(error)
                if cursor == range.upperBound {
                    logger.debug("Local install [\(self.id)]: connection ended after all response bytes were written response=\(responseID): \(details)")
                } else {
                    logger.warning("Local install [\(self.id)]: payload response interrupted response=\(responseID) written=\(cursor - range.lowerBound)/\(range.upperBound - range.lowerBound); awaiting retry: \(details)")
                }
                try? await stream.write(.error(error))
            }
        }, count: Int(range.upperBound - range.lowerBound), byteBufferAllocator: request.byteBufferAllocator)
        return response
    }
}
