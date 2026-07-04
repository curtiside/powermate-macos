// powermate — use a Griffin PowerMate USB knob as a volume control on modern
// macOS, with no driver/kext (the original Griffin software is dead and doesn't
// run on Apple Silicon). Reads the knob via IOHIDManager (userspace HID) and
// sets an output device's volume via CoreAudio. Turn = volume, press = mute.
//
// By default it controls your **current default output device**, so it works
// out of the box. Override with POWERMATE_DEVICE to pin a specific device.
//
// Modes:
//   powermate                  control volume (default). Env overrides:
//                                POWERMATE_DEVICE  output device name substring
//                                                  (default: current default output)
//                                POWERMATE_STEP    volume change per detent (default 0.03)
//   powermate --list           list HID devices (find the knob / other devices' VID/PID)
//   powermate --watch          print the knob's raw HID reports (decode/debug)
//
// Build: swiftc -O -swift-version 5 powermate.swift -o powermate
// Needs Input Monitoring permission for the running process
// (System Settings > Privacy & Security > Input Monitoring).
//
// MIT licensed.

import Foundation
import IOKit.hid
import CoreAudio

let GRIFFIN_VID = 0x077d
let POWERMATE_PID = 0x0410

// MARK: - CoreAudio helpers

let SYS = AudioObjectID(kAudioObjectSystemObject)
let kVMVC: AudioObjectPropertySelector = 0x766d7663 // 'vmvc' VirtualMainVolume

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
}
func settable(_ id: AudioObjectID, _ a: inout AudioObjectPropertyAddress) -> Bool {
    var s: DarwinBoolean = false
    return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &s) == noErr && s.boolValue
}
func gStr(_ id: AudioObjectID, _ a: inout AudioObjectPropertyAddress) -> String? {
    guard AudioObjectHasProperty(id, &a) else { return nil }
    var o: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &o) == noErr ? (o?.takeRetainedValue() as String?) : nil
}
func nameOf(_ id: AudioObjectID) -> String { var a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal); return gStr(id, &a) ?? "device \(id)" }
func outputChannels(_ id: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func defaultOutputDevice() -> AudioObjectID? {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
    var d: AudioObjectID = 0; var s = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(SYS, &a, 0, nil, &s, &d) == noErr && d != 0 ? d : nil
}
func findOutputDevice(_ needle: String) -> AudioObjectID? {
    var a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
    var size: UInt32 = 0; AudioObjectGetPropertyDataSize(SYS, &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(SYS, &a, 0, nil, &size, &ids)
    return ids.first { outputChannels($0) > 0 && nameOf($0).localizedCaseInsensitiveContains(needle) }
}
func getVolume(_ id: AudioObjectID) -> Float? {
    for el in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
        var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el)
        if AudioObjectHasProperty(id, &a) { var v: Float = 0; var s = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr { return v } }
    }
    var vm = addr(kVMVC)
    if AudioObjectHasProperty(id, &vm) { var v: Float = 0; var s = UInt32(MemoryLayout<Float>.size)
        if AudioObjectGetPropertyData(id, &vm, 0, nil, &s, &v) == noErr { return v } }
    return nil
}
func setVolume(_ id: AudioObjectID, _ v: Float) {
    let val = max(0, min(1, v))
    var did = false
    for el in [AudioObjectPropertyElement(1), 2] {
        var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el)
        if settable(id, &a) { var x = val; AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &x); did = true }
    }
    var vm = addr(kVMVC)
    if settable(id, &vm) { var x = val; AudioObjectSetPropertyData(id, &vm, 0, nil, UInt32(MemoryLayout<Float>.size), &x); did = true }
    if !did { var m = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 0)
        if settable(id, &m) { var x = val; AudioObjectSetPropertyData(id, &m, 0, nil, UInt32(MemoryLayout<Float>.size), &x) } }
}
func toggleMute(_ id: AudioObjectID) {
    var a = addr(kAudioDevicePropertyMute)
    guard settable(id, &a) else { return }
    var cur: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cur)
    var nv: UInt32 = cur == 0 ? 1 : 0
    AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &nv)
}

// Resolve which device the knob controls: POWERMATE_DEVICE name, else the
// current default output (resolved live, so it follows output switches).
let deviceNameOverride: String? = ProcessInfo.processInfo.environment["POWERMATE_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }
func currentTarget() -> AudioObjectID? {
    if let n = deviceNameOverride { return findOutputDevice(n) }
    return defaultOutputDevice()
}

// MARK: - HID list (--list)

func listHID() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { print("no HID devices"); return }
    func p(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }
    for d in set {
        let vid = (p(d, kIOHIDVendorIDKey) as? Int) ?? -1
        let pid = (p(d, kIOHIDProductIDKey) as? Int) ?? -1
        print(String(format: "VID=0x%04x PID=0x%04x  (dec %d/%d)  %@ / %@", vid, pid, vid, pid, (p(d, kIOHIDManufacturerKey) as? String) ?? "?", (p(d, kIOHIDProductKey) as? String) ?? "?"))
    }
}

// MARK: - Knob

var step: Float = 0.03
var prevButton: UInt8 = 0
var watchMode = false
var reportBuffer = [UInt8](repeating: 0, count: 16)
func logErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// PowerMate input report: [button, signedRotation, ...].
let reportCallback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    let len = Int(length)
    let btn = len > 0 ? report[0] : 0
    let rot = len > 1 ? Int(Int8(bitPattern: report[1])) : 0
    if watchMode {
        let hex = (0..<len).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
        logErr("report[\(len)]: \(hex)   button=\(btn) rotation=\(rot)")
        return
    }
    guard let dev = currentTarget() else { return }
    if rot != 0, let vol = getVolume(dev) { setVolume(dev, vol + Float(rot) * step) }
    if btn == 1 && prevButton == 0 { toggleMute(dev) }
    prevButton = btn
}

let knobMatched: IOHIDDeviceCallback = { _, _, _, device in
    reportBuffer.withUnsafeMutableBufferPointer { buf in
        IOHIDDeviceRegisterInputReportCallback(device, buf.baseAddress!, buf.count, reportCallback, nil)
    }
    logErr("PowerMate connected.")
}

func startKnob() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [kIOHIDVendorIDKey: GRIFFIN_VID, kIOHIDProductIDKey: POWERMATE_PID]
    IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, knobMatched, nil)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let openRes = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    if openRes != kIOReturnSuccess {
        logErr(String(format: "Could not open HID (0x%08x). Grant Input Monitoring: System Settings > Privacy & Security > Input Monitoring.", openRes))
    }
    if watchMode {
        print("Watching PowerMate — turn and press the knob. Ctrl-C to stop.")
    } else {
        let target = deviceNameOverride.map { "device matching \"\($0)\"" } ?? "the default output device"
        print("PowerMate controlling \(target) (step=\(step)). Turn = volume, press = mute. Waiting for knob… Ctrl-C to stop.")
    }
    CFRunLoopRun()
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--list": listHID()
case "--watch": watchMode = true; startKnob()
case "--help", "-h":
    print("""
    powermate — Griffin PowerMate USB knob -> volume, no kext.
      powermate                control volume (turn) / mute (press)
      powermate --list         list HID devices
      powermate --watch        print raw knob reports
    Env: POWERMATE_DEVICE (default: current default output), POWERMATE_STEP (default 0.03)
    """)
default:
    if let s = ProcessInfo.processInfo.environment["POWERMATE_STEP"], let v = Float(s) { step = v }
    startKnob()
}
