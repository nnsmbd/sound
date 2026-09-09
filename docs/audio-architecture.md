# Per-app volume: техническое решение до реализации

Проверено по первичным источникам 10 сентября 2026. Это исследование и проектное решение, не результат испытаний звукового движка.

## Решение

Начать с **Core Audio Process Taps**, без устанавливаемого HAL-драйвера. Apple документирует захват одного процесса или группы процессов, private taps и подключение tap к aggregate device; официальный пример требует macOS 14.2+. Для первого поддерживаемого релиза предлагается macOS 14.4+ как более узкий стартовый диапазон, а не как заявленный Apple минимум API. [Apple: Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [AudioCap, авторский пример на 14.4+](https://github.com/insidegui/AudioCap).

Это не системный setter громкости чужого приложения. Предлагаемый тракт: **аудиопроцессы приложения → private tap → изменение амплитуды → текущий выход**. Отдельный тракт на управляемую группу; остальные приложения продолжают играть напрямую. Aggregate device — объект Core Audio во время работы, не установленный virtual driver. Работоспособность такого полного тракта нужно доказать звуковым прототипом.

## Сравнение подходов

| Подход | Что подтверждено | Вывод для MVP |
|---|---|---|
| Process Taps | Захват выбранных процессов; управление подавлением их исходного вывода. | Основной кандидат: меньше установки и системного вмешательства. Требует собственного корректного playback/DSP. |
| Virtual HAL device | Background Music получает клиентские потоки до общего смешивания и меняет per-client gain. Его driver реализует AudioServerPlugIn. | Рабочий архитектурный прецедент, но больше компонентов и сопровождения. Резервный путь, если taps не пройдут испытания. |
| ScreenCaptureKit | `capturesAudio` даёт аудио захвата, есть исключение собственного аудио. В изученной конфигурации нет аналога tap mute для исходного вывода чужого приложения. | Одного захвата недостаточно: исходный звук останется слышен. Не выбирать как основу микшера. |

Источники: [Apple tap mute](https://developer.apple.com/documentation/coreaudio/catapmutebehavior?language=objc), [Background Music driver](https://github.com/kyleneideck/BackgroundMusic/blob/master/BGMDriver/BGMDriver/BGM_PlugInInterface.cpp), [Background Music architecture](https://github.com/kyleneideck/BackgroundMusic/blob/master/DEVELOPING.md), [ScreenCaptureKit audio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio).

## Надёжность важнее ползунков

Использовать `.mutedWhenTapped`: Apple описывает подавление прямого звука только на время чтения tap другим аудиоклиентом. Это основание для восстановления прямого звука после остановки, **не доказанная гарантия после crash или зависания**. Зависший playback при продолжающемся чтении может оставить приложение без звука. Нужны испытания принудительного завершения, зависания callback и восстановления Core Audio; штатное завершение обязано остановить I/O и уничтожить tap/aggregate. [Apple: CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior?language=objc).

Предлагаемые инженерные требования: предусмотреть безопасное отключение обработки; не делать allocation, locks, disk I/O или UI-вызовов в realtime callback; менять gain плавно; не допускать повторного захвата собственного playback. Переключение выхода требует явного управления жизненным циклом тракта. Эти требования — наш проектный вывод, а их выполнение ещё не проверено.

У Background Music virtual device становится системным выходом. README прямо описывает восстановление звука вручную после crash сменой output device, а также случаи, когда звук принадлежит Helper-процессу. Поэтому driver сам по себе не делает продукт автоматически надёжным и не решает группировку процессов. [Background Music README](https://github.com/kyleneideck/BackgroundMusic).

## Разрешения и распространение

Для taps нужен `NSAudioCaptureUsageDescription`; Apple запрашивает system audio recording permission при первом запуске захвата через aggregate с tap. В onboarding объяснить: доступ нужен для изменения громкости; аудио обрабатывается в памяти, не сохраняется и не отправляется. Последнее — требование к нашему продукту, не свойство API. [Apple sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

Не копировать private TCC permission API из AudioCap: сам автор отмечает этот путь как private и предоставляет флаг отключения. Использовать публичный штатный запрос при старте. [AudioCap](https://github.com/insidegui/AudioCap).

Первое распространение предлагается напрямую: Developer ID, Hardened Runtime, notarization. App Sandbox обязателен для Mac App Store, но для прямого notarized распространения опционален. **Совместимость конкретного tap/playback тракта с sandbox здесь не доказана; невозможность Mac App Store не утверждается.** Не добавлять предположительные entitlements. [Apple distribution setup](https://developer.apple.com/documentation/Xcode/preparing-your-app-for-distribution), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Маленькое ядро продукта

Одна menu bar панель; список реально обнаруженных аудиоприложений; gain 0–100%; mute с возвратом предыдущего значения; название текущего выхода. Swift/AppKit для status item и панели, нативные элементы управления. Одна строка на приложение с объединением подтверждённых аудиопроцессов; неизвестный Helper не приписывать приложению по догадке. Проценты означают дополнительный gain поверх собственного регулятора приложения.

Первый звуковой прототип: два одновременно играющих приложения, встроенный стереовыход, независимое ослабление и mute. Затем Chrome/Telegram/Spotify/Discord, запуск и перезапуск helper-процессов. Без boost, EQ, маршрутизации приложений на разные устройства, глобальных профилей и записи.

## Что ещё не подтверждено

- Отсутствие щелчков, удвоения звука и заметной задержки; измерить, а не обещать число миллисекунд.
- Автоматический возврат прямого звука при crash, hang, sleep/wake и перезапуске audio service.
- Переход встроенные динамики ↔ USB ↔ Bluetooth, смена sample rate и Bluetooth hands-free режима при звонке. AirPods, AirPlay, HDMI/multichannel и профессиональные устройства не объявлять поддержанными без тестов.
- Надёжное объединение helper-процессов, особенно браузеров и звонков. Громкость отдельных вкладок не входит в MVP.
- DRM/защищённые потоки: в просмотренных источниках нет достаточной гарантии захвата каждого сервиса. Не обещать универсальность и не обходить защиту. Нулевые samples сами по себе не доказывают отсутствие разрешения или DRM.
- Поведение разрешений после обновления подписанной сборки и на каждой поддерживаемой версии macOS.

Критерий выбора окончательной архитектуры: taps остаются основой, только если звуковой прототип проходит перечисленные базовые проверки. При провале сначала локализовать ограничение; решение о HAL-драйвере принимать по конкретному воспроизводимому дефекту, а не заранее усложнять установку.
