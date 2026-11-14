// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import CoreBluetooth
@preconcurrency import GameController
import UIKit
import SwiftUI

// MARK: - Pure Steam Controller protocol

/// Model of a connected Valve Steam Controller.
enum SteamControllerModel: String, Sendable, Equatable {
    case triton2026 = "Steam Controller (2026)"
    case original2015 = "Steam Controller"
}

/// Battery report from a 2026 Steam Controller (Triton report 0x43).
struct SteamControllerBattery: Equatable, Sendable {
    /// 1 = discharging, 2 = charging, 4 = charging done.
    var chargeState: UInt8
    /// Percentage 0...100.
    var level: UInt8
    var percent: UInt8 { level }
}

/// Decoded controller state in XInput / DualSense-ready form.
struct SteamControllerSnapshot: Equatable, Sendable {
    var model: SteamControllerModel = .triton2026
    var seqNum: UInt8 = 0
    var rawButtons: UInt32 = 0
    var buttons: UInt16 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var lx: Int16 = 0
    var ly: Int16 = 0
    var rx: Int16 = 0
    var ry: Int16 = 0
    var leftPadTouched: Bool = false
    var rightPadTouched: Bool = false
    var leftPadClicked: Bool = false
    var rightPadClicked: Bool = false
    var leftPadX: Int16 = 0
    var leftPadY: Int16 = 0
    var rightPadX: Int16 = 0
    var rightPadY: Int16 = 0
    var leftPadPressure: UInt16 = 0
    var rightPadPressure: UInt16 = 0
    var imuTimestampUs: UInt64 = 0
    var accelX: Int16 = 0
    var accelY: Int16 = 0
    var accelZ: Int16 = 0
    var gyroX: Int16 = 0
    var gyroY: Int16 = 0
    var gyroZ: Int16 = 0
    var hasIMU: Bool = false

    var lt: UInt8 { leftTrigger }
    var rt: UInt8 { rightTrigger }
    var ltClick: Bool {
        model == .triton2026
            ? (rawButtons & SteamControllerProtocol.tritonLeftTriggerClick) != 0
            : (rawButtons & 0x0000_0002) != 0
    }
    var rtClick: Bool {
        model == .triton2026
            ? (rawButtons & SteamControllerProtocol.tritonRightTriggerClick) != 0
            : (rawButtons & 0x0000_0001) != 0
    }
    var touchpadClicked: Bool { leftPadClicked || rightPadClicked }
}

/// Pure packet encoding and decoding for the 2026 Steam Controller ("Triton" / "Ibex",
/// Valve VID 0x28DE, PIDs 0x1302..0x1305) and 2015 BLE Steam Controller (PID 0x1106).
enum SteamControllerProtocol {
    // BLE GATT service and characteristic UUIDs (Valve custom GATT service).
    static let serviceUUID = "100F6C32-1735-4313-B402-38567131E5F3"
    static let deviceInfoServiceUUID = "180A"
    static let reportCharUUID = "100F6C34-1735-4313-B402-38567131E5F3"
    static let originalInputCharUUID = "100F6C33-1735-4313-B402-38567131E5F3"
    static let tritonStateInputCharUUID = "100F6C77-1735-4313-B402-38567131E5F3"
    static let tritonBatteryCharUUID = "100F6C78-1735-4313-B402-38567131E5F3"
    static let tritonBLEInputCharUUID = "100F6C7A-1735-4313-B402-38567131E5F3"
    static let tritonTimestampInputCharUUID = "100F6C7C-1735-4313-B402-38567131E5F3"
    // Output report 0x80 (ID_OUT_REPORT_HAPTIC_RUMBLE) maps to 0x80 + 0x35 = 0xB5.
    static let tritonHapticRumbleCharUUID = "100F6CB5-1735-4313-B402-38567131E5F3"

    // USB Vendor and Product IDs.
    static let valveVendorID: UInt16 = 0x28DE
    static let originalBLEPID: UInt16 = 0x1106
    static let tritonWiredPID: UInt16 = 0x1302
    static let tritonBLEPID: UInt16 = 0x1303
    static let tritonWirelessPID: UInt16 = 0x1304
    static let tritonPuckPID: UInt16 = 0x1305

    // Triton report IDs.
    static let reportIDTritonState: UInt8 = 0x42
    static let reportIDTritonBattery: UInt8 = 0x43
    static let reportIDTritonStateBLE: UInt8 = 0x45
    static let reportIDTritonStateTimestamp: UInt8 = 0x47
    static let reportIDOriginalBLE: UInt8 = 0x03

    // Triton button masks (32-bit little-endian at offset 1 of TritonMTUNoQuat_t).
    static let tritonButtonA: UInt32                  = 0x0000_0001
    static let tritonButtonB: UInt32                  = 0x0000_0002
    static let tritonButtonX: UInt32                  = 0x0000_0004
    static let tritonButtonY: UInt32                  = 0x0000_0008
    static let tritonButtonQAM: UInt32                = 0x0000_0010
    static let tritonButtonR3: UInt32                 = 0x0000_0020
    static let tritonButtonView: UInt32               = 0x0000_0040
    static let tritonButtonR4: UInt32                 = 0x0000_0080
    static let tritonButtonR5: UInt32                 = 0x0000_0100
    static let tritonButtonRightShoulder: UInt32      = 0x0000_0200
    static let tritonButtonDpadDown: UInt32           = 0x0000_0400
    static let tritonButtonDpadRight: UInt32          = 0x0000_0800
    static let tritonButtonDpadLeft: UInt32           = 0x0000_1000
    static let tritonButtonDpadUp: UInt32             = 0x0000_2000
    static let tritonButtonMenu: UInt32               = 0x0000_4000
    static let tritonButtonL3: UInt32                 = 0x0000_8000
    static let tritonButtonSteam: UInt32              = 0x0001_0000
    static let tritonButtonL4: UInt32                 = 0x0002_0000
    static let tritonButtonL5: UInt32                 = 0x0004_0000
    static let tritonButtonLeftShoulder: UInt32       = 0x0008_0000
    static let tritonRightStickTouch: UInt32          = 0x0010_0000
    static let tritonRightTouchpadTouch: UInt32       = 0x0020_0000
    static let tritonRightTouchpadClick: UInt32       = 0x0040_0000
    static let tritonRightTriggerClick: UInt32        = 0x0080_0000
    static let tritonLeftStickTouch: UInt32           = 0x0100_0000
    static let tritonLeftTouchpadTouch: UInt32        = 0x0200_0000
    static let tritonLeftTouchpadClick: UInt32        = 0x0400_0000
    static let tritonLeftTriggerClick: UInt32         = 0x0800_0000
    static let tritonRightGripTouch: UInt32           = 0x1000_0000
    static let tritonLeftGripTouch: UInt32            = 0x2000_0000

