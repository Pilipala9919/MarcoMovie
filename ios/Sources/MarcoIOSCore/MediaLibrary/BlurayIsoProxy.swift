// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network

public struct IsoExtent: Equatable, Hashable, Sendable {
    public let isoOffset: Int64
    public let length: Int64

    public init(isoOffset: Int64, length: Int64) {
        self.isoOffset = isoOffset
        self.length = length
    }
}

public struct IsoFileEntry: Equatable, Hashable, Sendable {
    public let name: String
    public let size: Int64
    public let extents: [IsoExtent]
    public let inlineData: Data?

    public init(name: String, size: Int64, extents: [IsoExtent] = [], inlineData: Data? = nil) {
        self.name = name
        self.size = size
        self.extents = extents
        self.inlineData = inlineData
    }
}

public struct BlurayChapter: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let title: String
    public let positionMs: Int64
    public let durationMs: Int64?

    public init(index: Int, title: String, positionMs: Int64, durationMs: Int64? = nil) {
        self.index = index
        self.title = title
        self.positionMs = positionMs
        self.durationMs = durationMs
    }
}

public struct BlurayPlaylistInfo: Equatable, Hashable, Sendable {
    public let playlistName: String
    public let totalDurationMs: Int64
    public let clipNames: [String]
    public let chapters: [BlurayChapter]
    public let totalBytes: Int64
    public let isDvdVob: Bool

    public init(
        playlistName: String,
        totalDurationMs: Int64,
        clipNames: [String],
        chapters: [BlurayChapter] = [],
        totalBytes: Int64,
        isDvdVob: Bool = false
    ) {
        self.playlistName = playlistName
        self.totalDurationMs = totalDurationMs
        self.clipNames = clipNames
        self.chapters = chapters
        self.totalBytes = totalBytes
        self.isDvdVob = isDvdVob
    }
}

public protocol IsoRangeReader: Sendable {
    func totalLength() async throws -> Int64?
    func readAt(offset: Int64, length: Int) async throws -> Data
    func close() async
}

/// Local file random-access ISO reader backed by `FileHandle`.
public actor LocalFileIsoReader: IsoRangeReader {
    private let fileUrl: URL
    private var handle: FileHandle?
    private var cachedLength: Int64?

    public init(fileUrl: URL) {
        self.fileUrl = fileUrl
    }

    private func ensureOpen() throws -> FileHandle {
        if let h = handle { return h }
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            throw MarcoError.storageError("ISO 文件不存在：\(fileUrl.path)")
        }
        let fh = try FileHandle(forReadingFrom: fileUrl)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileUrl.path)
        cachedLength = (attrs[.size] as? NSNumber)?.int64Value
        handle = fh
        return fh
    }

    public func totalLength() async throws -> Int64? {
        _ = try ensureOpen()
        return cachedLength
    }

    public func readAt(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        let fh = try ensureOpen()
        let total = cachedLength ?? 0
        guard offset < total else { return Data() }
        let toRead = Int(min(Int64(length), total - offset))
        try fh.seek(toOffset: UInt64(offset))
        return try fh.read(upToCount: toRead) ?? Data()
    }

    public func close() async {
        try? handle?.close()
        handle = nil
    }
}

/// In-memory ISO reader for synthetic fixtures and unit tests.
public actor DataIsoReader: IsoRangeReader {
    private let data: Data

    public init(data: Data) {
        self.data = data
    }

    public func totalLength() async throws -> Int64? { Int64(data.count) }

    public func readAt(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0, offset < Int64(data.count) else { return Data() }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }

    public func close() async {}
}

/// HTTP(S) Range reader for remote WebDAV/AList/Emby `.iso` images using iOS 14+ `URLSession.marcoData`.
public actor HttpRangeIsoReader: IsoRangeReader {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private var cachedLength: Int64?

    public init(url: URL, headers: [String: String] = [:], session: URLSession? = nil) {
        self.url = url
        self.headers = headers
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 60
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func totalLength() async throws -> Int64? {
        if let len = cachedLength { return len }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        let (_, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range") {
                if let slash = cr.lastIndex(of: "/"),
                   let total = Int64(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces))
                {
                    cachedLength = total
                }
            } else if http.statusCode == 200, let cl = http.value(forHTTPHeaderField: "Content-Length"), let total = Int64(cl) {
                cachedLength = total
            }
        }
        return cachedLength
    }

    public func readAt(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        if let total = cachedLength, offset >= total { return Data() }
        let end = cachedLength.map { min(offset + Int64(length) - 1, $0 - 1) } ?? (offset + Int64(length) - 1)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let (data, resp) = try await session.marcoData(for: req)
        guard let http = resp as? HTTPURLResponse else { return Data() }
        if http.statusCode == 416 { return Data() }
        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw MarcoError.networkFailure("ISO Range 请求失败 (HTTP \(http.statusCode))")
        }
        if http.statusCode == 200 {
            let start = Int(offset)
            let count = Int(end - offset + 1)
            guard start < data.count else { return Data() }
            return data.subdata(in: start..<min(data.count, start + count))
        }
        return data
    }

    public func close() async {}
}

