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
        var brightnessSet: Int?
        var heightSet: Int?
        os.onToggleMic = { micEvents.append($0) }
        os.onSetScreenAsleep = { if $0 { sleepCalled = true } }
        os.onSetBrightness = { brightnessSet = $0 }
        os.onSetDisplayHeight = { heightSet = $0 }

        // 1. Starts on stock-style Dashboard with multi-container + 4-bit pixel clock
        XCTAssertEqual(os.currentScreen, .dashboard)
        XCTAssertEqual(os.currentPage.textContainers.count, 3)
        XCTAssertEqual(os.currentPage.imageContainers.count, 1)
        XCTAssertEqual(os.currentPage.textContainers.filter(\.captureEvents).count, 1)

        // 2. Back on Dashboard NEVER sleeps or exits to stock OS
        os.handle(RemoteCommandEvent(action: .back, source: .motionPad))
        XCTAssertEqual(os.currentScreen, .dashboard)
        XCTAssertFalse(sleepCalled)

        // 3. Swipe right cycles Dashboard widgets, tap opens 3x2 bordered App Launcher
        os.handle(RemoteCommandEvent(action: .right, source: .motionPad))
        XCTAssertEqual(os.dashboardTab, 1)
        os.handle(RemoteCommandEvent(action: .select, source: .motionPad))
        XCTAssertEqual(os.currentScreen, .launcher)
        XCTAssertEqual(os.currentPage.textContainers.count, 7) // header + 6 bordered app cards
        XCTAssertEqual(os.currentPage.textContainers.filter(\.captureEvents).count, 1)

        // 4. Navigate to Hardware Settings on Launcher Page 2 (row 0, col 1 after wrapping right past col 2)
        os.handle(RemoteCommandEvent(action: .right, source: .motionPad))
        os.handle(RemoteCommandEvent(action: .right, source: .motionPad))
        os.handle(RemoteCommandEvent(action: .right, source: .motionPad)) // Page 1, col 0 (HeadUp)
        os.handle(RemoteCommandEvent(action: .right, source: .motionPad)) // Page 1, col 1 (Settings)
        os.handle(RemoteCommandEvent(action: .select, source: .motionPad))
        XCTAssertEqual(os.currentScreen, .settings)
        os.handle(RemoteCommandEvent(action: .right, source: .motionPad))
        XCTAssertEqual(brightnessSet, 30)
        os.handle(RemoteCommandEvent(action: .down, source: .motionPad))
        os.handle(RemoteCommandEvent(action: .down, source: .motionPad))
        os.handle(RemoteCommandEvent(action: .right, source: .motionPad))
        XCTAssertEqual(heightSet, 12)

        // 5. Head-Up transparent standby wakes via IMU tilt
        os.setHeadUpWakeMode(true)
        os.handleImuSample(G2ImuSample(x: 0, y: 0, z: 1))
        os.calibrateHeadUpNeutral()
        os.enterHeadUpStandby()
        XCTAssertTrue(os.isHeadUpDimmed)
        XCTAssertTrue(os.currentPage.isBlankTransparent)

        os.handleImuSample(G2ImuSample(x: 0, y: 0.6, z: 0.8)) // ~36.9 deg tilt
        XCTAssertFalse(os.isHeadUpDimmed)
        XCTAssertEqual(os.currentScreen, .dashboard)

        // 6. Tailscale & Spark node badge displays on glasses
        os.tailscaleConnected = true
        os.handleSparkEvent(.connected(host: "spark01", latencyMs: 18, sttModel: "large-v3-turbo"))
        XCTAssertTrue(os.renderedFrameText.contains("TS●64"))

        // 7. Global Push-to-Talk -> Even AI streaming flow
        os.handle(RemoteCommandEvent(action: .micStart, source: .motionPad))
        os.handle(RemoteCommandEvent(action: .micStart, source: .motionPad))
        XCTAssertTrue(os.isMicOn)
        os.handleSparkEvent(.sttPartial(mode: .evenAI, text: "내일 서울 날씨", elapsedMs: 90))
        XCTAssertTrue(os.renderedFrameText.contains("내일 서울 날씨"))

        os.handle(RemoteCommandEvent(action: .micStop, source: .motionPad))
        os.handle(RemoteCommandEvent(action: .micStop, source: .motionPad))
        XCTAssertFalse(os.isMicOn)
        XCTAssertEqual(micEvents, [true, false])

        os.handleSparkEvent(.sttFinal(mode: .evenAI, text: "내일 서울 날씨 알려줘", language: "ko", elapsedMs: 115))
        os.handleSparkEvent(.aiDone(mode: .evenAI, text: "내일 서울은 맑고 최고 16도입니다.", commands: [], durationSeconds: 1.1))
        XCTAssertEqual(os.currentScreen, .agent)
        XCTAssertTrue(os.renderedFrameText.contains("최고 16도"))
    }
}
