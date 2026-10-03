# P2: обязательная проверка CorePackage не компилируется

**Подтверждено.**

```sh
swift test --package-path CorePackage
```

Ошибка: `EditorInputSurface` не найден в области видимости `snippets/SecureSnippetCaptureRenderer.swift:508`. Тип объявлен в `snippets/LiquidGlassDesign.swift:672`, но отсутствует в тестовом overlay `SnippetsSecureEditor`.

Mac/iOS app targets собираются. Временный тестовый overlay, исключающий только `SnippetsSecureEditor` и его tests, позволил выполнить другие suites, но это **не исправление** штатной команды и не зелёный обязательный check.

Логи: `/tmp/snippets-account-key-audit/core.log`, `/tmp/snippets-account-key-extended/core-overlay.log`; новый целевой запуск `/tmp/snippets-account-key-chaos/core-boundary.log` — 110 passed.

Исправить границу зависимости renderer/design так, чтобы тестовый target компилировал реальный код. Не добавлять заглушку вместо проверяемого поведения и не переносить AppKit в Foundation-only SnippetsCore. Затем выполнить штатный CorePackage и обе платформенные сборки из AGENTS.md.
