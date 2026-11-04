import Foundation

/// Reads CPU types from a Mach-O (thin or universal) header without shelling out to `lipo`
/// (which would trigger the "install developer tools" prompt on a clean Mac).
public enum MachOArch {
    public static let cpuARM64: UInt32 = 0x0100_000C
    public static let cpuX86_64: UInt32 = 0x0100_0007

    public static func cpuTypes(ofFileAt url: URL) -> Set<UInt32> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096) else { return [] }
        return cpuTypes(header: header)
    }

    public static func cpuTypes(header data: Data) -> Set<UInt32> {
        let bytes = [UInt8](data)
        func be32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func le32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard let magic = be32(0) else { return [] }
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF: // universal (fat / fat64), big-endian
            guard let count = be32(4) else { return [] }
            let entrySize = magic == 0xCAFE_BABE ? 20 : 32
            var result = Set<UInt32>()
            for i in 0..<Int(min(count, 16)) {
                if let cpu = be32(8 + i * entrySize) { result.insert(cpu) }
            }
            return result
        case 0xCFFA_EDFE: // thin 64-bit, little-endian
            return le32(4).map { [$0] } ?? []
        default:
            return []
        }
    }
}
