#!/usr/bin/env python3
"""Scapy fallback injector for the Fail2ban end-to-end test.

Emits ONE TCP SYN with a spoofed source of 203.0.113.66 (RFC 5737 TEST-NET-3) on a
chosen interface, so the passive Suricata sensor captures it off the wire and trips
the temporary e2e rule (sid 1000099). Preferred path in test_e2e_ban.sh is hping3;
this is used only when hping3 is unavailable.

Run as root (raw socket), isolated from CWD imports:  python3 -I inject_packet.py <iface> [dest_ip]
"""
import sys

SPOOF_SRC = "203.0.113.66"
DEFAULT_DST = "203.0.113.1"  # same TEST-NET range; nothing real receives it


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: inject_packet.py <iface> [dest_ip]", file=sys.stderr)
        return 2
    iface = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DST

    try:
        from scapy.all import IP, TCP, sendp, Ether  # noqa: N811
    except Exception as exc:  # pragma: no cover - env dependent
        print(f"scapy unavailable: {exc}", file=sys.stderr)
        return 3

    pkt = Ether() / IP(src=SPOOF_SRC, dst=dst) / TCP(sport=44321, dport=80, flags="S")
    sendp(pkt, iface=iface, verbose=False)
    print(f"sent spoofed SYN {SPOOF_SRC} -> {dst} on {iface}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
