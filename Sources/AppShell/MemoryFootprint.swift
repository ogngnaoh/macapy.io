import Darwin
import Foundation

/// The diagnostics "Memory" tile's data source (slice-4 decision on exit
/// criterion 7): `phys_footprint` is the number Activity Monitor's "Memory"
/// column shows and the one the <400MB budget is written against.
enum MemoryFootprint {
    /// Current process physical footprint in bytes; nil only if the kernel
    /// call fails (never observed in practice — surfaced as a reserved tile,
    /// not a crash).
    static func currentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}