    // XInput button masks.
    static let xinputDpadUp: UInt16        = 0x0001
    static let xinputDpadDown: UInt16      = 0x0002
    static let xinputDpadLeft: UInt16      = 0x0004
    static let xinputDpadRight: UInt16     = 0x0008
    static let xinputStart: UInt16         = 0x0010
    static let xinputBack: UInt16          = 0x0020
    static let xinputLeftThumb: UInt16     = 0x0040
    static let xinputRightThumb: UInt16    = 0x0080
    static let xinputLeftShoulder: UInt16  = 0x0100
    static let xinputRightShoulder: UInt16 = 0x0200
    static let xinputGuide: UInt16         = 0x0400
    static let xinputA: UInt16             = 0x1000
    static let xinputB: UInt16             = 0x2000
    static let xinputX: UInt16             = 0x4000
    static let xinputY: UInt16             = 0x8000

    /// Feature report payload for 100F6C34-... that disables Lizard Mode on the 2026 Steam Controller.
    /// Must be sent on connect and refreshed every ~3 seconds (hardware watchdog is 5 seconds).
    static func tritonLizardModeOffReport() -> Data {
        var bytes = [UInt8](repeating: 0, count: 63)
        bytes[0] = 0x87 // ID_SET_SETTINGS_VALUES
        bytes[1] = 0x03 // 1 setting (3 bytes)
        bytes[2] = 0x09 // SETTING_DEFAULT_DIGITAL_IO_STATE
        bytes[3] = 0x00
        bytes[4] = 0x00
        return Data(bytes)
    }

