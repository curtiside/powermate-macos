// powermate — use a Griffin PowerMate USB knob on modern macOS with no kext.
// Reads the knob via IOHIDManager (userspace HID) and runs built-in actions
// (volume, mute, media keys, output-device switch) mapped from gestures via a
// local config file.
//
// Gestures:  turn_cw  turn_ccw  click  double_click  long_press  press_turn_cw  press_turn_ccw
// Actions:   volume_up  volume_down  mute_toggle  play_pause  next_track
//            previous_track  output_cycle  none
//
// Config (first found wins):  $POWERMATE_CONFIG  |  ~/.config/powermate/powermate.conf
// With no config file the defaults are turn=volume, click=mute, rest=none — i.e.
// identical to the classic volume-knob behavior, with no added latency (a plain
// click fires immediately unless you map double_click / long_press / press_turn).
//
// Modes:  powermate            run (default)
//         powermate --list     list HID devices
//         powermate --watch    print raw knob reports
//
// Build: swiftc -O -swift-version 5 powermate.swift -o powermate
// Needs Input Monitoring; media-key actions may also need Accessibility.
// MIT licensed.

import Foundation
import IOKit.hid
import CoreAudio
import AppKit

let GRIFFIN_VID = 0x077d
let POWERMATE_PID = 0x0410

// MARK: - CoreAudio

let SYS = AudioObjectID(kAudioObjectSystemObject)
let kVMVC: AudioObjectPropertySelector = 0x766d7663 // 'vmvc'

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
func allOutputDevices() -> [(AudioObjectID, String)] {
    var a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
    var size: UInt32 = 0; AudioObjectGetPropertyDataSize(SYS, &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(SYS, &a, 0, nil, &size, &ids)
    return ids.filter { outputChannels($0) > 0 }.map { ($0, nameOf($0)) }
}
func defaultOutputDevice() -> AudioObjectID? {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
    var d: AudioObjectID = 0; var s = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(SYS, &a, 0, nil, &s, &d) == noErr && d != 0 ? d : nil
}
func setDefaultOutput(_ id: AudioObjectID) {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
    var d = id; AudioObjectSetPropertyData(SYS, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
}
func findOutputDevice(_ needle: String) -> AudioObjectID? {
    allOutputDevices().first { $0.1.localizedCaseInsensitiveContains(needle) }?.0
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
    let val = max(0, min(1, v)); var did = false
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

// MARK: - Media keys (NSSystemDefined)

func mediaKey(_ keyType: Int) {
    func post(_ down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = (keyType << 16) | ((down ? 0xa : 0xb) << 8)
        if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) {
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }
    post(true); post(false)
}
let NX_KEYTYPE_PLAY = 16, NX_KEYTYPE_NEXT = 17, NX_KEYTYPE_PREVIOUS = 18

// MARK: - Config

final class Config {
    var device: String? = nil
    var step: Float = 0.03
    var longPressMs = 500
    var doubleClickMs = 250
    var map: [String: String] = [
        "turn_cw": "volume_up", "turn_ccw": "volume_down", "click": "mute_toggle",
        "double_click": "none", "long_press": "none",
        "press_turn_cw": "none", "press_turn_ccw": "none",
    ]
    func action(_ gesture: String) -> String { map[gesture] ?? "none" }
    func mapped(_ gesture: String) -> Bool { let a = action(gesture); return a != "none" && !a.isEmpty }
}

func loadConfig() -> Config {
    let cfg = Config()
    let env = ProcessInfo.processInfo.environment
    let path = env["POWERMATE_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSString(string: "~/.config/powermate/powermate.conf").expandingTildeInPath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return cfg }
    for raw in text.split(separator: "\n") {
        let line = raw.split(separator: "#", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "device": cfg.device = val.isEmpty || val == "default" ? nil : val
        case "step": if let v = Float(val) { cfg.step = v }
        case "long_press_ms": if let v = Int(val) { cfg.longPressMs = v }
        case "double_click_ms": if let v = Int(val) { cfg.doubleClickMs = v }
        default: if cfg.map[key] != nil { cfg.map[key] = val }
        }
    }
    // env override for device still honored
    if let d = env["POWERMATE_DEVICE"], !d.isEmpty { cfg.device = d }
    return cfg
}

let cfg = loadConfig()
func target() -> AudioObjectID? { cfg.device.flatMap { findOutputDevice($0) } ?? defaultOutputDevice() }

// Run a discrete action. `magnitude` scales volume steps for rotation.
func run(_ action: String, magnitude: Int = 1) {
    switch action {
    case "volume_up":   if let d = target(), let v = getVolume(d) { setVolume(d, v + cfg.step * Float(magnitude)) }
    case "volume_down": if let d = target(), let v = getVolume(d) { setVolume(d, v - cfg.step * Float(magnitude)) }
    case "mute_toggle": if let d = target() { toggleMute(d) }
    case "play_pause":  mediaKey(NX_KEYTYPE_PLAY)
    case "next_track":  mediaKey(NX_KEYTYPE_NEXT)
    case "previous_track": mediaKey(NX_KEYTYPE_PREVIOUS)
    case "output_cycle":
        let outs = allOutputDevices()
        if !outs.isEmpty, let cur = defaultOutputDevice() {
            let i = outs.firstIndex { $0.0 == cur } ?? -1
            setDefaultOutput(outs[(i + 1) % outs.count].0)
        }
    default: break
    }
}

// MARK: - Gesture state machine

var buttonDown = false
var pressUsedForTurn = false
var longPressFired = false
var clickHandledOnDown = false
var longPressWork: DispatchWorkItem?
var pendingClick: DispatchWorkItem?

let advancedClick = cfg.mapped("double_click") || cfg.mapped("long_press")
    || cfg.mapped("press_turn_cw") || cfg.mapped("press_turn_ccw")

func onButtonDown() {
    buttonDown = true; pressUsedForTurn = false; longPressFired = false; clickHandledOnDown = false
    if cfg.mapped("long_press") {
        let w = DispatchWorkItem {
            if buttonDown && !pressUsedForTurn { longPressFired = true; run(cfg.action("long_press")) }
        }
        longPressWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cfg.longPressMs), execute: w)
    }
    // Instant click (mute) when no advanced gestures are configured — preserves classic feel.
    if cfg.mapped("click") && !advancedClick {
        clickHandledOnDown = true; run(cfg.action("click"))
    }
}

func onButtonUp() {
    buttonDown = false
    longPressWork?.cancel(); longPressWork = nil
    if clickHandledOnDown || longPressFired || pressUsedForTurn { return }
    guard cfg.mapped("click") else { return }
    if cfg.mapped("double_click") {
        if let p = pendingClick { p.cancel(); pendingClick = nil; run(cfg.action("double_click")); return }
        let w = DispatchWorkItem { pendingClick = nil; run(cfg.action("click")) }
        pendingClick = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cfg.doubleClickMs), execute: w)
    } else {
        run(cfg.action("click"))
    }
}

