#!/usr/bin/env python3
"""
Parse the log produced by collect_ca.sh and summarize NR CA / band state.

Usage:
    python parse_telephony.py ca_20261103_120000.log
    python parse_telephony.py ca_*.log --csv out.csv
"""

import argparse
import csv
import re
import sys
from pathlib import Path


def parse_int(text, key):
    m = re.search(rf"{re.escape(key)}\s*=\s*(-?\d+)", text)
    return int(m.group(1)) if m else None


def parse_str(text, key):
    m = re.search(rf"{re.escape(key)}\s*=\s*([^,}}\s]+)", text)
    return m.group(1) if m else None


def parse_physical_configs(line):
    """Return a list of dicts for mPhysicalChannelConfigs entries."""
    if "mPhysicalChannelConfigs=" not in line:
        return []
    body = line.split("mPhysicalChannelConfigs=", 1)[1]
    # Each entry is a {...} group.  Split on '}, {'; nested braces are not
    # expected inside a PhysicalChannelConfig.
    parts = re.split(r"},\s*\{", body)
    entries = []
    for part in parts:
        part = part.strip("{}[] \n")
        if "mNetworkType=" not in part:
            continue
        entries.append({
            "status": parse_str(part, "mConnectionStatus"),
            "network": parse_str(part, "mNetworkType"),
            "band": parse_int(part, "mBand"),
            "pci": parse_int(part, "mPhysicalCellId"),
            "channel": parse_int(part, "mDownlinkChannelNumber"),
            "bw_dl_khz": parse_int(part, "mCellBandwidthDownlinkKhz"),
        })
    return entries


def parse_signal(line):
    """Extract NR / LTE signal values from mSignalStrength."""
    out = {"nr_rsrp": None, "nr_rsrq": None, "nr_sinr": None,
           "lte_rsrp": None, "lte_rsrq": None, "lte_snr": None}
    m = re.search(r"mNr=CellSignalStrengthNr:\{(.*?)\},\s*primary=", line)
    if m:
        nr = m.group(1)
        out["nr_rsrp"] = parse_int(nr, "ssRsrp")
        out["nr_rsrq"] = parse_int(nr, "ssRsrq")
        out["nr_sinr"] = parse_int(nr, "ssSinr")
    m = re.search(r"mLte=CellSignalStrengthLte:\s*(.*?),\s*mNr=", line)
    if m:
        lte = m.group(1)
        out["lte_rsrp"] = parse_int(lte, "rsrp")
        out["lte_rsrq"] = parse_int(lte, "rsrq")
        out["lte_snr"] = parse_int(lte, "rssnr")
    return out


def parse_cell_identity(line):
    """Extract serving cell identity fields."""
    out = {"rat": None, "pci": None, "arfcn": None, "bands": None}
    if "CellIdentityNr:" in line:
        out["rat"] = "NR"
        out["pci"] = parse_int(line, "mPci")
        out["arfcn"] = parse_int(line, "mNrArfcn")
        m = re.search(r"mBands\s*=\s*\[([^\]]*)\]", line)
        out["bands"] = m.group(1).strip() if m else None
    elif "CellIdentityLte:" in line:
        out["rat"] = "LTE"
        out["pci"] = parse_int(line, "mPci")
        out["arfcn"] = parse_int(line, "mEarfcn")
        m = re.search(r"mBands=\[([^\]]*)\]", line)
        out["bands"] = m.group(1).strip() if m else None
    return out


def parse_ca_flag(line):
    """isUsingCarrierAggregation from the mServiceState line (RIL-level hint)."""
    m = re.search(r"isUsingCarrierAggregation\s*=\s*(true|false)", line)
    return None if not m else (1 if m.group(1) == "true" else 0)


def parse_display(line):
    m = re.search(r"mTelephonyDisplayInfo=TelephonyDisplayInfo\s*\{([^}]*)\}", line)
    if not m:
        return {}
    body = m.group(1)
    return {
        "network": parse_str(body, "network"),
        "override": parse_str(body, "overrideNetwork"),
    }


