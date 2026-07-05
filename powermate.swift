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
// With no config file the defaults are exactly turn=volume, click=mute, rest=none —
// i.e. the classic volume-knob behavior, with no added latency (a plain click fires
// instantly unless you map double_click / long_press / press_turn).
//
// Modes:  powermate                 run (default)
//         powermate --list          list HID devices
//         powermate --watch [V P]   print raw reports (optionally another device)
//         powermate --selftest      run config-parser tests
//         powermate --version
//
// Build: swiftc -O -swift-version 5 powermate.swift -o powermate
// Needs Input Monitoring; media-key actions may also need Accessibility.
// MIT licensed.

import Foundation
import IOKit.hid
import CoreAudio
import AppKit

let VERSION = "0.9.0"
let GRIFFIN_VID = 0x077d
let POWERMATE_PID = 0x0410

func logErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

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
func transportType(_ id: AudioObjectID) -> UInt32 {
    var a = addr(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
    var t: UInt32 = 0; var s = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &t) == noErr else { return 0 }
    return t
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

let GESTURES: Set<String> = ["turn_cw", "turn_ccw", "click", "double_click",
                             "long_press", "press_turn_cw", "press_turn_ccw"]
let ACTIONS: Set<String> = ["volume_up", "volume_down", "mute_toggle", "play_pause",
                            "next_track", "previous_track", "output_cycle", "none"]

enum LogLevel: Int, CustomStringConvertible {
    case error = 0, info = 1, debug = 2
    var description: String { ["error", "info", "debug"][rawValue] }
}

final class Config {
    var device: String? = nil
    var step: Float = 0.03
    var longPressMs = 500
    var doubleClickMs = 250
    var logLevel = LogLevel.info
    var map: [String: String] = [
        "turn_cw": "volume_up", "turn_ccw": "volume_down", "click": "mute_toggle",
        "double_click": "none", "long_press": "none",
        "press_turn_cw": "none", "press_turn_ccw": "none",
    ]
    func action(_ gesture: String) -> String { map[gesture] ?? "none" }
    func mapped(_ gesture: String) -> Bool { action(gesture) != "none" }
}

// Parse config text into cfg. Returns human-readable warnings (bad keys, bad
// values); the caller decides where to print them. Never traps on bad input —
// this runs in a KeepAlive agent, so a typo must not become a crash loop.
func parseConfig(_ text: String, into cfg: Config) -> [String] {
    var warnings: [String] = []
    for (n, rawLine) in text.components(separatedBy: .newlines).enumerated() {
        var line = rawLine
        if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) } // strip comment
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        guard let eq = line.firstIndex(of: "=") else {
            warnings.append("line \(n + 1): not 'key = value', ignored: '\(line)'"); continue
        }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "device":
            cfg.device = val.isEmpty || val == "default" ? nil : val
        case "step":
            if let v = Float(val), v > 0, v <= 1 { cfg.step = v }
            else { warnings.append("line \(n + 1): step must be a number in (0, 1], got '\(val)' — keeping \(cfg.step)") }
        case "long_press_ms":
            if let v = Int(val), (100...5000).contains(v) { cfg.longPressMs = v }
            else { warnings.append("line \(n + 1): long_press_ms must be 100–5000, got '\(val)' — keeping \(cfg.longPressMs)") }
        case "double_click_ms":
            if let v = Int(val), (100...2000).contains(v) { cfg.doubleClickMs = v }
            else { warnings.append("line \(n + 1): double_click_ms must be 100–2000, got '\(val)' — keeping \(cfg.doubleClickMs)") }
        case "log_level":
            switch val.lowercased() {
            case "error": cfg.logLevel = .error
            case "info":  cfg.logLevel = .info
            case "debug": cfg.logLevel = .debug
            default: warnings.append("line \(n + 1): log_level must be error, info, or debug, got '\(val)' — keeping \(cfg.logLevel)")
            }
        default:
            if GESTURES.contains(key) {
                if ACTIONS.contains(val) { cfg.map[key] = val }
                else {
                    // An unrecognized action must NOT count as "mapped" — that
                    // would silently do nothing yet still add click latency.
                    cfg.map[key] = "none"
                    warnings.append("line \(n + 1): unknown action '\(val)' for \(key) — treating as none. Actions: \(ACTIONS.sorted().joined(separator: " "))")
                }
            } else {
                warnings.append("line \(n + 1): unknown key '\(key)', ignored. Gestures: \(GESTURES.sorted().joined(separator: " "))")
            }
        }
    }
    return warnings
}

