import XCTest
@testable import G2RemoteOS

final class G2ProtocolTests: XCTestCase {

    func testCRC16CCITTFalseMatchesStandardVector() {
        // Standard check value for CRC-16/CCITT-FALSE ("123456789") is 0x29B1.
        let crc = CRC16.ccittFalse(Data("123456789".utf8))
        XCTAssertEqual(crc, 0x29B1)
        XCTAssertEqual(CRC16.ccittFalseBytes(Data("123456789".utf8)), Data([0xB1, 0x29]))
    }

    func testAuthFrameMatchesLiveCapturedShape() {
        let frame = G2Frame.authFrame(magic: 1)
        // Header: AA 21 01 0C 01 01 80 00
        // Payload (10 bytes): 08 04 10 01 1A 04 08 01 10 04
        // Trailing 2 bytes: CRC-16/CCITT-FALSE LE of payload
        XCTAssertEqual(frame.count, 20)
        XCTAssertEqual(Data(frame[0..<8]), Data([0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00]))
        let payload = Data([0x08, 0x04, 0x10, 0x01, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])
        XCTAssertEqual(Data(frame[8..<18]), payload)
        XCTAssertEqual(Data(frame[18..<20]), CRC16.ccittFalseBytes(payload))
    }

    func testPreludeFrameHasExpectedSidAndMagic() {
        let frame = G2Commands.preludeFrame
        let parsed = G2Frame.parseFrame(frame)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.sid, G2SID.dashboard)
        XCTAssertEqual(parsed?.flag, G2Frame.flagRequest)
        XCTAssertEqual(G2Frame.readAckMagic(parsed!.payload), G2Commands.preludeAckMagic)
    }

    func testMultiPacketFramingAndReassembly() {
        let largeText = String(repeating: "가나다라마바사ABCDEF1234567890", count: 16)
        let pb = G2Commands.buildTextUpgrade(magic: 42, text: largeText)
        let frames = G2Frame.framePb(pb, sid: G2SID.evenHub, flag: G2Frame.flagRequest, seq: 77, maxWrite: 80)
        XCTAssertGreaterThan(frames.count, 1)

        // Every fragment must share the same `seq` byte (firmware reassembly group key).
        for (idx, f) in frames.enumerated() {
            XCTAssertEqual(f[2], 77)
            XCTAssertEqual(Int(f[4]), frames.count)
            XCTAssertEqual(Int(f[5]), idx + 1)
        }

        let assembler = G2FrameAssembler()
        var completed: Data?
        for f in frames {
            completed = assembler.feed(f)
        }
        XCTAssertNotNil(completed)
        let parsed = G2Frame.parseFrame(completed!)
        XCTAssertEqual(parsed?.sid, G2SID.evenHub)
        XCTAssertEqual(parsed?.payload, pb)
    }

    func testAudioControlCommandEncoding() {
        let onPb = G2Commands.buildAudioControl(magic: 15, enable: true)
        XCTAssertEqual(ProtobufLite.readVarintField(onPb, field: 1), 15)
        XCTAssertEqual(ProtobufLite.readVarintField(onPb, field: 2), 15)
        let inner = ProtobufLite.readBytesField(onPb, field: 18)
        XCTAssertNotNil(inner)
        XCTAssertEqual(ProtobufLite.readVarintField(inner!, field: 1), 1)
    }

    func testLensNameParsing() {
        let left = G2Constants.parseLensName("Even G2_42_L_1A2B3C")
        XCTAssertEqual(left?.pairId, "42")
        XCTAssertEqual(left?.side, .left)
        XCTAssertEqual(left?.macTail, "1A2B3C")

        let right = G2Constants.parseLensName("Even G2_42_R_DEADBF")
        XCTAssertEqual(right?.side, .right)
        XCTAssertNil(G2Constants.parseLensName("AirPods Pro"))
    }

    func testMicPacketParsing() {
        var raw = Data(repeating: 0x55, count: 200)
        // signalRatio = -120 (0xFF88 LE -> 0x88, 0xFF)
        raw.append(contentsOf: [0x88, 0xFF])
        // direction = 270 (0x010E LE -> 0x0E, 0x01)
        raw.append(contentsOf: [0x0E, 0x01])
        // counter = 99
        raw.append(99)

        let pkt = G2MicPacket.parse(raw)
        XCTAssertNotNil(pkt)
        XCTAssertEqual(pkt?.lc3Frames.count, 5)
        XCTAssertEqual(pkt?.signalRatio, -120)
        XCTAssertEqual(pkt?.directionDegrees, 270)
        XCTAssertEqual(pkt?.counter, 99)
    }

    func testOSStateMachineAllControls() {
        let os = G2OSStateMachine()
        var micState: Bool?
        var brightnessSet: Int?
        os.onToggleMic = { micState = $0 }
        os.onSetBrightness = { brightnessSet = $0 }

        // 1. Navigate Home 2x3 grid with right/down and open 4-way D-pad test (row 1, col 1)
        os.handle(RemoteCommandEvent(action: .right, source: .virtualPad))
        os.handle(RemoteCommandEvent(action: .down, source: .virtualPad))
        os.handle(RemoteCommandEvent(action: .select, source: .virtualPad))
        XCTAssertEqual(os.currentScreen, .dpadTest)

        // 2. Test 4-way movement & scrolling
        os.handle(RemoteCommandEvent(action: .up, source: .flicDuo))
        os.handle(RemoteCommandEvent(action: .left, source: .flicDuo))
        os.handle(RemoteCommandEvent(action: .scrollUp, source: .flicDuo))
        XCTAssertEqual(os.padX, 4)
        XCTAssertEqual(os.padY, 1)
        XCTAssertEqual(os.padScrollValue, 5)

        // 3. Global Mic toggle from any screen
        os.handle(RemoteCommandEvent(action: .micToggle, source: .flicDuo))
        XCTAssertEqual(micState, true)
        XCTAssertTrue(os.isMicOn)

        // 4. Global Brightness control
        os.handle(RemoteCommandEvent(action: .brightnessUp, source: .flicDuo))
        XCTAssertEqual(brightnessSet, 30)

        // 5. Return home
        os.handle(RemoteCommandEvent(action: .home, source: .flicDuo))
        XCTAssertEqual(os.currentScreen, .home)
    }
}