def parse_log(path):
    text = Path(path).read_text(errors="replace")
    blocks = re.split(r"^=====\s*(.*?)\s*=====\s*$", text, flags=re.M)
    rows = []
    # blocks: [preamble, timestamp, body, timestamp, body, ...]
    for i in range(1, len(blocks) - 1, 2):
        ts = blocks[i].strip()
        body = blocks[i + 1]
        pc_lines = [l for l in body.splitlines() if "mPhysicalChannelConfigs=" in l]
        sig_line = next((l for l in body.splitlines() if "mSignalStrength=" in l), "")
        cid_lines = [l for l in body.splitlines() if "mCellIdentity=" in l]
        cid_line = next((l for l in cid_lines if "CellIdentityNr:" in l), cid_lines[0] if cid_lines else "")
        disp_line = next((l for l in body.splitlines() if "mTelephonyDisplayInfo=" in l), "")
        svc_line = next((l for l in body.splitlines() if "mServiceState=" in l), "")

        disp = parse_display(disp_line)

        # Dual-SIM dumps contain one config line per subscription.  Pick the
        # line that looks most like the serving NR carrier: prefer lines with
        # NR-typed entries, then the one with the most entries.
        best = None
        best_score = None
        cfg_counts = []
        for line in pc_lines:
            entries = parse_physical_configs(line)
            cfg_counts.append(str(len(entries)))
            n_nr = sum(1 for e in entries if e["network"] == "NR")
            score = (1 if n_nr else 0, n_nr, len(entries))
            if best_score is None or score > best_score:
                best_score, best = score, entries
        entries = best or []
        nr_entries = [e for e in entries if e["network"] == "NR"]
        if not nr_entries and disp.get("network") in ("NR", "NR_NSA"):
            # HyperOS redacts mNetworkType to UNKNOWN as soon as a SCell is
            # added, so a 2-entry config with both marked UNKNOWN is still NR CA.
            nr_entries = entries
        lte_entries = [e for e in entries if e["network"] == "LTE"]
        sig = parse_signal(sig_line)
        # On ColorOS the top-level mCellIdentity band list can disagree with
        # its own ARFCN (seen: 723360 -> n79 reported as [41]).  The copy inside
        # mServiceState's NetworkRegistrationInfo has been consistent, so prefer it.
        cid = parse_cell_identity(svc_line if "CellIdentityNr:" in svc_line else cid_line)

        rows.append({
            "time": ts,
            "nr_count": len(nr_entries),
            "nr_ca": 1 if len(nr_entries) >= 2 else 0,
            "nr_entries": ";".join(
                f"{e['status']}/b{e['band']}/pci{e['pci']}/ch{e['channel']}/bw{e['bw_dl_khz']}"
                for e in nr_entries),
            "lte_count": len(lte_entries),
            "lte_entries": ";".join(
                f"{e['status']}/b{e['band']}/pci{e['pci']}/ch{e['channel']}/bw{e['bw_dl_khz']}"
                for e in lte_entries),
            "serving_rat": cid["rat"],
            "serving_bands": cid["bands"],
            "serving_arfcn": cid["arfcn"],
            "serving_pci": cid["pci"],
            **sig,
            "ss_ca": parse_ca_flag(svc_line),
            "ss_arfcn": parse_int(svc_line, "mChannelNumber"),
            "secondary": 1 if any(e["status"] == "SecondaryServing" for e in entries) else 0,
            "cfg_lines": len(pc_lines),
            "sub_cfg_counts": "/".join(cfg_counts),
            "display_network": disp.get("network"),
            "display_override": disp.get("override"),
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="+", help="collect_ca.sh log file(s)")
    ap.add_argument("--csv", help="write CSV to this file")
    args = ap.parse_args()

    all_rows = []
    for path in args.log:
        all_rows.extend(parse_log(path))

    if not all_rows:
        print("no samples found", file=sys.stderr)
        return 1

    fields = ["time", "nr_count", "nr_ca", "nr_entries", "lte_count", "lte_entries",
              "serving_rat", "serving_bands", "serving_arfcn", "serving_pci",
              "nr_rsrp", "nr_rsrq", "nr_sinr", "lte_rsrp", "lte_rsrq", "lte_snr",
              "ss_ca", "ss_arfcn", "secondary", "cfg_lines", "sub_cfg_counts",
              "display_network", "display_override"]

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            w.writerows(all_rows)
        print(f"wrote {len(all_rows)} samples to {args.csv}")
    else:
        w = csv.DictWriter(sys.stdout, fieldnames=fields)
        w.writeheader()
        w.writerows(all_rows)

    ca = [r for r in all_rows if r["nr_ca"]]
    print(f"\n# samples: {len(all_rows)}, NR-CA samples: {len(ca)}", file=sys.stderr)
    if ca:
        print("# first NR-CA sample:", file=sys.stderr)
        print(ca[0], file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