func loadConfig() -> Config {
    let cfg = Config()
    let env = ProcessInfo.processInfo.environment
    let path = env["POWERMATE_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSString(string: "~/.config/powermate/powermate.conf").expandingTildeInPath
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        for w in parseConfig(text, into: cfg) { logErr("config \(path): \(w)") }
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
        // Skip virtual sinks (Zoom/Teams-style loopbacks) — landing on one
        // silently routes all audio nowhere. AirPlay/aggregates stay in.
        let outs = allOutputDevices().filter { transportType($0.0) != kAudioDeviceTransportTypeVirtual }
        if !outs.isEmpty, let cur = defaultOutputDevice() {
            let i = outs.firstIndex { $0.0 == cur } ?? -1
            let next = outs[(i + 1) % outs.count]
            setDefaultOutput(next.0)
            log(.info, "output_cycle -> \(next.1)")
        }
    default: break
    }
}

// Leveled, timestamped logging. error: failures only (always shown).
// info (default): + lifecycle — startup, device connect/disconnect, output
// switches. debug: + every caught event with the action it resolved to.
// Set via `log_level` in the config.
let logTimeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
// The gate is its own function so the selftest can verify the full
// message-level x configured-level matrix.
func shouldLog(_ level: LogLevel, at configured: LogLevel) -> Bool { level.rawValue <= configured.rawValue }
func log(_ level: LogLevel, _ s: String) {
    if shouldLog(level, at: cfg.logLevel) { logErr("\(logTimeFmt.string(from: Date())) \(s)") }
}

// Central gesture dispatch. At log_level=debug every decoded gesture is logged
// with the action it resolved to — including "none" — so you can prove the
// driver caught an event even when it deliberately does nothing.
func fire(_ gesture: String, magnitude: Int = 1) {
    let action = cfg.action(gesture)
    log(.debug, "event: \(gesture)\(magnitude > 1 ? " x\(magnitude)" : "") -> \(action)")
    run(action, magnitude: magnitude)
}

// MARK: - Gesture state machine
//
// All of this runs on the main run loop (IOHIDManager is scheduled there and
// the timers are main-queue), so no locking is needed.

var buttonDown = false
var pressUsedForTurn = false
var longPressFired = false
var clickHandledOnDown = false
var pressConsumed = false
var longPressWork: DispatchWorkItem?
var pendingClick: DispatchWorkItem?
// Shadow detection: when double_click / long_press / press_turn are unmapped,
// their detectors aren't armed (that's what keeps a plain click instant). But
// at log_level=debug the log must still show what the user physically did —
// so these track just enough to LOG the recognized gesture, with zero effect
// on dispatch.
var lastDownAt: Date?
var shadowPressTurnLogged = false
var shadowLongPressWork: DispatchWorkItem?

let advancedClick = cfg.mapped("double_click") || cfg.mapped("long_press")
    || cfg.mapped("press_turn_cw") || cfg.mapped("press_turn_ccw")

func onButtonDown() {
    buttonDown = true; pressUsedForTurn = false; longPressFired = false
    clickHandledOnDown = false; pressConsumed = false
    shadowPressTurnLogged = false
    // Shadow double-click: no pending-click machinery exists when double_click
    // is unmapped, but the debug log must still show the physical gesture.
    // Both clicks have dispatched (or will) individually — log only.
    if !cfg.mapped("double_click"), let t = lastDownAt,
       Date().timeIntervalSince(t) * 1000 < Double(cfg.doubleClickMs) {
        log(.debug, "event: double_click -> none (unmapped; clicks dispatched individually)")
    }
    lastDownAt = Date()
    // A second press while a single click is pending IS the double-click:
    // consume it here, on the down edge. (Resolving on the up edge instead
    // would let click-then-hold fire both click and long_press, and would
    // misjudge the window as release-to-release.)
    if let p = pendingClick {
        p.cancel(); pendingClick = nil
        pressConsumed = true
        fire("double_click")
        return
    }
    if cfg.mapped("long_press") {
        let w = DispatchWorkItem {
            if buttonDown && !pressUsedForTurn && !pressConsumed { longPressFired = true; fire("long_press") }
        }
        longPressWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cfg.longPressMs), execute: w)
    } else {
        // Shadow long-press: log-only; never sets longPressFired, so release
        // handling (and the already-dispatched click) is unaffected.
        let w = DispatchWorkItem {
            if buttonDown && !pressUsedForTurn && !pressConsumed && !shadowPressTurnLogged {
                log(.debug, "event: long_press -> none (unmapped; click already dispatched)")
            }
        }
        shadowLongPressWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cfg.longPressMs), execute: w)
    }
    // Instant click (mute) when no advanced gestures are configured — preserves
    // classic feel. Fires even when click=none so the debug log shows the no-op.
    if !advancedClick {
        clickHandledOnDown = true; fire("click")
    }
}

