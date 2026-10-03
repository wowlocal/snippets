# Аудит work/cloud-account-key — 3 октября 2026

Проверенный исходный код: `5f249dfcf3384ccc6a75f904c51f5cb02bc2de47`.
Рабочая копия была чистой. Производственный код не изменялся. В автономном продолжении добавлены два opt-in протокольных E2E-теста; результаты продолжения приведены в конце отчёта.

**Итог с учётом следующего stateful-прогона:** ветка не готова по сохранности данных. Подтверждена потеря конкурентной версии Android при Mac/Android/Linux sync; после kill/recovery и последующих последовательных правок появляются лишние конфликтные копии. Также остаются прежние CorePackage build failure, MainActor Keychain и Linux timing flake. Подробные задачи для Opus 5.5: [индекс дефектов](issues/cloud-account-key/README.md). Успешные результаты более ранних прогонов ниже сохраняются как история проверки, но не отменяют этих находок.

## Стенд и изоляция

- macOS: настоящий Mac, отдельный `com.khm.snippets.debug.native-sync`, отдельный каталог данных.
- Linux: Arch ARM64 в UTM, нативный Rust-клиент этой ветки. GUI Xfce настроен ранее; виртуальный диск расширен до 40 GiB. Новый тестовый бинарник: `/usr/local/bin/snippets-account-key-audit`.
- Android: Pixel 8 / API 35, временный экземпляр AVD `-read-only -no-snapshot`.
- iPhone и iPad: отдельные одноразовые симуляторы iOS/iPadOS 26.5. Физические устройства не использовались.
- Backend: отдельный Compose project `snippets-account-key-audit`, PostgreSQL 18.4, Go 1.26.6, native account-key auth, отдельные случайные серверные секреты и тестовая БД. HTTP на `127.0.0.1:8087`, PostgreSQL на `127.0.0.1:55437`.
- Мобильные и Linux live-тесты использовали настоящий HTTPS через временный Cloudflare tunnel. Нагрузочный HTTP-прогон обращался непосредственно к loopback backend, минуя tunnel.
- Только синтетические библиотеки и одноразовые аккаунты. Пользовательские библиотеки, Production CloudKit, установленные пользовательские приложения и другие Docker-сервисы не сбрасывались.

Артефакты этого запуска находятся в приватном каталоге `/tmp/snippets-account-key-audit` (он может исчезнуть после очистки временных файлов). Серверные `.env`, ключи и токены не включены в репозиторий. UI-артефакты могут содержать экран с ключом **тестового** аккаунта; не публиковать весь каталог как обычный лог.

## Подтверждённые проблемы

### 1. CorePackage не компилируется

Команда: `swift test --package-path CorePackage`.

`snippets/SecureSnippetCaptureRenderer.swift:508` обращается к `EditorInputSurface.inputBackgroundColor`, но `EditorInputSurface` определён в `snippets/LiquidGlassDesign.swift` и не входит в target `SnippetsSecureEditor` пакета. Ошибка: `cannot find 'EditorInputSurface' in scope`.

Это блокирует обязательную проверку CorePackage. App targets Mac/iOS при этом собираются. Исправление должно восстановить корректную границу зависимостей renderer/design, а не замаскировать её тестовой заглушкой. Доказательство: `core.log`.

### 2. Keychain на главном потоке при включённом Snippets Cloud

`SyncLifecycleTests.testIOSLaunchDoesNotBlockOnUnrelatedCloudCredentialMarkers` падает на iPhone и iPad, а также при отдельном повторном запуске на iPhone. Проверка в `snippets-ios-tests/SyncLifecycleTests.swift:1732` обнаруживает `gate.calledOnMainThread == true`.

Прослеживаемый путь: `SyncBackendSelectionStore.swift:499–506` запускает `Task @MainActor`, после фонового чтения одного маркера вызывает `resumeCredentialLineageIfNeeded()`. При `snippetsCloudEnabled == true` строки 522–525 синхронно вызывают `inspectCredentialLineage()`, который читает session/replacement/revocation items из Keychain (строка 2467 и далее).

