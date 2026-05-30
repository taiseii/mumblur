// MumblurCore/Sources/MumblurCore/AudioInputs.swift
//
// Microphone-input selection: enumeration via Core Audio, persistence by stable
// UID (so re-plugged USB devices re-bind), application onto an AVAudioEngine's
// HAL input AU. The only piece worth unit-testing in isolation is `resolve`;
// everything else touches real Core Audio and is verified by running the app.

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os

public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public let uid: String
    public let name: String
    public var id: String { uid }
    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public enum AudioInputs {

    /// Given a stored preference UID and the currently-available devices, return
    /// the matching device, or nil meaning "fall back to system default".
    /// - Returns nil when no preference is stored.
    /// - Returns nil when the preferred UID is no longer present (device unplugged).
    public static func resolve(preferredUID: String?, available: [AudioInputDevice]) -> AudioInputDevice? {
        guard let uid = preferredUID else { return nil }
        return available.first { $0.uid == uid }
    }

    /// Enumerate Core Audio devices that have at least one input channel.
    public static func listInputDevices() -> [AudioInputDevice] {
        let ids = allDeviceIDs()
        var out: [AudioInputDevice] = []
        for id in ids where hasInputChannels(id) {
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { continue }
            out.append(AudioInputDevice(uid: uid, name: name))
        }
        return out
    }

    /// Find the live AudioDeviceID for a device UID. Returns nil if not present.
    public static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        for id in allDeviceIDs() {
            if let found = stringProperty(id, kAudioDevicePropertyDeviceUID), found == uid {
                return id
            }
        }
        return nil
    }

    /// Set the current input device on a running/stopped AVAudioEngine's input node.
    /// Must be called before `engine.start()` (or after `engine.stop()`); a no-op if
    /// the engine has no underlying audio unit.
    public static func apply(deviceID: AudioDeviceID, to engine: AVAudioEngine) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw NSError(domain: "MumblurCore.AudioInputs", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no underlying audio unit"])
        }
        var dev = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: "MumblurCore.AudioInputs", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey:
                            "AudioUnitSetProperty(CurrentDevice) failed (\(status))"])
        }
    }

    // MARK: - Core Audio plumbing (private)

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return status == noErr ? ids : []
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, listPtr) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(listPtr)
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard status == noErr else { return nil }
        return cf as String
    }
}
