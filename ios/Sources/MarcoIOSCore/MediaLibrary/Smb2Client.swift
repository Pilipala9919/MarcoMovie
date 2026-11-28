// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import Network

public struct Smb2Entry: Equatable, Hashable, Sendable {
    public let name: String
    public let relativePath: String
    public let isDir: Bool
    public let size: Int64

    public init(name: String, relativePath: String, isDir: Bool, size: Int64) {
        self.name = name
        self.relativePath = relativePath
        self.isDir = isDir
        self.size = size
    }
}

public struct Smb2FileHandle: Equatable, Sendable {
    public let fileId: Data
    public let size: Int64

    public init(fileId: Data, size: Int64) {
        self.fileId = fileId
        self.size = size
    }
}

public struct Smb2Error: LocalizedError, Sendable {
    public let status: UInt32
    public let message: String

    public init(_ message: String, status: UInt32 = 0) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Pure-Swift SMB2/SMB2.1 client over TCP (default port 445) using Apple `Network.framework`,
/// with RFC 1320 MD4 + MS-NLMP NTLMv2 and Guest/Anonymous authentication, directory enumeration,
/// and random-access byte-range file reads.
public actor Smb2Client {
    private static let cmdNegotiate: UInt16 = 0x0000
    private static let cmdSessionSetup: UInt16 = 0x0001
    private static let cmdTreeConnect: UInt16 = 0x0003
    private static let cmdCreate: UInt16 = 0x0005
    private static let cmdClose: UInt16 = 0x0006
    private static let cmdRead: UInt16 = 0x0008
    private static let cmdQueryDirectory: UInt16 = 0x000E

    private static let statusSuccess: UInt32 = 0x0000_0000
    private static let statusMoreProcessing: UInt32 = 0xC000_0016
    private static let statusNoMoreFiles: UInt32 = 0x8000_0006
    private static let statusEndOfFile: UInt32 = 0xC000_0011
    private static let statusAccessDenied: UInt32 = 0xC000_0022
    private static let statusLogonFailure: UInt32 = 0xC000_006D
    private static let statusBadNetworkName: UInt32 = 0xC000_00CC
    private static let statusObjectNameNotFound: UInt32 = 0xC000_0034

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.ios.smb2")
    private var readBuffer = Data()
    private var messageId: UInt64 = 0
    private var sessionId: UInt64 = 0
    private var treeId: UInt32 = 0
    private var maxReadSize: Int = 65_536
    private var closed = false

    private init(connection: NWConnection) {
        self.connection = connection
    }

    public static func connect(
        host: String,
        port: UInt16 = 445,
        share: String,
        username: String = "",
        password: String = "",
        domain: String = ""
    ) async throws -> Smb2Client {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanShare = share
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanHost.isEmpty else { throw Smb2Error("请输入有效的 SMB 服务器地址") }
        guard !cleanShare.isEmpty else { throw Smb2Error("请填写 SMB 共享目录名称（例如 Movies）") }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Smb2Error("SMB 端口号无效")
        }

        let conn = NWConnection(host: NWEndpoint.Host(cleanHost), port: nwPort, using: .tcp)
        let client = Smb2Client(connection: conn)
        do {
            try await client.startConnection()
            try await client.negotiate()
            try await client.authenticate(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                domain: domain.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try await client.treeConnect(host: cleanHost, share: cleanShare)
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        readBuffer.removeAll(keepingCapacity: false)
    }

    public func listDirectory(_ relativePath: String) async throws -> [Smb2Entry] {
        let normalized = Self.normalizeSmbPath(relativePath)
        let handle = try await create(smbPath: normalized, isDirectory: true)
        var results: [Smb2Entry] = []
        do {
            var restart = true
            while true {
                var body = Data(count: 34)
                Self.writeU16LE(&body, at: 0, 33) // StructureSize
                body[2] = 0x03 // FileBothDirectoryInformation
                body[3] = restart ? 0x01 : 0x00
                Self.writeU32LE(&body, at: 4, 0)
                body.replaceSubrange(8..<24, with: handle.fileId.prefix(16))
                Self.writeU16LE(&body, at: 24, 96) // 64 + 32
                Self.writeU16LE(&body, at: 26, 2)  // "*" UTF-16LE
                Self.writeU32LE(&body, at: 28, 65_536)
                body[32] = 0x2A
                body[33] = 0x00

                let resp = try await exchange(command: Self.cmdQueryDirectory, body: body)
                restart = false
                if resp.status == Self.statusNoMoreFiles { break }
                if resp.status != Self.statusSuccess {
                    throw Smb2Error(Self.describeStatus(resp.status, fallback: "读取 SMB 目录失败"), status: resp.status)
                }
                guard resp.payload.count >= 8 else { break }
                let outOff = Int(Self.readU16LE(resp.payload, at: 2))
                let outLen = Int(Self.readU32LE(resp.payload, at: 4))
                let start = outOff - 64
                guard start >= 0, outLen > 0, start + outLen <= resp.payload.count else { break }
                let buf = resp.payload.subdata(in: start..<(start + outLen))
                var pos = 0
                while pos + 94 <= buf.count {
                    let nextOff = Int(Self.readU32LE(buf, at: pos))
                    let endOfFile = Self.readI64LE(buf, at: pos + 40)
                    let attrs = Self.readU32LE(buf, at: pos + 56)
                    let nameLen = Int(Self.readU32LE(buf, at: pos + 60))
                    let nameStart = pos + 94
                    if nameLen > 0 && nameStart + nameLen <= buf.count {
                        let name = Self.decodeUtf16LE(buf.subdata(in: nameStart..<(nameStart + nameLen)))
                        if name != "." && name != ".." && !name.isEmpty {
                            let isDir = (attrs & 0x0000_0010) != 0
                            let childPath = normalized.isEmpty ? name : "\(normalized)/\(name)"
                            results.append(
                                Smb2Entry(
                                    name: name,
                                    relativePath: childPath.replacingOccurrences(of: "\\", with: "/"),
                                    isDir: isDir,
                                    size: max(0, endOfFile)
                                )
                            )
                        }
                    }
                    if nextOff == 0 { break }
                    pos += nextOff
                }
            }
            await closeHandle(handle.fileId)
        } catch {
            await closeHandle(handle.fileId)
            throw error
        }

        results.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.lowercased() < b.name.lowercased()
        }
        return results
    }

    public func openFile(_ relativePath: String) async throws -> Smb2FileHandle {
        try await create(smbPath: Self.normalizeSmbPath(relativePath), isDirectory: false)
    }

    public func readFileChunk(handle: Smb2FileHandle, offset: UInt64, length: Int) async throws -> Data {
        let safeLen = min(length, min(maxReadSize, 65_536))
        guard safeLen > 0 else { return Data() }
        var body = Data(count: 49)
        Self.writeU16LE(&body, at: 0, 49)
        Self.writeU32LE(&body, at: 4, UInt32(safeLen))
        Self.writeU64LE(&body, at: 8, offset)
        body.replaceSubrange(16..<32, with: handle.fileId.prefix(16))

        let resp = try await exchange(command: Self.cmdRead, body: body)
        if resp.status == Self.statusEndOfFile { return Data() }
        guard resp.status == Self.statusSuccess else {
            throw Smb2Error(Self.describeStatus(resp.status, fallback: "读取 SMB 文件内容失败"), status: resp.status)
        }
        guard resp.payload.count >= 16 else { return Data() }
        let dataOff = Int(resp.payload[2])
        let dataLen = Int(Self.readU32LE(resp.payload, at: 4))
        let start = dataOff - 64
        guard start >= 0, dataLen > 0, start + dataLen <= resp.payload.count else { return Data() }
        return resp.payload.subdata(in: start..<(start + dataLen))
    }

    public func closeFile(_ handle: Smb2FileHandle) async {
        await closeHandle(handle.fileId)
    }

    // MARK: - SMB2 Wire Operations

    private func startConnection() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = MarcoOnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.tryClaim() else { return }
                    cont.resume(returning: ())
                case .failed(let err):
                    guard once.tryClaim() else { return }
                    cont.resume(throwing: Smb2Error("SMB 连接失败：\(err)"))
                case .cancelled:
                    guard once.tryClaim() else { return }
                    cont.resume(throwing: Smb2Error("SMB 连接已取消"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func negotiate() async throws {
        let dialects: [UInt16] = [0x0202, 0x0210]
        var body = Data(count: 36 + dialects.count * 2)
        Self.writeU16LE(&body, at: 0, 36)
        Self.writeU16LE(&body, at: 2, UInt16(dialects.count))
        Self.writeU16LE(&body, at: 4, 1)
        for i in 0..<16 { body[12 + i] = UInt8.random(in: 0...255) }
        for (idx, d) in dialects.enumerated() {
            Self.writeU16LE(&body, at: 36 + idx * 2, d)
        }
        let resp = try await exchange(command: Self.cmdNegotiate, body: body)
        guard resp.status == Self.statusSuccess else {
            throw Smb2Error(Self.describeStatus(resp.status, fallback: "SMB2 协议协商失败"), status: resp.status)
        }
        if resp.payload.count >= 36 {
            let serverMaxRead = Int(Self.readU32LE(resp.payload, at: 32))
            if serverMaxRead >= 4096 {
                maxReadSize = min(serverMaxRead, 256 * 1024)
            }
        }
    }

    private func authenticate(username: String, password: String, domain: String) async throws {
        let type1 = Self.buildNtlmType1()
        let resp1 = try await sendSessionSetup(secBuf: type1)
        if resp1.status == Self.statusSuccess {
            sessionId = resp1.sessionId
            return
        }
        guard resp1.status == Self.statusMoreProcessing else {
            throw Smb2Error(Self.describeStatus(resp1.status, fallback: "SMB 会话认证初始化失败"), status: resp1.status)
        }
        sessionId = resp1.sessionId
        let secBuf = Self.extractSecurityBuffer(resp1.payload)
        let parsed = try Self.parseNtlmType2(secBuf)
        let type3 = Self.buildNtlmType3(
            username: username,
            password: password,
            domain: domain,
            serverChallenge: parsed.serverChallenge,
            targetInfo: parsed.targetInfo
        )
        let resp2 = try await sendSessionSetup(secBuf: type3)
        guard resp2.status == Self.statusSuccess else {
            throw Smb2Error(Self.describeStatus(resp2.status, fallback: "SMB 认证失败，请检查账号或密码"), status: resp2.status)
        }
        sessionId = resp2.sessionId
    }

    private func sendSessionSetup(secBuf: Data) async throws -> (status: UInt32, treeId: UInt32, sessionId: UInt64, payload: Data) {
        var body = Data(count: 24 + secBuf.count)
        Self.writeU16LE(&body, at: 0, 25)
        body[3] = 1
        Self.writeU16LE(&body, at: 12, 88) // 64 + 24
        Self.writeU16LE(&body, at: 14, UInt16(secBuf.count))
        body.replaceSubrange(24..<(24 + secBuf.count), with: secBuf)
        return try await exchange(command: Self.cmdSessionSetup, body: body)
    }

    private func treeConnect(host: String, share: String) async throws {
        let unc = Self.encodeUtf16LE("\\\\\(host)\\\(share)")
        var body = Data(count: 8 + unc.count)
        Self.writeU16LE(&body, at: 0, 9)
        Self.writeU16LE(&body, at: 4, 72) // 64 + 8
        Self.writeU16LE(&body, at: 6, UInt16(unc.count))
        body.replaceSubrange(8..<(8 + unc.count), with: unc)
        let resp = try await exchange(command: Self.cmdTreeConnect, body: body)
        guard resp.status == Self.statusSuccess else {
            throw Smb2Error(Self.describeStatus(resp.status, fallback: "连接 SMB 共享目录「\(share)」失败"), status: resp.status)
        }
        treeId = resp.treeId
    }

    private func create(smbPath: String, isDirectory: Bool) async throws -> Smb2FileHandle {
        let nameBytes = Self.encodeUtf16LE(smbPath)
        var body = Data(count: 56 + max(1, nameBytes.count))
        Self.writeU16LE(&body, at: 0, 57)
        Self.writeU32LE(&body, at: 4, 2)
        Self.writeU32LE(&body, at: 24, isDirectory ? 0x0010_0081 : 0x0012_0089)
        Self.writeU32LE(&body, at: 28, isDirectory ? 0x0000_0010 : 0x0000_0080)
        Self.writeU32LE(&body, at: 32, 0x0000_0007)
        Self.writeU32LE(&body, at: 36, 1)
        Self.writeU32LE(&body, at: 40, isDirectory ? 0x0000_0001 : 0x0000_0040)
        Self.writeU16LE(&body, at: 44, 120) // 64 + 56
        Self.writeU16LE(&body, at: 46, UInt16(nameBytes.count))
        if !nameBytes.isEmpty {
            body.replaceSubrange(56..<(56 + nameBytes.count), with: nameBytes)
        }
        let resp = try await exchange(command: Self.cmdCreate, body: body)
        guard resp.status == Self.statusSuccess else {
            throw Smb2Error(
                Self.describeStatus(resp.status, fallback: isDirectory ? "无法打开 SMB 目录" : "无法打开 SMB 文件"),
                status: resp.status
            )
        }
        guard resp.payload.count >= 80 else { throw Smb2Error("SMB CREATE 响应格式无效") }
        let eof = Self.readI64LE(resp.payload, at: 48)
        let fid = resp.payload.subdata(in: 64..<80)
        return Smb2FileHandle(fileId: fid, size: max(0, eof))
    }

    private func closeHandle(_ fileId: Data) async {
        guard !closed else { return }
        var body = Data(count: 24)
        Self.writeU16LE(&body, at: 0, 24)
        body.replaceSubrange(8..<24, with: fileId.prefix(16))
        _ = try? await exchange(command: Self.cmdClose, body: body)
    }

    private func exchange(command: UInt16, body: Data) async throws -> (status: UInt32, treeId: UInt32, sessionId: UInt64, payload: Data) {
        let msgId = messageId
        messageId &+= 1
        let packetLen = 64 + body.count
        var frame = Data(count: 4 + packetLen)
        frame[0] = 0x00
        frame[1] = UInt8((packetLen >> 16) & 0xFF)
        frame[2] = UInt8((packetLen >> 8) & 0xFF)
        frame[3] = UInt8(packetLen & 0xFF)

        frame[4] = 0xFE; frame[5] = 0x53; frame[6] = 0x4D; frame[7] = 0x42
        Self.writeU16LE(&frame, at: 4 + 4, 64)
        Self.writeU16LE(&frame, at: 4 + 6, 1)
        Self.writeU16LE(&frame, at: 4 + 12, command)
        Self.writeU16LE(&frame, at: 4 + 14, 64)
        Self.writeU64LE(&frame, at: 4 + 24, msgId)
        Self.writeU32LE(&frame, at: 4 + 36, treeId)
        Self.writeU64LE(&frame, at: 4 + 40, sessionId)
        frame.replaceSubrange(68..<(68 + body.count), with: body)

        try await sendAll(frame)
        let respBytes = try await readFrame()
        guard respBytes.count >= 64,
              respBytes[0] == 0xFE, respBytes[1] == 0x53, respBytes[2] == 0x4D, respBytes[3] == 0x42
        else {
            throw Smb2Error("服务器返回的不是有效的 SMB2 协议响应")
        }
        let status = Self.readU32LE(respBytes, at: 8)
        let rTreeId = Self.readU32LE(respBytes, at: 36)
        let rSessionId = Self.readU64LE(respBytes, at: 40)
        return (status, rTreeId, rSessionId, respBytes.subdata(in: 64..<respBytes.count))
    }

    private func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: Smb2Error("SMB 发送失败：\(err)")) }
                else { cont.resume(returning: ()) }
            })
        }
    }

    private func readExact(_ count: Int) async throws -> Data {
        while readBuffer.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, err in
                    if let err = err {
                        cont.resume(throwing: Smb2Error("SMB 接收失败：\(err)"))
                        return
                    }
                    if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                        return
                    }
                    if isComplete {
                        cont.resume(throwing: Smb2Error("SMB 连接已断开"))
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            if chunk.isEmpty { throw Smb2Error("SMB 连接意外中断") }
            readBuffer.append(chunk)
        }
        let out = readBuffer.subdata(in: 0..<count)
        readBuffer.removeSubrange(0..<count)
        return out
    }

    private func readFrame() async throws -> Data {
        let lenHdr = try await readExact(4)
        let frameLen = (Int(lenHdr[1]) << 16) | (Int(lenHdr[2]) << 8) | Int(lenHdr[3])
        guard frameLen >= 64, frameLen <= 16 * 1024 * 1024 else {
            throw Smb2Error("SMB 帧长度无效 (\(frameLen))")
        }
        return try await readExact(frameLen)
    }

    // MARK: - NTLMv2 + RFC 1320 MD4

    public static func buildNtlmType1() -> Data {
        var buf = Data(count: 32)
        buf.replaceSubrange(0..<8, with: Data("NTLMSSP\0".utf8))
        writeU32LE(&buf, at: 8, 1)
        writeU32LE(&buf, at: 12, 0x6008_8215)
        return buf
    }

    public static func extractSecurityBuffer(_ payload: Data) -> Data {
        guard payload.count >= 8 else { return Data() }
        let secOff = Int(readU16LE(payload, at: 4))
        let secLen = Int(readU16LE(payload, at: 6))
        let start = secOff - 64
        guard start >= 0, start + secLen <= payload.count else { return Data() }
        return payload.subdata(in: start..<(start + secLen))
    }

    public static func parseNtlmType2(_ secBuf: Data) throws -> (serverChallenge: Data, targetInfo: Data) {
        let sig = Data("NTLMSSP\0".utf8)
        guard let range = secBuf.range(of: sig),
              secBuf.count - range.lowerBound >= 32
        else {
            throw Smb2Error("SMB 服务器未返回有效的 NTLM 质询包")
        }
        let ntlm = secBuf.subdata(in: range.lowerBound..<secBuf.count)
        guard readU32LE(ntlm, at: 8) == 2 else { throw Smb2Error("SMB NTLM 质询类型异常") }
        let challenge = ntlm.subdata(in: 24..<32)
        var targetInfo = Data()
        if ntlm.count >= 48 {
            let tiLen = Int(readU16LE(ntlm, at: 40))
            let tiOff = Int(readU32LE(ntlm, at: 44))
            if tiLen > 0 && tiOff + tiLen <= ntlm.count {
                targetInfo = ntlm.subdata(in: tiOff..<(tiOff + tiLen))
            }
        }
        return (challenge, targetInfo)
    }

    public static func buildNtlmType3(
        username: String,
        password: String,
        domain: String,
        serverChallenge: Data,
        targetInfo: Data
    ) -> Data {
        let domainBytes = encodeUtf16LE(domain)
        let userBytes = encodeUtf16LE(username)
        let hostBytes = encodeUtf16LE("MARCO")

        let lmResp: Data
        let ntResp: Data
        if username.isEmpty {
            lmResp = Data()
            ntResp = Data()
        } else {
            let ntHash = md4(encodeUtf16LE(password))
            let userDom = encodeUtf16LE("\(username.uppercased())\(domain)")
            let ntlmv2Hash = hmacMd5(key: ntHash, data: userDom)
            var clientChallenge = Data(count: 8)
            for i in 0..<8 { clientChallenge[i] = UInt8.random(in: 0...255) }
            let unixMs = UInt64(Date().timeIntervalSince1970 * 1000)
            let fileTime = (unixMs &+ 11_644_473_600_000) &* 10_000

            var blob = Data(count: 28 + targetInfo.count + 4)
            blob[0] = 0x01; blob[1] = 0x01
            writeU64LE(&blob, at: 8, fileTime)
            blob.replaceSubrange(16..<24, with: clientChallenge)
            if !targetInfo.isEmpty {
                blob.replaceSubrange(28..<(28 + targetInfo.count), with: targetInfo)
            }
            var ntInput = Data(serverChallenge)
            ntInput.append(blob)
            let ntProof = hmacMd5(key: ntlmv2Hash, data: ntInput)
            var ntBuf = Data(ntProof)
            ntBuf.append(blob)
            ntResp = ntBuf

            var lmInput = Data(serverChallenge)
            lmInput.append(clientChallenge)
            let lmProof = hmacMd5(key: ntlmv2Hash, data: lmInput)
            var lmBuf = Data(lmProof)
            lmBuf.append(clientChallenge)
            lmResp = lmBuf
        }

        let headerLen = 72
        var offset = headerLen
        let domOff = offset; offset += domainBytes.count
        let userOff = offset; offset += userBytes.count
        let hostOff = offset; offset += hostBytes.count
        let lmOff = offset; offset += lmResp.count
        let ntOff = offset; offset += ntResp.count

        var out = Data(count: offset)
        out.replaceSubrange(0..<8, with: Data("NTLMSSP\0".utf8))
        writeU32LE(&out, at: 8, 3)
        writeSecBuf(&out, pos: 12, len: lmResp.count, offset: lmOff)
        writeSecBuf(&out, pos: 20, len: ntResp.count, offset: ntOff)
        writeSecBuf(&out, pos: 28, len: domainBytes.count, offset: domOff)
        writeSecBuf(&out, pos: 36, len: userBytes.count, offset: userOff)
        writeSecBuf(&out, pos: 44, len: hostBytes.count, offset: hostOff)
        writeSecBuf(&out, pos: 52, len: 0, offset: offset)
        writeU32LE(&out, at: 60, 0x6008_8215)

        out.replaceSubrange(domOff..<(domOff + domainBytes.count), with: domainBytes)
        out.replaceSubrange(userOff..<(userOff + userBytes.count), with: userBytes)
        out.replaceSubrange(hostOff..<(hostOff + hostBytes.count), with: hostBytes)
        out.replaceSubrange(lmOff..<(lmOff + lmResp.count), with: lmResp)
        out.replaceSubrange(ntOff..<(ntOff + ntResp.count), with: ntResp)
        return out
    }

    private static func writeSecBuf(_ data: inout Data, pos: Int, len: Int, offset: Int) {
        writeU16LE(&data, at: pos, UInt16(len))
        writeU16LE(&data, at: pos + 2, UInt16(len))
        writeU32LE(&data, at: pos + 4, UInt32(offset))
    }

    public static func hmacMd5(key: Data, data: Data) -> Data {
        let code = HMAC<Insecure.MD5>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(code)
    }

    /// RFC 1320 MD4 implementation used to compute NTLM NT hashes (`MD4(UTF16LE(password))`).
    public static func md4(_ input: Data) -> Data {
        let bitLen = UInt64(input.count) &* 8
        let padLen = ((56 - (input.count + 1) % 64) + 64) % 64
        var msg = Data(count: input.count + 1 + padLen + 8)
        msg.replaceSubrange(0..<input.count, with: input)
        msg[input.count] = 0x80
        writeU64LE(&msg, at: msg.count - 8, bitLen)

        var a: UInt32 = 0x6745_2301
        var b: UInt32 = 0xEFCD_AB89
        var c: UInt32 = 0x98BA_DCFE
        var d: UInt32 = 0x1032_5476

        func rotl(_ x: UInt32, _ s: UInt32) -> UInt32 { (x << s) | (x >> (32 - s)) }
        func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
        func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
        func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }

        var x = [UInt32](repeating: 0, count: 16)
        for i in stride(from: 0, to: msg.count, by: 64) {
            for j in 0..<16 { x[j] = readU32LE(msg, at: i + j * 4) }
            let aa = a, bb = b, cc = c, dd = d

            for k in stride(from: 0, to: 16, by: 4) {
                a = rotl(a &+ f(b, c, d) &+ x[k], 3)
                d = rotl(d &+ f(a, b, c) &+ x[k + 1], 7)
                c = rotl(c &+ f(d, a, b) &+ x[k + 2], 11)
                b = rotl(b &+ f(c, d, a) &+ x[k + 3], 19)
            }
            for k in 0..<4 {
                a = rotl(a &+ g(b, c, d) &+ x[k] &+ 0x5A82_7999, 3)
                d = rotl(d &+ g(a, b, c) &+ x[k + 4] &+ 0x5A82_7999, 5)
                c = rotl(c &+ g(d, a, b) &+ x[k + 8] &+ 0x5A82_7999, 9)
                b = rotl(b &+ g(c, d, a) &+ x[k + 12] &+ 0x5A82_7999, 13)
            }
            let idx3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
            for k in stride(from: 0, to: 16, by: 4) {
                a = rotl(a &+ h(b, c, d) &+ x[idx3[k]] &+ 0x6ED9_EBA1, 3)
                d = rotl(d &+ h(a, b, c) &+ x[idx3[k + 1]] &+ 0x6ED9_EBA1, 9)
                c = rotl(c &+ h(d, a, b) &+ x[idx3[k + 2]] &+ 0x6ED9_EBA1, 11)
                b = rotl(b &+ h(c, d, a) &+ x[idx3[k + 3]] &+ 0x6ED9_EBA1, 15)
            }

            a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
        }

        var out = Data(count: 16)
        writeU32LE(&out, at: 0, a)
        writeU32LE(&out, at: 4, b)
        writeU32LE(&out, at: 8, c)
        writeU32LE(&out, at: 12, d)
        return out
    }

    // MARK: - Byte & String Utilities

    private static func normalizeSmbPath(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "\\")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    }

    private static func encodeUtf16LE(_ value: String) -> Data {
        let units = Array(value.utf16)
        var out = Data(count: units.count * 2)
        for (i, u) in units.enumerated() {
            out[i * 2] = UInt8(u & 0xFF)
            out[i * 2 + 1] = UInt8((u >> 8) & 0xFF)
        }
        return out
    }

    private static func decodeUtf16LE(_ data: Data) -> String {
        let count = data.count / 2
        var units = [UInt16](repeating: 0, count: count)
        for i in 0..<count {
            units[i] = UInt16(data[i * 2]) | (UInt16(data[i * 2 + 1]) << 8)
        }
        return String(utf16CodeUnits: units, count: count)
    }

    private static func describeStatus(_ status: UInt32, fallback: String) -> String {
        switch status {
        case statusLogonFailure: return "SMB 用户名或密码错误 (0xC000006D)"
        case statusAccessDenied: return "SMB 权限不足 (0xC0000022)"
        case statusBadNetworkName: return "SMB 共享目录不存在 (0xC00000CC)"
        case statusObjectNameNotFound: return "SMB 文件或目录不存在 (0xC0000034)"
        default: return "\(fallback) (0x\(String(status, radix: 16).uppercased()))"
        }
    }

    private static func readU16LE(_ d: Data, at o: Int) -> UInt16 {
        UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }

    private static func readU32LE(_ d: Data, at o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }

    private static func readU64LE(_ d: Data, at o: Int) -> UInt64 {
        UInt64(readU32LE(d, at: o)) | (UInt64(readU32LE(d, at: o + 4)) << 32)
    }

    private static func readI64LE(_ d: Data, at o: Int) -> Int64 {
        Int64(bitPattern: readU64LE(d, at: o))
    }

    private static func writeU16LE(_ d: inout Data, at o: Int, _ v: UInt16) {
        d[o] = UInt8(v & 0xFF)
        d[o + 1] = UInt8((v >> 8) & 0xFF)
    }

    private static func writeU32LE(_ d: inout Data, at o: Int, _ v: UInt32) {
        d[o] = UInt8(v & 0xFF)
        d[o + 1] = UInt8((v >> 8) & 0xFF)
        d[o + 2] = UInt8((v >> 16) & 0xFF)
        d[o + 3] = UInt8((v >> 24) & 0xFF)
    }

    private static func writeU64LE(_ d: inout Data, at o: Int, _ v: UInt64) {
        writeU32LE(&d, at: o, UInt32(v & 0xFFFF_FFFF))
        writeU32LE(&d, at: o + 4, UInt32((v >> 32) & 0xFFFF_FFFF))
    }
}
