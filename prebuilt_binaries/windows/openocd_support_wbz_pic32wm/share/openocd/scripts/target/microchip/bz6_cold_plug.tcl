# SPDX-License-Identifier: GPL-2.0-or-later
#
# bz6_cold_plug.tcl — Shared BZ6 Cold-Plug + DAP Power-Up + MEM-AP Setup
#
# Supports all Microchip BZ-family devices:
#   PIC32WM_BZ6204, WBZ451, WBZ451HPE, WBZ450, WBZ351
#
# Cold-Plug is required when DEBUG_LCK bits [7:6] are non-zero (device is
# debug-locked).  The C flash driver (pic32cx_bz.c) automatically selects:
#   DEBUG_LCK != 0  ->  Quad Double Word programming (no TARGET_HALTED check)
#   DEBUG_LCK == 0  ->  Row programming (erase + write via SRAM working area)
#
# HOW INIT INTERCEPTION WORKS:
#
#   OpenOCD batch mode auto-calls 'init' BEFORE running any -c commands.
#   On a DEBUG_LCK secured BZ6 the SWD DP does not respond without cold-plug,
#   so auto-init fails and -c commands never execute.
#
#   This file installs a TCL wrapper over 'init' (the built-in is renamed to
#   _bz6_orig_init).  The wrapper:
#     1. Calls _bz6_orig_init — initialises CMSIS-DAP USB; fails at SWD on a
#        secured device (that error is caught, not fatal).
#     2. Attempts automated cold-plug via DAP_SWJ_Pins (works when the probe
#        can drive nRESET, e.g. external J-Link).
#     3. Tries bz6_dap_powerup — if CRSTEXT fired, DAP init now succeeds.
#     4. If step 3 fails (probe could not drive nRESET — e.g. on-board PKOB4
#        where the reset supervisor blocks it), falls back to user-button mode:
#        probe holds SWCLK=LOW and prints a prompt; user presses the board RESET
#        button which triggers CRSTEXT=1; then retries bz6_dap_powerup.
#     5. Verifies DBGPRES=1 / PROT=0.
#   If _bz6_orig_init succeeds (unsecured device), the wrapper returns immediately.
#
# Usage (same command for both secured and unsecured devices):
#
#   openocd -f board/microchip/pic32wm-curiosity.cfg \
#           -c "program app.production.signed.hex; shutdown"
#
# Author: Dinesh Arasu (dinesh.arasu@microchip.com)

# ---------------------------------------------------------------------------
# DAP_SWJ_Pins (CMSIS-DAP cmd 0x10) byte layout:
#   Byte 1: nOutput  — output values for selected pins
#   Byte 2: nSelect  — pin selection mask (1 = drive, 0 = release/high-Z)
#   Bytes 3-6: nWait — wait in microseconds (32-bit LE); 0 = no wait
#
# Pin bit assignments (CMSIS-DAP spec Table 5-9):
#   bit 0 = SWCLK/TCK
#   bit 7 = nRESET  (active-low SRST / MCLR)
#
# Response byte (Returned data[0]):
#   Reflects the actual electrical state of each pin after driving.
#   If nRESET (bit7) reads back 1 after we tried to drive it 0, the probe
#   hardware cannot control nRESET (reset supervisor / open-drain pull-up).
# ---------------------------------------------------------------------------
set BZ6_PIN_SWCLK  0x01
set BZ6_PIN_nRESET 0x80

# DP CTRL/STAT power-up request/ack masks
set BZ6_DP_PWRUP_REQ 0x50000000  ;# CSYSPWRUPREQ(30) | CDBGPWRUPREQ(28)
set BZ6_DP_PWRUP_ACK 0xA0000000  ;# CSYSPWRUPACK(31) | CDBGPWRUPACK(29)

# MEM-AP (AP0) CSW: Prot=0x23 privileged, AddrInc=off, Size=32-bit
set BZ6_AP_CSW_VAL          0x23000002
set BZ6_AP_CSW_DEVICE_EN    0x40        ;# bit 6 — MEM-AP live gate

