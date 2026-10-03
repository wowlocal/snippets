# P3: нестабильная нижняя граница двухсекундного тайм-аута

**Подтверждён flaky test, не доказанная ошибка безопасности/данных.**

Тест `private_input_protocol_checks_unicode_sealed_maps_key_pairs_and_cancellation`, `snippets-linux/src/secure_insertion_wayland_tests.rs:241–242`, требует `Instant::elapsed() >= Duration::from_secs(2)`.

Нативный код `snippets-linux/src/input_wayland.c:32` считает CLOCK_BOOTTIME в миллисекундах с усечением наносекунд, затем прибавляет 2000 мс. Из-за разного разрешения ожидание может окончиться менее чем на 1 мс раньше строгой границы высокоточного Rust Instant.

Первый запуск упал; три обычных повтора прошли; из 20 инструментированных повторов упали 2. Диапазон измерений: 1 999 727–2 009 987 мкс. Временная инструментализация удалена.

Артефакты: `/tmp/snippets-account-key-extended/linux-timing.log`, `linux-recheck.log`, `linux-input-failure.log`.

Согласовать проверку нижней границы с разрешением часов либо корректно округлять нативный deadline. Сохранить верхнюю границу и проверку cancellation, не превращать тест в безусловно проходящий sleep.