Последствие: медленный Security.framework IPC может задерживать UI запуска. Тест доказывает неправильный поток, но не измеряет длительность задержки на физическом устройстве. По `git blame` этот путь предшествует последним account-key коммитам; это найденная проблема проверяемого состояния ветки, а не доказанная новая регрессия этих коммитов.

Доказательства: `ipad-unit.xcresult`, `ipad-unit-summary.json`, `iphone-repro-unit.xcresult`. Полный iPhone unit-прогон выполнил 543 теста с одним падением, но Xcode завис на завершении сессии; после сохранения stdout он был остановлен. Его незавершённый result bundle не считается успешно финализированным отчётом.

## Результаты

| Проверка | Результат |
|---|---|
| Go `go test -race ./...`, `go vet ./...` | Прошли |
| Auth/domain/httpapi, 30 повторов с race detector и перемешиванием | Прошли; в этом запуске DB-dependent тесты не включены |
| Отдельный PostgreSQL integration suite | Прошёл, 19 верхнеуровневых тестов auth/postgres, включая вложенные сценарии |
| Auth с настоящей PostgreSQL, 10 повторов, race detector | Прошёл, включая device approval, refresh races, отзыв и изоляцию |
| PostgreSQL compaction | Прошёл на 100 000 records / 200 001 changes |
| Linux основной набор | 1062 прошли, 38 пропущены |
| Linux дополнительные live HTTPS-тесты | 2 прошли |
| Android Swift core | 17 прошли |
| Android JVM | 75 прошли, 0 пропущены |
| Mac app tests | 98 прошли, 2 пропущены, 2 падения проверок фокуса окна при заблокированном Mac; требуется проверка после разблокировки |
| iPhone full unit stdout | 542 прошли, 1 падение Keychain; финализация Xcode прервана |
| iPad full unit | 542 прошли, 1 падение Keychain |
| Android instrumentation (UI и platform boundaries) | 13 прошли |
| Android native account-key UI E2E | 1 прошёл |
| iPhone native account-key UI E2E | 1 прошёл |
| iPad native account-key UI E2E | 1 прошёл |
| Межплатформенный native sync harness | Все 15 этапов прошли |
| HTTP-нагрузка с backoff | Прошла, детали ниже |
| Перезапуск PostgreSQL + backend | Прошёл: 32 записи, scope, cursor, refresh и вход по сохранённому account key сохранились |

Mac-падения: `ClipboardHistoryMenuTrackingTests/testEscapeClosesNativeActionsMenuBeforeDismissingPicker` и `FloatingPanelAppearanceTests/testPickerSurfaceFollowsInheritedThemeWithoutDependingOnKeyboardFocus`. Повторный запуск также падает на проверках фокуса. Computer Use подтвердил, что Mac заблокирован. Связь с блокировкой — наиболее вероятное объяснение, но повтор на разблокированном Mac ещё нужен; это не установленный дефект sync; визуальный smoke-тест Linux также не завершён по этой причине.

## Что проверено в живом взаимодействии клиентов

Основной harness (`scripts/test-native-cloud-integration.py`) выполнил:

1. Mac создаёт запись; iPhone читает её и добавляет свою; Android читает обе и добавляет свою.
2. Mac редактирует запись Android, iPhone редактирует запись Mac; клиенты и iPad сходятся к ожидаемому состоянию.
3. Сервер отклоняет устаревший CAS.
4. Android удаляет запись при потере ответа после применения записи сервером.
5. Mac восстанавливается после обрезанного ответа; Android — после устаревшего курсора.
6. iPhone, iPad и Android подтверждают удаление без воскрешения записи.
7. Финальное состояние: 2 живые записи, 1 tombstone. Контрольные plaintext-пробы отсутствуют на сервере. Отзыв семейства токенов подтверждён.

Linux отдельно расшифровал реальные записи Mac/iPhone из того же тестового пространства. Второй Linux live-тест проверил создание аккаунта, вход, refresh, чужой аккаунт, 120 зашифрованных Unicode-записей с пагинацией, повтор CAS и отзыв токенов. Он не был пятым участником всех 15 этапов основного harness; двусторонний полный пятисторонний прогон не заявляется.

