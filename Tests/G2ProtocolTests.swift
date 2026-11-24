import XCTest
@testable import G2RemoteOS

final class G2ProtocolTests: XCTestCase {

    func testCRC16CCITTFalseMatchesStandardVector() {
        let crc = CRC16.ccittFalse(Data("123456789".utf8))
        XCTAssertEqual(crc, 0x29B1)
        XCTAssertEqual(CRC16.ccittFalseBytes(Data("123456789".utf8)), Data([0xB1, 0x29]))
    }

    func testAuthFrameMatchesLiveCapturedShape() {
        let frame = G2Frame.authFrame(magic: 1)
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

    func testAudioAndImuControlCommandEncoding() {
        let onPb = G2Commands.buildAudioControl(magic: 15, enable: true)
        XCTAssertEqual(ProtobufLite.readVarintField(onPb, field: 1), 15)
        XCTAssertEqual(ProtobufLite.readVarintField(onPb, field: 2), 15)
        let inner = ProtobufLite.readBytesField(onPb, field: 18)
        XCTAssertNotNil(inner)
        XCTAssertEqual(ProtobufLite.readVarintField(inner!, field: 1), 1)

        let imuPb = G2Commands.buildImuControl(magic: 20, enable: true, reportFreqMs: 250)
        XCTAssertEqual(ProtobufLite.readVarintField(imuPb, field: 1), 19)
        let imuInner = ProtobufLite.readBytesField(imuPb, field: 22)
        XCTAssertNotNil(imuInner)
        XCTAssertEqual(ProtobufLite.readVarintField(imuInner!, field: 1), 1)
        XCTAssertEqual(ProtobufLite.readVarintField(imuInner!, field: 2), 250)
    }

    func testFourBitBmpEncodingHeaderAndSize() {
        let canvas = G2PixelCanvas(width: 40, height: 24)
        canvas.drawBigClock("12:34", originX: 0, originY: 2, digitW: 6, digitH: 18, thickness: 2, spacing: 1)
        let packed = canvas.pack4bpp()
        XCTAssertEqual(packed.count, 20 * 24)

        let bmp = G2PixelCanvas.encodeBmp4bpp(packed: packed, width: 40, height: 24)
        // Header (14 + 40 + 64 = 118) + 20-byte rows (already multiple of 4) * 24 = 598
        XCTAssertEqual(bmp.count, 118 + 20 * 24)
        XCTAssertEqual(bmp[0], 0x42) // 'B'
        XCTAssertEqual(bmp[1], 0x4D) // 'M'
        XCTAssertEqual(bmp[28], 4)   // 4 bpp
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
        raw.append(contentsOf: [0x88, 0xFF]) // signalRatio = -120
        raw.append(contentsOf: [0x0E, 0x01]) // direction = 270
        raw.append(99)                       // counter = 99

        let pkt = G2MicPacket.parse(raw)
        XCTAssertNotNil(pkt)
        XCTAssertEqual(pkt?.lc3Frames.count, 5)
        XCTAssertEqual(pkt?.signalRatio, -120)
        XCTAssertEqual(pkt?.directionDegrees, 270)
        XCTAssertEqual(pkt?.counter, 99)
    }

    func testDashboardLauncherHeadUpAndPushToTalk() {
        let os = G2OSStateMachine()
        var micEvents: [Bool] = []
        var sleepCalled = false
        os.onToggleMic = { micEvents.append($0) }
        os.onSetScreenAsleep = { if $0 { sleepCalled = true } }

        // 1. Starts on Studio Minimalist Home (centered clock + top Tailscale/battery + bottom peek pill)
        XCTAssertEqual(os.currentScreen, .dashboard)
        XCTAssertEqual(os.currentPage.textContainers.count, 1)
        XCTAssertEqual(os.currentPage.imageContainers.count, 2)
        XCTAssertEqual(os.currentPage.textContainers.filter(\.captureEvents).count, 1)

        // 2. Back on Home NEVER sleeps or exits to stock OS
        os.handle(RemoteCommandEvent(action: .back, source: .zero2))
        XCTAssertEqual(os.currentScreen, .dashboard)
        XCTAssertFalse(sleepCalled)

        // 3. Home ↓ opens Alerts Stack; ← dismisses 1 alert; ↑ at top returns to Home
        let initialAlerts = os.alerts.count
        XCTAssertGreaterThan(initialAlerts, 0)
        os.handle(RemoteCommandEvent(action: .down, source: .zero2))
        XCTAssertEqual(os.currentScreen, .alerts)
        os.handle(RemoteCommandEvent(action: .left, source: .zero2))
        XCTAssertEqual(os.alerts.count, initialAlerts - 1)
        os.handle(RemoteCommandEvent(action: .up, source: .zero2))
        XCTAssertEqual(os.currentScreen, .dashboard)

        // 4. Home → opens 8-slot Menu Preview (Dock focused = -1); ↑ enters/exits Quick Preview (↓ stays on Dock)
        os.handle(RemoteCommandEvent(action: .right, source: .zero2))
        XCTAssertEqual(os.currentScreen, .launcher)
        XCTAssertEqual(os.menuFocus, -1)
        XCTAssertEqual(os.currentPage.textContainers.count, 3)  // header + 2 balanced preview rows
        XCTAssertEqual(os.currentPage.imageContainers.count, 3) // top status + 2 bottom dock tiles
        os.handle(RemoteCommandEvent(action: .down, source: .zero2))
        XCTAssertEqual(os.menuFocus, -1) // ↓ must NOT enter quick preview from dock
        os.handle(RemoteCommandEvent(action: .up, source: .zero2))
        XCTAssertEqual(os.menuFocus, 0)  // ↑ enters quick preview article #1
        os.handle(RemoteCommandEvent(action: .down, source: .zero2))
        XCTAssertEqual(os.menuFocus, 1)  // ↓ moves to article #2
        os.handle(RemoteCommandEvent(action: .up, source: .zero2))
        XCTAssertEqual(os.menuFocus, 0)
        os.handle(RemoteCommandEvent(action: .up, source: .zero2))
        XCTAssertEqual(os.menuFocus, -1) // ↑ at article #1 exits back to dock

        // 5. L2 on Dock opens Full-Screen Feed; → switches category; L2 opens Reader; R2 returns
        os.handle(RemoteCommandEvent(action: .select, source: .zero2))
        XCTAssertEqual(os.currentScreen, .feedApp)
        os.handle(RemoteCommandEvent(action: .right, source: .zero2))
        XCTAssertEqual(os.feedCatIdx, 1)
        os.handle(RemoteCommandEvent(action: .select, source: .zero2))
        XCTAssertEqual(os.currentScreen, .readerDetail)
        os.handle(RemoteCommandEvent(action: .back, source: .zero2))
        XCTAssertEqual(os.currentScreen, .feedApp)
        os.handle(RemoteCommandEvent(action: .back, source: .zero2))
        XCTAssertEqual(os.currentScreen, .launcher)

        // 6. Head-Up transparent standby wakes via IMU tilt
        os.setHeadUpWakeMode(true)
        os.handleImuSample(G2ImuSample(x: 0, y: 0, z: 1))
        os.calibrateHeadUpNeutral()
        os.enterHeadUpStandby()
        XCTAssertTrue(os.isHeadUpDimmed)
        XCTAssertTrue(os.currentPage.isBlankTransparent)

        os.handleImuSample(G2ImuSample(x: 0, y: 0.6, z: 0.8)) // ~36.9 deg tilt
        XCTAssertFalse(os.isHeadUpDimmed)
        XCTAssertEqual(os.currentScreen, .dashboard)

        // 7. Tailscale & Spark connected state reflects in 9-dot graphic image hash
        os.tailscaleConnected = true
        os.handleSparkEvent(.connected(host: "spark01", latencyMs: 18, sttModel: "large-v3-turbo"))
        XCTAssertTrue(os.currentPage.imageContainers.contains { $0.contentHash.hasPrefix("tsbat_1_1_") })

        // 8. Global Push-to-Talk -> Even AI streaming flow
        os.handle(RemoteCommandEvent(action: .micStart, source: .zero2))
        os.handle(RemoteCommandEvent(action: .micStart, source: .zero2))
        XCTAssertTrue(os.isMicOn)
        os.handleSparkEvent(.sttPartial(mode: .evenAI, text: "내일 서울 날씨", elapsedMs: 90))
        XCTAssertTrue(os.renderedFrameText.contains("내일 서울 날씨"))

        os.handle(RemoteCommandEvent(action: .micStop, source: .zero2))
        os.handle(RemoteCommandEvent(action: .micStop, source: .zero2))
        XCTAssertFalse(os.isMicOn)
        XCTAssertEqual(micEvents, [true, false])

        os.handleSparkEvent(.sttFinal(mode: .evenAI, text: "내일 서울 날씨 알려줘", language: "ko", elapsedMs: 115))
        os.handleSparkEvent(.aiDone(mode: .evenAI, text: "내일 서울은 맑고 최고 16도입니다.", commands: [], durationSeconds: 1.1))
        XCTAssertEqual(os.currentScreen, .agent)
        XCTAssertTrue(os.renderedFrameText.contains("최고 16도"))
    }
}
