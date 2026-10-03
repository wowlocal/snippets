# Ограничения среды и исправленные проблемы оркестратора

Эти пункты не являются подтверждёнными дефектами продукта.

## Mac focus/UI

Mac был заблокирован, автоматическая разблокировка Computer Use не сработала. Повторно падают `ClipboardHistoryMenuTrackingTests.testEscapeClosesNativeActionsMenuBeforeDismissingPicker` и `FloatingPanelAppearanceTests.testPickerSurfaceFollowsInheritedThemeWithoutDependingOnKeyboardFocus`. Вероятна зависимость от lock/focus; требуется повтор на разблокированном Mac. Причинная связь ещё не доказана.

## Hyprland

Два compositor-specific теста (`ui::tests::live_paste`, `desktop-quit`) не выполнены: вложенный Hyprland 0.56.2 в Arch/UTM завершается с `CBackend::create() failed` до запуска Snippets. Xfce остаётся рабочим; отдельный headless Weston picker и дополнительные Xvfb GTK-тесты выполнены. Логи: `/tmp/snippets-account-key-extended/linux-hyprland-*.log`.

## Android disk

Повторная установка большой debug APK в read-only копии Pixel AVD закончилась `INSTALL_FAILED_INSUFFICIENT_STORAGE`: /data 5.8 GiB, свободно около 630 MiB. Создан отдельный временный AVD с диском 12 GiB; исходный AVD не очищался. После переноса тесты продолжились.

## Не засчитанные попытки stateful runner

- Проверка начального provider `iCloud` была неприменима к повторному запуску постоянной установки; удалена только из нового stateful теста.
- Симуляторы нужно явно boot перед XCTest, иначе тест мог использовать отдельный clone, а get_app_container исходного устройства возвращал Shutdown.
- Исправлены ошибочный запуск тела helper-модуля при импорте и восстановление координат исходного fixture. Ранние результаты исключены.
- `SyncCoordinator.stop()` не гарантирует длительный offline: shutdown completion может снова запустить транспорт. Новый тест выключает runtime и отсоединяет syncDelegate, а оркестратор сравнивает серверные records/versions после каждой подготовки.
- Исправлено определение собственного Mac-процесса: фактический bundle `Snippets Debug.app`, путь может начинаться с `/private/tmp`.
- Linux SIGKILL завершает также wrapper service, поэтому он не может сам записать exit status. Завершение процесса было выполнено, а ожидание и recovery продолжены отдельной стадией. Не считать timeout оркестратора отказом recovery продукта.
- Ручные access-token fixtures истекают; один поздний check с `authentication_required` повторён после native refresh. В продуктовых auth-проверках используется реальный механизм refresh.

Кандидатные находки из ранних прогонов не включены в продуктовые задачи без повторения в исправленном изолированном сценарии.

## Не покрыто этим стендом

Физические iPhone/iPad/Android, реальные фоновые ограничения ОС и аппаратная биометрия; длительный многочасовой soak; массовая библиотека именно в GUI всех пяти платформ; аварийное заполнение пользовательского диска; повреждённый checkpoint/ciphertext на каждой платформе. Не считать эти области прошедшими.
