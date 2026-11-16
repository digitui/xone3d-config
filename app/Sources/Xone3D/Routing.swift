import Foundation

/// The Xone:3D soundcard configuration, modelled to match the "Soundcard
/// Operating Modes" section of the Xone:3D User Guide (p.12) and the original
/// Configuration Utility.
///
/// Mode 1 — 1 Stereo In, 3 Stereo Out (default)
///   * one soundcard input source (5 choices incl. SPDIF in)
///   * digital out source: 4 choices
///   * returns: SC 1-2→CH1&CH4, 3-4→CH2, 5-6→CH3
///
/// Mode 2 — 2 Stereo In, 2 Stereo Out
///   * In 3-4 source (5 choices incl. SPDIF in) + In 1-2 source (3 choices)
///   * digital out source: 2 choices
///   * returns: SC 1-2→CH1&CH4, 3-4→CH2, 5-6 unused
///
/// The encode()/decode() below reproduce the exact 16-bit routing-word packing
/// recovered from -[XoneControl encodeAndSendRouting] / readAndDecodeRouting.
/// The option counts in the User Guide match that packing, which corroborates
/// the reconstruction. The UI also exposes the raw word for verification.
struct SoundcardConfig: Equatable {

    // Menu option labels (authoritative text from the User Guide).
    static let modeLabels = [
        "Mode 1 — 1 Stereo In, 3 Stereo Out",
        "Mode 2 — 2 Stereo In, 2 Stereo Out",
    ]
    /// Soundcard input source. In Mode 1 this is "the" input; in Mode 2 it is
    /// the In 3-4 source. 5 choices, order fixed by the routing encoding.
    static let input1Labels = [
        "SPDIF coax input",
        "SPDIF optical input",
        "Main MIX",
        "FX1 send",
        "CH2 phono preamp",
    ]
    /// Mode 2 only: the In 1-2 source. 3 choices.
    static let input2Labels = [
        "Main MIX",
        "FX1 send",
        "CH3 phono preamp",
    ]
    static let digitalOutMode1Labels = [
        "Soundcard output 1-2",
        "Main MIX",
        "FX1 send",
        "CH3 phono preamp",
    ]
    static let digitalOutMode2Labels = [
        "Soundcard output 1-2",
        "Soundcard input 1-2",
    ]
    static let midiMapLabels = ["Map 1", "Map 2"]   // Map 2 is the default

    static func returnsText(mode: Int) -> String {
        mode == 0
            ? "Returns:  SC 1-2 → CH1 & CH4    3-4 → CH2    5-6 → CH3"
            : "Returns:  SC 1-2 → CH1 & CH4    3-4 → CH2    5-6 not used"
    }

    var mode: Int        // 0 = Mode 1, 1 = Mode 2
    var input1: Int      // 0..4
    var input2: Int      // 0..2  (Mode 2 only)
    var digitalOut: Int  // Mode 1: 0..3, Mode 2: 0..1
    var midiChannel: Int // 0..15  (displayed as 1..16)
    var midiMap: Int     // 0 = Map 1, 1 = Map 2

    // MARK: - packing  (exact reconstruction from the binary)

    func encode() -> UInt16 {
        var w: UInt16 = 0

        // Soundcard input source (A): indices 0,1 are the SPDIF inputs and sit
        // in bits 9/10; indices 2..4 sit in bits 2-3 as (A-1).
        if input1 <= 1 {
            w |= 0x0200
            w |= UInt16(input1 & 1) << 10
        } else {
            w |= UInt16((input1 - 1) & 3) << 2
        }

        if mode == 0 {
            // Digital out: index 0 -> bit 14; indices 1..3 -> bits 0-1.
            if digitalOut != 0 { w |= UInt16(digitalOut & 3) } else { w |= 0x4000 }
        } else {
            w |= 0x0100                                   // Mode 2 select (bit 8)
            w |= UInt16((input2 + 1) & 3)                 // In 1-2 source, bits 0-1
            if digitalOut == 0 { w |= 0x4000 }            // digital out in bit 14 only
        }

        w |= UInt16(midiChannel & 0x0F) << 4              // MIDI channel, bits 4-7
        if midiMap != 0 { w |= 0x8000 }                   // MIDI map, bit 15
        return w
    }

    static func decode(_ w: UInt16) -> SoundcardConfig {
        let mode = Int((w >> 8) & 1)

        let input1: Int
        if (w >> 9) & 1 == 1 {
            input1 = Int((w >> 10) & 1)          // 0 or 1 (SPDIF coax/optical)
        } else {
            input1 = Int((w >> 2) & 3) + 1       // 2..4 (MIX/FX1/CH2)
        }

        var input2 = 0
        var digitalOut = 0
        if mode == 0 {
            digitalOut = ((w >> 14) & 1 == 1) ? 0 : Int(w & 3)
        } else {
            input2 = max(0, min(2, Int(w & 3) - 1))
            digitalOut = ((w >> 14) & 1 == 1) ? 0 : 1
        }

        return SoundcardConfig(
            mode: mode,
            input1: min(4, max(0, input1)),
            input2: input2,
            digitalOut: digitalOut,
            midiChannel: Int((w >> 4) & 0x0F),
            midiMap: Int((w >> 15) & 1))
    }
}