# DSU external registers (accessible on secured device — Table 17-5)
set BZ6_DSU_WORD0      0x41000100  ;# CTRL[7:0] | STATUSA[15:8] | STATUSB[23:16]
set BZ6_DSU_DID        0x41000118  ;# Device ID
set BZ6_DSU_SECCFG     0x41000148  ;# DEBUG_LCK bits[7:6]
set BZ6_DSU_BOOT_STATUS 0x41000150 ;# Boot status
set BZ6_DSU_BOOT_KEY0  0x41000154  ;# Boot key word 0

# STATUSB masks (bits [23:16] of DSU_WORD0)
set BZ6_STATUSB_PROT    0x010000   ;# bit 16 — code-protected
set BZ6_STATUSB_DBGPRES 0x020000   ;# bit 17 — cold-plug detected (CRSTEXT)

# ---------------------------------------------------------------------------
# proc: bz6_cold_plug_auto
#   Automated cold-plug: drives nRESET=LOW+SWCLK=LOW, toggles SWCLK 5x,
#   releases nRESET while SWCLK=LOW.
#   Works on probes that can electrically drive nRESET (e.g. external J-Link).
#   On probes where nRESET is held HIGH by board hardware (e.g. on-board PKOB4
#   with reset supervisor), the MCLR pulse never occurs — CRSTEXT does not
#   fire, and the subsequent bz6_dap_powerup call will fail.
# ---------------------------------------------------------------------------
proc bz6_cold_plug_auto {} {
    global BZ6_PIN_SWCLK BZ6_PIN_nRESET

    echo "BZ6: Cold-plug attempt (automated — probe drives nRESET)"

    # A: Assert nRESET=LOW + SWCLK=LOW, hold 300 ms
    cmsis-dap cmd 0x10 0x00 [expr {$BZ6_PIN_nRESET | $BZ6_PIN_SWCLK}] 0 0 0 0
    after 300

    # B: Toggle SWCLK HIGH/LOW 5 cycles, nRESET=LOW
    set i 0
    while {$i < 5} {
        cmsis-dap cmd 0x10 $BZ6_PIN_SWCLK [expr {$BZ6_PIN_nRESET | $BZ6_PIN_SWCLK}] 0 0 0 0
        after 1
        cmsis-dap cmd 0x10 0x00 [expr {$BZ6_PIN_nRESET | $BZ6_PIN_SWCLK}] 0 0 0 0
        after 1
        incr i
    }

    # C: Release nRESET (drive HIGH) while SWCLK stays LOW
    #    If the probe CAN drive nRESET, this produces the MCLR rising edge
    #    that triggers CRSTEXT=1 on the BZ6.
    cmsis-dap cmd 0x10 $BZ6_PIN_nRESET [expr {$BZ6_PIN_nRESET | $BZ6_PIN_SWCLK}] 0 0 0 0
    after 20

    # D: Release all pins
    cmsis-dap cmd 0x10 0x00 0x00 0 0 0 0
    after 5

    echo "BZ6: Automated cold-plug GPIO sequence complete"
}