func onButtonUp() {
    buttonDown = false
    longPressWork?.cancel(); longPressWork = nil
    shadowLongPressWork?.cancel(); shadowLongPressWork = nil
    if pressConsumed || clickHandledOnDown || longPressFired || pressUsedForTurn { return }
    // No mapped-click guard here: the pending click must be scheduled even when
    // click=none, both so double_click works with click unmapped and so
    // log_events records the no-op dispatch.
    if cfg.mapped("double_click") {
        let w = DispatchWorkItem { pendingClick = nil; fire("click") }
        pendingClick = w
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cfg.doubleClickMs), execute: w)
    } else {
        fire("click")
    }
}

func onRotate(_ delta: Int) {
    let cw = delta > 0
    let mag = abs(delta)
    if buttonDown && (cfg.mapped("press_turn_cw") || cfg.mapped("press_turn_ccw")) {
        pressUsedForTurn = true
        longPressWork?.cancel(); longPressWork = nil
        fire(cw ? "press_turn_cw" : "press_turn_ccw", magnitude: mag)
    } else {
        // Shadow press+turn: recognized and logged once per press even when
        // unmapped; the turns still dispatch as plain turns below.
        if buttonDown && !shadowPressTurnLogged {
            shadowPressTurnLogged = true
            log(.debug, "event: press_turn -> none (unmapped; turns dispatch as plain turns)")
        }
        fire(cw ? "turn_cw" : "turn_ccw", magnitude: mag)
    }
}

func resetGestureState() {
    prevButton = 0; buttonDown = false; pressUsedForTurn = false
    longPressFired = false; clickHandledOnDown = false; pressConsumed = false
    longPressWork?.cancel(); longPressWork = nil
    pendingClick?.cancel(); pendingClick = nil
    shadowLongPressWork?.cancel(); shadowLongPressWork = nil
    shadowPressTurnLogged = false; lastDownAt = nil
}

// MARK: - HID

var prevButton: UInt8 = 0
var watchMode = false

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
    if btn == 1 && prevButton == 0 {
        log(.debug, "event: button down") // raw edge: proves receipt even if nothing is mapped
        onButtonDown()
    }
    if btn == 0 && prevButton == 1 {
        log(.debug, "event: button up")
        onButtonUp()
    }
    prevButton = btn
}

