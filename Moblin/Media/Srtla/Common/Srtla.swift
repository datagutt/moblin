// SRTLA is a bonding protocol on top of SRT.
// Designed by rationalsa for the BELABOX project.
// https://github.com/BELABOX/srtla

import Foundation

enum SrtlaPacketType: UInt16 {
    case keepalive = 0x1000
    case ack = 0x1100
    case reg1 = 0x1200
    case reg2 = 0x1201
    case reg3 = 0x1202
    case regErr = 0x1210
    case regNgp = 0x1211
    case regNak = 0x1212
}

let srtlaKeepaliveMagic: UInt16 = 0xC01F
let srtlaKeepaliveExtVersion: UInt16 = 0x0001
let srtlaKeepaliveStandardLength = 10
let srtlaKeepaliveExtendedLength = 42

struct SrtlaConnectionInfo {
    let connId: UInt32
    let window: Int32
    let inFlight: Int32
    let rttMs: UInt32
    let nakCount: UInt32
    let bitrateBytesPerSec: UInt32
}

func createSrtlaPacket(type: SrtlaPacketType, length: Int) -> Data {
    var packet = Data(count: length)
    packet.setUInt16Be(value: type.rawValue | srtControlPacketTypeBit)
    return packet
}

func createSrtlaKeepalivePacket(timestamp: Int64) -> Data {
    var packet = createSrtlaPacket(type: .keepalive, length: srtlaKeepaliveStandardLength)
    packet.setInt64Be(value: timestamp, offset: srtControlTypeSize)
    return packet
}

func createSrtlaKeepalivePacketExt(timestamp: Int64, info: SrtlaConnectionInfo) -> Data {
    let writer = ByteWriter()
    writer.writeUInt16(SrtlaPacketType.keepalive.rawValue | srtControlPacketTypeBit)
    writer.writeInt64(timestamp)
    writer.writeUInt16(srtlaKeepaliveMagic)
    writer.writeUInt16(srtlaKeepaliveExtVersion)
    writer.writeUInt32(info.connId)
    writer.writeInt32(info.window)
    writer.writeInt32(info.inFlight)
    writer.writeUInt32(info.rttMs)
    writer.writeUInt32(info.nakCount)
    writer.writeUInt32(info.bitrateBytesPerSec)
    return writer.data
}
