# Передача результатов второго раунда в Opus 5.5

Дата: 2026-10-03–04 (Europe/Moscow). Ветка: `work/cloud-account-key`.
Проверенный HEAD: `4acbecfce5048cf5d5412547525dd8ffd41062ab`.
Рабочая копия: `/Users/mike/src/tries/2026-02-15-snippets/snippets-cloud-account-key`.

## Итог для принимающего агента

Новых подтверждённых продуктовых дефектов не найдено. Исправленные потеря конкурентной версии Android и лишние копии после crash/recovery не воспроизвелись в повторных сценариях. Найдена ошибка ожидания приватного пятистороннего теста после явного Linux Keep; исправлять нужно тестовый сценарий, а не продуктовый merge.

Продуктовый код не менялся. Отчёты и JSON находятся в этой рабочей копии; они **не закоммичены и не запушены**. Не считать их доступными в другом checkout только потому, что ветка называется одинаково.

## Находки и действия

| Статус | Находка | Что делать |
|---|---|---|
| P3 / тест, ожидание исправлено | [07 — неверное ожидание после Linux Keep](07-e2e-keep-oracle.md) | Разделить чистый пятисторонний конфликт и явное восстановление. Keep создаёт новую правку; сохранение текста iPhone в отключённой копии не является потерей данных. |
| Исправление подтверждено сценариями | [01 — потеря версии Android](01-concurrent-body-loss.md) | 10 concurrent + 6 порядков отправки прошли; чистый пятисторонний прогон тоже прошёл. Сохранить эти регрессии. |
| Исправление подтверждено сценариями | [02 — crash/recovery и reseal](02-post-crash-conflict-copies.md) | Обе пятисторонние цепочки прошли. Сохранить независимую проверку целевого текста на сервере: одного `accepted >= 1` недостаточно. |
| Ограничение остаётся | [03 — Keychain / MainActor](03-ios-main-thread-keychain.md) | Стартовая lineage-проверка исправлена; чтения активного cloud-provider и холодный старт физического устройства в этом раунде не измерялись. |
| Исправление подтверждено | [04 — CorePackage](04-corepackage-build.md) | Обычная команда `swift test --package-path CorePackage` проходит. |
| Известная нестабильность, не закрыта | [05 — Linux timeout](05-linux-timeout-test.md) | Явные повторы с `--ignored`: 20/20 PASS. Это не доказывает устранение прежней flaky-границы; продуктовый код для неё не менялся. |

## Карта передаваемых артефактов

[Полный отчёт](../../cloud-account-key-integration-round2-2026-10-03.md) содержит состав стенда, проверки, ограничения и состояние после уборки.

Следующие JSON — санитизированные агрегаты, сохранённые рядом с MD:

