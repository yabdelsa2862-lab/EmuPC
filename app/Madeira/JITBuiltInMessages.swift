// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// Codable messages shared by Madeira and its JIT helper extension. Each travels as JSON
/// in an extension request's item (userInfo[itemKey]), to the helper and back.
struct MadeiraJITRequest: Codable, Sendable {
    static let itemKey = "madeira-jit-request"

    enum Operation: String, Codable, Sendable {
        case prepare
        case enable
        case resetDDI
        /// The memory experiment (MemoryProbe): the helper fills shared memory
        /// for Madeira to map.
        case memoryProbe
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?
    /// memoryProbe: how many MB to fill, and the shared memory's name.
    var probeMB: Int? = nil
    var probeName: String? = nil

    static func prepare(pairingData: Data) -> MadeiraJITRequest {
        MadeiraJITRequest(operation: .prepare, targetPID: nil,
                          pairingData: pairingData, scriptBase64: nil)
    }

    static func enable(targetPID: Int32, pairingData: Data,
                       scriptBase64: String) -> MadeiraJITRequest {
        MadeiraJITRequest(operation: .enable, targetPID: targetPID,
                          pairingData: pairingData, scriptBase64: scriptBase64)
    }

    static var resetDDI: MadeiraJITRequest {
        MadeiraJITRequest(operation: .resetDDI, targetPID: nil,
                          pairingData: nil, scriptBase64: nil)
    }

    struct Response: Codable, Sendable {
        static let itemKey = "madeira-jit-response"
        let success: Bool
        let message: String
        let txmPresent: Bool?
        /// memoryProbe: the helper's own footprint after filling, in bytes.
        var footprint: UInt64? = nil
    }
}

// MARK: - Memory experiment

/// Does memory a second process (the helper) creates and fills count against
/// Madeira's own iOS memory limit when Madeira maps it? The idea behind
/// MeloNX's multiprocess RAM workaround (willfaust/Madeira#105), whose code is
/// not public, measured on this device before anything is built on it.
/// Log tag: [mem-probe].
enum MemoryProbe {
    /// The app group both targets share (Madeira.entitlements, the helper's
    /// entitlements): POSIX shared memory names must start with it.
    static var appGroup: String {
        var id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".JITHelper") { id.removeLast(".JITHelper".count) }
        return "group." + id
    }

    /// Names are at most 31 bytes (PSHMNAMLEN) including the group prefix.
    static func name(_ index: Int) -> String { appGroup + "/mp\(index)" }

    /// task_vm_info's phys_footprint: the number jetsam compares with the limit.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// shm_open is variadic, which Swift cannot call. On Apple arm64 a variadic
    /// argument goes on the stack while the first eight go in registers, so the
    /// mode is passed as the ninth (stack) argument of a fixed prototype.
    private typealias ShmOpen = @convention(c) (UnsafePointer<CChar>, Int32, Int, Int, Int, Int, Int, Int, UInt64) -> Int32
    private static let shmOpenFn: ShmOpen? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(sym, to: ShmOpen.self)
    }()

    static func open(_ name: String, create: Bool) -> Int32 {
        guard let fn = shmOpenFn else { return -1 }
        return name.withCString { fn($0, create ? (O_CREAT | O_RDWR) : O_RDWR, 0, 0, 0, 0, 0, 0, 0o600) }
    }

    /// Maps `bytes` of the named memory, creating and sizing it first when asked.
    static func map(_ name: String, bytes: Int, create: Bool) -> UnsafeMutableRawPointer? {
        let fd = open(name, create: create)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if create && ftruncate(fd, off_t(bytes)) != 0 { return nil }
        let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        return p == MAP_FAILED ? nil : p
    }

    /// Writes one word per 16 KB page, so every page is resident.
    static func touch(_ p: UnsafeMutableRawPointer, bytes: Int, seed: UInt64) {
        for off in stride(from: 0, to: bytes, by: 16384) {
            p.storeBytes(of: seed &+ UInt64(off), toByteOffset: off, as: UInt64.self)
        }
    }

    /// Pages whose word does not match `touch`'s pattern.
    static func mismatches(_ p: UnsafeMutableRawPointer, bytes: Int, seed: UInt64) -> Int {
        var bad = 0
        for off in stride(from: 0, to: bytes, by: 16384)
            where p.load(fromByteOffset: off, as: UInt64.self) != seed &+ UInt64(off) { bad += 1 }
        return bad
    }

    /// The helper side: memory it filled stays mapped here for as long as the
    /// helper process lives.
    nonisolated(unsafe) static var held: [UnsafeMutableRawPointer] = []
}