Android UI E2E проверил локальную опечатку, корректно оформленный неизвестный ключ, создание и сохранение ключа, refresh/инвалидацию прежнего access token, пересоздание Activity, выход и повторный вход с нормализацией ключа. Apple UI E2E проверил отмену, опечатку, создание аккаунта, экран сохранения ключа и Change Account с входом по сохранённому ключу без переключения библиотеки на sync.

Device-approved sign-in проверен серверными DB-тестами (включая чужого получателя, неверный poll token, повтор claim, expiry, rate limits и отсутствие plaintext poll token в БД) и клиентскими unit-тестами. Полный QR-flow между двумя живыми UI не выполнялся.

## Нагрузка и отказы

`http-load.py` в каталоге артефактов создаёт отдельный аккаунт/space и 10 000 записей с opaque blob по 8192 байта (около 78 MiB). Это нагрузка сервера, а не тест дешифрования этих blobs приложениями.

- 32 worker, batch по 50; вставка с повторами заняла 9,602 с.
- Полный snapshot: ровно 10 000 записей, 200 страниц, совпадение blobs, отсутствие повторов ID.
- 20 CAS-гонок по 32 претендента: ровно 20 принятых изменений и 620 conflicts.
- Stale dataset scope: HTTP 409; 51 элемент в batch: HTTP 400.
- Delta содержит ровно 20 победивших изменений. 20 удалений возвращаются как tombstones.
- Отозванный access token: HTTP 401.
- В этом прогоне: 332 ответа 429, 14 ответов 503, один разрыв соединения без HTTP-ответа. Backoff и повторная проверка результата записи позволили завершить прогон без потери данных.
- p50 HTTP-попытки ~10 ms, p95 ~74 ms, max ~190 ms. Это локальный тест, не прогноз production throughput; времена не включают ожидание backoff.

Первый fail-fast прогон остановился на перегрузке/разрыве соединения; сохранён отдельно как `http-load-first.log`. Ошибки не скрыты из статистики повторного прогона. Отдельной проверки retry/backoff каждого клиентского UI под этим профилем нагрузки нет.

## Особенности сборки

Swift 6.3.3 падал при чтении SwiftPM manifest со свежим macOS SDK 27 (`unknown argument: -target-arch-variant`, signal 11). С `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` Android bootstrap, Swift core tests и оба Android ABI собрались. Потребовались Swift 6.3.3 Android SDK, NDK r27d и JDK 25 для bootstrap SwiftKit; приложение собрано с JBR Android Studio.

Apple sync harness использует entitlements-free app-host tests. Для настоящего Apple auth UI была выполнена отдельная `xcodebuild build-for-testing` с simulator signing и минимальными тестовыми Keychain entitlements. Первоначальная попытка использовать вручную подписанную копию не запустилась и не считается продуктовым дефектом; корректно собранные артефакты прошли на обеих платформах.

## Основные артефакты и воспроизведение

Каталог: `/tmp/snippets-account-key-audit`.

- `tested-source.json`, `native-result.json`, `http-load-result.json`, `restart-result.json` — итоговые machine-readable результаты.
- `server-fast.log`, `database.log`, `server-repeat.log`, `server-auth-db-repeat.log` — серверные проверки.
- `linux-tests.log`, `linux-live.log`, `audit_live.rs` — Linux результаты и дополнительный test-only модуль, добавленный только в гостевую копию.
- `android-build.log`, `android-core-2.log`, `android-auth-ui.log` — Android.
- `*-summary.json`, `*.xcresult` — Apple; последний успешный auth UI имеет суффикс `auth-ui-2`.
- `http-load.py`, `restart-check.py` — одноразовые тестовые драйверы, жёстко привязанные к loopback тестового стенда. Restart driver перезапускает только два контейнера `snippets-account-key-audit-*`.

Базовые команды репозитория:

