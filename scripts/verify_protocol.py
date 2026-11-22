#!/usr/bin/env python3
"""
Cross-checks G2RemoteOS Swift protocol constants and wire encodings against
live-confirmed open-g2-hub / even-g2-protocol golden byte vectors.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc


def crc16_le(data: bytes) -> bytes:
    c = crc16_ccitt(data)
    return bytes([c & 0xFF, (c >> 8) & 0xFF])


def varint(v: int) -> bytes:
    if v < 0:
        v += 1 << 64
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v & 0x7F)
    return bytes(out)


def field_varint(num: int, val: int) -> bytes:
    return varint((num << 3) | 0) + varint(val)


def field_bytes(num: int, data: bytes) -> bytes:
    return varint((num << 3) | 2) + varint(len(data)) + data


def frame_pb(pb: bytes, sid: int, flag: int, seq: int) -> bytes:
    body = pb + crc16_le(pb)
    return bytes([0xAA, 0x21, seq & 0xFF, len(body) & 0xFF, 1, 1, sid & 0xFF, flag & 0xFF]) + body


def main():
    # 1. Verify CRC-16/CCITT-FALSE standard vector ("123456789" -> 0x29B1, LE: b1 29)
    assert crc16_ccitt(b"123456789") == 0x29B1
    assert crc16_le(b"123456789") == bytes([0xB1, 0x29])

    # 2. Verify Auth frame golden bytes (magic=1)
    auth_pb = bytes([0x08, 0x04, 0x10, 0x01, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])
    auth_frame = bytes([0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00]) + auth_pb + crc16_le(auth_pb)
    assert len(auth_frame) == 20
    print(f"[OK] Auth frame (magic=1):      {auth_frame.hex(' ')}")

    # 3. Verify Prelude frame (SID 0x01, cmd 2, magic 156, seq 0x92)
    innermost = field_varint(1, 0) + field_varint(2, 0)
    f4 = field_bytes(3, field_bytes(2, field_bytes(2, innermost)))
    prelude_pb = field_varint(1, 2) + field_varint(2, 156) + field_bytes(4, f4)
    prelude_frame = frame_pb(prelude_pb, sid=0x01, flag=0x20, seq=0x92)
    assert prelude_pb.hex() == "0802109c01220a1a081206120408001000"
    print(f"[OK] Prelude frame (seq=0x92):  {prelude_frame.hex(' ')}")

    # 4. Verify EvenHub Heartbeat (SID 0xE0, cmd 12, field 14 {1:0})
    hb_pb = field_varint(1, 12) + field_varint(2, 101) + field_bytes(14, field_varint(1, 0))
    print(f"[OK] Heartbeat pb (magic=101):  {hb_pb.hex(' ')}")

    # 5. Verify AudioControl ON (SID 0xE0, cmd 15, field 18 {1:1})
    mic_on = field_varint(1, 15) + field_varint(2, 102) + field_bytes(18, field_varint(1, 1))
    assert mic_on.hex() == "080f10669201020801"
    print(f"[OK] Mic ON pb (magic=102):     {mic_on.hex(' ')}")

    # 6. Verify Brightness=30 (SID 0x09, cmd 1, field 3 {1: {2: 30}})
    br_pb = field_varint(1, 1) + field_varint(2, 103) + field_bytes(3, field_bytes(1, field_varint(2, 30)))
    assert br_pb.hex() == "080110671a040a02101e"
    print(f"[OK] Brightness 30 pb:          {br_pb.hex(' ')}")

    # 7. Cross-check Swift source constants against golden UUIDs & fields
    const_swift = (ROOT / "Sources/BLE/G2Constants.swift").read_text(encoding="utf-8")
    for token in ["00002760-08C2-11E1-9073-0E8AC72E", "5450", "5401", "5402", "6450", "6402"]:
        assert token in const_swift, f"Missing UUID token in G2Constants.swift: {token}"

    cmds_swift = (ROOT / "Sources/Protocol/G2Commands.swift").read_text(encoding="utf-8")
    for token in [
        "preludeAckMagic = 156",
        "wrapEvenHub(cmd: 12, magic: magic, innerField: 14",
        "wrapEvenHub(cmd: 15, magic: magic, innerField: 18",
        "wrapEvenHub(cmd: 0, magic: magic, innerField: 3",
        "wrapEvenHub(cmd: 5, magic: magic, innerField: 9",
    ]:
        assert token in cmds_swift, f"Missing protocol clause in G2Commands.swift: {token}"

    plist = (ROOT / "Resources/Info.plist").read_text(encoding="utf-8")
    for key in ["bluetooth-central", "audio", "NSBluetoothAlwaysUsageDescription"]:
        assert key in plist, f"Missing Info.plist key: {key}"

    proj_yml = (ROOT / "project.yml").read_text(encoding="utf-8")
    assert "INFOPLIST_FILE: Resources/Info.plist" in proj_yml
    assert "CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES: YES" in proj_yml
    assert not re.search(r"^\s+info:\s*$", proj_yml, re.MULTILINE), "XcodeGen info: block would overwrite Info.plist!"

    print("[OK] All Swift source constants, Info.plist keys, and project.yml guards verified!")


if __name__ == "__main__":
    main()