| Артефакт | Содержание |
|---|---|
| [matrix.json](evidence/round2/matrix.json) | 16/16 PASS: 10 concurrent + все 6 send orders; по 5 одинаковых записей, все 3 текста сохранены. |
| [five-clean.json](evidence/round2/five-clean.json) | Пять клиентов: по 7 записей, 5 версий текста, 4 отключённые копии, независимые поля сохранены. |
| [five.json](evidence/round2/five.json) | Оригинальный failed-результат ошибочного ожидания после Keep. Не удалять и не подменять успешным результатом. |
| [five-keep-classification.json](evidence/round2/five-keep-classification.json) | Отдельная классификация того же результата: 8 одинаковых записей, все тексты сохранены; Keep — новая локальная правка. |
| [crash.json](evidence/round2/crash.json) | Kill после принятого целевого изменения на каждой платформе; после 3 циклов обмена по 3 одинаковые записи. |
| [crash-first-batch.json](evidence/round2/crash-first-batch.json) | Kill после первого принятого пакета. На iPhone/iPad он ещё не содержал правку; после одного восстановления она уже есть на сервере. Финально по 3 записи. |
| [paging.json](evidence/round2/paging.json) | 128 записей / 3 страницы, затем 125 версий одной записи; финальная сходимость всех пяти клиентов. |
| [clock-skew.json](evidence/round2/clock-skew.json) | Один прогон противоположного ранжирования HLC / updatedAt; все 4 версии сохранены, 6 записей. Не исключает документированное расхождение выбора победителя. |
| [legacy-journals.json](evidence/round2/legacy-journals.json) | 10 копий прежних Linux-журналов, одна с pending outbound packet: чтение, пересохранение, повторное открытие без изменения модели intent. Только офлайн. |
| [native-cloud.json](evidence/round2/native-cloud.json) | 15/15 фаз: account-key auth, refresh/logout, CAS, lost ACK, truncated page, stale cursor, удаление. |
| [auth-ui.json](evidence/round2/auth-ui.json) | Нативные экраны входа iPhone/iPad/Android: все прошли, без skipped. |
| [baseline-checks.json](evidence/round2/baseline-checks.json) | Сборки и тестовые наборы CorePackage, iPhone/iPad, Android, Linux, backend. |
| [linux-timeout-repeat.json](evidence/round2/linux-timeout-repeat.json) | 20 реально выполненных повторов, 0 skipped; прежняя flaky-проблема не объявлена исправленной. |
| [cleanup.json](evidence/round2/cleanup.json) | Отзыв сессий, удаление одноразовых устройств, остановка tunnel и gateway. |

## Приватные первичные материалы

Логи, xcresult, snapshots синтетических библиотек и приватные оркестраторы находятся в `/tmp/snippets-round2/`. Основные каталоги: `five/`, `five-clean/`, `crash/`, `crash-reseal/`, `paging/`. Путь к каждому первичному трёхстороннему прогону сохранён в `/tmp/snippets-round2/matrix-results.json`; путь native-cloud прогона — в `native-progress.log`.

Каталог `/tmp` может быть очищен системой. Долговременная передача выводов обеспечена MD и агрегатами выше. Не передавать весь приватный каталог автоматически: логи/xcresult могут содержать конфигурацию запуска, а `server.env` — секреты одноразового backend. Перед передачей конкретного первичного файла проверить его содержимое и удалить credentials. Старые origin, tokens и simulator IDs для повторного запуска не использовать.

Репозиторный воспроизводитель трёхстороннего сценария: `scripts/test-stateful-cloud-integration.py`; общая native-cloud процедура: `scripts/test-native-cloud-integration.md`. Приватные уточняющие сценарии: `/tmp/snippets-round2/five-clean.py`, `crash.py`, `crash-reseal.py`, `paging.py`, `gateway.py`. Они привязаны к одноразовому стенду, а не являются готовой переносимой CI-командой.

## Что не подтверждено этим раундом

- Смена аккаунта при задержанном сетевом ответе повторно на текущем HEAD не запускалась; результаты предыдущего раунда не считать новой проверкой.
- Новые перекрёстные approvals с kill между approve/bind/commit и реальным ожиданием 10-минутного expiry не выполнялись.
- Сетевой replay старых Linux-журналов не выполнялся; подтверждена только совместимость сохранённого состояния.
- Физические устройства, Production CloudKit, биометрия и измерение MainActor при холодном старте активного cloud-provider не проверены.
- Hyprland в Arch VM падает с `CBackend::create() failed` до запуска Snippets. Нативный sync проверен, Omarchy/PAM и compositor-specific UI — нет.

## Состояние стенда

Все session families нового backend отозваны; в БД 0 активных. Пять сохранённых access tokens дополнительно проверены через API и получили 401. Два одноразовых Apple simulators и Android AVD удалены; исходный Pixel AVD сохранён. Публичный tunnel и gateway остановлены, временные credential fixtures удалены.

Arch/Xfce и локальный backend `snippets-round2` на 8089 / PostgreSQL 55439 оставлены запущенными. Старые backend на 8087/8088 не изменялись. Временные audit-модули удалены из Linux checkout; его `lib.rs` восстановлен из проверенного исходника.