```sh
swift test --package-path CorePackage
./server/Scripts/test-integration.sh
cargo test --locked --manifest-path snippets-linux/Cargo.toml
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swiftly run swift test +6.3.3 --package-path AndroidCorePackage
```

Для повторного мобильного live-прогона использовать `scripts/test-native-cloud-integration.md` и новый одноразовый тестовый backend/origin. Не переносить токены этого запуска в пользовательские установки.

## Оставшиеся ограничения

Нужны разблокированный Mac для проверки фокуса Mac UI и визуального Linux smoke; физические iPhone/iPad/Android для проверки реального Keychain/Keystore, фонового режима и lifecycle; живое подтверждение устройства между разными платформами; более длительный soak, перебои сети/питания, заполнение диска и нагрузка каждой GUI-библиотеки большим числом записей. Это не утверждение, что в этих областях есть дефект: они не покрыты данным запуском полностью.

После проверки backend и PostgreSQL оставлены локально; временный публичный HTTPS tunnel и gateway остановлены. Старый tunnel-origin в тестовых бинарниках больше не доступен; для следующего live-прогона потребуется новый origin и сборка с ним.


## Автономное продолжение после 18:08 MSK

Выполнено без пользовательских действий. Новый приватный каталог артефактов: `/tmp/snippets-account-key-extended`. Новый отдельный backend — Compose project `snippets-account-key-extended`, HTTP `127.0.0.1:8088`, PostgreSQL `127.0.0.1:55438`. Мобильные APK и Apple app-host artifacts пересобраны с новым HTTPS origin.

### Пять платформ в одном цикле

Расширенный harness завершил **32/32 этапа** (`fiveplatform-result.json`). Linux больше не только читатель: четыре раза он расшифровывает библиотеку, добавляет собственные теги, повышает HLC и записывает заново зашифрованные envelopes с CAS. После каждой такой записи Mac, Android, iPhone и iPad проверяют библиотеку через свои настоящие store/coordinator/client stacks. Linux в финале проверяет tombstone и сохранность своих тегов. Проверены lost ACK, обрезанный ответ, stale cursor и отзыв токенов.

Linux использует реальные Rust crypto/HTTP API в Arch VM; это не утверждение, что все операции выполнялись через мышь в Linux UI. Платформенные UI-проверки выполнены отдельно.

### Подтверждение нового устройства: межъязыковая криптография

Прошли **Mac → Linux, iPhone → Linux, iPad → Linux и Android → Linux**. Для каждого перехода:

- Linux создаёт настоящий unauthenticated device request; приватный P-256 ключ и poll token остаются в гостевой тестовой копии.
- До одобрения claim возвращает pending; неверный poll token отклоняется.
- Apple/Android production bootstrap client создаёт pairing, проверяет confirmation code, подписывает library-authority challenge, шифрует ключ для Linux-получателя и дважды отправляет одинаковое approval для проверки идемпотентности.
- Linux получает keyless account session, проверяет аккаунт и пространство, скачивает ciphertext, расшифровывает ключ и сверяет Ed25519 authority с сервером.
- Повтор claim моделирует потерянный ответ: прежние access/refresh перестают работать, новая сессия работает; после revoke доступ запрещён.

Это live protocol E2E с настоящими клиентскими реализациями на каждом runtime. Сканирование QR камерой и биометрическое подтверждение пользователя в этот сценарий не входят.

Добавлены opt-in методы, которые по умолчанию пропускаются:

- `snippets-cross-platform-tests/SnippetsCloudAppIntegrationTests.swift`: `testLiveDeviceApprovalForLinuxRecipient`, флаг `SNIPPETS_DEVICE_APPROVAL_E2E=disposable-backend`.
- `app/src/androidTest/java/com/khm/snippets/android/NativeDeviceApprovalEndToEndTest.kt`: `approvesLinuxRecipientWithLibraryAuthority`, флаг `snippetsDeviceApprovalE2E=disposable-emulator`; дополнительно проверяются эмулятор и URL, встроенный в APK.

