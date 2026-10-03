# P2: Keychain читается на MainActor при включённом Snippets Cloud

**Подтверждено тестом и трассировкой исходников; не новая регрессия последних account-key коммитов.**

`SyncLifecycleTests.testIOSLaunchDoesNotBlockOnUnrelatedCloudCredentialMarkers` падает на iPhone и iPad. Повторный целевой прогон iPhone воспроизводит падение. В `snippets-ios-tests/SyncLifecycleTests.swift:1732` фиксируется `gate.calledOnMainThread == true`.

Путь: `SyncBackendSelectionStore.swift:499–506` запускает `Task @MainActor`, после фонового чтения маркера вызывает `resumeCredentialLineageIfNeeded()`. При включённой cloud-функции строки 522–525 синхронно вызывают `inspectCredentialLineage()`. Реализация около строки 2467 читает session/replacement/revocation items из Keychain.

Ожидание: медленный Keychain IPC не блокирует показ локальной библиотеки и главный поток. Факт: чтение попадает на главный поток; фактическая длительность зависания физического устройства не измерялась.

Логи: `/tmp/snippets-account-key-audit/`, полный отчёт `docs/cloud-account-key-integration-audit-2026-10-03.md`. iPad full suite: 542 passed / 1 failed. iPhone stdout: тот же результат, но финализация полного xcresult была прервана после зависания Xcode; целевой повтор подтверждён отдельно.

Для исправления сохранить сериализацию credential mutations, fail-closed handling и порядок journal/revocation. Перенести потенциально блокирующее чтение за границу MainActor; не подменять исправление отменой теста. Проверить startup с cloud enabled/disabled, незавершёнными replacement/revocation markers, sign-out во время preflight.