let knobMatched: IOHIDDeviceCallback = { _, _, _, device in
    // The report buffer must outlive this call — IOKit writes into it for every
    // report until the device goes away. Allocate it stably; intentionally never
    // freed (a replug leaks a few bytes, which beats a use-after-free race
    // during teardown).
    let size = max((IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64, 8)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    IOHIDDeviceRegisterInputReportCallback(device, buf, size, reportCallback, nil)
    log(.info, "device connected: \(IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?")")
}

let knobRemoved: IOHIDDeviceCallback = { _, _, _, _ in
    // Unplugged mid-gesture: drop any half-tracked press so a replug starts clean.
    resetGestureState()
    log(.info, "device disconnected.")
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

func startKnob(vid: Int = GRIFFIN_VID, pid: Int = POWERMATE_PID) {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid]
    IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, knobMatched, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(mgr, knobRemoved, nil)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let openRes = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    if openRes != kIOReturnSuccess {
        log(.error, String(format: "Could not open HID (0x%08x). Grant Input Monitoring: System Settings > Privacy & Security > Input Monitoring.", openRes))
    }
    // Banners go to stderr: logErr is unbuffered, while print/stdout is
    // block-buffered when redirected to the launchd log file.
    if watchMode { logErr(String(format: "Watching VID=0x%04x PID=0x%04x — interact with the device. Ctrl-C to stop.", vid, pid)) }
    else {
        let dev = cfg.device.map { "\"\($0)\"" } ?? "the default output"
        log(.info, "powermate v\(VERSION) active (target=\(dev)). turn_cw=\(cfg.action("turn_cw")) click=\(cfg.action("click")) … Ctrl-C to stop.")
    }
    CFRunLoopRun()
}

// Accept "1917", "0x077d", or bare hex with letters ("077d").
func parseID(_ s: String) -> Int? {
    let t = s.lowercased()
    if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
    return Int(t) ?? Int(t, radix: 16)
}

// MARK: - Self-test (config parser; run with `make test`)

func selftest() -> Int {
    var fails = 0
    func check(_ name: String, _ cond: Bool) {
        print((cond ? "PASS" : "FAIL") + "  " + name); if !cond { fails += 1 }
    }
    var c = Config()
    var w = parseConfig("# double_click = play_pause\n", into: c)
    check("commented-out mapping stays off", c.action("double_click") == "none" && w.isEmpty)
    c = Config(); w = parseConfig("#\n###\n   #\n\n", into: c)
    check("bare-# and blank lines are ignored (no crash)", c.action("click") == "mute_toggle" && w.isEmpty)
    c = Config(); w = parseConfig("step = 0.05  # inline comment\n", into: c)
    check("inline comment stripped", abs(c.step - 0.05) < 0.0001 && w.isEmpty)
    c = Config(); w = parseConfig("double_click = play_puase\n", into: c)
    check("misspelled action -> none + warning", c.action("double_click") == "none" && !w.isEmpty)
    c = Config(); w = parseConfig("dbl_click = play_pause\n", into: c)
    check("unknown key ignored + warning", !w.isEmpty)
    c = Config(); w = parseConfig("step = -5\nlong_press_ms = 0\ndouble_click_ms = 99999\n", into: c)
    check("out-of-range values rejected, defaults kept",
          abs(c.step - 0.03) < 0.0001 && c.longPressMs == 500 && c.doubleClickMs == 250 && w.count == 3)
    c = Config(); w = parseConfig("long_press = output_cycle\ndouble_click_ms = 300\ndevice = Studio Display\n", into: c)
    check("valid settings apply", c.action("long_press") == "output_cycle" && c.doubleClickMs == 300 && c.device == "Studio Display")
    c = Config(); w = parseConfig("log_level = debug\n", into: c)
    check("log_level = debug parses", c.logLevel == .debug && w.isEmpty)
    c = Config(); w = parseConfig("log_level = info\n", into: c)
    check("log_level = info parses", c.logLevel == .info && w.isEmpty)
    c = Config(); w = parseConfig("log_level = error\n", into: c)
    check("log_level = error parses", c.logLevel == .error && w.isEmpty)
    c = Config(); w = parseConfig("log_level = verbose\n", into: c)
    check("bad log_level rejected, default info kept", c.logLevel == .info && !w.isEmpty)
    // Filtering matrix — every message level against every configured level.
    check("filter at error: error only",
          shouldLog(.error, at: .error) && !shouldLog(.info, at: .error) && !shouldLog(.debug, at: .error))
    check("filter at info: error + info, not debug",
          shouldLog(.error, at: .info) && shouldLog(.info, at: .info) && !shouldLog(.debug, at: .info))
    check("filter at debug: everything",
          shouldLog(.error, at: .debug) && shouldLog(.info, at: .debug) && shouldLog(.debug, at: .debug))
    // Regression guard: the shipped example must parse clean and leave every
    // commented-out extra OFF.
    if let ex = try? String(contentsOfFile: "powermate.conf.example", encoding: .utf8) {
        c = Config(); w = parseConfig(ex, into: c)
        check("powermate.conf.example: no warnings", w.isEmpty)
        check("powermate.conf.example: extras stay off",
              !c.mapped("double_click") && !c.mapped("long_press")
              && !c.mapped("press_turn_cw") && !c.mapped("press_turn_ccw"))
        check("powermate.conf.example: defaults preserved",
              c.action("turn_cw") == "volume_up" && c.action("click") == "mute_toggle")
    } else {
        print("SKIP  powermate.conf.example not in cwd (run from the repo root)")
    }
    print(fails == 0 ? "all tests passed" : "\(fails) test(s) FAILED")
    return fails
}

// MARK: - Main

let HELP = """
powermate v\(VERSION) — Griffin PowerMate (USB) knob driver, no kext.

usage: powermate [mode]
  (none)              run: read the knob, perform configured actions
  --list              list connected HID devices (VID/PID, names)
  --watch [VID PID]   print raw input reports (default: the PowerMate;
                      pass VID PID — decimal or 0x-hex — to watch another device)
  --selftest          run built-in config-parser tests
  --version           print version
  --help              this help

config: $POWERMATE_CONFIG or ~/.config/powermate/powermate.conf (optional —
        without it: turn=volume, click=mute, click fires instantly)
  gestures: turn_cw turn_ccw click double_click long_press press_turn_cw press_turn_ccw
  actions:  volume_up volume_down mute_toggle play_pause next_track
            previous_track output_cycle none
  settings: device  step  long_press_ms  double_click_ms  log_level
  log_level: error | info (default: + lifecycle) | debug (+ every event,
             timestamped, with the action it resolved to — including none)
env: POWERMATE_DEVICE (output-device name substring; overrides config)
"""

switch CommandLine.arguments.dropFirst().first {
case "--list": listHID()
case "--watch":
    watchMode = true
    let a = CommandLine.arguments
    if a.count >= 4, let v = parseID(a[2]), let p = parseID(a[3]) { startKnob(vid: v, pid: p) }
    else { startKnob() }
case "--selftest": exit(selftest() == 0 ? 0 : 1)
case "--version": print("powermate \(VERSION)")
case "--help", "-h": print(HELP)
default: startKnob()
}
