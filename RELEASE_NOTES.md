Native macOS per-app volume utility with a compact 224 pt menu bar panel and system Liquid Glass on macOS 26.

Apple Silicon build, macOS 14.4+. Older macOS uses the standard visual-effect material.

Includes app discovery, 0–100% gain, mute, reset and current output. Core Audio process taps; no installed driver, audio recording or network services.

Validation: release build and four DSP tests passed; six-second Telegram route check returned 557 callbacks with zero format faults and correct 30% amplitude. Native panel and volume click inspected.

Preview limitations: ad-hoc signed, not notarized. Distribution signing is not configured. Bluetooth transitions, crash/hang recovery, simultaneous live-source isolation and latency have not been fully validated. See docs/verification.md. Levels do not persist across relaunches.

Download and extract the zip to obtain VolumeMixer.app. This release is a downloadable native app, not a VPS service.