Драйверы и Linux test-only модули сохранены в каталоге артефактов: `device-approval.py`, `android-device-approval.py`, `audit_device_pairing.rs`, `fiveplatform.py`, `audit_fiveplatform.rs`. Они привязаны к этому локальному стенду и отдельной гостевой копии. Результаты: `device-approval-result.json`, `android-pairing-result.json`.

### Дополнительное покрытие UI и хранения

| Проверка | Результат |
|---|---|
| iPhone полный обычный UI smoke | 7 passed, 6 ожидаемых skips, 0 failures |
| iPad полный обычный UI smoke | 6 passed, 7 ожидаемых skips, 0 failures |
| Linux дополнительные ignored-тесты в приватном Xvfb/D-Bus | 30 passed, 1 нестабильный timing-тест |
| Linux Secret Service / настоящий приватный gnome-keyring | Passed |
| Linux picker на настоящем Wayland backend в отдельном headless Weston | Passed |
| Swift Core/Pasteboard/AX через отдельный временный overlay | 935 + 81 + 22 Swift Testing и 28 XCTest passed |

Linux GUI-проверки включают account-key screens, acknowledgement, device-sign-in polling/handoff, отмену, очистку credential fields, восстановление черновика после прерванного запуска, backup/vault dialogs, настройки, историю и диагностику. Это GTK-окна на виртуальном дисплее; пользовательский Xfce-сеанс не использовался. Secret Service проверен только через штатный `tests/secret-service.sh` с отдельным bus/keyring.

Core overlay исключал только сломанные `SnippetsSecureEditor`/`SnippetsSecureEditorTests`, сохраняя те же исходники остальных targets. **Это не исправляет и не делает зелёной штатную команду CorePackage.** Overlay был удалён после прогона.

Для UI smoke использованы корректно подписанные simulator artifacts. Первая попытка с unsigned app-host artifacts не запускала приложение через XCUIApplication и прервана как ошибка подготовки стенда, а не продукта. В итоговые UI-счётчики включён только завершённый signed-прогон.

### Новая находка: нестабильная нижняя граница Wayland timeout-теста

`private_input_protocol_checks_unicode_sealed_maps_key_pairs_and_cancellation` один раз упал в наборе дополнительных тестов, затем прошёл три повтора. В отдельном диагностическом прогоне 20 повторов было 2 падения. Измеренный диапазон ожидания: **1 999 727–2 009 987 μs**.

`src/input_wayland.c:32` округляет CLOCK_BOOTTIME вниз до миллисекунд, затем добавляет 2000 ms. Тест `src/secure_insertion_wayland_tests.rs:241` требует не меньше ровно 2 секунд по высокоточному `Instant`. Минимальное наблюдённое ожидание короче на 273 μs, что согласуется с точностью C-дедлайна. Это воспроизводимая нестабильность теста; нарушений отмены, отправки после отзыва или данных не обнаружено. Рекомендуется согласовать нижнюю границу теста с разрешением таймера, сохранив верхнюю границу и проверки отмены. Производственный timeout не менялся; диагностическая печать была только в гостевой копии и удалена после прогона.

### Что по-прежнему не объявляется проверенным

Физические устройства, Face ID/Touch ID, камера/QR UI между двумя устройствами, разблокированный macOS focus/menu UI, реальная длительная приостановка ОС и многодневный soak. Блокировка Mac не обходилась. Результаты headless GTK и simulator UI не заменяют эти аппаратные проверки.


Попытка закрыть два оставшихся Hyprland-specific сценария (`ui::tests::live_paste` и `desktop-quit`) выполнялась во вложенном compositor на отдельном Wayland display. Hyprland 0.56.2 завершился до запуска Snippets с `CBackend::create() failed`; это сбой подготовки графического стенда, не приложения. Эти два сценария не объявляются пройденными. Headless outputs предусмотрены [документацией Hyprland](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Using-hyprctl/), но наличие подходящего backend в этой VM отдельно не подтверждено. Установлены только тестовые зависимости; основной Xfce не заменён.