# ---------------------------------------------------------------------------
# proc: bz6_cold_plug_user_button
#   User-button cold-plug: holds SWCLK=LOW and waits 10 seconds for the user
#   to press the board RESET button.
#   Used as fallback when the probe cannot electrically drive nRESET (e.g.
#   on-board PKOB4 on a Curiosity board with a reset supervisor).
#
#   Cold-plug fires when the BZ6 sees MCLR rising edge while SWCLK=LOW.
# ---------------------------------------------------------------------------
proc bz6_cold_plug_user_button {} {
    global BZ6_PIN_SWCLK

    echo "BZ6:"
    echo "BZ6: Probe cannot drive nRESET — switching to user-button cold-plug mode."
    echo "BZ6: SWCLK is now held LOW by the probe."
    echo "BZ6:"
    echo "BZ6: ============================================================"
    echo "BZ6:  >>> ACTION REQUIRED <<<"
    echo "BZ6:  Press and RELEASE the RESET button on the board NOW."
    echo "BZ6:  The BZ6 samples SWCLK=LOW at the MCLR rising edge -> CRSTEXT=1"
    echo "BZ6: ============================================================"
    echo "BZ6:"
    echo "BZ6: Waiting 10 seconds..."

    # Hold SWCLK=LOW; nRESET is not driven (probe cannot control it)
    cmsis-dap cmd 0x10 0x00 $BZ6_PIN_SWCLK 0 0 0 0
    after 10000

    # Release SWCLK
    cmsis-dap cmd 0x10 0x00 0x00 0 0 0 0
    after 5

    echo "BZ6: User-button cold-plug window closed — proceeding"
}

# ---------------------------------------------------------------------------
# proc: bz6_dap_powerup
#   Manual DAP power-up and MEM-AP configuration.
#   Calls 'dap init' which does a fresh SWD line reset + DPIDR read.
#   Succeeds after cold-plug fires (CRSTEXT=1 — SWD DP is accessible).
# ---------------------------------------------------------------------------
proc bz6_dap_powerup {} {
    global BZ6_DP_PWRUP_REQ BZ6_DP_PWRUP_ACK
    global BZ6_AP_CSW_VAL BZ6_AP_CSW_DEVICE_EN

    echo "BZ6: Phase 2 - DAP power-up"

    set _dap ${::CHIPNAME}.dap

    # Initiate SWD connection (SWD line reset + DPIDR read).
    # On a CRSTEXT secured device, 'dap init' reads DPIDR successfully but may
    # fail at the internal DP power-up ACK polling step.  Catch that error:
    # if DPIDR was read the SWD transport IS connected and we can proceed with
    # manual dpreg/apreg writes to complete the power-up ourselves.
    if {[catch {dap init} dap_err]} {
        echo "BZ6:   dap init note (SWD connected, proceeding): $dap_err"
    }

    # Manual DP power-up: write CSYSPWRUPREQ + CDBGPWRUPREQ to CTRL/STAT.
    # dpreg uses BYTE OFFSET (4-byte aligned), not register index:
    #   CTRL/STAT = offset 0x04 = 4
    #   SELECT    = offset 0x08 = 8
    $_dap dpreg 4 $BZ6_DP_PWRUP_REQ

    # Poll for CSYSPWRUPACK + CDBGPWRUPACK (100 ms timeout)
    set timeout 100
    while {$timeout > 0} {
        set v [$_dap dpreg 4]
        if {($v & $BZ6_DP_PWRUP_ACK) == $BZ6_DP_PWRUP_ACK} {
            echo "BZ6: Phase 2 - DAP power-up ACK (CTRL/STAT=0x[format %08x $v])"
            break
        }
        after 1
        incr timeout -1
    }
    if {$timeout == 0} {
        error "BZ6: DAP power-up timed out — check probe and cold-plug"
    }

    echo "BZ6: Phase 3 - MEM-AP setup"
    # Select AP 0, bank 0 via DP SELECT (offset 0x08 = 8)
    $_dap dpreg 8 0x00000000
    # Write MEM-AP CSW: privileged 32-bit, AddrInc=off  (AP 0, reg 0 = CSW)
    $_dap apreg 0 0 $BZ6_AP_CSW_VAL

    # Read CSW back and verify DeviceEn (bit 6)
    set csw [$_dap apreg 0 0]
    if {($csw & $BZ6_AP_CSW_DEVICE_EN) == 0} {
        error "BZ6: MEM-AP DeviceEn=0 — cold-plug did not succeed (CSW=0x[format %08x $csw])"
    }
    echo "BZ6: Phase 3 - MEM-AP live, CSW=0x[format %08x $csw]"
}