/// Virtual ISO-9660 (ECMA-119) & UDF 2.50 (ECMA-167) filesystem parser using on-demand 2 KiB sector reads.
public actor IsoFilesystem {
    public static let sectorSize = 2048

    public struct DirectoryEntry: Sendable {
        public let name: String
        public let isDir: Bool
        public let file: IsoFileEntry?
    }

    private struct UdfPartitionMap {
        let partitionNumber: Int
        let isMetadata: Bool
        let metadataFileLoc: Int
        let metadataMirrorLoc: Int
    }

    private let reader: IsoRangeReader
    private var sectorCache: [Int64: Data] = [:]
    public let isUdf: Bool
    private let blockSize: Int

    private var udfPhysPartitions: [Int: (startSector: Int64, lengthSectors: Int64)] = [:]
    private var udfMaps: [Int: UdfPartitionMap] = [:]
    private var udfMetadataExtents: [Int: [IsoExtent]] = [:]
    private var udfRootIcb: (block: Int64, partitionRef: Int)?
    private var iso9660Root: (extentSector: Int64, size: Int64, isJoliet: Bool)?

    private init(reader: IsoRangeReader, isUdf: Bool, blockSize: Int) {
        self.reader = reader
        self.isUdf = isUdf
        self.blockSize = blockSize
    }

    private func readSector(_ sectorIndex: Int64) async throws -> Data {
        if let cached = sectorCache[sectorIndex] { return cached }
        let data = try await reader.readAt(offset: sectorIndex * Int64(Self.sectorSize), length: Self.sectorSize)
        if !data.isEmpty {
            if sectorCache.count >= 256 { sectorCache.removeAll() }
            sectorCache[sectorIndex] = data
        }
        return data
    }

    private func readBytes(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        if length <= Self.sectorSize * 4 {
            let startSec = offset / Int64(Self.sectorSize)
            let endSec = (offset + Int64(length) - 1) / Int64(Self.sectorSize)
            var out = Data()
            for s in startSec...endSec {
                let sec = try await readSector(s)
                if sec.isEmpty { break }
                let secBase = s * Int64(Self.sectorSize)
                let sliceStart = Int(max(0, offset - secBase))
                let sliceEnd = Int(min(Int64(sec.count), offset + Int64(length) - secBase))
                if sliceEnd > sliceStart { out.append(sec.subdata(in: sliceStart..<sliceEnd)) }
            }
            return out
        }
        return try await reader.readAt(offset: offset, length: length)
    }

    public static func mount(reader: IsoRangeReader) async throws -> IsoFilesystem {
        if let udf = try await tryMountUdf(reader: reader) { return udf }
        if let iso = try await tryMountIso9660(reader: reader) { return iso }
        throw MarcoError.invalidFormat("无法识别该镜像的 UDF 2.50 或 ISO-9660 文件系统")
    }

    private static func tryMountUdf(reader: IsoRangeReader) async throws -> IsoFilesystem? {
        let probe = IsoFilesystem(reader: reader, isUdf: true, blockSize: sectorSize)
        var avdp = try await probe.readSector(256)
        if avdp.count < 32 || u16LE(avdp, 0) != 2 {
            if let total = try await reader.totalLength(), total >= Int64(258 * sectorSize) {
                let totalSectors = total / Int64(sectorSize)
                for candidate in [totalSectors - 257, totalSectors - 1] where candidate > 256 {
                    let alt = try await probe.readSector(candidate)
                    if alt.count >= 32 && u16LE(alt, 0) == 2 {
                        avdp = alt
                        break
                    }
                }
            }
        }
        guard avdp.count >= 32, u16LE(avdp, 0) == 2 else { return nil }
        let mvdsLength = Int(u32LE(avdp, 16))
        let mvdsLocation = Int64(u32LE(avdp, 20))
        guard mvdsLength >= sectorSize, mvdsLocation > 0 else { return nil }

        let mvdsSectors = min((mvdsLength + sectorSize - 1) / sectorSize, 64)
        var physParts: [Int: (startSector: Int64, lengthSectors: Int64)] = [:]
        var lvdBlockSize: Int?
        var fsdLength: Int = 0
        var fsdBlock: Int64 = 0
        var fsdPartRef: Int = 0
        var rawMaps: [UdfPartitionMap] = []

        for i in 0..<mvdsSectors {
            let sec = try await probe.readSector(mvdsLocation + Int64(i))
            if sec.count < 16 { break }
            let tagId = u16LE(sec, 0)
            if tagId == 8 { break }
            if tagId == 5 && sec.count >= 196 {
                let partNum = Int(u16LE(sec, 22))
                physParts[partNum] = (Int64(u32LE(sec, 188)), Int64(u32LE(sec, 192)))
            } else if tagId == 6 && sec.count >= 440 {
                let bs = Int(u32LE(sec, 212))
                lvdBlockSize = bs > 0 ? bs : sectorSize
                fsdLength = Int(u32LE(sec, 248))
                fsdBlock = Int64(u32LE(sec, 252))
                fsdPartRef = Int(u16LE(sec, 256))
                let mapTableLen = Int(u32LE(sec, 264))
                let numMaps = Int(u32LE(sec, 268))
                var mapOff = 440
                let mapLimit = min(sec.count, 440 + mapTableLen)
                for _ in 0..<numMaps {
                    guard mapOff + 2 <= mapLimit else { break }
                    let mType = sec[mapOff]
                    let mLen = Int(sec[mapOff + 1])
                    guard mLen >= 2, mapOff + mLen <= mapLimit else { break }
                    if mType == 1 && mLen >= 6 {
                        rawMaps.append(UdfPartitionMap(partitionNumber: Int(u16LE(sec, mapOff + 4)), isMetadata: false, metadataFileLoc: 0, metadataMirrorLoc: 0))
                    } else if mType == 2 && mLen >= 64 {
                        rawMaps.append(UdfPartitionMap(
                            partitionNumber: Int(u16LE(sec, mapOff + 38)),
                            isMetadata: true,
                            metadataFileLoc: Int(u32LE(sec, mapOff + 40)),
                            metadataMirrorLoc: Int(u32LE(sec, mapOff + 44))
                        ))
                    } else {
                        rawMaps.append(UdfPartitionMap(partitionNumber: 0, isMetadata: false, metadataFileLoc: 0, metadataMirrorLoc: 0))
                    }
                    mapOff += mLen
                }
            }
        }

        guard !physParts.isEmpty, let bs = lvdBlockSize, fsdLength > 0 else { return nil }
        let mounted = IsoFilesystem(reader: reader, isUdf: true, blockSize: bs)
        await mounted.configureUdf(physParts: physParts, rawMaps: rawMaps)
        let ok = try await mounted.finishUdfMount(fsdPartRef: fsdPartRef, fsdBlock: fsdBlock)
        return ok ? mounted : nil
    }

    private func configureUdf(physParts: [Int: (startSector: Int64, lengthSectors: Int64)], rawMaps: [UdfPartitionMap]) {
        self.udfPhysPartitions = physParts
        for (i, m) in rawMaps.enumerated() { self.udfMaps[i] = m }
        if udfMaps.isEmpty, let firstKey = physParts.keys.first {
            udfMaps[0] = UdfPartitionMap(partitionNumber: firstKey, isMetadata: false, metadataFileLoc: 0, metadataMirrorLoc: 0)
        }
    }

    private func finishUdfMount(fsdPartRef: Int, fsdBlock: Int64) async throws -> Bool {
        for (i, map) in udfMaps where map.isMetadata {
            guard let phys = udfPhysPartitions[map.partitionNumber] else { continue }
            for cand in [map.metadataFileLoc, map.metadataMirrorLoc] {
                if cand == 0 && map.metadataMirrorLoc != 0 { continue }
                let feOff = (phys.startSector + Int64(cand)) * Int64(blockSize)
                let feBytes = try await readBytes(offset: feOff, length: blockSize)
                if let parsed = try await parseUdfFileEntry(feBytes, defaultPartRef: i, forcePhysPartNum: map.partitionNumber),
                   !parsed.extents.isEmpty
                {
                    udfMetadataExtents[i] = parsed.extents
                    break
                }
            }
        }
        guard let fsdOff = resolveUdfBlockOffset(partRef: fsdPartRef, logicalBlock: fsdBlock) else { return false }
        let fsdBytes = try await readBytes(offset: fsdOff, length: blockSize)
        guard fsdBytes.count >= 416, Self.u16LE(fsdBytes, 0) == 256 else { return false }
        udfRootIcb = (Int64(Self.u32LE(fsdBytes, 404)), Int(Self.u16LE(fsdBytes, 408)))
        return true
    }

    private static func tryMountIso9660(reader: IsoRangeReader) async throws -> IsoFilesystem? {
        let probe = IsoFilesystem(reader: reader, isUdf: false, blockSize: sectorSize)
        var pvd: (bs: Int, sector: Int64, size: Int64)?
        var joliet: (bs: Int, sector: Int64, size: Int64)?

        for secIdx in Int64(16)..<Int64(32) {
            let sec = try await probe.readSector(secIdx)
            guard sec.count >= 190,
                  sec[1] == 0x43, sec[2] == 0x44, sec[3] == 0x30, sec[4] == 0x30, sec[5] == 0x31
            else { break }
            let volType = sec[0]
            if volType == 255 { break }
            if volType == 1 && pvd == nil {
                let bs = Int(u16LE(sec, 128))
                pvd = (bs > 0 ? bs : sectorSize, Int64(u32LE(sec, 158)), Int64(u32LE(sec, 166)))
            } else if volType == 2, sec[88] == 0x25, sec[89] == 0x2F, (sec[90] == 0x40 || sec[90] == 0x43 || sec[90] == 0x45) {
                let bs = Int(u16LE(sec, 128))
                joliet = (bs > 0 ? bs : sectorSize, Int64(u32LE(sec, 158)), Int64(u32LE(sec, 166)))
            }
        }
        if let j = joliet, j.size > 0 {
            let fs = IsoFilesystem(reader: reader, isUdf: false, blockSize: j.bs)
            await fs.setIso9660Root(extentSector: j.sector, size: j.size, isJoliet: true)
            return fs
        }
        if let p = pvd, p.size > 0 {
            let fs = IsoFilesystem(reader: reader, isUdf: false, blockSize: p.bs)
            await fs.setIso9660Root(extentSector: p.sector, size: p.size, isJoliet: false)
            return fs
        }
        return nil
    }

    private func setIso9660Root(extentSector: Int64, size: Int64, isJoliet: Bool) {
        self.iso9660Root = (extentSector, size, isJoliet)
    }

    public func listDirectory(_ pathSegments: [String]) async throws -> [DirectoryEntry] {
        if isUdf { return try await listUdfDirectory(pathSegments) }
        return try await listIso9660Directory(pathSegments)
    }

    public func readFileBytes(_ file: IsoFileEntry, maxBytes: Int = 4 * 1024 * 1024) async throws -> Data {
        if let inline = file.inlineData { return inline }
        let targetLen = Int(min(file.size, Int64(maxBytes)))
        var out = Data()
        for ext in file.extents {
            if out.count >= targetLen { break }
            let need = Int(min(ext.length, Int64(targetLen - out.count)))
            let chunk = try await readBytes(offset: ext.isoOffset, length: need)
            out.append(chunk)
        }
        return out
    }

    private func resolveUdfBlockOffset(partRef: Int, logicalBlock: Int64) -> Int64? {
        guard let map = udfMaps[partRef] else {
            guard let first = udfPhysPartitions.values.first else { return nil }
            return (first.startSector + logicalBlock) * Int64(blockSize)
        }
        if !map.isMetadata {
            guard let phys = udfPhysPartitions[map.partitionNumber] else { return nil }
            return (phys.startSector + logicalBlock) * Int64(blockSize)
        }
        guard let metaExtents = udfMetadataExtents[partRef], !metaExtents.isEmpty else {
            guard let phys = udfPhysPartitions[map.partitionNumber] else { return nil }
            return (phys.startSector + logicalBlock) * Int64(blockSize)
        }
        var byteInMeta = logicalBlock * Int64(blockSize)
        for ext in metaExtents {
            if byteInMeta < ext.length { return ext.isoOffset + byteInMeta }
            byteInMeta -= ext.length
        }
        return nil
    }

    private func parseUdfFileEntry(
        _ fe: Data,
        defaultPartRef: Int,
        forcePhysPartNum: Int? = nil
    ) async throws -> (isDir: Bool, size: Int64, extents: [IsoExtent], inlineData: Data?)? {
        guard fe.count >= 176 else { return nil }
        let tagId = Self.u16LE(fe, 0)
        guard tagId == 261 || tagId == 266 else { return nil }
        let isDir = fe[27] == 4
        let allocType = Int(Self.u16LE(fe, 34) & 0x07)
        let infoLen = Self.u64LE(fe, 56)

        let lEa: Int
        let lAd: Int
        let adBase: Int
        if tagId == 266 {
            guard fe.count >= 216 else { return nil }
            lEa = Int(Self.u32LE(fe, 208))
            lAd = Int(Self.u32LE(fe, 212))
            adBase = 216 + lEa
        } else {
            lEa = Int(Self.u32LE(fe, 168))
            lAd = Int(Self.u32LE(fe, 172))
            adBase = 176 + lEa
        }
        guard adBase <= fe.count, lAd >= 0 else { return nil }
        let adEnd = min(fe.count, adBase + lAd)

        if allocType == 3 {
            let inlineEnd = min(adEnd, adBase + Int(min(infoLen, Int64(fe.count))))
            return (isDir, infoLen, [], fe.subdata(in: adBase..<inlineEnd))
        }

        var extents: [IsoExtent] = []
        var worklist: [(buf: Data, start: Int, end: Int)] = [(fe, adBase, adEnd)]
        while !worklist.isEmpty {
            let item = worklist.removeFirst()
            var pos = item.start
            if allocType == 0 {
                while pos + 8 <= item.end {
                    let rawLen = Self.u32LE(item.buf, pos)
                    let extType = (rawLen >> 30) & 0x03
                    let len = Int64(rawLen & 0x3FFF_FFFF)
                    let blk = Int64(Self.u32LE(item.buf, pos + 4))
                    pos += 8
                    if len == 0 { continue }
                    let isoOff: Int64?
                    if let fpn = forcePhysPartNum {
                        isoOff = udfPhysPartitions[fpn].map { ($0.startSector + blk) * Int64(blockSize) }
                    } else {
                        isoOff = resolveUdfBlockOffset(partRef: defaultPartRef, logicalBlock: blk)
                    }
                    if extType == 3, let off = isoOff {
                        let aed = try await readBytes(offset: off, length: blockSize)
                        if aed.count >= 24 && Self.u16LE(aed, 0) == 258 {
                            let nextLAd = Int(Self.u32LE(aed, 20))
                            worklist.append((aed, 24, min(aed.count, 24 + nextLAd)))
                        }
                    } else if extType == 0, let off = isoOff {
                        extents.append(IsoExtent(isoOffset: off, length: len))
                    }
                }
            } else if allocType == 1 {
                while pos + 16 <= item.end {
                    let rawLen = Self.u32LE(item.buf, pos)
                    let extType = (rawLen >> 30) & 0x03
                    let len = Int64(rawLen & 0x3FFF_FFFF)
                    let blk = Int64(Self.u32LE(item.buf, pos + 4))
                    let pRef = Int(Self.u16LE(item.buf, pos + 8))
                    pos += 16
                    if len == 0 { continue }
                    let isoOff = resolveUdfBlockOffset(partRef: pRef, logicalBlock: blk)
                    if extType == 3, let off = isoOff {
                        let aed = try await readBytes(offset: off, length: blockSize)
                        if aed.count >= 24 && Self.u16LE(aed, 0) == 258 {
                            let nextLAd = Int(Self.u32LE(aed, 20))
                            worklist.append((aed, 24, min(aed.count, 24 + nextLAd)))
                        }
                    } else if extType == 0, let off = isoOff {
                        extents.append(IsoExtent(isoOffset: off, length: len))
                    }
                }
            }
        }
        return (isDir, infoLen, extents, nil)
    }

    private func readUdfDirChildren(block: Int64, partRef: Int) async throws -> [(name: String, isDir: Bool, block: Int64, partRef: Int)] {
        guard let feOff = resolveUdfBlockOffset(partRef: partRef, logicalBlock: block) else { return [] }
        let feBytes = try await readBytes(offset: feOff, length: blockSize)
        guard let parsed = try await parseUdfFileEntry(feBytes, defaultPartRef: partRef), parsed.isDir else { return [] }
        let dirData = try await readFileBytes(IsoFileEntry(name: "", size: parsed.size, extents: parsed.extents, inlineData: parsed.inlineData))
        var out: [(String, Bool, Int64, Int)] = []
        var pos = 0
        while pos + 38 <= dirData.count {
            guard Self.u16LE(dirData, pos) == 257 else { break }
            let chars = dirData[pos + 18]
            let lFi = Int(dirData[pos + 19])
            let childBlk = Int64(Self.u32LE(dirData, pos + 24))
            let childPart = Int(Self.u16LE(dirData, pos + 28))
            let lIu = Int(Self.u16LE(dirData, pos + 36))
            let recordLen = ((38 + lIu + lFi + 3) / 4) * 4
            if pos + 38 + lIu + lFi > dirData.count { break }
            let isDeleted = (chars & 0x04) != 0
            let isParent = (chars & 0x08) != 0
            if !isDeleted && !isParent && lFi > 0 {
                let name = Self.decodeUdfDstring(dirData.subdata(in: (pos + 38 + lIu)..<(pos + 38 + lIu + lFi)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    out.append((name, (chars & 0x02) != 0, childBlk, childPart))
                }
            }
            pos += recordLen
        }
        return out
    }

    private func listUdfDirectory(_ pathSegments: [String]) async throws -> [DirectoryEntry] {
        guard var cur = udfRootIcb else { return [] }

        for seg in pathSegments {
            let target = seg.lowercased()
            let children = try await readUdfDirChildren(block: cur.block, partRef: cur.partitionRef)
            guard let match = children.first(where: { $0.isDir && $0.name.lowercased() == target }) else { return [] }
            cur = (match.block, match.partRef)
        }
        let finalChildren = try await readUdfDirChildren(block: cur.block, partRef: cur.partitionRef)
        var result: [DirectoryEntry] = []
        for c in finalChildren {
            if c.isDir {
                result.append(DirectoryEntry(name: c.name, isDir: true, file: nil))
            } else if let feOff = resolveUdfBlockOffset(partRef: c.partRef, logicalBlock: c.block) {
                let feBytes = try await readBytes(offset: feOff, length: blockSize)
                if let parsed = try await parseUdfFileEntry(feBytes, defaultPartRef: c.partRef), !parsed.isDir {
                    result.append(DirectoryEntry(
                        name: c.name,
                        isDir: false,
                        file: IsoFileEntry(name: c.name, size: parsed.size, extents: parsed.extents, inlineData: parsed.inlineData)
                    ))
                }
            }
        }
        return result
    }

    private func readIso9660Dir(sector: Int64, size: Int64, isJoliet: Bool) async throws -> [(name: String, isDir: Bool, sector: Int64, size: Int64)] {
        let bytes = try await readBytes(offset: sector * Int64(blockSize), length: Int(min(size, 4 * 1024 * 1024)))
        var out: [(String, Bool, Int64, Int64)] = []
        var pos = 0
        while pos < bytes.count {
            let recLen = Int(bytes[pos])
            if recLen == 0 {
                let nextBoundary = ((pos / blockSize) + 1) * blockSize
                if nextBoundary >= bytes.count { break }
                pos = nextBoundary
                continue
            }
            guard pos + 34 <= bytes.count, pos + recLen <= bytes.count else { break }
            let extLoc = Int64(Self.u32LE(bytes, pos + 2))
            let dataLen = Int64(Self.u32LE(bytes, pos + 10))
            let flags = bytes[pos + 25]
            let nameLen = Int(bytes[pos + 32])
            if pos + 33 + nameLen <= bytes.count && nameLen > 0 {
                let rawName = bytes.subdata(in: (pos + 33)..<(pos + 33 + nameLen))
                let isSpecial = nameLen == 1 && (rawName[0] == 0 || rawName[0] == 1)
                if !isSpecial {
                    var name: String
                    if isJoliet {
                        var units: [UInt16] = []
                        var i = 0
                        while i + 1 < rawName.count {
                            units.append((UInt16(rawName[i]) << 8) | UInt16(rawName[i + 1]))
                            i += 2
                        }
                        name = String(utf16CodeUnits: units, count: units.count)
                    } else {
                        name = String(data: rawName, encoding: .isoLatin1) ?? ""
                    }
                    if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
                    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        out.append((name, (flags & 0x02) != 0, extLoc, dataLen))
                    }
                }
            }
            pos += recLen
        }
        return out
    }

    private func listIso9660Directory(_ pathSegments: [String]) async throws -> [DirectoryEntry] {
        guard let root = iso9660Root else { return [] }
        var curSector = root.extentSector
        var curSize = root.size
        let isJoliet = root.isJoliet

        for seg in pathSegments {
            let target = seg.lowercased()
            let children = try await readIso9660Dir(sector: curSector, size: curSize, isJoliet: isJoliet)
            guard let match = children.first(where: { $0.isDir && $0.name.lowercased() == target }) else { return [] }
            curSector = match.sector
            curSize = match.size
        }
        let finalChildren = try await readIso9660Dir(sector: curSector, size: curSize, isJoliet: isJoliet)
        return finalChildren.map { c in
            if c.isDir {
                return DirectoryEntry(name: c.name, isDir: true, file: nil)
            }
            return DirectoryEntry(
                name: c.name,
                isDir: false,
                file: IsoFileEntry(
                    name: c.name,
                    size: c.size,
                    extents: [IsoExtent(isoOffset: c.sector * Int64(blockSize), length: c.size)]
                )
            )
        }
    }

    private static func decodeUdfDstring(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let compId = data[0]
        if compId == 8 { return String(data: data.dropFirst(), encoding: .isoLatin1) ?? "" }
        if compId == 16 {
            let bytes = [UInt8](data.dropFirst())
            var units: [UInt16] = []
            var i = 0
            while i + 1 < bytes.count {
                units.append((UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]))
                i += 2
            }
            return String(utf16CodeUnits: units, count: units.count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func u16LE(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | (UInt16(d[o + 1]) << 8) }
    private static func u32LE(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }
    private static func u64LE(_ d: Data, _ o: Int) -> Int64 {
        Int64(bitPattern: UInt64(u32LE(d, o)) | (UInt64(u32LE(d, o + 4)) << 32))
    }
}

/// Parses Blu-ray `.mpls` playlist binaries (PlayItem clip sequence + PlayListMark chapters)
/// and filters suspected fake/obfuscated loop playlists.
public enum MplsParser {
    public struct ParsedPlaylist: Sendable {
        public let fileName: String
        public let clipNames: [String]
        public let chapters: [BlurayChapter]
        public let totalDurationSeconds: Double
    }

    public static func parse(fileName: String, data: Data) -> ParsedPlaylist? {
        guard data.count >= 40 else { return nil }
        guard String(data: data.subdata(in: 0..<4), encoding: .ascii) == "MPLS" else { return nil }
        let playlistStart = Int(u32BE(data, 8))
        let markStart = Int(u32BE(data, 12))
        guard playlistStart >= 40, playlistStart + 10 <= data.count else { return nil }

        let numPlayItems = Int(u16BE(data, playlistStart + 6))
        var pos = playlistStart + 10
        var items: [(clipName: String, inTicks: UInt32, outTicks: UInt32)] = []
        var itemStartsSec: [Double] = []
        var runningSec = 0.0

        for _ in 0..<numPlayItems {
            guard pos + 2 <= data.count else { break }
            let itemLen = Int(u16BE(data, pos))
            guard itemLen >= 20, pos + 2 + itemLen <= data.count else { break }
            let base = pos + 2
            let clip = (String(data: data.subdata(in: base..<(base + 5)), encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
            let inTime = u32BE(data, base + 14)
            let outTime = u32BE(data, base + 18)
            let durSec = outTime > inTime ? Double(outTime - inTime) / 45_000.0 : 0.0
            itemStartsSec.append(runningSec)
            runningSec += durSec
            items.append((clip, inTime, outTime))
            pos += 2 + itemLen
        }
        guard !items.isEmpty else { return nil }

        var rawMarksMs: [Int64] = []
        if markStart > 0 && markStart + 6 <= data.count {
            let numMarks = Int(u16BE(data, markStart + 4))
            var mPos = markStart + 6
            for _ in 0..<numMarks {
                guard mPos + 14 <= data.count else { break }
                let markType = data[mPos + 1]
                let refIdx = Int(u16BE(data, mPos + 2))
                let markTs = u32BE(data, mPos + 4)
                mPos += 14
                if markType == 0x01 && refIdx < items.count {
                    let it = items[refIdx]
                    let relTicks = markTs >= it.inTicks ? Double(markTs - it.inTicks) : 0.0
                    let absMs = Int64(((itemStartsSec[refIdx] + relTicks / 45_000.0) * 1000.0).rounded())
                    rawMarksMs.append(absMs)
                }
            }
        }
        rawMarksMs.sort()

        var dedupMs: [Int64] = []
        for ms in rawMarksMs {
            if let last = dedupMs.last, abs(ms - last) < 500 { continue }
            dedupMs.append(ms)
        }
        let totalMs = Int64((runningSec * 1000.0).rounded())
        var chapters: [BlurayChapter] = []
        for (i, posMs) in dedupMs.enumerated() {
            let nextMs = (i + 1 < dedupMs.count) ? dedupMs[i + 1] : totalMs
            let dur = max(0, nextMs - posMs)
            chapters.append(BlurayChapter(index: i, title: "第 \(i + 1) 章", positionMs: posMs, durationMs: dur))
        }

        return ParsedPlaylist(
            fileName: fileName,
            clipNames: items.map(\.clipName),
            chapters: chapters,
            totalDurationSeconds: runningSec
        )
    }

    public static func isSuspectedFakeLoopPlaylist(_ pl: ParsedPlaylist) -> Bool {
        let clips = pl.clipNames
        guard clips.count > 1 else { return false }
        var counts: [String: Int] = [:]
        var consecutiveDupes = 0
        for (i, clip) in clips.enumerated() {
            let k = clip.uppercased()
            counts[k, default: 0] += 1
            if i > 0 && clips[i - 1].uppercased() == k { consecutiveDupes += 1 }
        }
        if consecutiveDupes >= 2 { return true }
        if (counts.values.max() ?? 0) >= 3 { return true }
        if clips.count >= 6 && Double(counts.count) * 1.5 < Double(clips.count) { return true }
        if clips.count > 40 && Double(counts.count) < Double(clips.count) * 0.7 { return true }
        return false
    }

    private static func u16BE(_ d: Data, _ o: Int) -> UInt16 { (UInt16(d[o]) << 8) | UInt16(d[o + 1]) }
    private static func u32BE(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16) | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
    }
}

/// Active loopback HTTP 206 virtual stream lease serving a Blu-ray `.m2ts` or DVD `.vob` playlist
/// directly out of a local/remote `.iso` image via targeted Range reads.
public final class BlurayIsoLease: @unchecked Sendable {
    private struct VirtualSegment: Sendable {
        let virtualStart: Int64
        let virtualEnd: Int64
        let file: IsoFileEntry
    }

    public let url: URL
    public let playlistInfo: BlurayPlaylistInfo
    private let listener: NWListener
    private let reader: IsoRangeReader
    private let segments: [VirtualSegment]
    private let capability: String
    private let contentType: String
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.bluray-iso")
    private let lock = NSLock()
    private var closed = false

    private init(
        listener: NWListener,
        port: UInt16,
        reader: IsoRangeReader,
        segments: [VirtualSegment],
        playlistInfo: BlurayPlaylistInfo,
        capability: String,
        fileExt: String,
        contentType: String
    ) {
        self.listener = listener
        self.reader = reader
        self.segments = segments
        self.playlistInfo = playlistInfo
        self.capability = capability
        self.contentType = contentType
        self.url = URL(string: "http://127.0.0.1:\(port)/\(capability)/stream\(fileExt)")!
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed {
            listener.cancel()
            let r = reader
            Task { await r.close() }
        }
    }

    public static func isIsoTarget(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pathOnly = (URL(string: trimmed)?.path ?? trimmed.components(separatedBy: "?").first ?? trimmed).lowercased()
        return pathOnly.hasSuffix(".iso")
    }

    public static func open(reader: IsoRangeReader) async throws -> BlurayIsoLease {
        let fs = try await IsoFilesystem.mount(reader: reader)

        // 1. Try Blu-ray BDMV/PLAYLIST + BDMV/STREAM
        let playlistsDir = try await fs.listDirectory(["BDMV", "PLAYLIST"])
        let streamDir = try await fs.listDirectory(["BDMV", "STREAM"])
        var streamMap: [String: IsoFileEntry] = [:]
        for entry in streamDir where !entry.isDir {
            if let f = entry.file { streamMap[entry.name.uppercased()] = f }
        }

        var chosenFiles: [IsoFileEntry] = []
        var chosenInfo: BlurayPlaylistInfo?

        if !playlistsDir.isEmpty && !streamMap.isEmpty {
            var parsedLists: [MplsParser.ParsedPlaylist] = []
            for entry in playlistsDir where !entry.isDir && entry.name.lowercased().hasSuffix(".mpls") {
                if let f = entry.file, let bytes = try? await fs.readFileBytes(f, maxBytes: 1024 * 1024),
                   let parsed = MplsParser.parse(fileName: entry.name, data: bytes)
                {
                    parsedLists.append(parsed)
                }
            }
            let nonFake = parsedLists.filter { !MplsParser.isSuspectedFakeLoopPlaylist($0) }
            let pool = nonFake.isEmpty ? parsedLists : nonFake
            if let best = pool.max(by: { $0.totalDurationSeconds < $1.totalDurationSeconds }) {
                var files: [IsoFileEntry] = []
                for clip in best.clipNames {
                    if let f = streamMap["\(clip.uppercased()).M2TS"] { files.append(f) }
                }
                if !files.isEmpty {
                    let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
                    chosenFiles = files
                    chosenInfo = BlurayPlaylistInfo(
                        playlistName: best.fileName,
                        totalDurationMs: Int64((best.totalDurationSeconds * 1000.0).rounded()),
                        clipNames: best.clipNames,
                        chapters: best.chapters,
                        totalBytes: totalBytes,
                        isDvdVob: false
                    )
                }
            }
        }

        // 2. Fallback: largest .m2ts in BDMV/STREAM
        if chosenFiles.isEmpty, let largest = streamMap.values.max(by: { $0.size < $1.size }) {
            chosenFiles = [largest]
            chosenInfo = BlurayPlaylistInfo(
                playlistName: largest.name,
                totalDurationMs: 0,
                clipNames: [largest.name],
                totalBytes: largest.size,
                isDvdVob: false
            )
        }

        // 3. Fallback: DVD VIDEO_TS/*.VOB
        if chosenFiles.isEmpty {
            let vobDir = try await fs.listDirectory(["VIDEO_TS"])
            let vobs = vobDir
                .compactMap(\.file)
                .filter { $0.name.uppercased().hasSuffix(".VOB") && !$0.name.uppercased().hasSuffix("_0.VOB") }
                .sorted { $0.name < $1.name }
            if !vobs.isEmpty {
                let totalBytes = vobs.reduce(Int64(0)) { $0 + $1.size }
                chosenFiles = vobs
                chosenInfo = BlurayPlaylistInfo(
                    playlistName: "VIDEO_TS",
                    totalDurationMs: 0,
                    clipNames: vobs.map(\.name),
                    totalBytes: totalBytes,
                    isDvdVob: true
                )
            }
        }

        guard let info = chosenInfo, !chosenFiles.isEmpty else {
            await reader.close()
            throw MarcoError.invalidFormat("ISO 镜像中未找到可播放的蓝光 BDMV 或 DVD VIDEO_TS 流")
        }

        var segments: [VirtualSegment] = []
        var cursor: Int64 = 0
        for f in chosenFiles where f.size > 0 {
            segments.append(VirtualSegment(virtualStart: cursor, virtualEnd: cursor + f.size - 1, file: f))
            cursor += f.size
        }

        var capBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<capBytes.count { capBytes[i] = UInt8.random(in: 0...255) }
        let capability = capBytes.map { String(format: "%02x", $0) }.joined()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let nwListener = try NWListener(using: params)
        let startQueue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.bluray-iso.start")

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = MarcoOnceFlag()
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.tryClaim() else { return }
                    if let p = nwListener.port?.rawValue, p > 0 { cont.resume(returning: p) }
                    else { cont.resume(throwing: MarcoError.networkFailure("蓝光代理端口分配失败")) }
                case .failed(let err):
                    guard once.tryClaim() else { return }
                    cont.resume(throwing: MarcoError.networkFailure("蓝光代理启动失败：\(err)"))
                case .cancelled:
                    guard once.tryClaim() else { return }
                    cont.resume(throwing: MarcoError.networkFailure("蓝光代理已关闭"))
                default: break
                }
            }
            nwListener.start(queue: startQueue)
        }

        let lease = BlurayIsoLease(
            listener: nwListener,
            port: boundPort,
            reader: reader,
            segments: segments,
            playlistInfo: info,
            capability: capability,
            fileExt: info.isDvdVob ? ".vob" : ".m2ts",
            contentType: info.isDvdVob ? "video/mpeg" : "video/mp2t"
        )
        nwListener.newConnectionHandler = { [weak lease] conn in
            lease?.handleConnection(conn)
        }
        return lease
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, err in
            guard let self = self, err == nil, let data = data, !data.isEmpty else {
                conn.cancel()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            guard let reqLine = lines.first else { conn.cancel(); return }
            let parts = reqLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { conn.cancel(); return }
            let method = parts[0].uppercased()
            let path = parts[1].components(separatedBy: "?").first ?? parts[1]
            guard (method == "GET" || method == "HEAD"), path == self.url.path else {
                let nf = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(nf.utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            var rangeHeader: String?
            for line in lines.dropFirst() {
                if let c = line.firstIndex(of: ":"),
                   line[..<c].trimmingCharacters(in: .whitespaces).lowercased() == "range"
                {
                    rangeHeader = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
            }
            Task { await self.serveRange(method: method, rangeHeader: rangeHeader, connection: conn) }
        }
    }

    private func serveRange(method: String, rangeHeader: String?, connection: NWConnection) async {
        let total = playlistInfo.totalBytes
        let reqStart: Int64
        let reqEnd: Int64
        let isRange: Bool
        if let raw = rangeHeader, raw.lowercased().hasPrefix("bytes=") {
            let spec = String(raw.dropFirst(6)).components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let dashParts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if dashParts.count == 2, let s = Int64(dashParts[0]), s >= 0, s < total {
                let e = dashParts[1].isEmpty ? (total - 1) : min(Int64(dashParts[1]) ?? (total - 1), total - 1)
                reqStart = s; reqEnd = max(s, e); isRange = true
            } else {
                reqStart = 0; reqEnd = max(0, total - 1); isRange = false
            }
        } else {
            reqStart = 0; reqEnd = max(0, total - 1); isRange = false
        }

        let contentLen = total > 0 ? (reqEnd - reqStart + 1) : 0
        var hdrLines = [
            "HTTP/1.1 \(isRange ? "206 Partial Content" : "200 OK")",
            "Accept-Ranges: bytes",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLen)",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        if isRange { hdrLines.append("Content-Range: bytes \(reqStart)-\(reqEnd)/\(total)") }
        let hdrData = Data((hdrLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        guard await sendData(hdrData, on: connection) else { connection.cancel(); return }
        if method == "HEAD" || contentLen == 0 {
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        var cursor = reqStart
        for seg in segments where cursor <= reqEnd {
            if cursor > seg.virtualEnd { continue }
            let segEndWant = min(reqEnd, seg.virtualEnd)
            var inFileOffset = cursor - seg.virtualStart
            let inFileEnd = segEndWant - seg.virtualStart

            if let inline = seg.file.inlineData {
                let slice = inline.subdata(in: Int(inFileOffset)..<Int(inFileEnd + 1))
                guard await sendData(slice, on: connection) else { connection.cancel(); return }
                cursor += Int64(slice.count)
                continue
            }

            var extBase: Int64 = 0
            for ext in seg.file.extents where cursor <= segEndWant {
                let extEnd = extBase + ext.length - 1
                if inFileOffset <= extEnd {
                    var extOff = ext.isoOffset + (inFileOffset - extBase)
                    var rem = min(extEnd, inFileEnd) - inFileOffset + 1
                    while rem > 0 {
                        let take = Int(min(rem, 256 * 1024))
                        guard let chunk = try? await reader.readAt(offset: extOff, length: take), !chunk.isEmpty else {
                            connection.cancel()
                            return
                        }
                        guard await sendData(chunk, on: connection) else { connection.cancel(); return }
                        extOff += Int64(chunk.count)
                        inFileOffset += Int64(chunk.count)
                        cursor += Int64(chunk.count)
                        rem -= Int64(chunk.count)
                    }
                }
                extBase += ext.length
            }
        }
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendData(_ data: Data, on conn: NWConnection) async -> Bool {
        await withCheckedContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { err in
                cont.resume(returning: err == nil)
            })
        }
    }
}
