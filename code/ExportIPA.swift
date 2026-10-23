// ExportIPA.swift — Pure Swift IPA exporter for Swift Playgrounds (iPadOS)

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────
// MARK: – CRC-32 (pure Swift, no zlib import needed)
// ─────────────────────────────────────────────────────────────

private let crcTable: [UInt32] = {
    (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1 == 1) ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
}()

private func crc32(_ data: Data) -> UInt32 {
    data.reduce(0xFFFFFFFF) { crc, byte in
        (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
    } ^ 0xFFFFFFFF
}

// ─────────────────────────────────────────────────────────────
// MARK: – Mini ZIP (STORE, no compression — fully compatible)
// ─────────────────────────────────────────────────────────────

private struct MiniZip {
    
    private static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
    
    private static func localHeader(name: Data, size: UInt32, crc: UInt32) -> Data {
        var h = Data()
        h += [0x50, 0x4B, 0x03, 0x04]   // local file signature
        h += le16(20)                     // version needed: 2.0
        h += le16(0)                      // flags
        h += le16(0)                      // compression: STORE
        h += le16(0); h += le16(0)        // mod time / date
        h += le32(crc)
        h += le32(size)                   // compressed size
        h += le32(size)                   // uncompressed size
        h += le16(UInt16(name.count))
        h += le16(0)                      // extra field length
        h += name
        return h
    }
    
    private static func centralHeader(name: Data, size: UInt32, crc: UInt32,
                                      offset: UInt32, isDir: Bool) -> Data {
        var h = Data()
        h += [0x50, 0x4B, 0x01, 0x02]   // central dir signature
        h += le16(20); h += le16(20)      // version made by / needed
        h += le16(0)                      // flags
        h += le16(0)                      // compression: STORE
        h += le16(0); h += le16(0)        // mod time / date
        h += le32(crc)
        h += le32(size)
        h += le32(size)
        h += le16(UInt16(name.count))
        h += le16(0)                      // extra length
        h += le16(0)                      // comment length
        h += le16(0)                      // disk number start
        h += le16(0)                      // internal attributes
        h += le32(isDir ? 0x10 : 0)       // external attributes
        h += le32(offset)
        h += name
        return h
    }
    
    private static func endRecord(count: UInt16, cdSize: UInt32, cdOffset: UInt32) -> Data {
        var h = Data()
        h += [0x50, 0x4B, 0x05, 0x06]
        h += le16(0); h += le16(0)
        h += le16(count); h += le16(count)
        h += le32(cdSize)
        h += le32(cdOffset)
        h += le16(0)
        return h
    }
    
    // Build the full ZIP Data from a Payload directory on disk.
    static func build(from payloadDir: URL) throws -> Data {
        let base = payloadDir.deletingLastPathComponent() // …/tmp/UUID/
        
        struct Entry { let zipPath: String; let data: Data; let crc: UInt32; let offset: UInt32 }
        var entries: [Entry] = []
        var body = Data()
        
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: payloadDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { throw NSError(domain: "MiniZip", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot enumerate Payload"]) }
        
        for case let url as URL in enumerator {
            let rv = try url.resourceValues(forKeys: Set(keys))
            // Build the ZIP-internal path (relative to base, e.g. "Payload/YT for TV.app/Info.plist")
            var zipPath = url.path
            let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
            if zipPath.hasPrefix(basePath) { zipPath = String(zipPath.dropFirst(basePath.count)) }
            
            if rv.isSymbolicLink == true { continue } // skip symlinks — safe to omit for sideloading
            
            if rv.isDirectory == true {
                let pathData = (zipPath + "/").data(using: .utf8)!
                let offset = UInt32(body.count)
                body += localHeader(name: pathData, size: 0, crc: 0)
                entries.append(Entry(zipPath: zipPath + "/", data: Data(), crc: 0, offset: offset))
            } else if rv.isRegularFile == true {
                let fileData = (try? Data(contentsOf: url)) ?? Data()
                let crc = crc32(fileData)
                let pathData = zipPath.data(using: .utf8)!
                let offset = UInt32(body.count)
                body += localHeader(name: pathData, size: UInt32(fileData.count), crc: crc)
                body += fileData
                entries.append(Entry(zipPath: zipPath, data: fileData, crc: crc, offset: offset))
            }
        }
        
        // Central directory
        let cdOffset = UInt32(body.count)
        var cd = Data()
        for e in entries {
            let pathData = e.zipPath.data(using: .utf8)!
            cd += centralHeader(name: pathData, size: UInt32(e.data.count),
                                crc: e.crc, offset: e.offset,
                                isDir: e.zipPath.hasSuffix("/"))
        }
        body += cd
        body += endRecord(count: UInt16(entries.count),
                          cdSize: UInt32(cd.count),
                          cdOffset: cdOffset)
        return body
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – FileDocument wrapper
// ─────────────────────────────────────────────────────────────

struct IPADocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "ipa") ?? .data]
    }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Export button view
// ─────────────────────────────────────────────────────────────

struct ExportIPAButton: View {
    @State private var showExporter = false
    @State private var ipaDocument: IPADocument?
    @State private var isBuilding   = false
    @State private var errorMsg     = ""
    @State private var showError    = false
    
    var body: some View {
        Button(action: start) {
            HStack(spacing: 6) {
                if isBuilding {
                    ProgressView().tint(.white).scaleEffect(0.8)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
                Text(isBuilding ? "Building…" : "Export IPA")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
        }
        .glassEffect(in: Capsule())
        .disabled(isBuilding)
        .fileExporter(
            isPresented: $showExporter,
            document: ipaDocument,
            contentType: UTType(filenameExtension: "ipa") ?? .data,
            defaultFilename: "YT_for_TV",
            onCompletion: { result in
                if case .failure(let e) = result { errorMsg = e.localizedDescription; showError = true }
            }
        )
        .alert("Export Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMsg) }
    }
    
    private func start() {
        isBuilding = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = buildIPA()
            DispatchQueue.main.async {
                isBuilding = false
                switch result {
                case .success(let doc): ipaDocument = doc; showExporter = true
                case .failure(let e):  errorMsg = e.localizedDescription; showError = true
                }
            }
        }
    }
    
    private func buildIPA() -> Result<IPADocument, Error> {
        do {
            let bundle   = Bundle.main.bundleURL
            let tmp      = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let payload  = tmp.appendingPathComponent("Payload")
            
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundle,
                                             to: payload.appendingPathComponent(bundle.lastPathComponent))
            
            let zipData = try MiniZip.build(from: payload)
            try? FileManager.default.removeItem(at: tmp)
            
            return .success(IPADocument(data: zipData))
        } catch {
            return .failure(error)
        }
    }
}