    /// Feature report payload for 100F6C34-... that enables or disables 6-axis IMU streaming on the 2026 Steam Controller.
    static func tritonIMUModeReport(enabled: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: 63)
        bytes[0] = 0x87 // ID_SET_SETTINGS_VALUES
        bytes[1] = 0x03 // 1 setting (3 bytes)
        bytes[2] = 0x30 // SETTING_IMU_MODE (48)
        // SETTING_GYRO_MODE_SEND_RAW_ACCEL (0x08) | SETTING_GYRO_MODE_SEND_RAW_GYRO (0x10) = 0x18
        bytes[3] = enabled ? 0x18 : 0x00
        bytes[4] = 0x00
        return Data(bytes)
    }

    /// Output report payload for 100F6CB5-... (ID_OUT_REPORT_HAPTIC_RUMBLE = 0x80) on the 2026 Steam Controller.
    /// Note: over BLE GATT characteristic 100F6CB5, the report ID is implied by the characteristic UUID, so the
    /// payload is the 9-byte MsgHapticRumble struct.
    static func tritonHapticRumbleReport(leftSpeed: UInt16, rightSpeed: UInt16) -> Data {
        let bytes: [UInt8] = [
            0x00, // type
            0x00, 0x00, // intensity
            UInt8(leftSpeed & 0xFF), UInt8(leftSpeed >> 8),
            0x00, // left gain
            UInt8(rightSpeed & 0xFF), UInt8(rightSpeed >> 8),
            0x00  // right gain
        ]
        return Data(bytes)
    }

    /// Feature report payload for 100F6C34-... that switches the 2015 BLE Steam Controller into native Valve mode.
    static func originalEnterValveModeReport() -> Data {
        Data([0xC0, 0x87, 0x03, 0x08, 0x07, 0x00])
    }

    @inline(__always)
    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    @inline(__always)
    private static func readI16(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: readU16(bytes, offset))
    }

    @inline(__always)
    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Scale Triton's 0...32767 trigger range (plus digital full-pull click) to XInput's 0...255.
    static func scaleTritonTrigger(_ raw: Int16, clicked: Bool) -> UInt8 {
        if clicked { return 255 }
        if raw <= 0 { return 0 }
        let scaled = (Int(raw) * 255 + 16383) / 32767
        return UInt8(min(255, max(0, scaled)))
    }

    /// Decode a 2026 Steam Controller ("Triton" / "Ibex") BLE/USB state packet (0x45, 0x47, or 0x42).
    /// Accepts either the 45-byte characteristic payload directly or a 46-byte report-ID-prefixed packet.
    static func parseTritonReport(
        _ data: Data,
        reportID: UInt8? = nil,
        mapBackGrips: Bool = true,
        trackpadStickFallback: Bool = true
    ) -> SteamControllerSnapshot? {
        var bytes = [UInt8](data)
        var effectiveID = reportID
        if bytes.count >= 46,
           bytes[0] == reportIDTritonState || bytes[0] == reportIDTritonStateBLE || bytes[0] == reportIDTritonStateTimestamp {
            effectiveID = bytes[0]
            bytes.removeFirst()
        }
        guard bytes.count >= 45 else { return nil }
        let id = effectiveID ?? reportIDTritonStateBLE
        guard id == reportIDTritonState || id == reportIDTritonStateBLE || id == reportIDTritonStateTimestamp else {
            return nil
        }

        var snap = SteamControllerSnapshot()
        snap.model = .triton2026
        snap.seqNum = bytes[0]
        let rawButtons = readU32(bytes, 1)
        snap.rawButtons = rawButtons

        var xi: UInt16 = 0
        if rawButtons & tritonButtonA != 0             { xi |= xinputA }
        if rawButtons & tritonButtonB != 0             { xi |= xinputB }
        if rawButtons & tritonButtonX != 0             { xi |= xinputX }
        if rawButtons & tritonButtonY != 0             { xi |= xinputY }
        if rawButtons & tritonButtonLeftShoulder != 0  { xi |= xinputLeftShoulder }
        if rawButtons & tritonButtonRightShoulder != 0 { xi |= xinputRightShoulder }
        if rawButtons & tritonButtonView != 0          { xi |= xinputStart }
        if rawButtons & tritonButtonMenu != 0          { xi |= xinputBack }
        if rawButtons & tritonButtonL3 != 0            { xi |= xinputLeftThumb }
        if rawButtons & tritonButtonR3 != 0            { xi |= xinputRightThumb }
        if rawButtons & (tritonButtonSteam | tritonButtonQAM) != 0 { xi |= xinputGuide }
        if rawButtons & tritonButtonDpadUp != 0        { xi |= xinputDpadUp }
        if rawButtons & tritonButtonDpadDown != 0      { xi |= xinputDpadDown }
        if rawButtons & tritonButtonDpadLeft != 0      { xi |= xinputDpadLeft }
        if rawButtons & tritonButtonDpadRight != 0     { xi |= xinputDpadRight }

        if mapBackGrips {
            if rawButtons & tritonButtonL4 != 0 { xi |= xinputLeftThumb }
            if rawButtons & tritonButtonR4 != 0 { xi |= xinputRightThumb }
            if rawButtons & tritonButtonL5 != 0 { xi |= xinputA }
            if rawButtons & tritonButtonR5 != 0 { xi |= xinputB }
        }

        let rawLT = readI16(bytes, 5)
        let rawRT = readI16(bytes, 7)
        snap.leftTrigger = scaleTritonTrigger(rawLT, clicked: (rawButtons & tritonLeftTriggerClick) != 0)
        snap.rightTrigger = scaleTritonTrigger(rawRT, clicked: (rawButtons & tritonRightTriggerClick) != 0)

        snap.lx = readI16(bytes, 9)
        snap.ly = readI16(bytes, 11)
        snap.rx = readI16(bytes, 13)
        snap.ry = readI16(bytes, 15)

        snap.leftPadTouched = (rawButtons & tritonLeftTouchpadTouch) != 0
        snap.rightPadTouched = (rawButtons & tritonRightTouchpadTouch) != 0
        snap.leftPadClicked = (rawButtons & tritonLeftTouchpadClick) != 0
        snap.rightPadClicked = (rawButtons & tritonRightTouchpadClick) != 0

        if id == reportIDTritonStateTimestamp {
            // TritonMTUNoQuat32TS_t: uint16 unTrackpadTimestamp at 17..18, pads at 19..30, uint16 32us IMU timestamp at 31..32.
            snap.leftPadX = readI16(bytes, 19)
            snap.leftPadY = readI16(bytes, 21)
            snap.leftPadPressure = readU16(bytes, 23)
            snap.rightPadX = readI16(bytes, 25)
            snap.rightPadY = readI16(bytes, 27)
            snap.rightPadPressure = readU16(bytes, 29)
            snap.imuTimestampUs = UInt64(readU16(bytes, 31)) * 32
        } else {
            // TritonMTUNoQuat_t: pads at 17..28, uint32 1us IMU timestamp at 29..32.
            snap.leftPadX = readI16(bytes, 17)
            snap.leftPadY = readI16(bytes, 19)
            snap.leftPadPressure = readU16(bytes, 21)
            snap.rightPadX = readI16(bytes, 23)
            snap.rightPadY = readI16(bytes, 25)
            snap.rightPadPressure = readU16(bytes, 27)
            snap.imuTimestampUs = UInt64(readU32(bytes, 29))
        }

        snap.accelX = readI16(bytes, 33)
        snap.accelY = readI16(bytes, 35)
        snap.accelZ = readI16(bytes, 37)
        snap.gyroX = readI16(bytes, 39)
        snap.gyroY = readI16(bytes, 41)
        snap.gyroZ = readI16(bytes, 43)
        snap.hasIMU = snap.imuTimestampUs != 0
            || snap.gyroX != 0 || snap.gyroY != 0 || snap.gyroZ != 0
            || snap.accelX != 0 || snap.accelY != 0 || snap.accelZ != 0

        // Trackpad fallback for XInput games when the player uses the trackpads as right stick / D-pad.
        if trackpadStickFallback {
            if snap.rightPadClicked {
                xi |= xinputRightThumb
            }
            if snap.rightPadTouched, abs(Int(snap.rx)) < 4000, abs(Int(snap.ry)) < 4000 {
                snap.rx = snap.rightPadX
                snap.ry = snap.rightPadY
            }
            if snap.leftPadClicked {
                let threshold: Int16 = 8000
                var dir: UInt16 = 0
                if snap.leftPadY > threshold { dir |= xinputDpadUp }
                else if snap.leftPadY < -threshold { dir |= xinputDpadDown }
                if snap.leftPadX > threshold { dir |= xinputDpadRight }
                else if snap.leftPadX < -threshold { dir |= xinputDpadLeft }
                xi |= (dir != 0 ? dir : xinputLeftThumb)
            }
        }

        snap.buttons = xi
        return snap
    }

    /// Decode a 2026 Steam Controller battery status packet (0x43, TritonBatteryStatus_t).
    static func parseTritonBattery(_ data: Data) -> SteamControllerBattery? {
        var bytes = [UInt8](data)
        if bytes.count >= 3, bytes[0] == reportIDTritonBattery {
            bytes.removeFirst()
        }
        guard bytes.count >= 2 else { return nil }
        let state = bytes[0]
        let level = min(100, bytes[1])
        return SteamControllerBattery(chargeState: state, level: level)
    }

    /// Decode a 2015 BLE Steam Controller packet (characteristic 100F6C33, report 0x03).
    static func parseOriginalBLEReport(
        _ data: Data,
        previous snap: inout SteamControllerSnapshot,
        mapBackGrips: Bool = true
    ) -> Bool {
        var bytes = [UInt8](data)
        if bytes.first == reportIDOriginalBLE {
            bytes.removeFirst()
        }
        guard bytes.count >= 2, (bytes[0] & 0x0F) == 4 else { return false } // k_EBLEReportState = 4
        snap.model = .original2015
        snap.seqNum &+= 1

        let optionMask = UInt32(bytes[0] & 0xF0) | (UInt32(bytes[1]) << 8)
        var offset = 2
        var rawButtons = snap.rawButtons

        // k_EBLEButtonChunk1 = 0x10 (3 bytes: buttons 0..23)
        if optionMask & 0x0010 != 0 {
            guard offset + 3 <= bytes.count else { return false }
            let b0 = UInt32(bytes[offset])
            let b1 = UInt32(bytes[offset + 1]) << 8
            let b2 = UInt32(bytes[offset + 2]) << 16
            rawButtons = (rawButtons & 0xFF00_0000) | b0 | b1 | b2
            offset += 3
        }
        // k_EBLEButtonChunk2 = 0x20 (2 bytes: left/right analog triggers)
        if optionMask & 0x0020 != 0 {
            guard offset + 2 <= bytes.count else { return false }
            snap.leftTrigger = bytes[offset]
            snap.rightTrigger = bytes[offset + 1]
            offset += 2
        }
        // k_EBLEButtonChunk3 = 0x40 (3 bytes)
        if optionMask & 0x0040 != 0 {
            guard offset + 3 <= bytes.count else { return false }
            offset += 3
        }
        // k_EBLELeftJoystickChunk = 0x80 (4 bytes: lx, ly)
        if optionMask & 0x0080 != 0 {
            guard offset + 4 <= bytes.count else { return false }
            snap.lx = readI16(bytes, offset)
            snap.ly = readI16(bytes, offset + 2)
            offset += 4
        }
        // k_EBLELeftTrackpadChunk = 0x100 (4 bytes: leftPadX, leftPadY)
        if optionMask & 0x0100 != 0 {
            guard offset + 4 <= bytes.count else { return false }
            snap.leftPadX = readI16(bytes, offset)
            snap.leftPadY = readI16(bytes, offset + 2)
            offset += 4
        }
        // k_EBLERightTrackpadChunk = 0x200 (4 bytes: rightPadX, rightPadY)
        if optionMask & 0x0200 != 0 {
            guard offset + 4 <= bytes.count else { return false }
            snap.rightPadX = readI16(bytes, offset)
            snap.rightPadY = readI16(bytes, offset + 2)
            offset += 4
        }
        // k_EBLEIMUAccelChunk = 0x400 (6 bytes)
        if optionMask & 0x0400 != 0 {
            guard offset + 6 <= bytes.count else { return false }
            snap.accelX = readI16(bytes, offset)
            snap.accelY = readI16(bytes, offset + 2)
            snap.accelZ = readI16(bytes, offset + 4)
            snap.hasIMU = true
            offset += 6
        }
        // k_EBLEIMUGyroChunk = 0x800 (6 bytes)
        if optionMask & 0x0800 != 0 {
            guard offset + 6 <= bytes.count else { return false }
            snap.gyroX = readI16(bytes, offset)
            snap.gyroY = readI16(bytes, offset + 2)
            snap.gyroZ = readI16(bytes, offset + 4)
            snap.hasIMU = true
            offset += 6
        }

        snap.rawButtons = rawButtons
        snap.leftPadTouched = (rawButtons & 0x0008_0000) != 0
        snap.rightPadTouched = (rawButtons & 0x0010_0000) != 0
        snap.leftPadClicked = (rawButtons & 0x0002_0000) != 0
        snap.rightPadClicked = (rawButtons & 0x0004_0000) != 0

        var xi: UInt16 = 0
        if rawButtons & 0x0000_0080 != 0 { xi |= xinputA }
        if rawButtons & 0x0000_0020 != 0 { xi |= xinputB }
        if rawButtons & 0x0000_0040 != 0 { xi |= xinputX }
        if rawButtons & 0x0000_0010 != 0 { xi |= xinputY }
        if rawButtons & 0x0000_0008 != 0 { xi |= xinputLeftShoulder }
        if rawButtons & 0x0000_0004 != 0 { xi |= xinputRightShoulder }
        if rawButtons & 0x0000_1000 != 0 { xi |= xinputBack }
        if rawButtons & 0x0000_2000 != 0 { xi |= xinputGuide }
        if rawButtons & 0x0000_4000 != 0 { xi |= xinputStart }
        if rawButtons & 0x0040_0000 != 0 { xi |= xinputLeftThumb }
        if rawButtons & 0x0004_0000 != 0 { xi |= xinputRightThumb }
        if rawButtons & 0x0000_0100 != 0 { xi |= xinputDpadUp }
        if rawButtons & 0x0000_0200 != 0 { xi |= xinputDpadRight }
        if rawButtons & 0x0000_0400 != 0 { xi |= xinputDpadLeft }
        if rawButtons & 0x0000_0800 != 0 { xi |= xinputDpadDown }
        if mapBackGrips {
            if rawButtons & 0x0000_8000 != 0 { xi |= xinputLeftThumb }
            if rawButtons & 0x0001_0000 != 0 { xi |= xinputRightThumb }
        }
        if rawButtons & 0x0000_0002 != 0 { snap.leftTrigger = 255 }
        if rawButtons & 0x0000_0001 != 0 { snap.rightTrigger = 255 }
        snap.rx = snap.rightPadTouched ? snap.rightPadX : 0
        snap.ry = snap.rightPadTouched ? snap.rightPadY : 0
        snap.buttons = xi
        return true
    }

    /// Map the Steam Controller's left and right trackpads into the DualSense's 1920x1080 two-finger touchpad.
    static func dualSenseTouchPoints(from snap: SteamControllerSnapshot) -> (
        left: (down: Bool, x: UInt16, y: UInt16),
        right: (down: Bool, x: UInt16, y: UInt16),
        clicked: Bool
    ) {
        func mapCoord(_ raw: Int16, invert: Bool, minOut: Int, maxOut: Int) -> UInt16 {
            let norm = (Double(raw) / 65536.0) * (invert ? -1.0 : 1.0) + 0.5
            let clamped = max(0.0, min(1.0, norm))
            let val = minOut + Int((clamped * Double(maxOut - minOut)).rounded())
            return UInt16(max(minOut, min(maxOut, val)))
        }
        let lx = mapCoord(snap.leftPadX, invert: false, minOut: 0, maxOut: 959)
        let ly = mapCoord(snap.leftPadY, invert: true, minOut: 0, maxOut: 1079)
        let rx = mapCoord(snap.rightPadX, invert: false, minOut: 960, maxOut: 1919)
        let ry = mapCoord(snap.rightPadY, invert: true, minOut: 0, maxOut: 1079)
        return (
            left: (snap.leftPadTouched, lx, ly),
            right: (snap.rightPadTouched, rx, ry),
            clicked: snap.leftPadClicked || snap.rightPadClicked
        )
    }

    static func dualSenseTouchpad(from snap: SteamControllerSnapshot) -> (
        touch0: UInt8, x0: UInt16, y0: UInt16,
        touch1: UInt8, x1: UInt16, y1: UInt16
    ) {
        let pts = dualSenseTouchPoints(from: snap)
        return (
            touch0: pts.left.down ? 1 : 0, x0: pts.left.x, y0: pts.left.y,
            touch1: pts.right.down ? 1 : 0, x1: pts.right.x, y1: pts.right.y
        )
    }

    /// Convert Triton/Steam Controller raw gyro (2000 deg/s full scale over 32768) to radians/sec
    /// in GameController's axis frame (x right, y away from player, z out of face).
    static func gyroRadiansPerSecond(from snap: SteamControllerSnapshot) -> (x: Double, y: Double, z: Double)? {
        guard snap.hasIMU else { return nil }
        let scale = (2000.0 / 32768.0) * (.pi / 180.0)
        return (
            x: Double(snap.gyroX) * scale,
            y: Double(snap.gyroY) * scale,
            z: Double(snap.gyroZ) * scale
        )
    }

    /// Convert Triton/Steam Controller IMU to DualSense HID report units (16 units per deg/s, 8192 units per g).
    static func dualSenseMotion(from snap: SteamControllerSnapshot) -> (
        gyro: (Int16, Int16, Int16),
        accel: (Int16, Int16, Int16)
    )? {
        guard snap.hasIMU else { return nil }
        let gy = snap.gyroY == Int16.min ? Int16.max : -snap.gyroY
        let ay = snap.accelY == Int16.min ? Int16.max : -snap.accelY
        return (
            gyro: (snap.gyroX, snap.gyroZ, gy),
            accel: (snap.accelX / 2, snap.accelZ / 2, ay / 2)
        )
    }
}

