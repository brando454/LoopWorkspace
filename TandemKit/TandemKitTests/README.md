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

## Two tests fail ON PURPOSE

`testInitiateBolusRequest_1u_PINS_KNOWN_ENCODER_BUGS` encodes the CORRECT pump
bytes and will fail until `InitiateBolusRequest.init(units:bolusId:)` is fixed:

1. `foodVolume` is currently set to `units * 1000`; pumpX2 requires `0` for a
   bolus with no carbs (otherwise the pump double-books the volume).
2. `bolusTypeBitmask` is currently `0`; a standard food bolus is `8`.

That failing test is the regression guard for the fix. Do not relax the
assertion to make it green — fix the initializer.