# ---------------------------------------------------------------------------
# proc: bz6_mww / bz6_mrw
#   Direct MEM-AP memory read/write via TAR + DRW apreg commands.
#   Used instead of mww/mrw because on a secured device (DEBUG_LCK != 0)
#   the target is never examined (CPUID at 0xE000ED00 is blocked), so
#   OpenOCD's target memory access path fails with "Target not examined yet".
#   These procs bypass the target layer and use the MEM-AP directly.
#
#   Requires bz6_dap_powerup to have run (MEM-AP CSW already configured).
#
#   apreg offsets within the MEM-AP (AP 0):
#     reg  0 = CSW (0x00)
#     reg  4 = TAR (0x04) — target address register
#     reg 12 = DRW (0x0C) — data read/write
# ---------------------------------------------------------------------------
proc bz6_mww {address value} {
    set _dap ${::CHIPNAME}.dap
    $_dap apreg 0 4  $address   ;# TAR = address
    $_dap apreg 0 12 $value     ;# DRW write → triggers 32-bit write to memory
}

proc bz6_mrw {address} {
    set _dap ${::CHIPNAME}.dap
    $_dap apreg 0 4  $address   ;# TAR = address
    $_dap apreg 0 12            ;# DRW read 1: initiates fetch (posted read,
                                ;#   returns stale data — discard)
    return [$_dap apreg 0 12]   ;# DRW read 2: returns data from first fetch
}