После автономного прогона временные публичный tunnel/gateway и одноразовый Android emulator остановлены, принадлежащие прогону iOS-симуляторы удалены. Оба локальных backend (`8087` — первый аудит, `8088` — расширенный) и их отдельные PostgreSQL оставлены запущенными. В пользовательской библиотеке и Production CloudKit изменений нет. Коммиты и публикация не выполнялись.

## Следующий цикл: постоянные установки, конкуренция, kill и смена аккаунта

Использованы те же исходники ветки, real Go/PostgreSQL backend, app-host Mac/iPhone/iPad tests, Android instrumentation и настоящий Linux sender/receiver с локальным журналом. Продуктовый код не менялся. Тестовые Apple/Android entry points и Linux fixture добавлены отдельно.

### Подтверждённые новые проблемы

1. **P1, потеря текста (зависит от порядка обмена).** Три клиента Mac/Android/Linux получают один серверный предок, меняют одну запись офлайн, одновременно синхронизируются. Серверные records/versions проверены неизменными до отправки. После трёх дополнительных кругов у всех одинаковые 6 записей вместо ожидаемых 5, а конкурентный текст Android отсутствует. Удалений в минимальном сценарии нет. В пятистороннем сценарии проблема также воспроизводится: стабильные 9 записей, сохранены 4 из 5 текстов. [Полная задача](issues/cloud-account-key/01-concurrent-body-loss.md).
2. **P2, лишние копии после crash/recovery.** В чистой библиотеке из 3 записей по очереди завершали каждый из пяти процессов после ответа backend с одним accepted outcome, задержав этот ответ клиенту. Сразу после восстановления каждая платформа сохраняет правку и 3 ID. После последующих правок других устройств iPhone/iPad создают копии собственных старых подтверждённых текстов. Два дополнительных круга приводят все пять клиентов к 5 записям вместо 3. [Полная задача](issues/cloud-account-key/02-post-crash-conflict-copies.md).

### Положительные проверки

- Независимые поля пяти клиентов слились: имя Mac, pin iPhone, tag iPad, enabled=false Android, content Linux.
- Старый HTTP-ответ удерживался во время смены аккаунта на всех пяти платформах. Новый аккаунт оставался пустым. Apple проверил quiescence и неизменность старого checkpoint после смены; Android — ожидание repository mutex; Linux — остановку по SessionChanged и недоступность старого space с credentials нового аккаунта. Это проверка нативных границ данных/credentials, не полный UI-проход формы входа на всех пяти устройствах.
- 110 целевых тестов общего ядра прошли (account bindings / conflict copies / conflict dependencies). Штатный CorePackage по-прежнему блокируется отдельной ошибкой SecureEditor; использован и затем удалён временный overlay.

### Повторение и передача

[Индекс задач для Opus 5.5](issues/cloud-account-key/README.md) включает новые дефекты, все предыдущие подтверждённые проблемы и отдельный перечень ограничений среды. Агрегаты без токенов скопированы в `docs/issues/cloud-account-key/evidence/`. Полные приватные артефакты: `/tmp/snippets-account-key-chaos/`.

`scripts/test-stateful-cloud-integration.py` сохраняет минимальный трёхсторонний сценарий в репозитории. Требует disposable backend, origin-pinned сборки, отдельный Android emulator и разрешённый тестовый Arch checkout; намеренно возвращает ошибку при потере версии. Старые quick-tunnel адреса после завершения работы не действуют.

Невалидные ранние попытки (ошибки helper imports, clone simulator lookup, нестрогий offline, поиск PID, нехватка места в старой копии AVD) исключены из доказательств. Подробности — [ограничения стенда](issues/cloud-account-key/06-test-environment.md). Пользователь попросил передать исправления Opus 5.5; исправления продуктовой логики здесь не выполнялись.

Контрольный запуск сохранённого трёхстороннего скрипта прошёл (5 записей, все 3 текста): это подтверждает зависимость дефекта от расписания. В handoff сохранены и падающие, и успешный результаты; единичный зелёный прогон не считается достаточной проверкой исправления.
