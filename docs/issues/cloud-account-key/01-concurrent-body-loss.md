# P1: конкурентная версия Android исчезает после успешной сходимости

**Статус: подтверждённый дефект сохранности данных, зависит от порядка обмена.** Точный виновный компонент ещё не установлен. Формулировка «версия Android» обозначает автора потерянного текста, а не доказанную виновность Android-клиента.

## Ожидаемое поведение

При независимом редактировании одной исходной записи на нескольких устройствах каждый конкурентный текст должен сохраниться как основная запись или отключённая конфликтная копия. Одинаковое состояние всех клиентов само по себе недостаточно: в нём не должны исчезать пользовательские версии.

## Минимальный воспроизводящий сценарий

1. Создать отдельный native account-key аккаунт и space на реальном Go/PostgreSQL backend.
2. Mac создаёт три обычные записи: `race`, `fields`, `delete-edit`.
3. Mac, Android и Linux получают одну исходную версию. Каждый сохраняет собственный текст `race` офлайн. В этом сценарии удалений нет.
4. Проверить по `/changes`, что весь набор серверных записей и версий не изменился во время подготовки офлайн-правок. Эта проверка прошла.
5. Одновременно отправить накопленные изменения через настоящий `SnippetStore`/`SyncCoordinator`, Android `SnippetRepository` и Linux `receiver::Owner::synchronize` с его локальным журналом.
6. Выполнить ещё три круга обмена каждым из трёх клиентов.

Ожидание: 5 записей — три исходных + две конфликтные копии; все три версии `race` присутствуют.

Факт: все три клиента показывают одинаковые **6 записей**, но остаются только тексты Mac и Linux. Текст Android отсутствует. Это воспроизводится также в более широком сценарии с пятью платформами: после четырёх кругов все имеют одинаковые 9 записей, а из пяти конкурентных текстов осталось четыре — без Android.

Отдельное слияние независимых полей в пятистороннем сценарии прошло: имя Mac, флаг закрепления iPhone, тег iPad, выключенный флаг Android и содержимое Linux сохранились вместе. Потеря текста не объясняется общим отказом синхронизации.

## Доказательства

- `evidence/three-client-result.json`: общий предок проверен, итоговые counts `[6,6,6]`, `equal=true`, сохранены только `macos` и `linux`.
- `evidence/five-client-result.json`: сервер неизменен до отправки, итог `[9,9,9,9,9]`, сходимость стабильна, отсутствует версия Android.
- `/tmp/snippets-account-key-chaos/minimal-three/`: логи и снимки каждого этапа `901`–`916`.
- `/tmp/snippets-account-key-chaos/controlled/605-android-prepare-snapshot.json` и `608-android-replay-snapshot.json` ещё содержат синтетический Android-текст; `610-iphone-replay-snapshot.json` уже не содержит его. Финальные снимки всех пяти платформ также его не содержат.
- Более ранние попытки из корня `/tmp/snippets-account-key-chaos/` не использовать как основное доказательство: там были исправления оркестратора. Подтверждённые прогоны — `controlled/` и `minimal-three/`.

## Исполняемый регрессионный сценарий

В репозитории добавлены:

- `scripts/test-stateful-cloud-integration.py` — трёхсторонний запуск с проверкой общего предка и наличия всех текстов;
- `scripts/test-fixtures/stateful_fault_audit.rs` — временный opt-in Linux fixture;
- `SnippetsCloudAppIntegrationTests.testStatefulFaultAudit`;
- `StatefulFaultAuditTest.persistedOfflineAndCrashRecovery`.

Нужны заранее собранные тестовые Mac/Android артефакты с одним актуальным HTTPS origin, запущенный disposable backend и отдельный пустой Android emulator. Скрипт **очищает только явно выбранную тестовую Android-инсталляцию** и временно добавляет тестовый модуль в явно разрешённый тестовый checkout Arch.

```sh
python3 scripts/test-stateful-cloud-integration.py   --origin-file /path/to/disposable-origin   --macos-derived /path/to/macos-derived   --android-serial emulator-5580   --android-apk app/build/outputs/apk/debug/app-debug.apk   --android-test-apk app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk   --linux-vm ArchLinux   --linux-checkout /root/src/snippets-account-key   --allow-disposable-android-reset   --allow-disposable-linux-checkout
```

Origin должен совпадать с origin в обеих сборках. Временный quick tunnel из аудита после работы закрывается, поэтому его старый адрес использовать нельзя.

## Успешный контрольный повтор

Первый запуск сохранённого в репозитории скрипта завершился успешно: 5 записей у всех трёх клиентов, все три текста сохранены. Это не отменяет два падающих сценария выше. Гонка не воспроизводится при каждом расписании. Агрегат контрольного повтора: `evidence/three-client-control-passed.json`. Последовательная публикация подготовленных офлайн-правок в порядке Android → Linux → Mac также прошла: `evidence/three-client-ordered-control-passed.json`. Это дополнительное свидетельство зависимости от конкурирующих HTTP/CAS операций, но ещё не доказанный root cause.

Скрипт поддерживает `--send-order concurrent` (по умолчанию), а также все перестановки `macos,android,linux`. Перед публикацией правки всех трёх клиентов всё равно готовятся от одного проверенного предка. Для проверки исправления нужны разные порядки и повторения, а не один зелёный запуск.

## Где исследовать

Это гипотезы для отладки, а не установленный root cause:

- `AndroidCorePackage/Sources/SnippetsAndroidCore/AndroidBridge.swift:240,309,341`: преобразование wire envelopes в plain snippets, `SyncMerge.mergeLocal`, повторное создание `SyncEnvelope.plain`. Проверить сохранение provenance/версий при конкуренции.
- `app/src/main/java/com/khm/snippets/android/SnippetRepository.kt`: `syncWithAccessToken`, CAS retry, confirmed base и pending offers.
- `snippets/Core/SyncMerge.swift`: сопоставить mergeLocal с envelope merge, fingerprint и детерминированный ID копии.
- `snippets-linux/src/merge.rs`, `sender.rs`, `receiver.rs`: проверить, какой клиент первым заменяет/удаляет носитель Android-версии.

## Критерии исправления

Сценарий проходит многократно при разных порядках отправки. Все три/пять текстов сохраняются; копии отключены; повторные обмены не создают новые копии; независимые поля не регрессируют. Нужен regression test на реальных границах wire/plain/journal, а не только повтор unit-тестов merge одного языка.