// MARK: - CoreBluetooth manager & GCPhysicalInputProfile fallback

/// Reads a GCController whose `extendedGamepad` is nil (e.g. a 2026 Steam Controller connected via
/// USB-C or 2.4 GHz Puck whose HID descriptor is exposed through `physicalInputProfile`).
enum SteamControllerGCProfileFallback {
    static func isCandidate(_ controller: GCController) -> Bool {
        if controller.extendedGamepad != nil { return false }
        let vendor = controller.vendorName ?? ""
        let category = controller.productCategory
        let combined = "\(vendor) \(category)".lowercased()
        if combined.contains("steam") || combined.contains("valve")
            || combined.contains("triton") || combined.contains("ibex") {
            return true
        }
        let profile = controller.physicalInputProfile
        return profile.buttons[GCInputButtonA] != nil && profile.dpads[GCInputLeftThumbstick] != nil
    }

    static func sample(_ profile: GCPhysicalInputProfile) -> SteamControllerSnapshot {
        var snap = SteamControllerSnapshot()
        let buttons = profile.buttons
        let dpads = profile.dpads

        var xi: UInt16 = 0
        if buttons[GCInputButtonA]?.isPressed == true { xi |= SteamControllerProtocol.xinputA }
        if buttons[GCInputButtonB]?.isPressed == true { xi |= SteamControllerProtocol.xinputB }
        if buttons[GCInputButtonX]?.isPressed == true { xi |= SteamControllerProtocol.xinputX }
        if buttons[GCInputButtonY]?.isPressed == true { xi |= SteamControllerProtocol.xinputY }
        if buttons[GCInputLeftShoulder]?.isPressed == true { xi |= SteamControllerProtocol.xinputLeftShoulder }
        if buttons[GCInputRightShoulder]?.isPressed == true { xi |= SteamControllerProtocol.xinputRightShoulder }
        if buttons[GCInputButtonMenu]?.isPressed == true { xi |= SteamControllerProtocol.xinputStart }
        if buttons[GCInputButtonOptions]?.isPressed == true { xi |= SteamControllerProtocol.xinputBack }
        if buttons[GCInputLeftThumbstickButton]?.isPressed == true { xi |= SteamControllerProtocol.xinputLeftThumb }
        if buttons[GCInputRightThumbstickButton]?.isPressed == true { xi |= SteamControllerProtocol.xinputRightThumb }
        if buttons[GCInputButtonHome]?.isPressed == true { xi |= SteamControllerProtocol.xinputGuide }

        if let dpad = dpads[GCInputDirectionPad] {
            if dpad.up.isPressed { xi |= SteamControllerProtocol.xinputDpadUp }
            if dpad.down.isPressed { xi |= SteamControllerProtocol.xinputDpadDown }
            if dpad.left.isPressed { xi |= SteamControllerProtocol.xinputDpadLeft }
            if dpad.right.isPressed { xi |= SteamControllerProtocol.xinputDpadRight }
        }
        snap.buttons = xi

        if let lt = buttons[GCInputLeftTrigger]?.value {
            snap.leftTrigger = GamepadInput.trigger(lt)
        }
        if let rt = buttons[GCInputRightTrigger]?.value {
            snap.rightTrigger = GamepadInput.trigger(rt)
        }
        if let leftStick = dpads[GCInputLeftThumbstick] {
            snap.lx = GamepadInput.axis(leftStick.xAxis.value)
            snap.ly = GamepadInput.axis(leftStick.yAxis.value)
        }
        if let rightStick = dpads[GCInputRightThumbstick] {
            snap.rx = GamepadInput.axis(rightStick.xAxis.value)
            snap.ry = GamepadInput.axis(rightStick.yAxis.value)
        }
        return snap
    }
}

