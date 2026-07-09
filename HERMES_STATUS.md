# Hermes Cross-Instance Status

> Both instances read this on session start. Keep your section current.
> Private: thj.no:~/hermes/noaidi/HERMES_STATUS.md

## Hermes Linux (ThinkPad, FPGA synth) — 192.168.0.104
- **Project:** Noaidi (`Thorwegian/noaidi`, `/home/thor/Documents/FPGA/noaidi`)
- **Branch:** main
- **Waveforms:** saw ✓, pulse ✓, triangle ✓, sine ✓ (all iverilog-passed, synthesis-passed for triangle)
- **Filter:** SVF restored (no more bypass guard)
- **Hardware:** Tang Nano 20K connected (FTDI 0403:6010 detected), ready to flash
- **Network:** WiFi 192.168.0.104, Mac reachable at 3ms
- **Gateway:** Running but Telegram disabled (Mac owns it)
- **Next:** hardware-test triangle at 50 Hz, then sine, then ADSR (#2)
- **Changed files (uncommitted):** HERMES_STATUS.md, README.md, top.sv, osc_bank.sv, tb_osc_bank.sv
- **Last update:** 2026-07-08 02:00 CEST

## Hermes macOS (Mac Mini M2) — 192.168.0.100
- **Role:** Life management, Telegram gateway
- **Gateway:** Running (launchd, PID 10021), Telegram connected
- **Storage:** 500GB internal, 6TB Backup, 12TB RAID Media
- **Scanner:** ~/.hermes/scripts/mac-scan.sh ready (#26)
- **Last update:** pending

## Cloud — thj.no (152.70.60.248)
- **Role:** Coordination endpoint
- **Web:** nginx, index.html dashboard active
- **Ping:** 65ms from ThinkPad

---

## Coordination
- **Protocol:** Lock via `mkdir ~/www/thj.no/locks/<agent>` on thj.no before state changes
- **Status file:** thj.no:~/hermes/noaidi/HERMES_STATUS.md
- **SSH:** Both LAN machines SSH each other
- **Repo:** github.com/Thorwegian/noaidi
- **Telegram:** macOS only — Linux backing off

### Division
- **Hermes Linux:** FPGA synth, DSP, RTL, Verilog, NEORV32 firmware
- **Hermes macOS:** Project management, Telegram gateway, cron jobs, life management
- **thj.no:** Dashboard, file sharing, lock server
