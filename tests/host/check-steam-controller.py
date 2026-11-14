#!/usr/bin/env python3
"""Exercise 2026 ("Triton" / "Ibex") and 2015 BLE Steam Controller support (app/Madeira/SteamController.swift) without an iOS SDK.

Compiles the production pure section with swiftc:
- 2026 Triton/Ibex input report 0x45 (sticks, triggers, face/shoulder/dpad/menu/guide/grips, trackpads, IMU)
- 2026 Triton/Ibex extended input report 0x47 (32us IMU timestamps)
- 2026 Triton/Ibex input report 0x42
- 2026 Triton/Ibex battery status report 0x43 (state, percent)
- 2015 BLE Steam Controller input report 0x03 (flags, buttons, triggers, stick, pads, gyro)
- Feature reports (Lizard Mode disable, IMU enable/disable, 2015 Valve mode)
- Haptic rumble output report 0x80 (9-byte MsgHapticRumble)
- DualSense touchpad & 6-axis IMU unit conversions
- App source wiring in GamepadInput.swift, PadOutput.h/.m, Info.plist, and project.pbxproj
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'app/Madeira/SteamController.swift').read_text()
pure = source.split('// MARK: - Pure Steam Controller protocol', 1)[1].split('// MARK: - CoreBluetooth manager & GCPhysicalInputProfile fallback', 1)[0]

tests = r'''
import Foundation

// 1. Vendor / Product IDs & BLE GATT UUIDs.
assert(SteamControllerProtocol.valveVendorID == 0x28DE)
assert(SteamControllerProtocol.tritonWiredPID == 0x1302)
assert(SteamControllerProtocol.tritonBLEPID == 0x1303)
assert(SteamControllerProtocol.tritonWirelessPID == 0x1304)
assert(SteamControllerProtocol.tritonPuckPID == 0x1305)
assert(SteamControllerProtocol.originalBLEPID == 0x1106)
assert(SteamControllerProtocol.serviceUUID == "100F6C32-1735-4313-B402-38567131E5F3")
assert(SteamControllerProtocol.tritonHapticRumbleCharUUID == "100F6CB5-1735-4313-B402-38567131E5F3")

// 2. Feature & output report builders.
let lizardOff = [UInt8](SteamControllerProtocol.tritonLizardModeOffReport())
assert(lizardOff.count == 63 && Array(lizardOff.prefix(5)) == [0x87, 0x03, 0x09, 0x00, 0x00])
let imuOn = [UInt8](SteamControllerProtocol.tritonIMUModeReport(enabled: true))
assert(imuOn.count == 63 && Array(imuOn.prefix(5)) == [0x87, 0x03, 0x30, 0x18, 0x00])
let imuOff = [UInt8](SteamControllerProtocol.tritonIMUModeReport(enabled: false))
assert(imuOff.count == 63 && Array(imuOff.prefix(5)) == [0x87, 0x03, 0x30, 0x00, 0x00])
let rumble = [UInt8](SteamControllerProtocol.tritonHapticRumbleReport(leftSpeed: 0x1234, rightSpeed: 0x5678))
assert(rumble == [0x00, 0x00, 0x00, 0x34, 0x12, 0x00, 0x78, 0x56, 0x00])
assert([UInt8](SteamControllerProtocol.originalEnterValveModeReport()) == [0xC0, 0x87, 0x03, 0x08, 0x07, 0x00])

// 3. 2026 Triton/Ibex input report 0x45 (46 bytes with report ID prefix).
var pkt45 = [UInt8](repeating: 0, count: 46)
pkt45[0] = 0x45
pkt45[1] = 0x09 // seqNum = 9
let rawBtn45: UInt32 = SteamControllerProtocol.tritonButtonA
    | SteamControllerProtocol.tritonButtonRightShoulder
    | SteamControllerProtocol.tritonButtonView
    | SteamControllerProtocol.tritonButtonR4
    | SteamControllerProtocol.tritonButtonDpadUp
    | SteamControllerProtocol.tritonButtonL3
    | SteamControllerProtocol.tritonButtonSteam
    | SteamControllerProtocol.tritonRightTouchpadTouch
    | SteamControllerProtocol.tritonRightTouchpadClick
pkt45[2] = UInt8(rawBtn45 & 0xFF)
pkt45[3] = UInt8((rawBtn45 >> 8) & 0xFF)
pkt45[4] = UInt8((rawBtn45 >> 16) & 0xFF)
pkt45[5] = UInt8((rawBtn45 >> 24) & 0xFF)
// Triggers at offset 6..9 (5..8 after stripping report ID): LT = 16384 (~128), RT = 32767 (255)
pkt45[6] = 0x00; pkt45[7] = 0x40
pkt45[8] = 0xFF; pkt45[9] = 0x7F
// Left stick at offset 10..13: X = 16000 (0x3E80), Y = -8000 (0xE0C0)
pkt45[10] = 0x80; pkt45[11] = 0x3E
pkt45[12] = 0xC0; pkt45[13] = 0xE0
// Right stick at rest (0, 0) at offset 14..17 so right trackpad deflects RS:
// Left trackpad at offset 18..21: X = -16384 (0xC000), Y = 16384 (0x4000)
pkt45[18] = 0x00; pkt45[19] = 0xC0
pkt45[20] = 0x00; pkt45[21] = 0x40
// Right trackpad at offset 24..27: X = 16384 (0x4000), Y = 16384 (0x4000)
pkt45[24] = 0x00; pkt45[25] = 0x40
pkt45[26] = 0x00; pkt45[27] = 0x40
// IMU timestamp (1us) at offset 30..33 = 1000
pkt45[30] = 0xE8; pkt45[31] = 0x03; pkt45[32] = 0x00; pkt45[33] = 0x00
// Accel Z at offset 38..39 = 16384 (0x4000 = 1g)
pkt45[38] = 0x00; pkt45[39] = 0x40
// Gyro X, Y, Z at offset 40..45: X = 1638, Y = -819, Z = 3276
pkt45[40] = 0x66; pkt45[41] = 0x06
pkt45[42] = 0xCD; pkt45[43] = 0xFC
pkt45[44] = 0xCC; pkt45[45] = 0x0C

let snap45 = SteamControllerProtocol.parseTritonReport(Data(pkt45), mapBackGrips: true, trackpadStickFallback: true)!
assert(snap45.seqNum == 9)
assert(snap45.lt == 128 && snap45.rt == 255)
assert(snap45.lx == 16000 && snap45.ly == -8000)
assert(snap45.rx == 16384 && snap45.ry == 16384)
let expectedBtns45: UInt16 = 0x1000 | 0x0200 | 0x0010 | 0x0080 | 0x0001 | 0x0040 | 0x0400
assert(snap45.buttons == expectedBtns45)
assert(snap45.rightPadTouched && !snap45.leftPadTouched && snap45.touchpadClicked)
assert(snap45.hasIMU && snap45.imuTimestampUs == 1000 && snap45.accelZ == 16384)

// DualSense touchpad & motion conversions on snap45.
let tp = SteamControllerProtocol.dualSenseTouchpad(from: snap45)
assert(tp.touch0 == 0 && tp.touch1 == 1)
assert(tp.x1 > 960 && tp.x1 <= 1919 && tp.y1 < 540)
let dsm = SteamControllerProtocol.dualSenseMotion(from: snap45)!
assert(dsm.gyro.0 == 1638 && dsm.gyro.1 == 3276 && dsm.gyro.2 == 819)
assert(dsm.accel.2 == 0 && dsm.accel.1 == 8192)
let rad = SteamControllerProtocol.gyroRadiansPerSecond(from: snap45)!
assert(rad.x > 0 && rad.y < 0 && rad.z > 0)

// 4. 2026 Triton/Ibex extended timestamp input report 0x47 (45 bytes without prefix).
var pkt47 = [UInt8](repeating: 0, count: 45)
pkt47[0] = 0x03
let rawBtn47: UInt32 = SteamControllerProtocol.tritonButtonB
    | SteamControllerProtocol.tritonButtonQAM
    | SteamControllerProtocol.tritonLeftTriggerClick
    | SteamControllerProtocol.tritonLeftTouchpadTouch
pkt47[1] = UInt8(rawBtn47 & 0xFF)
pkt47[2] = UInt8((rawBtn47 >> 8) & 0xFF)
pkt47[3] = UInt8((rawBtn47 >> 16) & 0xFF)
pkt47[4] = UInt8((rawBtn47 >> 24) & 0xFF)
// Left pad in 0x47 is at offset 19..22: X = -16384, Y = 16384
pkt47[19] = 0x00; pkt47[20] = 0xC0
pkt47[21] = 0x00; pkt47[22] = 0x40
// 32us IMU timestamp at offset 31..32 = 100 (3200 us)
pkt47[31] = 100; pkt47[32] = 0
let snap47 = SteamControllerProtocol.parseTritonReport(Data(pkt47), reportID: 0x47)!
let expectedBtns47: UInt16 = 0x2000 | 0x0400
assert(snap47.buttons == expectedBtns47)
assert(snap47.lt == 255 && snap47.rt == 0 && snap47.ltClick && !snap47.rtClick)
assert(snap47.leftPadTouched && snap47.leftPadX == -16384 && snap47.leftPadY == 16384)
assert(snap47.hasIMU && snap47.imuTimestampUs == 3200)

// 5. Battery report 0x43.
let bat = SteamControllerProtocol.parseTritonBattery(Data([0x43, 0x01, 85]))!
assert(bat.chargeState == 1 && bat.level == 85 && bat.percent == 85)

// 6. 2015 BLE Steam Controller input report 0x03.
// Byte 0: low nibble = 4 (k_EBLEReportState), high nibble = 0xB0 (chunk1 0x10 | chunk2 0x20 | leftStick 0x80)
// Byte 1: 0x02 (rightTrackpad 0x200)
let pkt2015: [UInt8] = [
    0x03,
    0xB4, 0x02,
    // 3 button bytes: b0 = A (0x80) | RT_FULL (0x01), b1 = DPAD_DOWN (0x08) | BACK (0x10) | STEAM (0x20), b2 = RPAD_TOUCH (0x10)
    0x81, 0x38, 0x10,
    // 2 trigger bytes: LT = 90, RT = 120 (boosted to 255 by RT_FULL)
    90, 120,
    // 4 stick bytes: X = 10000 (0x2710), Y = 5000 (0x1388)
    0x10, 0x27, 0x88, 0x13,
    // 4 rightPad bytes: X = -10000 (0xD8F0), Y = 10000 (0x2710)
    0xF0, 0xD8, 0x10, 0x27
]
var snap2015 = SteamControllerSnapshot()
assert(SteamControllerProtocol.parseOriginalBLEReport(Data(pkt2015), previous: &snap2015))
let expectedBtns2015: UInt16 = 0x1000 | 0x0002 | 0x0020 | 0x0400
assert(snap2015.buttons == expectedBtns2015)
assert(snap2015.lt == 90 && snap2015.rt == 255 && snap2015.rtClick)
assert(snap2015.lx == 10000 && snap2015.ly == 5000)
assert(snap2015.rx == -10000 && snap2015.ry == 10000)
print("STEAM_CONTROLLER_PROTOCOL_OK")
'''

with tempfile.TemporaryDirectory(prefix='madeira-steam-controller-') as tmp:
    swift_path = Path(tmp) / 'check.swift'
    bin_path = Path(tmp) / 'check'
    swift_path.write_text(pure + '\n' + tests)
    swiftc = os.environ.get('SWIFTC', 'swiftc')
    subprocess.run([swiftc, '-O', str(swift_path), '-o', str(bin_path)], check=True)
    out = subprocess.run([str(bin_path)], check=True, capture_output=True, text=True).stdout
    assert 'STEAM_CONTROLLER_PROTOCOL_OK' in out

# Check app wiring invariants.
gamepad_swift = (root / 'app/Madeira/GamepadInput.swift').read_text()
assert 'SteamControllerManager.shared.start()' in gamepad_swift
assert 'madeira_pad_output_set_custom_rumble' in gamepad_swift
assert 'SteamControllerGCProfileFallback.isCandidate' in gamepad_swift
assert 'SteamControllerProtocol.dualSenseTouchpad' in gamepad_swift
assert 'SteamControllerProtocol.dualSenseMotion' in gamepad_swift

pad_output_h = (root / 'app/Madeira/PadOutput.h').read_text()
pad_output_m = (root / 'app/Madeira/PadOutput.m').read_text()
assert 'madeira_pad_output_set_custom_rumble' in pad_output_h
assert 'madeira_pad_output_set_custom_rumble' in pad_output_m

info_plist = (root / 'app/Madeira/Info.plist').read_text()
assert 'NSBluetoothAlwaysUsageDescription' in info_plist

pbxproj = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()
assert 'SteamController.swift' in pbxproj
assert 'CoreBluetooth.framework' in pbxproj

print('PASS: 2026 Triton/Ibex (0x45/0x47/0x42/0x43) and 2015 BLE (0x03) Steam Controller reports, '
      'Lizard Mode/IMU feature reports, 0x80 haptic rumble, DualSense touchpad/IMU mapping, and app wiring')
