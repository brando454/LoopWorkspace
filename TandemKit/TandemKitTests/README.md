# TandemKit unit tests

These tests validate the dose-reporting foundation against real device-captured
byte vectors from [jwoglom/pumpX2](https://github.com/jwoglom/pumpX2)
(revision `9bfc6691a463e783ac55067dd3eeffb76be8b0f7`). They run with no pump and
no Raspberry Pi simulator — pure logic and wire-format checks.

## Files

- `CRC16Tests.swift` — pre-existing CRC-16/CCITT checks.
- `TandemMessageVectorTests.swift` — encode/parse each bolus and temp-rate message
  to/from the exact cargo bytes pumpX2 captured from physical Tandem pumps.
- `TandemDoseReporterTests.swift` — the LoopKit-facing reconciliation logic:
  report DELIVERED (not requested) insulin, dedupe by `bolusId`, handle
  partial/cancelled boluses, and report temp basal as an absolute U/hr rate.

## Running on your Mac

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `TandemKit/project.yml`, so regenerate before opening:

```bash
cd TandemKit
xcodegen generate        # rebuilds TandemKit.xcodeproj from project.yml
xcodebuild test \
  -project TandemKit.xcodeproj \
  -scheme TandemKitTests \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

`TandemDoseReporterTests` imports `LoopKit`, so the test target now links
`LoopKit.framework` explicitly (see `project.yml`); transitive linking is off
project-wide. If the framework is not found, confirm LoopKit has built into
`BUILT_PRODUCTS_DIR` first (build the `TandemKit` scheme once).

## InitiateBolus encoder fix (regression guard)

`testInitiateBolusRequest_1u_matchesPumpX2Capture` guards a fix to
`InitiateBolusRequest.init(units:bolusId:)`:

1. `foodVolume` must be `0`, not `units * 1000` (the old value made the pump
   double-book the dose, since the pump treats foodVolume as a separate
   component of the total).
2. `bolusTypeBitmask` must be `8` (FOOD2), not `0`.

Both are now fixed in source. Do not relax the assertion — it encodes the bytes a
real pump expects for a standard override bolus.

The initializer still hardcodes every bolus as FOOD2 with no carb/BG/IOB context.
That is correct for the current no-carb override path but must be replaced with a
fuller initializer (per-type bitmask, foodVolume/correctionVolume split) before
Loop drives meal or correction boluses. See the note in `BolusMessages.swift`.