# ---------------------------------------------------------------------------
# proc: bz6_verify_device_state
#   Verify DBGPRES=1 (cold-plug confirmed) and PROT=0.
#   Uses bz6_mrw/bz6_mww (direct MEM-AP) instead of mrw/mww (target layer).
# ---------------------------------------------------------------------------
proc bz6_verify_device_state {} {
    global BZ6_DSU_WORD0 BZ6_DSU_DID BZ6_DSU_SECCFG
    global BZ6_STATUSB_PROT BZ6_STATUSB_DBGPRES

    echo "BZ6: Phase 4 - Device state verification"

    # W1C clear stale STATUSA flags (bits [15:8]) before reading
    bz6_mww $BZ6_DSU_WORD0 0x00001F00

    set word0 [bz6_mrw $BZ6_DSU_WORD0]
    echo "BZ6: DSU_WORD0 = 0x[format %08x $word0]"

    if {($word0 & $BZ6_STATUSB_DBGPRES) == 0} {
        error "BZ6: Cold-plug NOT detected (DBGPRES=0) — retry"
    }
    echo "BZ6: DBGPRES=1 — cold-plug confirmed"

    if {($word0 & $BZ6_STATUSB_PROT) != 0} {
        error "BZ6: Device is code-protected (PROT=1) — chip erase required"
    }
    echo "BZ6: PROT=0 — proceed"

    set did    [bz6_mrw $BZ6_DSU_DID]
    set seccfg [bz6_mrw $BZ6_DSU_SECCFG]
    set dlck   [expr {($seccfg >> 6) & 0x3}]
    echo "BZ6: Device ID = 0x[format %08x $did]"
    echo "BZ6: SECCFG = 0x[format %08x $seccfg], DEBUG_LCK = $dlck"

    return 1
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Replace the 'program' proc to skip 'reset init' for secured CRSTEXT devices.
#
# The standard 'program' proc (flash/startup.tcl) calls 'reset init' before
# flash write.  On a secured CRSTEXT BZ6:
#   - 'reset init' issues SWD line resets that clear DP power-up state
#   - The CPU cannot be halted (DHCSR writes blocked)
#   - 'reset run' after programming is replaced by power-cycling the board
#
# Strategy: call 'init' first (runs cold-plug, sets ::_bz6_secured_mode),
# then decide whether to skip or execute reset init.
# For unsecured devices the full standard program behavior is replicated.
# No rename needed — proc definition replaces the existing program proc.
# ---------------------------------------------------------------------------
proc program {filename args} {
    set exit 0
    set needsflash 1

    foreach arg $args {
        if {[string equal $arg "preverify"]} {
            set preverify 1
        } elseif {[string equal $arg "verify"]} {
            set verify 1
        } elseif {[string equal $arg "reset"]} {
            set doreset 1
        } elseif {[string equal $arg "exit"]} {
            set exit 1
        } else {
            set address $arg
        }
    }

    set fn "\{$filename\}"
    if {[info exists address]} {
        set flash_args "$fn $address"
    } else {
        set flash_args "$fn"
    }

    # Step 1: init  — triggers cold-plug for secured devices and sets
    #                  ::_bz6_secured_mode; no-op on second call for unsecured.
    if {[catch {init}] != 0} {
        program_error "** OpenOCD init failed **" 1
    }

    # Step 2: reset target before programming
    if {[info exists ::_bz6_secured_mode]} {
        # Secured CRSTEXT: skip reset init — preserves DP power-up state.
        # The device is already in CRSTEXT mode from cold-plug.
        echo "BZ6: Skipping 'reset init' — preserving CRSTEXT cold-plug DAP state"
    } else {
        # Unsecured: standard reset + init
        if {[catch {reset init}] != 0} {
            program_error "** Unable to reset target **" $exit
        }
    }

    # Step 3: optional pre-verify
    if {[info exists preverify]} {
        echo "**pre-verifying**"
        if {[catch {eval verify_image $flash_args}] == 0} {
            echo "**Verified OK - No flashing**"
            set needsflash 0
        }
    }

    # Step 4: flash write
    if {$needsflash == 1} {
        echo "** Programming Started **"

        if {[catch {eval flash write_image erase $flash_args}] == 0} {
            echo "** Programming Finished **"

            if {[info exists verify]} {
                echo "** Verify Started **"
                if {[catch {eval verify_image $flash_args}] == 0} {
                    echo "** Verified OK **"
                } else {
                    program_error "** Verify Failed **" $exit
                }
            }
        } else {
            program_error "** Programming Failed **" $exit
        }
    }

    # Step 5: optional reset after programming
    if {[info exists doreset]} {
        if {[info exists ::_bz6_secured_mode]} {
            echo "BZ6: Post-program reset skipped — power-cycle the board to boot"
            echo "BZ6: ROM will authenticate the signed image on power-up"
        } else {
            if {$exit == 1} { poll off }
            echo "** Resetting Target **"
            # 'reset run' triggers the target's 'reset-deassert-post' event,
            # which is wired (in pic32wm.cfg) to call 'pic32cx_bz
            # dsu_reset_deassert' — the official DSU debugger-aware reset
            # handshake. This tells the Secure Boot ROM that a debugger is
            # attached so it takes the debug-aware boot path, rather than
            # pausing at its BKPT debugger-detection checkpoint early in ROM
            # (which happened with a plain reset while SWD stays connected).
            # Fallback to 'resume' (continue from the already-halted state
            # without a fresh reset event) if 'reset run' still fails.
            if {[catch {reset run} err]} {
                echo "BZ6: reset run failed ($err) — falling back to resume"
                resume
            }
        }
    }

    if {$exit == 1} { shutdown }
    return
}

# Shadow the built-in 'init' command to inject cold-plug automatically.
#
# Sequence:
#  1. _bz6_orig_init  — initialises USB; fails at SWD on a secured device.
#  2. bz6_cold_plug_auto  — GPIO sequence; needs probe to drive nRESET.
#  3. bz6_dap_powerup  — if CRSTEXT fired, 'dap init' now succeeds.
#  4. If step 3 fails: bz6_cold_plug_user_button (SWCLK=LOW, wait for RESET
#     button press), then retry bz6_dap_powerup.
#  5. bz6_verify_device_state.
# ---------------------------------------------------------------------------
rename init _bz6_orig_init

proc init {} {
    global _bz6_init_done

    if {[info exists _bz6_init_done]} {
        # Already fully initialized via cold-plug sequence.
        # Subsequent calls (e.g. from the 'program' proc in startup.tcl)
        # are no-ops — our DAP/MEM-AP setup is still valid.
        return
    }
    set _bz6_init_done 1

    echo "BZ6: Intercepting init for cold-plug handling"

    # Step 1: Try normal init — succeeds immediately on unsecured devices
    if {![catch {_bz6_orig_init} err]} {
        echo "BZ6: init succeeded without cold-plug (unsecured device)"
        return
    }

    echo "BZ6: init failed at SWD level (expected on secured device): $err"
    echo "BZ6: CMSIS-DAP USB is ready — attempting cold-plug"

    # Step 2: Try automated cold-plug (probe drives nRESET)
    bz6_cold_plug_auto

    # Step 3: DAP power-up — succeeds if CRSTEXT fired in step 2
    if {![catch {bz6_dap_powerup} dap_err]} {
        echo "BZ6: Automated cold-plug succeeded"
        bz6_verify_device_state
        echo "BZ6: init override complete — device ready"
        return
    }

    # Step 4: Probe could not drive nRESET — fall back to user-button
    echo "BZ6: Automated cold-plug did not achieve CRSTEXT: $dap_err"
    bz6_cold_plug_user_button

    # Step 5: Retry DAP power-up after user-button cold-plug
    bz6_dap_powerup
    bz6_verify_device_state

    # Attempt target examine to initialize armv7m->debug_ap in the C layer.
    # On a secured CRSTEXT device, examine fails at CPUID (0xE000ED00 blocked)
    # but the side-effect of setting debug_ap and calling mem_ap_init IS needed
    # so that pic32cx_get_ap() in the flash driver can fall back to debug_ap.
    # The error is expected and caught.
    echo "BZ6: Initializing C-level target memory structures (arp_examine)..."
    catch {${::CHIPNAME}.cpu arp_examine} exam_err
    if {$exam_err ne ""} {
        echo "BZ6:   arp_examine note (expected on secured device): $exam_err"
    }

    # Mark device as secured: halt/reset overrides will return early,
    # preventing SWD line resets that would clear DP power-up state.
    # This flag is ONLY set when cold-plug was required (DEBUG_LCK != 0).
    set ::_bz6_secured_mode 1

    # Settle delay before the first NVM operation.
    # Observed: PFM sector 0 erase can intermittently report WRERR
    # (NVMCON=0x6004) when it is the FIRST NVM command issued right after
    # cold-plug (no prior BFM operation to implicitly let the NVM controller
    # settle). A short delay here is cheap insurance against that race.
    after 50

    echo "BZ6: init override complete — device ready for flash operations"
}

# ---------------------------------------------------------------------------
# Pre-register flash EXEC commands at config-file source time.
#
# 'flash write_image', 'flash erase_sector', etc. are COMMAND_EXEC-level
# commands registered by flash_init_drivers() which is called from
# handle_init_command() at COMMAND_CONFIG level (lines 154-164 of openocd.c).
#
# For a DEBUG_LCK secured device, handle_init_command() fails at transport
# init (SWD cannot connect without cold-plug) and returns before reaching
# those lines.  As a result, flash EXEC commands are never registered and
# 'flash write_image erase' fails with "unknown subcommand".
#
# Fix: call 'flash init' HERE, at config-file source time, while:
#   - Command mode is COMMAND_CONFIG  (flash init is CONFIG-only)
#   - Flash banks are already registered (target .cfg was sourced first)
#
# flash_init_drivers() registers the EXEC commands into Jim's global command
# table; they will be callable at EXEC level after our cold-plug init runs.
# For unsecured devices, handle_init_command() calls 'flash init' again
# later — duplicate registration via Jim_CreateCommand is harmless (replaces
# with the same handler).
# ---------------------------------------------------------------------------
if {[llength [flash list]] > 0} {
    echo "BZ6: Pre-registering flash EXEC commands (flash write_image etc.)..."
    flash init
}