/// Manages Bluetooth Low Energy (BLE) connections to 2026 Steam Controllers ("Triton" / "Ibex")
/// and 2015 BLE Steam Controllers via Valve's custom GATT service (`100F6C32-1735-4313-B402-38567131E5F3`).
final class SteamControllerManager: NSObject, @unchecked Sendable, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = SteamControllerManager()

    static let didConnectNotification = Notification.Name("MadeiraSteamControllerDidConnect")
    static let didDisconnectNotification = Notification.Name("MadeiraSteamControllerDidDisconnect")

    private final class DeviceEntry {
        let peripheral: CBPeripheral
        var model: SteamControllerModel = .triton2026
        var snapshot = SteamControllerSnapshot()
        var battery: SteamControllerBattery?
        var reportChar: CBCharacteristic?
        var hapticRumbleChar: CBCharacteristic?
        var ready: Bool = false
        var leftMotor: UInt16 = 0
        var rightMotor: UInt16 = 0

        init(peripheral: CBPeripheral) {
            self.peripheral = peripheral
        }
    }

    private let lock = NSLock()
    private let bleQueue = DispatchQueue(label: "madeira.steam.ble", qos: .userInteractive)
    private var central: CBCentralManager?
    private var entries: [UUID: DeviceEntry] = [:]
    private var slotPeripherals: [UUID?] = [nil, nil, nil, nil]
    private var lizardWatchdog: DispatchSourceTimer?
    private var rumbleWatchdog: DispatchSourceTimer?
    private var scanTimer: DispatchSourceTimer?
    private var imuWanted: Bool = false
    private var started: Bool = false

    /// Invoked whenever a BLE Steam Controller input report arrives.
    var onValueChanged: (() -> Void)?

    /// Invoked on the main queue when a BLE Steam Controller connects or disconnects.
    var onConnectionChanged: (() -> Void)?

    /// Settings › Steam Controller (Bluetooth). Off by default, so EmuPC only
    /// asks for Bluetooth when the player turns it on.
    static let enabledKey = "steamControllerBluetooth"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Turns the Bluetooth Steam Controller driver on or off and remembers it.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    /// Start CoreBluetooth discovery and connected-peripheral retrieval for Steam Controllers.
    /// Does nothing until the player turns the setting on.
    func start() {
        guard Self.enabled else { return }
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        bleQueue.async { [weak self] in
            guard let self else { return }
            self.central = CBCentralManager(delegate: self, queue: self.bleQueue, options: [
                CBCentralManagerOptionShowPowerAlertKey: false
            ])
        }
    }

    /// Disconnects every Steam Controller and releases Bluetooth.
    func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        lock.unlock()
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.stopPeriodicDiscovery()
            self.lock.lock()
            let hadReady = self.entries.values.contains { $0.ready }
            let peripherals = self.entries.values.map { $0.peripheral }
            self.entries.removeAll()
            self.slotPeripherals = [nil, nil, nil, nil]
            self.lock.unlock()
            for peripheral in peripherals { self.central?.cancelPeripheralConnection(peripheral) }
            self.central?.delegate = nil
            self.central = nil
            self.updateLizardWatchdog()
            self.updateRumbleWatchdog()
            if hadReady {
                DispatchQueue.main.async { [weak self] in
                    self?.onConnectionChanged?()
                    NotificationCenter.default.post(name: Self.didDisconnectNotification, object: nil)
                }
            }
        }
    }

    /// True if at least one BLE Steam Controller is connected and ready.
    var hasConnectedController: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.contains { $0.ready }
    }

    /// Connected BLE Steam Controller UUIDs in connection order.
    func connectedIDs() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { $0.ready }.map { $0.peripheral.identifier }
    }

    /// Assigns slot indices (0..<4) for connected BLE Steam Controllers so rumble and snapshots map to the right slot.
    func updateSlotAssignment(_ slots: [UUID?]) {
        lock.lock()
        for i in 0..<min(4, slots.count) {
            slotPeripherals[i] = slots[i]
        }
        lock.unlock()
    }

    /// Latest snapshot for the BLE Steam Controller in `slot`, or nil if none.
    func snapshot(slot: Int) -> SteamControllerSnapshot? {
        guard (0..<4).contains(slot) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let id = slotPeripherals[slot], let entry = entries[id], entry.ready else { return nil }
        return entry.snapshot
    }

    /// Latest battery status for the BLE Steam Controller in `slot`, or nil if unknown.
    func battery(slot: Int) -> SteamControllerBattery? {
        guard (0..<4).contains(slot) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let id = slotPeripherals[slot], let entry = entries[id], entry.ready else { return nil }
        return entry.battery
    }

    /// First connected BLE Steam Controller's battery level (0...1), for the UI top bar.
    var primaryBatteryLevel: Float? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.values.first(where: { $0.ready && $0.battery != nil }),
              let bat = entry.battery else { return nil }
        return Float(bat.level) / 100.0
    }

    /// Enable or disable 6-axis IMU streaming on connected 2026 Steam Controllers.
    func setIMUEnabled(_ enabled: Bool) {
        lock.lock()
        let changed = imuWanted != enabled
        imuWanted = enabled
        lock.unlock()
        guard changed else { return }
        bleQueue.async { [weak self] in
            self?.sendIMUModeToAll()
        }
    }

    /// Set haptic rumble motor speeds (0...1 float each) for `slot`.
    func setRumble(slot: Int, low: Float, high: Float) {
        guard (0..<4).contains(slot) else { return }
        let left = UInt16(max(0, min(65535, (low * 65535.0).rounded())))
        let right = UInt16(max(0, min(65535, (high * 65535.0).rounded())))
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let id = self.slotPeripherals[slot], let entry = self.entries[id], entry.ready else {
                self.lock.unlock()
                return
            }
            let changed = entry.leftMotor != left || entry.rightMotor != right
            entry.leftMotor = left
            entry.rightMotor = right
            self.lock.unlock()
            if changed {
                self.sendRumble(to: entry)
                self.updateRumbleWatchdog()
            }
        }
    }

    // MARK: - BLE internal helpers (bleQueue)

    private static let valveServiceCBUUID = CBUUID(string: SteamControllerProtocol.serviceUUID)
    private static let deviceInfoServiceCBUUID = CBUUID(string: SteamControllerProtocol.deviceInfoServiceUUID)

    private static func isSteamControllerName(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.hasPrefix("steam") || name.contains("steam controller") || name.contains("steam ctrl")
    }

    private func pollConnectedPeripherals() {
        guard let central, central.state == .poweredOn else { return }
        lock.lock()
        let busy = entries.count >= 4
        lock.unlock()
        if busy { return }
        let valvePeripherals = central.retrieveConnectedPeripherals(withServices: [Self.valveServiceCBUUID])
        let infoPeripherals = central.retrieveConnectedPeripherals(withServices: [Self.deviceInfoServiceCBUUID])
            .filter { Self.isSteamControllerName($0.name) }
        for peripheral in valvePeripherals + infoPeripherals {
            connectPeripheralIfNeeded(peripheral)
        }
    }

    private func connectPeripheralIfNeeded(_ peripheral: CBPeripheral) {
        lock.lock()
        if entries[peripheral.identifier] != nil {
            lock.unlock()
            return
        }
        let entry = DeviceEntry(peripheral: peripheral)
        entries[peripheral.identifier] = entry
        lock.unlock()

        peripheral.delegate = self
        LogStore.shared.log("[steam-pad] connecting to BLE peripheral name=\(peripheral.name ?? "Steam Controller") id=\(peripheral.identifier)")
        central?.connect(peripheral, options: nil)
    }

    /// Radio scanning runs for a short window after Bluetooth comes on (or the
    /// setting is turned on), then stops; paired controllers that iOS already
    /// connected are still picked up by the cheap connected-peripheral poll.
    private static let scanWindow: DispatchTimeInterval = .seconds(30)
    private var scanStop: DispatchWorkItem?

    private func startPeriodicDiscovery() {
        guard scanTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.pollConnectedPeripherals()
        }
        scanTimer = timer
        timer.resume()
        central?.scanForPeripherals(withServices: [Self.valveServiceCBUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        let stop = DispatchWorkItem { [weak self] in
            guard let self, let central = self.central, central.isScanning else { return }
            central.stopScan()
            LogStore.shared.log("[steam-pad] Bluetooth scan window ended")
        }
        scanStop = stop
        bleQueue.asyncAfter(deadline: .now() + Self.scanWindow, execute: stop)
    }

    private func stopPeriodicDiscovery() {
        scanTimer?.cancel()
        scanTimer = nil
        scanStop?.cancel()
        scanStop = nil
        if let central, central.state == .poweredOn, central.isScanning { central.stopScan() }
    }

    private func updateLizardWatchdog() {
        lock.lock()
        let hasTriton = entries.values.contains { $0.ready && $0.model == .triton2026 && $0.reportChar != nil }
        lock.unlock()
        if !hasTriton {
            lizardWatchdog?.cancel()
            lizardWatchdog = nil
            return
        }
        guard lizardWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        // Triton hardware watchdog re-enables Lizard Mode after 5 seconds without this message.
        timer.schedule(deadline: .now() + .seconds(3), repeating: .seconds(3), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.sendLizardModeOffToAll()
        }
        lizardWatchdog = timer
        timer.resume()
    }

    private func sendLizardModeOffToAll() {
        lock.lock()
        let list = entries.values.filter { $0.ready && $0.model == .triton2026 }
        lock.unlock()
        let payload = SteamControllerProtocol.tritonLizardModeOffReport()
        for entry in list {
            guard let char = entry.reportChar else { continue }
            let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            entry.peripheral.writeValue(payload, for: char, type: writeType)
        }
    }

    private func sendIMUModeToAll() {
        lock.lock()
        let enabled = imuWanted
        let list = entries.values.filter { $0.ready && $0.model == .triton2026 }
        lock.unlock()
        let payload = SteamControllerProtocol.tritonIMUModeReport(enabled: enabled)
        for entry in list {
            guard let char = entry.reportChar else { continue }
            let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            entry.peripheral.writeValue(payload, for: char, type: writeType)
        }
    }

    private func sendRumble(to entry: DeviceEntry) {
        guard let char = entry.hapticRumbleChar else { return }
        lock.lock()
        let left = entry.leftMotor
        let right = entry.rightMotor
        lock.unlock()
        let payload = SteamControllerProtocol.tritonHapticRumbleReport(leftSpeed: left, rightSpeed: right)
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        entry.peripheral.writeValue(payload, for: char, type: writeType)
    }

    private func updateRumbleWatchdog() {
        lock.lock()
        let activeRumble = entries.values.contains { $0.ready && ($0.leftMotor > 0 || $0.rightMotor > 0) && $0.hapticRumbleChar != nil }
        lock.unlock()
        if !activeRumble {
            rumbleWatchdog?.cancel()
            rumbleWatchdog = nil
            return
        }
        guard rumbleWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        // Triton haptic rumble stops after 50ms unless refreshed every 40ms.
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let list = self.entries.values.filter { $0.ready && ($0.leftMotor > 0 || $0.rightMotor > 0) }
            self.lock.unlock()
            if list.isEmpty {
                self.updateRumbleWatchdog()
                return
            }
            for entry in list {
                self.sendRumble(to: entry)
            }
        }
        rumbleWatchdog = timer
        timer.resume()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startPeriodicDiscovery()
        } else {
            stopPeriodicDiscovery()
            lock.lock()
            let hadReady = entries.values.contains { $0.ready }
            entries.removeAll()
            slotPeripherals = [nil, nil, nil, nil]
            lock.unlock()
            updateLizardWatchdog()
            updateRumbleWatchdog()
            if hadReady {
                DispatchQueue.main.async { [weak self] in
                    self?.onConnectionChanged?()
                    NotificationCenter.default.post(name: Self.didDisconnectNotification, object: nil)
                }
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        connectPeripheralIfNeeded(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.valveServiceCBUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        entries.removeValue(forKey: peripheral.identifier)
        lock.unlock()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        let removed = entries.removeValue(forKey: peripheral.identifier)
        for i in 0..<4 where slotPeripherals[i] == peripheral.identifier {
            slotPeripherals[i] = nil
        }
        lock.unlock()
        updateLizardWatchdog()
        updateRumbleWatchdog()
        if removed?.ready == true {
            LogStore.shared.log("[steam-pad] disconnected BLE Steam Controller name=\(peripheral.name ?? "Steam Controller")")
            DispatchQueue.main.async { [weak self] in
                self?.onConnectionChanged?()
                NotificationCenter.default.post(name: Self.didDisconnectNotification, object: nil)
            }
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.valveServiceCBUUID {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard service.uuid == Self.valveServiceCBUUID, let chars = service.characteristics else { return }
        lock.lock()
        guard let entry = entries[peripheral.identifier] else {
            lock.unlock()
            return
        }
        var foundTritonInput = false
        var foundOriginalInput = false
        for char in chars {
            let uuid = char.uuid.uuidString.uppercased()
            switch uuid {
            case SteamControllerProtocol.reportCharUUID:
                entry.reportChar = char
            case SteamControllerProtocol.tritonHapticRumbleCharUUID:
                entry.hapticRumbleChar = char
            case SteamControllerProtocol.tritonBLEInputCharUUID,
                 SteamControllerProtocol.tritonTimestampInputCharUUID,
                 SteamControllerProtocol.tritonStateInputCharUUID:
                foundTritonInput = true
                peripheral.setNotifyValue(true, for: char)
            case SteamControllerProtocol.tritonBatteryCharUUID:
                peripheral.setNotifyValue(true, for: char)
                peripheral.readValue(for: char)
            case SteamControllerProtocol.originalInputCharUUID:
                foundOriginalInput = true
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }
        entry.model = foundTritonInput ? .triton2026 : (foundOriginalInput ? .original2015 : .triton2026)
        let becameReady = !entry.ready && (foundTritonInput || foundOriginalInput)
        if becameReady {
            entry.ready = true
        }
        let reportChar = entry.reportChar
        let model = entry.model
        let enableIMU = imuWanted
        lock.unlock()

        if let reportChar {
            let writeType: CBCharacteristicWriteType = reportChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            if model == .triton2026 {
                peripheral.writeValue(SteamControllerProtocol.tritonLizardModeOffReport(), for: reportChar, type: writeType)
                if enableIMU {
                    peripheral.writeValue(SteamControllerProtocol.tritonIMUModeReport(enabled: true), for: reportChar, type: writeType)
                }
            } else {
                peripheral.writeValue(SteamControllerProtocol.originalEnterValveModeReport(), for: reportChar, type: writeType)
            }
        }
        updateLizardWatchdog()

        if becameReady {
            LogStore.shared.log("[steam-pad] connected \(model.rawValue) over BLE name=\(peripheral.name ?? "Steam Controller")")
            DispatchQueue.main.async { [weak self] in
                self?.onConnectionChanged?()
                NotificationCenter.default.post(name: Self.didConnectNotification, object: nil)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()
        let mapGrips = ProcessInfo.processInfo.environment["MADEIRA_STEAM_GRIPS"] != "0"

        lock.lock()
        guard let entry = entries[peripheral.identifier] else {
            lock.unlock()
            return
        }

        var updatedInput = false
        switch uuid {
        case SteamControllerProtocol.tritonBLEInputCharUUID:
            if let snap = SteamControllerProtocol.parseTritonReport(
                data,
                reportID: SteamControllerProtocol.reportIDTritonStateBLE,
                mapBackGrips: mapGrips
            ) {
                entry.snapshot = snap
                updatedInput = true
            }
        case SteamControllerProtocol.tritonTimestampInputCharUUID:
            if let snap = SteamControllerProtocol.parseTritonReport(
                data,
                reportID: SteamControllerProtocol.reportIDTritonStateTimestamp,
                mapBackGrips: mapGrips
            ) {
                entry.snapshot = snap
                updatedInput = true
            }
        case SteamControllerProtocol.tritonStateInputCharUUID:
            if let snap = SteamControllerProtocol.parseTritonReport(
                data,
                reportID: SteamControllerProtocol.reportIDTritonState,
                mapBackGrips: mapGrips
            ) {
                entry.snapshot = snap
                updatedInput = true
            }
        case SteamControllerProtocol.tritonBatteryCharUUID:
            if let bat = SteamControllerProtocol.parseTritonBattery(data) {
                entry.battery = bat
            }
        case SteamControllerProtocol.originalInputCharUUID:
            if SteamControllerProtocol.parseOriginalBLEReport(data, previous: &entry.snapshot, mapBackGrips: mapGrips) {
                updatedInput = true
            }
        default:
            break
        }
        lock.unlock()

        if updatedInput {
            onValueChanged?()
        }
    }
}


// MARK: - Settings

/// Settings › Steam Controller. Off by default: turning it on asks for Bluetooth.
struct SteamControllerSettingsSection: View {
    @State private var on = SteamControllerManager.enabled

    var body: some View {
        Section {
            Toggle("Steam Controller over Bluetooth", isOn: Binding(get: { on }, set: { value in
                on = value
                SteamControllerManager.shared.setEnabled(value)
            }))
        } header: {
            Text("Steam Controller")
        } footer: {
            Text("For Valve's Steam Controllers paired over Bluetooth. EmuPC asks for Bluetooth access when you turn this on. Other controllers don't need it.")
        }
    }
}
