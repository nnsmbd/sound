# Verification — 0.1.0 preview

- Release build: passed, Swift 6.3.3 / macOS SDK 26.5, arm64.
- Four Swift Testing tests passed: independent stereo gain, smooth mute and restore, non-finite samples, malformed-buffer rejection.
- Real Telegram tap, current stereo output at 48 kHz: 557 callbacks over six seconds, zero format faults. Output peaks were 0.3 × input peaks. No samples saved.
- Real application discovery passed, including Chrome helpers grouped by executable ownership.
- Native panel screenshot inspected at 224 × 132 pt with one real source. Labels, slider, mute and output fit; no overlaps. Native regular NSGlassEffectView renders system-controlled material.
- UI click changed Telegram from 100% to 26%; mute displayed disabled state. Outside clicks close the panel. Automated UI observation intermittently loses the nonactivating panel; full keyboard and menu regression remains unverified.
- Not verified: simultaneous live sources isolation, physical loopback/no double sound, perceptual latency, Bluetooth changes, sleep/wake, crash/hang recovery, four-row visual QA at final size, Intel, older macOS and notarized distribution.

This is a prerelease for local testing, not a claim of universal device support or release-quality audio reliability.

## 0.2.0 — переключение выхода

Проверено на Mac пользователя: выбор в панели меняет системный выход с MCHOSE G9 Pro на динамики MacBook Air и обратно; результат независимо прочитан через Core Audio. Исходный MCHOSE восстановлен. В списке также отображается DELL S2421HGF; физическое воспроизведение на нём и переподключение Bluetooth не проверены. Сборка release и 4 DSP-теста прошли. Видимость значка menu bar пока не подтверждена пользователем.
