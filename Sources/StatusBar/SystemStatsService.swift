import AppKit
import Combine
import CoreAudio
import IOKit.ps
import Network

/// System stats for the top bar (spec §4.4): CPU / battery / network / volume, sampled every 2s.
final class SystemStatsService: ObservableObject {
    @Published private(set) var cpuPercent: Int = 0
    @Published private(set) var batteryPercent: Int? = nil   // nil = no battery
    @Published private(set) var batteryCharging = false
    @Published private(set) var networkUp = true
    @Published private(set) var networkWifi = true
    @Published private(set) var muted = false

    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var prevCPUTicks: (idle: UInt64, total: UInt64)?

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.networkUp = path.status == .satisfied
                self?.networkWifi = path.usesInterfaceType(.wifi)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "quickterm.netpath"))
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    deinit {
        timer?.invalidate()
        pathMonitor.cancel()
    }

    private func sample() {
        sampleCPU()
        sampleBattery()
        sampleMute()
    }

    // MARK: CPU (differencing host_processor_info)

    private func sampleCPU() {
        var count = mach_msg_type_number_t()
        var cpuInfo: processor_info_array_t?
        var cpuCount = natural_t()
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &cpuInfo, &count) == KERN_SUCCESS,
              let info = cpuInfo else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var idle: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idl = UInt64(info[base + Int(CPU_STATE_IDLE)])
            idle += idl
            total += user + system + nice + idl
        }
        if let prev = prevCPUTicks {
            let dTotal = total &- prev.total
            let dIdle = idle &- prev.idle
            if dTotal > 0 {
                cpuPercent = Int((Double(dTotal &- dIdle) / Double(dTotal) * 100).rounded())
            }
        }
        prevCPUTicks = (idle, total)
    }

    // MARK: Battery (IOKit power sources)

    private func sampleBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
              let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
              let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else {
            batteryPercent = nil
            return
        }
        batteryPercent = Int((Double(capacity) / Double(max) * 100).rounded())
        batteryCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
    }

    // MARK: Volume (the mute bit of the CoreAudio default output device)

    private var defaultOutputDevice: AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private func sampleMute() {
        guard let device = defaultOutputDevice else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
            muted = value != 0
        }
    }

    /// Clicking the volume icon in the top bar: toggle mute.
    func toggleMute() {
        guard let device = defaultOutputDevice else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var newValue: UInt32 = muted ? 0 : 1
        if AudioObjectSetPropertyData(device, &addr, 0, nil,
                                      UInt32(MemoryLayout<UInt32>.size), &newValue) == noErr {
            muted = newValue != 0
        }
    }
}
