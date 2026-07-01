# Cue sound sources (build-time inputs)

Blurt's record-start/stop cues are rendered from two authentic vintage synths by
`../generate-sounds.swift`. Everything here is **build-time only** — the rendered
WAVs in `App/Blurt/Blurt/Resources/Sounds/` are what ship; Blurt needs none of
these to run.

## Yamaha DX7

`rom1a.syx` and `rom1b.syx` are the genuine Yamaha DX7 factory ROM cartridge
SysEx dumps (each a 4104-byte 32-voice bank), sourced from
<https://yamahablackboxes.com/patches/dx7/factory/>. The generator loads them
into the **Dexed** Audio Unit (`aumu Dexd DGSB`,
<https://asb2m10.github.io/dexed/>) via SysEx + program change. All 64 ROM1A/1B
voices become packs.

## Roland Juno-106

The Juno-106 voices are the 128 authentic factory presets built into **KR-106**
(Ultramaster KR-106, `aumu Kr16 Krok`, <https://kayrock.org/kr106/>), an
open-source Juno-106 emulation. The generator hosts the AU and selects each
named factory preset. Nothing to vendor here — the presets live in the plugin.

## Regenerating

Install both Dexed and KR-106, then run `swift scripts/generate-sounds.swift`.
It rewrites the WAVs and `Sources/BlurtEngine/Audio/SoundPackCatalog.swift`.
The default voice is ORCHESTRA (DX7 ROM1A v6).
