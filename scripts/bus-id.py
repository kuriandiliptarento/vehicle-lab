#!/usr/bin/env python3
"""Print the VIN-derived UDP multicast group and port (same as the simulator / apps)."""
import sys


def _cksum(data: bytes) -> int:
    crc = 0
    for b in data + len(data).to_bytes((len(data).bit_length() + 7) // 8 or 1, "little"):
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return ~crc & 0xFFFFFFFF


def bus_group(vin: str) -> str:
    h = _cksum(vin.encode())
    return f"239.74.{(h // 256) % 254 + 1}.{h % 254 + 1}"


def bus_port(vin: str) -> int:
    return 55000 + (_cksum(vin.encode()) % 10000)


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <VIN> [VIN...]", file=sys.stderr)
        return 2
    for vin in sys.argv[1:]:
        print(f"{vin}\tgroup={bus_group(vin)}\tport={bus_port(vin)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