func onRotate(_ delta: Int) {
    let cw = delta > 0
    let mag = abs(delta)
    if buttonDown && (cfg.mapped("press_turn_cw") || cfg.mapped("press_turn_ccw")) {
        pressUsedForTurn = true
        longPressWork?.cancel(); longPressWork = nil
        run(cfg.action(cw ? "press_turn_cw" : "press_turn_ccw"), magnitude: mag)
    } else {
        run(cfg.action(cw ? "turn_cw" : "turn_ccw"), magnitude: mag)
    }
}

// MARK: - HID

var prevButton: UInt8 = 0
var watchMode = false
var reportBuffer = [UInt8](repeating: 0, count: 16)
func logErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let reportCallback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    let len = Int(length)
    let btn = len > 0 ? report[0] : 0
    let rot = len > 1 ? Int(Int8(bitPattern: report[1])) : 0
    if watchMode {
        let hex = (0..<len).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
        logErr("report[\(len)]: \(hex)   button=\(btn) rotation=\(rot)")
        return
    }
    if rot != 0 { onRotate(rot) }
    if btn == 1 && prevButton == 0 { onButtonDown() }
    if btn == 0 && prevButton == 1 { onButtonUp() }
    prevButton = btn
}

let knobMatched: IOHIDDeviceCallback = { _, _, _, device in
    reportBuffer.withUnsafeMutableBufferPointer { buf in
        IOHIDDeviceRegisterInputReportCallback(device, buf.baseAddress!, buf.count, reportCallback, nil)
    }
    logErr("PowerMate connected.")
}

func listHID() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil); IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { print("no HID devices"); return }
    func p(_ d: IOHIDDevice, _ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }
    for d in set {
        let vid = (p(d, kIOHIDVendorIDKey) as? Int) ?? -1, pid = (p(d, kIOHIDProductIDKey) as? Int) ?? -1
        print(String(format: "VID=0x%04x PID=0x%04x  (dec %d/%d)  %@ / %@", vid, pid, vid, pid,
                     (p(d, kIOHIDManufacturerKey) as? String) ?? "?", (p(d, kIOHIDProductKey) as? String) ?? "?"))
    }
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
    if watchMode { print("Watching PowerMate — turn/press. Ctrl-C to stop.") }
    else {
        let dev = cfg.device.map { "\"\($0)\"" } ?? "the default output"
        print("PowerMate active (target=\(dev)). Config: turn_cw=\(cfg.action("turn_cw")) click=\(cfg.action("click")) … Ctrl-C to stop.")
    }
    CFRunLoopRun()
}

// MARK: - Main

switch CommandLine.arguments.dropFirst().first {
case "--list": listHID()
case "--watch": watchMode = true; startKnob()
case "--help", "-h":
    print("powermate — Griffin PowerMate knob, config-mapped built-in actions. Modes: (default run) --list --watch")
default: startKnob()
}
