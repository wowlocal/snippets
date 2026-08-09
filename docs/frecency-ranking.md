# Спецификация: Frecency-ранжирование панели подсказок

**Проект:** `/Users/mike/src/tries/2026-02-15-snippets/snippets`
**Статус:** финальная спецификация к реализации. Все ссылки `file:line` перепроверены по исходникам после ревью.

---

## Решения там, где судьи разошлись

Единогласного победителя нет (три линзы — три победителя), поэтому решения зафиксированы явно:

1. **Хребет — фиксированная эпоха (D1) + защита данных (D3).** Две линзы из трёх сходятся на этой паре, а сами дизайны совпадают примерно на 80%.
2. **Selection memory (липкая привязка префикса, идея D2) — включена, но на 4-м тире: ниже `score`, `keywordRank` и `isPinned`.** Это единственное размещение, которое допускают две линзы из трёх, и оно всё равно даёт рефлекс Raycast, потому что `FuzzyMatch` даёт *точные* ничьи именно в случае префиксной коллизии (доказано арифметикой в §3.3).
3. **Pin остаётся абсолютным на всех поверхностях.** `promotionTier` выше `isPinned` (D2) отклонён: «закреплено» не может значить разное до и после первого набранного символа.
4. **Per-app tier, burst-член и bucket-дискретизация выброшены** — максимум констант и приватностной цены при минимальной объяснимости; снимок сессии и так делает непрерывное значение безопасным.
5. **Вес копирования = 0.25 (D3), не 0.5 (D1)** — потому что одно копирование должно быть арифметически *ниже* порога значимости 0.5.
6. **Основной список и оверлей ⌘F в v1 не трогаем** — это буквально один массив `visibleSnippets`, их расхождение хуже, чем текущий порядок.
7. **Бейджа «часто используется» нет** — он рекламировал бы ранжирование, которого в основном списке нет.
8. **Вес привязки насыщается на `bindingWeightCap = 1.0`** — это превращает обещание «выход из ошибочной привязки за одну коррекцию» из лозунга в теорему (§3.4). Без насыщения выход занимал бы `⌊ln N / ln(1/0.7)⌋ + 1` коррекций.

---

## 1. Суть

Пользователь нажимает `\` в любом приложении — и первой строкой панели стоит сниппет, которым он реально пользуется, а не тот, который был создан последним. Tab сразу вставляет нужное. Когда пользователь начинает печатать, порядок по-прежнему решает качество совпадения: точно набранное ключевое слово всегда выигрывает, закреплённые сниппеты всегда выше незакреплённых, а частота использования разрешает только те ничьи, которые сегодня разрешаются случайным порядком создания. При включённой памяти выбора (PR 3) повторный выбор того же сниппета для тех же набранных символов делает эту тройку клавиш стабильным рефлексом. Ничего нового на экране не появляется: изменяется только порядок строк; управление — два чекбокса в настройках, кнопка полного сброса и пункт «Reset Usage» в контекстном меню строки.

---

## 2. Модель данных

### 2.1 Почему НЕ внутри `snippets.json` и не на `Snippet`

Проверено по исходникам — четыре независимых механизма, каждый из которых дисквалифицирует поле на модели:

* `Snippet.encode(to:)` (`snippets/Core/Snippet.swift:134-145`) пишет ровно 9 ключей, `init(from:)` (`:120-132`) игнорирует неизвестные. Отдельно установленный старый `snippets-cli` делает read → mutate → write (`snippets-cli/main.swift:15-43`) и **молча обнулит новое поле у всех сниппетов** при первой же команде. Ни ошибки, ни лога.
* `SnippetStore.update(_:)` (`snippets/SnippetStore.swift:102-129`) считает `didChange` ровно по шести полям (`:111-116`) — новое поле туда не попадёт и не сохранится через единственный debounced-путь.
* `undoStack`/`redoStack` хранят полные снимки `[Snippet]` (`SnippetStore.swift:582-608`), а `Snippet: Equatable` (`Snippet.swift:3`). Счётчик на модели откатывался бы по ⌘Z и создавал бы фиктивные undo-записи в `commitEditTransaction` (`SnippetStore.swift:574-580`).
* `exportSnippets(to:)` (`SnippetStore.swift:335-344`) кодирует все поля без фильтра — статистика утекла бы в файл, который пользователь отдаёт коллеге.

Дополнительно: `upsertImportedSnippet` (`SnippetStore.swift:312-332`) при совпадении keyword сохраняет только локальные `id` и `createdAt`, т.е. любая переимпортированная share-ссылка обнуляла бы счётчики.

### 2.2 Почему НЕ `UserDefaults`

Цель `snippets-cli` собирается из трёх файлов (`Snippets.xcodeproj/project.pbxproj:206-213`) и не имеет bundle identifier — `UserDefaults.standard` там резолвится в мусорный домен, что навсегда закрывает `snippets-cli list --by-frecency`. Плюс debug (`com.khm.snippets.debug`) и release (`com.khm.snippets`, `project.pbxproj:372, 409`) получили бы разные домены, деля один `snippets.json`. В `UserDefaults` живут **только переключатели**, не данные.

### 2.3 Где лежит файл

```
~/Library/Application Support/SnippetsClone/Usage/usage.json
```

**Подкаталог — несущая конструкция, а не косметика.** `SnippetStore.startObservingExternalChanges()` (`SnippetStore.swift:636-663`) открывает **папку** `saveFolderURL` через `open(path, O_EVTONLY)` (`:646`) и вешает `DispatchSource` с маской `[.write, .rename, .delete]`. `Data.write(options: .atomic)` создаёт временный файл в каталоге назначения и делает `rename` внутри него. Файл-сосед `SnippetsClone/usage.json` дёргал бы `scheduleExternalReload` (`:665`) на **каждом** раскрытии, а `reloadFromDiskIfNeeded` (`:684-712`) при непустом `persistWorkItem` вызывает `flushPendingWrites()` (`:692-695`) — то есть схлопывал бы 0.3 с debounce редактора (`persistDelay`, `SnippetStore.swift:24`) и переписывал бы всю библиотеку, пока пользователь печатает. Запись в `Usage/` меняет vnode `Usage`, а не `SnippetsClone`.

**Единственное событие родительской папки за всё время — однократный `createDirectory` при первом запуске, и он снят с горячего пути специально.** Если бы `Usage/` создавался лениво в `mergeAndWrite`, он бы мутировал vnode `SnippetsClone` в произвольный момент — ровно тот сбой, который эта секция запрещает. Поэтому:

* каталог создаётся в `SnippetUsageStore.init()`;
* в `AppDelegate` `usageStore` объявляется **раньше** `store` (`AppDelegate.swift:43-44`), потому что хранимые свойства инициализируются в порядке объявления, а `SnippetStore.init()` (`SnippetStore.swift:71-83`) ставит `DispatchSource` на `:82`. К этому моменту `Usage/` уже существует;
* `createDirectory(withIntermediateDirectories: true)` в `SnippetUsageStore.init()` создаёт и `SnippetsClone`, и `Usage`, а повторный вызов в `SnippetStore.init()` (`:77`) на существующей папке — no-op;
* `mergeAndWrite` всё равно вызывает `createDirectory` **защитно** (пользователь мог удалить папку между запусками), но в штатной жизни это никогда не первое создание.

### 2.4 Общие константы пути — в `Snippet.swift`

Цель CLI компилирует три файла (`project.pbxproj:206-213`): `main.swift`, `Snippet.swift`, `FuzzyMatch.swift`. Значит `Snippet.swift` — подходящее место для констант пути (а `FuzzyMatch.swift`, уже двухцелевой, делает PR 4 дешевле, чем казалось: сопоставление в CLI доступно бесплатно). Литерал `snippets.json` уже продублирован в `snippets-cli/main.swift:5-10`; не повторяем эту ошибку.

```swift
// snippets/Core/Snippet.swift — дописать после SnippetStorageSync (:68-70)

enum SnippetStorageLocations {
    static var supportFolderURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnippetsClone", isDirectory: true)
    }

    static var snippetsFileURL: URL {
        supportFolderURL.appendingPathComponent("snippets.json", isDirectory: false)
    }

    /// Намеренно ПОДКАТАЛОГ: SnippetStore следит за родительской папкой
    /// через DispatchSource (SnippetStore.swift:636-663), а атомарная запись
    /// делает rename инода в каталог назначения.
    static var usageFolderURL: URL {
        supportFolderURL.appendingPathComponent("Usage", isDirectory: true)
    }

    static var usageFileURL: URL {
        usageFolderURL.appendingPathComponent("usage.json", isDirectory: false)
    }
}
```

`SnippetStore.init()` (`SnippetStore.swift:71-83`) переводится на эти константы: строки 75-79 заменяются на `let folder = SnippetStorageLocations.supportFolderURL` / `saveURL = SnippetStorageLocations.snippetsFileURL`. `snippets-cli/main.swift:5-10` — тоже (2 строки); `saveSnippets` (`main.swift:32-43`) продолжает постить `SnippetStorageSync.distributedChangeNotification` с `object: saveURL.path`, поведение не меняется.

### 2.5 Документ

Новый файл `snippets/SnippetUsageDocument.swift` — чистый, `nonisolated`, без AppKit, компилируется отдельно (как `SuggestionTriggerContext.swift:1-20`). В нём же живёт `enum SnippetUsageFile` (§6.3), чтобы весь слой формата был тестируем одним `swiftc`.

```swift
import Foundation

struct SnippetUsageRecord: Codable, Equatable {
    /// Вес в системе отсчёта `epoch`. Истинный распадный вес в момент t равен
    /// `weight * 2^(-(t - epoch)/H)` — множитель ОДИНАКОВ для всех записей,
    /// поэтому сравнение сырых значений тождественно сравнению распадных.
    var weight: Double
    /// Пожизненный счётчик, никогда не распадается. Только для UI.
    var count: Int
    /// Последнее использование, Unix-секунды. Только для UI. Не ранжируется.
    var lastUsedAt: Double

    enum CodingKeys: String, CodingKey {
        case weight = "s", count = "n", lastUsedAt = "l"
    }

    init(weight: Double = 0, count: Int = 0, lastUsedAt: Double = 0) {
        self.weight = weight; self.count = count; self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 0
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        lastUsedAt = try c.decodeIfPresent(Double.self, forKey: .lastUsedAt) ?? 0
    }
}

struct SnippetUsageDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    /// Unix-секунды. НЕ Foundation reference date: файл должен читаться
    /// человеком и будущим CLI без знания стратегии дат приложения.
    var epoch: Double
    /// Период полураспада, в котором записаны веса. Делает файл
    /// самоописывающимся и позволяет корректно сменить константу.
    var halfLifeDays: Double
    /// uuidString -> запись
    var records: [String: SnippetUsageRecord]
    /// свёрнутый префикс запроса (1...8) -> uuidString -> вес в той же эпохе
    var bindings: [String: [String: Double]]
    /// Unix-секунды последнего «Reset Usage Data». Монотонный маркер для
    /// объединения (§6.3): более поздний сброс побеждает более старый диск.
    var recordsClearedAt: Double
    /// Unix-секунды последнего снятия чекбокса selection memory.
    var bindingsClearedAt: Double

    enum CodingKeys: String, CodingKey {
        case version = "v", epoch, halfLifeDays = "h"
        case records = "w", bindings = "b"
        case recordsClearedAt = "rc", bindingsClearedAt = "bc"
    }

    /// ЯВНЫЙ декодер обязателен. Со синтезированным декодером отсутствие
    /// или переименование любого не-опционального ключа (что и сделает
    /// будущая v2) роняет декодирование целиком, документ уходит в ветку
    /// «нечитаем», isReadOnly остаётся false — и старая сборка затирает
    /// данные новой. Ровно тот случай, от которого защищает §2.7.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        epoch = try c.decodeIfPresent(Double.self, forKey: .epoch) ?? 0
        halfLifeDays = try c.decodeIfPresent(Double.self, forKey: .halfLifeDays)
            ?? SnippetFrecency.halfLifeDays
        records = try c.decodeIfPresent([String: SnippetUsageRecord].self, forKey: .records) ?? [:]
        bindings = try c.decodeIfPresent([String: [String: Double]].self, forKey: .bindings) ?? [:]
        recordsClearedAt = try c.decodeIfPresent(Double.self, forKey: .recordsClearedAt) ?? 0
        bindingsClearedAt = try c.decodeIfPresent(Double.self, forKey: .bindingsClearedAt) ?? 0
    }

    init(version: Int, epoch: Double, halfLifeDays: Double,
         records: [String: SnippetUsageRecord], bindings: [String: [String: Double]],
         recordsClearedAt: Double = 0, bindingsClearedAt: Double = 0) {
        self.version = version; self.epoch = epoch; self.halfLifeDays = halfLifeDays
        self.records = records; self.bindings = bindings
        self.recordsClearedAt = recordsClearedAt; self.bindingsClearedAt = bindingsClearedAt
    }

    static func empty(now: Double) -> SnippetUsageDocument {
        SnippetUsageDocument(version: currentVersion, epoch: now,
                             halfLifeDays: SnippetFrecency.halfLifeDays,
                             records: [:], bindings: [:])
    }
}

/// Минимальный зонд версии. Читается ПЕРВЫМ, до полного декодирования,
/// потому что полное декодирование будущего формата может провалиться,
/// а провалиться оно обязано в read-only, а не в «начнём с чистого листа».
struct SnippetUsageVersionProbe: Decodable {
    let v: Int?
}
```

### 2.6 Точный JSON

Кодировщик: `[.sortedKeys]`, **без** `.prettyPrinted` (машинные данные; идентичное состояние → идентичные байты, что даёт дедупликацию бэкапов и работающее short-circuit «ничего не изменилось»).

```json
{"b":{"re":{"3F2A9C10-4B7E-4E21-9E55-0A1D2C3B4E5F":2.7},"sig":{"8C41BD02-1122-4F09-B7A1-6E5D4C3B2A19":4.41}},"bc":0,"epoch":1785312000,"h":14,"rc":0,"v":1,"w":{"3F2A9C10-4B7E-4E21-9E55-0A1D2C3B4E5F":{"l":1785311400,"n":218,"s":45.2},"8C41BD02-1122-4F09-B7A1-6E5D4C3B2A19":{"l":1785312000,"n":4412,"s":162.08}}}
```

В отформатированном виде:

```json
{
  "v": 1,
  "epoch": 1785312000,
  "h": 14,
  "rc": 0,
  "bc": 0,
  "w": {
    "8C41BD02-1122-4F09-B7A1-6E5D4C3B2A19": { "s": 162.08, "n": 4412, "l": 1785312000 },
    "3F2A9C10-4B7E-4E21-9E55-0A1D2C3B4E5F": { "s": 45.2,  "n": 218,  "l": 1785311400 }
  },
  "b": {
    "sig": { "8C41BD02-1122-4F09-B7A1-6E5D4C3B2A19": 4.41 },
    "re":  { "3F2A9C10-4B7E-4E21-9E55-0A1D2C3B4E5F": 2.7 }
  }
}
```

Явное поле версии — по образцу `SnippetDeepLink.Payload` (`snippets/SnippetDeepLink.swift:31, 33-40`), единственного версионированного формата в кодовой базе, а не по образцу `decodeImportData` (`SnippetStore.swift:389-412`), который просто пробует три формы.

Ключи `rc` и `bc` входят в схему **v1 с самого начала** (PR 1 пишет нули), поэтому PR 3 не меняет версию формата.

### 2.7 История миграции

Мигрировать нечего: v1 — первая версия. `snippets.json`, экспорт, share-ссылки и любой установленный `snippets-cli` не меняются ни на байт.

* **файла нет** → пустой документ, `isReadOnly = false`. Порядок в точности сегодняшний.
* **файл нечитаем / не декодируется / не тот shape** → пустой документ, `isReadOnly = false`, один `NSLog`, перезапишем при следующем flush. Намеренно **не** позиция `snippets-cli` с `fail()` (`main.swift:29`) и **не** позиция `SnippetStore.load()` с карантином и сбросом на starter-сниппет (`SnippetStore.swift:357-375`). Backup-файла нет: это производные данные, а лишний файл в наблюдаемой папке нам не нужен.
* **`version > currentVersion`** → пустой документ **и `isReadOnly = true`**: ранжируем как при пустом, пишем в память, на диск не пишем никогда. Порядок проверок обязателен: **сначала `SnippetUsageVersionProbe`, потом полный декодер.** Иначе будущая v2, переименовавшая или убравшая ключ, провалила бы полное декодирование, ушла бы в ветку «нечитаем» и старая сборка затёрла бы файл новой. Это не гипотетика — `ENABLE_APP_SANDBOX = NO` (`project.pbxproj:356, 393`), debug и release делят каталог. Двойная страховка: `SnippetUsageDocument.init(from:)` тотален (`decodeIfPresent` + дефолты по всем семи ключам), поэтому даже `{"v":1}` декодируется в валидный пустой документ, а не падает в «повреждён».
* **`halfLifeDays` отличается от текущей константы** → при загрузке делаем rebase по *старому* H (переводя веса в текущие распадные единицы) и записываем новый H. Это корректно и занимает три строки.

---

## 3. Формула

### 3.1 Ядро: фиксированная система отсчёта

Запись использования сниппета *i* в момент *t* с весом события *w*:

```
records[i].weight += w · 2^((t − epoch) / H)
```

Чтение в момент *t*:

```
S_i(t) = records[i].weight · 2^(−(t − epoch) / H)
```

Множитель `2^(−(t − epoch)/H)` **не зависит от i**. Следовательно для всех *i*, *j* и всех *t*:

```
S_i(t) > S_j(t)   ⟺   records[i].weight > records[j].weight
```

**Ранжирование по сырому сохранённому `Double` тождественно ранжированию по распадному весу в любой момент времени** — без `exp2`, без `Date()`, без вычисления прошедшего времени на пути чтения. Компаратор сравнивает два `Double`. Это не оптимизация, а свойство корректности: три вызова `updateSuggestionResults()` на одно нажатие (синхронный + AX-ресинки на 18 мс и 60 мс, `suggestionTextSyncDelays` `SnippetExpansionEngine.swift:37-40`, цикл `:637-652`) обязаны дать один и тот же порядок.

**Rebase** (`epoch → now`, все веса × `2^(−Δ/H)`) — тоже один общий положительный множитель, значит доказуемо сохраняет порядок. Нужен только для того, чтобы числа не росли без границ и файл оставался читаемым.

### 3.2 Константы

```swift
enum SnippetFrecency {
    // распад
    static let halfLifeDays: Double = 14
    static var halfLifeSeconds: Double { halfLifeDays * 86_400 }
    static let rebaseIntervalSeconds: Double = 30 * 86_400
    static let maxElapsedSeconds: Double = 400 * 86_400

    // веса событий
    static let expandWeight: Double = 1.0
    static let pasteWeight:  Double = 1.0
    static let copyWeight:   Double = 0.25

    // зажимы
    static let maxWeight: Double = 1e12
    static let rebaseWeightThreshold: Double = 1e9
    static let pruneThreshold: Double = 0.001
    static let meaningfulnessFloor: Double = 0.5
    static let maxTimestamp: Double = 4_102_444_800   // 2100-01-01

    // ёмкости
    static let maxRecords = 5_000
    static let maxBindingKeys = 400
    static let maxBindingEntriesPerKey = 4
    static let maxBindingPrefixLength = 8
    static let bindingCompetitorDecay: Double = 0.7
    /// Потолок веса привязки в единицах growth(now). При 1.0 выход из
    /// ошибочной привязки занимает ровно одну коррекцию (§3.4).
    static let bindingWeightCap: Double = 1.0

    // запись
    static let coalescingWindowSeconds: Double = 1.0
    static let persistDebounceSeconds: Double = 5.0
    static let maxStalenessSeconds: Double = 60.0
}
```

**`halfLifeDays = 14`.** Полураспад решает не «кто из активных выше» (отношения почти не зависят от H), а **как быстро умирает заброшенный сниппет**. Возьмём `q4plan`: 6 использований в один день, 45 дней назад.

| H | вес `q4plan` сегодня | вывод |
|---|---|---|
| 7 дней | `6 · 2^(−45/7)` = **0.070** | ниже порога 0.5, невидим — слишком дёргано: неделя отпуска делит всё пополам |
| **14 дней** | `6 · 2^(−45/14)` = **0.646** | виден, но ниже сниппета, использованного дважды сегодня (2.0). **Правильно** |
| 30 дней | `6 · 2^(−1.5)` = **2.121** | *выше* того, что использовали сегодня. Классическая «застрявшая верхушка» |

14 дней ≈ один спринт. Плюс: сниппет с еженедельным ритмом сохраняет между использованиями `2^(−0.5) = 0.71` от пика — привычка недельного масштаба выживает, месячного — нет.

**Установившиеся значения** (точная геометрическая сумма `w / (1 − 2^(−Δ/H))`, а не непрерывное приближение — тесты сравниваются именно с ней):

| ритм | вес |
|---|---|
| 8×/день | 162.08 |
| 4×/день | 81.29 |
| 2×/день | 40.90 |
| 1×/день | 20.70 |
| 3×/неделю | 9.17 |
| 1×/неделю | 3.41 |
| 1×/месяц (30 дн.) | 1.29 |

**Ритм «1×/рабочий день» намеренно вынесен из таблицы: он не геометрический и зависит от фазы недели.** Точные значения для пн–пт при `r = 2^(−1/14)`, `ρ = 2^(−1/2)`:

* сразу после пятничного использования: `(1 + r + r² + r³ + r⁴) / (1 − ρ)` = **15.50** (максимум цикла);
* сразу после понедельничного: `1 + (r³ + r⁴ + r⁵ + r⁶ + r⁷) / (1 − ρ)` = **14.36** (минимум цикла);
* среднее по циклу ≈ **14.9**.

Значение 14.93, которое даёт непрерывное приближение «одно использование каждые 1.4 дня», близко к среднему, но не воспроизводится ни в одной точке цикла. Тест на этот ритм обязан фиксировать фазу (§10).

**Веса событий 1.0 / 1.0 / 0.25.** `expand()` и `pasteSnippetIntoFrontmostApp` — намеренная вставка текста в реальный документ, одно намерение, один вес. `copySnippetToClipboard` — другое: он повешен на голый ↩ на выделенной строке (`ViewController+Keyboard.swift:169-172` → `ViewController+Actions.swift:314`) и на пункт «Copy Snippet» контекстного меню (`ViewController+TableView.swift:92`), это жест *просмотра*. При 0.25 четыре копирования равны одному раскрытию, и — ключевое — **одно копирование (0.25) лежит ниже `meaningfulnessFloor` (0.5)**, то есть арифметически неотличимо от «никогда не трогал». Одно осознанное раскрытие (1.0) регистрируется сразу.

**`meaningfulnessFloor = 0.5`.** Без него одно случайное копирование месяц назад оставляет остаток `0.25 · 2^(−30/14) = 0.057` — ненулевой, а значит навсегда меняет порядок двух в остальном равных сниппетов на основании шума, о котором пользователь не помнит. Порог схлопывает «практически не использовался» в ровный 0.0, где `Double`-равенство точное и 4-е/5-е тире чисто проваливаются в `displayOrder`. Обрыв на пороге виден только в порядке *внутри группы нулей*, то есть перемещает элемент из «верха нулевой группы» в «своё место в порядке создания» — эффект малый, и он честно описан в §6.8.

**Зажимы.** `elapsed` зажимается в `[0, 400 дней]`: отрицательная дельта (часы назад, DST, NTP, правка файла) даёт множитель ровно 1.0 («время не шло», использование засчитывается по номиналу); верхняя граница даёт `2^(400/14) ≈ 4.0e8`, что на 300 порядков ниже `Double.greatestFiniteMagnitude`. `maxWeight = 1e12` — при 8×/день установившееся значение 162, при абсурдных 10 000/день ≈ 2.0e5; запас гигантский. Все живые веса < 2^40, а `Double` даёт 53 бита мантиссы, значит `weight + increment` точно; накапливаемой ошибки нет.

**`pruneThreshold = 0.001`** в пост-rebase (= текущих распадных) единицах ≈ одно единичное использование ~10 полураспадов ≈ 140 дней назад. Это же — **единственный** сборщик мусора для UUID удалённых сниппетов и для устаревших ключей привязок; сверка со `SnippetStore` на штатном пути не выполняется вовсе, что полностью развязывает два стора (§6.3).

### 3.3 Почему ничья — частый случай, а не подстроенный

`FuzzyMatch.scoreContribution` (`snippets/Core/FuzzyMatch.swift:163-184`): база 1, `+2 × consecutive`, `+3` за начало слова, `+5` если `queryIndex == 0 && targetIndex == 0`. Значит вклад зависит только от *позиции* совпадений в цели, а не от длины цели. Для префиксного совпадения длины *k* в позиции 0:

| длина запроса | score |
|---|---|
| 1 | 9 |
| 2 | 12 |
| 3 | 17 |
| 4 | 24 |
| 5 | 33 |

**Любые два сниппета, чьё ключевое слово начинается с запроса, получают ровно одинаковый `score` при любой длине запроса.** А `let best = max(nameResult.score, keywordResult.score)` (`SnippetExpansionEngine.swift:826`) этого не меняет. Значит при запросе `re` со сниппетами `reply`, `req`, `refund` — тройная точная ничья по `score` (12), затем тройная ничья по `keywordMatchRank` (все 2), затем (если пинов нет) сегодня решает `displayOrder`, то есть «кого создали раньше». Это **и есть** доминирующий реальный случай, ровно тот, в котором пользователь выбирает. Утверждение «tie-break почти не срабатывает при 2-3 символах» неверно.

### 3.4 Selection memory (PR 3)

Отдельная таблица `bindings[foldedQueryPrefix][snippetID] = weight`, та же эпоха, тот же H.

* Ключ — свёрнутый (`caseInsensitive` + `diacriticInsensitive`) запрос, **только** если его длина ≤ 8. Длиннее — привязка не пишется и не читается (без усечения, чтобы не было алиасинга).
* Пишется **только** при явном принятии из панели (Tab / Return / клик).
* Правило записи с насыщением:
  ```
  table[id] = clamp(min(table[id] + growth, bindingWeightCap · growth))
  ```
  При `bindingWeightCap = 1.0` это тождественно `table[id] = growth(now)`, то есть вес привязки — просто «момент последнего выбора в системе отсчёта эпохи».
* Одновременно все остальные записи под этим ключом умножаются на `bindingCompetitorDecay = 0.7`.
* Никаких порогов и коэффициентов доминирования: привязка — просто 4-е тире, она физически не может ничего переупорядочить, кроме уже полностью равных элементов.

**Выход из ошибочной привязки — ровно одна коррекция, и это теорема, а не наблюдение.**

Инвариант: для любой записи `table[id] ≤ bindingWeightCap · growth(t_last_write)`. Пользователь выбирает B в момент `t_B ≥ t_A`:

```
A → 0.7 · cap · growth(t_A) ≤ 0.7 · growth(t_A) ≤ 0.7 · growth(t_B) < growth(t_B) = B
```

(используется `cap = 1` и монотонность `growth`, которая не убывает по времени). Инвариант переживает **rebase** — он умножает и веса, и базу отсчёта на один множитель `2^(−Δ/H)`, — и переживает **merge**, потому что `max` двух значений, каждое из которых удовлетворяет потолку, удовлетворяет ему же (§6.3).

Без насыщения обещание было бы ложным: при `+= growth` без потолка привязка, подкреплённая N раз за день, стоит на `N·G`, и выход занимает `⌊ln N / ln(1/0.7)⌋ + 1` коррекций — девять при N = 20. Общая формула для произвольного `cap = C`: `⌊ln C / ln(1/0.7)⌋ + 1`. При C = 1 это ровно 1.

**Что теряется от насыщения:** привязка перестаёт различать «выбирал 80% раз» и «выбрал один раз вчера». Это осознанный размен: 4-е тире срабатывает только на полных ничьих, а предсказуемость выхода стоит дороже градаций внутри тира, который пользователь всё равно не видит. Декай 0.7 при этом не декоративен — он загоняет заброшенных конкурентов под `pruneThreshold` и делает таблицу самоочищающейся.

### 3.5 Проработанный пример на 10 недель

Дана, support-инженер. Значения — в текущих распадных единицах (то есть ровно то, что видит ранжирование).

| сниппет | поведение | нед. 0 | нед. 2 | нед. 3 | нед. 4 | нед. 6 | нед. 10 |
|---|---|---|---|---|---|---|---|
| `sig` Email Signature | 8×/день постоянно | 162.08 | 162.08 | 162.08 | 162.08 | 162.08 | 162.08 |
| `addr` Mailing Address | 1×/день постоянно | 20.70 | 20.70 | 20.70 | 20.70 | 20.70 | 20.70 |
| `rma` Return Auth | 3×/неделю постоянно | 9.17 | 9.17 | 9.17 | 9.17 | 9.17 | 9.17 |
| `mig` Migration Plan | 4×/день недели 0–2, затем ничего | 1.00 | **41.15** | 29.09 | 20.57 | 10.29 | 2.57 |
| `lgtm` Review Reply | 2×/день начиная с недели 3 | 0 | 0 | 1.00 | 12.69 | **26.79** | 37.37 |

Читается так: `mig` в разгар проекта поднимается на второе место (41.15 > 20.70), после его окончания опускается ниже `addr` примерно к 4-й неделе и ниже `rma` к ~6.3-й; `lgtm` обгоняет `mig` между 4-й и 6-й неделей. Ни одна ручка не крутится — это одна константа.

Пустой запрос на неделе 6 **в текущем коде** дал бы `[lgtm, mig, …]`: `snippetsSortedForDisplay()` использует общий `SnippetDisplayOrder` — сначала pinned, затем `createdAt` по убыванию и UUID как детерминированный tie-break. Поэтому `lgtm`, созданный на неделе 3, стоит выше `mig`, созданного на неделе 0, независимо от локального порядка `snippets.json` и очередности CloudKit fetch. С frecency: `sig, lgtm, addr, mig, rma`.

---

## 4. Интеграция в ранжирование

### 4.1 Цепочка приоритетов — панель подсказок (scored-ветка)

Заменяет `SnippetExpansionEngine.suggestion(_:ranksBefore:query:displayOrder:)` (`SnippetExpansionEngine.swift:855-887`). Изменения помечены.

| # | ключ | статус |
|---|---|---|
| 1 | `score` desc | без изменений (`:861-863`) |
| 2 | `keywordRank` desc | семантика без изменений (`:865-869`), теперь **предвычислен** |
| 3 | `isPinned` | без изменений (`:871-873`) |
| 4 | `bindingWeight` desc | **НОВОЕ** (PR 3) |
| 5 | `frecency` desc | **НОВОЕ** (PR 1) |
| 6 | `displayOrder` asc | без изменений (`:875-879`) |
| 7 | `localizedCaseInsensitiveCompare(displayName)` | без изменений (`:881-884`) |
| 8 | `uuidString` asc | без изменений (`:886`) |

Frecency вставлена ровно туда, где существующая цепочка сдавалась и падала на «кого вы случайно создали раньше». Все семантические ключи выше неё не тронуты.

**Почему не бонус к `score`.** `FuzzyMatch.Result.score` — `Int` (`FuzzyMatch.swift:5`), а `scoreContribution` содержит слагаемое `base 1` (`:172`), значит соседние достижимые значения отличаются ровно на 1. Бонус *b*, гарантированно не пересекающий границу качества совпадения, обязан удовлетворять `b < 1`, а в пространстве `Int` единственное такое целое — **0**. Расширить `score` до `Double` и прибавлять `b ∈ [0,1)` — это ровно лексикографический порядок по `(score, b)`, то есть тот же tie-break, но уже ценой смены типа поля в `SuggestionItem` (`SuggestionPanelController.swift:3-20`) и в коде подсветки. И, главное, `keywordMatchRank` сравнивается **после** `score`, поэтому бонус в пространстве score структурно не может стоять ниже него. Tie-break строго безопаснее и строго меньше кода.

### 4.2 Чистые типы — `snippets/SnippetFrecency.swift` (новый)

`nonisolated`, без AppKit, тестируется отдельным `swiftc` — по образцу `SuggestionTriggerContext.swift:1-20`, единственного вне-акторного покрытого тестами компонента.

```swift
import Foundation

struct SnippetRankingKey {
    var score: Int = 0
    var keywordRank: Int = 0
    var isPinned: Bool = false
    var bindingWeight: Double = 0
    var frecency: Double = 0
    var displayOrder: Int = 0
    var displayName: String = ""
    var id: UUID = UUID()
}

extension SnippetFrecency {

    static func growth(epoch: Double, now: Double, halfLifeSeconds h: Double) -> Double {
        guard epoch.isFinite, now.isFinite, h.isFinite, h > 0 else { return 1 }
        let elapsed = min(max(now - epoch, 0), maxElapsedSeconds)
        let factor = exp2(elapsed / h)
        return (factor.isFinite && factor >= 1) ? factor : 1
    }

    static func clamp(weight: Double) -> Double {
        guard weight.isFinite else { return 0 }
        return min(max(weight, 0), maxWeight)
    }

    static func foldedForMatching(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Идентична SnippetExpansionEngine.keywordMatchRank(for:query:)
    /// (:889-902): 3 точное / 2 префикс / 1 нечёткое по keyword / 0.
    /// hasKeywordMatchRanges берётся из keywordResult.matchedRanges.isEmpty
    /// (:901), а НЕ из .matched — так было в оригинале.
    static func keywordRank(foldedKeyword: String,
                            foldedQuery: String,
                            hasKeywordMatchRanges: Bool) -> Int {
        if foldedKeyword == foldedQuery { return 3 }
        if foldedKeyword.hasPrefix(foldedQuery) { return 2 }
        return hasKeywordMatchRanges ? 1 : 0
    }

    /// Полный детерминированный порядок. Все ключи — предвычисленные
    /// примитивы, поэтому два сравнения одной пары внутри одного sorted()
    /// гарантированно совпадают.
    static func ranks(_ l: SnippetRankingKey, before r: SnippetRankingKey) -> Bool {
        if l.score != r.score { return l.score > r.score }
        if l.keywordRank != r.keywordRank { return l.keywordRank > r.keywordRank }
        if l.isPinned != r.isPinned { return l.isPinned }
        if l.bindingWeight != r.bindingWeight { return l.bindingWeight > r.bindingWeight }
        if l.frecency != r.frecency { return l.frecency > r.frecency }
        if l.displayOrder != r.displayOrder { return l.displayOrder < r.displayOrder }
        let c = l.displayName.localizedCaseInsensitiveCompare(r.displayName)
        if c != .orderedSame { return c == .orderedAscending }
        return l.id.uuidString < r.id.uuidString
    }

    /// Ветка пустого запроса: pin — строгий внешний ключ, displayOrder —
    /// строгий финальный, поэтому две различные позиции никогда не равны
    /// в обе стороны.
    static func emptyQueryRanks(lhsPinned: Bool, lhsFrecency: Double, lhsOrder: Int,
                                rhsPinned: Bool, rhsFrecency: Double, rhsOrder: Int) -> Bool {
        if lhsPinned != rhsPinned { return lhsPinned }
        if lhsFrecency != rhsFrecency { return lhsFrecency > rhsFrecency }
        return lhsOrder < rhsOrder
    }

    static func bindingKey(for query: String) -> String? {
        let folded = foldedForMatching(query)
        guard !folded.isEmpty, folded.count <= maxBindingPrefixLength else { return nil }
        return folded
    }

    // MARK: чистая логика записи — вынесена сюда, чтобы §10 могла её
    // протестировать без @MainActor и без реальных часов.

    /// Схлопывание автоповтора и двойной доставки. Ключ — пара
    /// (snippetID, тип события), а НЕ один snippetID: копирование (0.25) и
    /// раскрытие (1.0) одного сниппета внутри секунды — два разных
    /// намерения пользователя, и глотать второе нельзя.
    static func shouldCoalesce(lastID: UUID?, lastEventTag: Int?, lastAt: Double?,
                               id: UUID, eventTag: Int, now: Double) -> Bool {
        guard let lastID, let lastEventTag, let lastAt else { return false }
        return lastID == id && lastEventTag == eventTag
            && (now - lastAt) < coalescingWindowSeconds
    }

    /// Debounce с потолком устаревания. Голый trailing debounce — ловушка:
    /// раскрытие каждые 4 с не записалось бы никогда.
    static func flushDelay(now: Double, firstDirtyAt: Double?) -> Double {
        let sinceFirst = max(0, now - (firstDirtyAt ?? now))
        return max(0, min(persistDebounceSeconds, maxStalenessSeconds - sinceFirst))
    }

    /// Число коррекций, нужных для выхода из насыщенной привязки.
    /// При bindingWeightCap == 1.0 всегда 1 (§3.4).
    static var bindingRecoveryCorrections: Int {
        Int(( log(max(bindingWeightCap, 1)) / log(1 / bindingCompetitorDecay) ).rounded(.down)) + 1
    }
}

/// Замороженный на время одной сессии подсказок снимок.
struct FrecencySnapshot {
    static let empty = FrecencySnapshot(weights: [:], bindings: [:], cutoff: .infinity)

    /// COW-ссылка на словарь стора: захват — один retain, O(1).
    let weights: [UUID: Double]
    let bindings: [String: [UUID: Double]]
    /// meaningfulnessFloor, пересчитанный в систему отсчёта epoch:
    /// meaningfulnessFloor * growth(now). Один exp2 на сессию.
    let cutoff: Double

    func value(for id: UUID) -> Double {
        guard let w = weights[id], w >= cutoff else { return 0 }
        return w
    }

    func bindingTable(forQuery query: String) -> [UUID: Double] {
        guard let key = SnippetFrecency.bindingKey(for: query) else { return [:] }
        return bindings[key] ?? [:]
    }
}
```

`FrecencySnapshot.empty` имеет `cutoff = .infinity`, поэтому `value(for:)` всегда возвращает 0 — это и есть путь «фича выключена», доказуемо идентичный сегодняшнему поведению.

Порог применяется к **порогу**, а не к значениям: масштабируем `meaningfulnessFloor` в систему отсчёта эпохи один раз за сессию, вместо того чтобы масштабировать N весов. На горячем пути — ноль `exp2`.

### 4.3 Изменения в `SnippetExpansionEngine.swift`

**Поля** (рядом с `private let store: SnippetStore`, `:14`, и блоком состояния подсказок `:28-33`):

```swift
private let usage: SnippetUsageStore                       // :14, инъекция
private var suggestionFrecency: FrecencySnapshot = .empty  // :33
private var pendingSelectionMemoryQuery: String?           // :33, только PR 3
```

`init(store:)` (`:74-77`) → `init(store: SnippetStore, usage: SnippetUsageStore)`.

**`activateSuggestions()` (`:348-364`)** — после `suggestionHasSyncedAXContext = false` (`:353`) и **до** `updateSuggestionResults()` (`:362`):

```swift
suggestionFrecency = usage.makeRankingSnapshot()
pendingSelectionMemoryQuery = nil
```

`makeRankingSnapshot()` — один `exp2` и два COW-retain. Это единственная frecency-работа, синхронно достижимая из callback'а тапа (`installEventTap` `:137-178` → `handleEventTap` `:188-198` → `handle` `:290` → `:331-333`).

**`dismissSuggestions()` (`:479-490`)** — рядом с `suggestionSyncGeneration += 1` (`:488`):

```swift
suggestionFrecency = .empty
```

Время жизни снимка теперь ровно равно времени жизни сессии и привязано к тому же механизму отмены через `suggestionSyncGeneration`, что и in-flight refresh-таски.

**`SuggestionItem` (`SuggestionPanelController.swift:3-20`)** — три поля со значениями по умолчанию, ни один существующий вызов не ломается:

```swift
struct SuggestionItem {
    let snippet: Snippet
    let score: Int
    let nameMatchRanges: [NSRange]
    let keywordMatchRanges: [NSRange]
    let keywordRank: Int        // НОВОЕ, по умолчанию 0
    let bindingWeight: Double   // НОВОЕ, по умолчанию 0
    let frecency: Double        // НОВОЕ, по умолчанию 0
    // init(...) с дефолтами для трёх новых
}
```

**`updateSuggestionResults()` (`:812-848`), ветка пустого запроса (`:819-821`)** — заменяет
`scored = snippets.prefix(8).map { SuggestionItem(snippet: $0, score: 0) }`:

```swift
scored = snippets
    .enumerated()
    .sorted { lhs, rhs in
        SnippetFrecency.emptyQueryRanks(
            lhsPinned: lhs.element.isPinned,
            lhsFrecency: suggestionFrecency.value(for: lhs.element.id),
            lhsOrder: lhs.offset,
            rhsPinned: rhs.element.isPinned,
            rhsFrecency: suggestionFrecency.value(for: rhs.element.id),
            rhsOrder: rhs.offset)
    }
    .prefix(8)
    .map { SuggestionItem(snippet: $0.element, score: 0,
                          frecency: suggestionFrecency.value(for: $0.element.id)) }
```

Это заодно чинит **существующий скрытый баг**: сегодня `prefix(8)` (`:821`) применяется *до* какого-либо упорядочивания, то есть «топ-8» = «первые 8 в порядке создания». Указать это в описании PR как отдельную починку, а не растворять в фиче. `lhs.offset` уникален внутри одного `enumerated()`, поэтому компаратор — строгий полный порядок; ловушки `sort` быть не может.

**`updateSuggestionResults()`, scored-ветка (`:822-841`)** — свёрнутый запрос и таблица привязок считаются **один раз**, ключи ранжирования строятся **по одному разу на элемент**, а не на сравнение:

```swift
let foldedQuery = SnippetFrecency.foldedForMatching(suggestionQuery)
let binding = suggestionFrecency.bindingTable(forQuery: suggestionQuery)

scored = snippets.compactMap { snippet -> SuggestionItem? in
    let nameResult = FuzzyMatch.score(query: suggestionQuery, target: snippet.displayName)
    let keywordResult = FuzzyMatch.score(query: suggestionQuery, target: snippet.normalizedKeyword)
    let best = max(nameResult.score, keywordResult.score)
    guard nameResult.matched || keywordResult.matched else { return nil }
    return SuggestionItem(
        snippet: snippet,
        score: best,
        nameMatchRanges: nameResult.matchedRanges,
        keywordMatchRanges: keywordResult.matchedRanges,
        keywordRank: SnippetFrecency.keywordRank(
            foldedKeyword: SnippetFrecency.foldedForMatching(snippet.normalizedKeyword),
            foldedQuery: foldedQuery,
            hasKeywordMatchRanges: !keywordResult.matchedRanges.isEmpty),
        bindingWeight: binding[snippet.id] ?? 0,
        frecency: suggestionFrecency.value(for: snippet.id))
}
// Ключ строится ОДИН РАЗ на элемент (decorate-sort-undecorate).
// Вызов rankingKey(for:) прямо внутри замыкания sorted стоил бы
// 2 · O(N log N) построений структуры с retain на String и UUID —
// это просто заменило бы одну O(N log N)-стоимость другой.
.map { (key: rankingKey(for: $0, displayOrder: displayOrder), item: $0) }
.sorted { SnippetFrecency.ranks($0.key, before: $1.key) }
.prefix(8)
.map(\.item)
```

**Это делает горячий путь быстрее, чем сегодня.** Сейчас `suggestion(_:ranksBefore:query:displayOrder:)` вызывает `keywordMatchRank` **дважды на каждое сравнение** (`:865-866`), а каждый такой вызов делает `folding(options:[.caseInsensitive,.diacriticInsensitive])` и по ключевому слову, и по запросу (`:890-891`, `:904-906`) — то есть O(N log N) свёрток строк и аллокаций на каждое нажатие клавиши, внутри callback'а CGEvent-тапа. Предвычисление сводит это к O(N) и провабельно эквивалентно: значение зависит только от `snippet.normalizedKeyword`, `query` и `item.keywordMatchRanges`, которые фиксированы внутри одного вызова.

**`suggestion(_:ranksBefore:query:displayOrder:)` (`:855-887`)** заменяется тонким адаптером `rankingKey(for:displayOrder:)` + `SnippetFrecency.ranks`. `keywordMatchRank(for:query:)` (`:889-902`) удаляется (переехал в `SnippetFrecency.keywordRank`). `normalizedForSuggestionMatching(_:)` (`:904-906`) остаётся — он используется в `unambiguousExactMatch` (`:769, :774`).

### 4.4 Путь авто-раскрытия — БЕЗ ИЗМЕНЕНИЙ, и почему

`unambiguousExactMatch(for:)` (`:763-786`) не трогается ни на строку. Это путь, который срабатывает **без панели, без подтверждения и без отмены**, вставляя текст прямо в чужое поле ввода — в терминал, в консоль продакшена. Frecency:

* никогда не разрешает ничью между несколькими точными совпадениями (`exactMatches.count == 1`, `:784`),
* никогда не переопределяет вето `hasLongerPrefix` (`:784`),
* никогда не заставляет авто-раскрытие сработать на неточном запросе.

Единственное ценное свойство этой функции — что она независима от ранжирования, от порядка и от панели. Так и остаётся. Тест `autoExpandIsFrecencyIndependent` (§10) — регрессионная защита.

Асимметрия `deleteCount = query.count` в `autoExpandFromTypedBufferIfNeeded` (`:795`, текущий keydown ещё не применён хостом) — не «нормализуем», не трогаем.

### 4.5 Что ещё явно не трогается

* **`SnippetStore.enabledSnippetsSorted()` (`:226-235`)** — ноль строк. Это семантика сопоставления при раскрытии (самое длинное ключевое слово первым), и она видна пользователю через `updateKeywordWarning` (`ViewController+State.swift:439-460`), которая берёт `conflicting.first` и показывает «Overlaps with \…». Переупорядочивание по frecency назвало бы произвольный конфликт вместо самого специфичного. Плюс `updatedAt` там — tie-break (`SnippetStore.swift:231`), поэтому запись использования не имеет права его трогать.
* **`SnippetStore.snippetsSortedForDisplay()`** — frecency его не меняет. Это общий базовый порядок и для основного списка, и для панели: `SnippetDisplayOrder` вычисляет `pinned → createdAt desc → UUID`, поэтому одинаковый набор записей выглядит одинаково после локальной загрузки и после CloudKit fetch. Frecency остаётся отдельным tie-break только внутри панели.
* **`SuggestionPanelController` (`:139-194`)** — ноль строк. Это тупой рендерер, логике ранжирования там не место. Ничего нового на пути, где первый `show()` сессии делает AX-чтения (`caretScreenRect()`, вызов на `:152`, определение `:304`) **без** `AXUIElementSetMessagingTimeout`, в отличие от движка (`withBoundedMessagingTimeout`, `:1294-1297`).
* **`SnippetStore.update` / `persist` / `pushUndo` / `onChange`** — ноль строк. `SnippetUsageStore` не разделяет ни одного пути с `SnippetStore`.
* **Оверлей поиска в приложении и основной список** — ноль строк в v1. `SearchSuggestionOverlayView.update(snippets:selectedSnippetID:)` (`SearchSuggestionOverlayView.swift:59-63`) делает `prefix(8)` по неранжированному массиву — это действительно худшее ранжирование в приложении, и я оставляю его худшим осознанно: оверлей и таблица под ним — буквально один и тот же массив `visibleSnippets` (`ViewController+State.swift:90`, `ViewController+SearchSuggestions.swift:34-47`), и их расхождение хуже текущего порядка. См. открытый вопрос №2.
* **`ActionPanelContent.shortcuts` (`ViewController+BuildUI.swift:24-42`)** — ноль строк: новых горячих клавиш нет, поэтому нет и риска рассинхронизации с `handleKeyEvent` (`ViewController+Keyboard.swift:41-176`), которая ничем не связана с этим массивом на этапе компиляции.
* **`snippets-cli`** — `list` применяет тот же `SnippetDisplayOrder`, что и приложения; мутации и формат `snippets.json` не меняются, устаревший бинарник CLI безвреден.

### 4.6 Доказательство «фича выключена = сегодняшнее поведение»

При `killSwitch = true`, `rankingEnabled = false`, отсутствующем файле или после «Reset Usage Data» снимок — `FrecencySnapshot.empty`, значит `value(for:)` возвращает 0 для всех, `bindingTable` возвращает `[:]`. Тогда `l.bindingWeight != r.bindingWeight` и `l.frecency != r.frecency` всегда ложны, и цепочка сводится ровно к сегодняшней (`score → keywordRank → isPinned → displayOrder → name → uuid`). Ветка пустого запроса сводится к устойчивой сортировке по всюду равному ключу над уже канонически упорядоченным массивом, то есть к тождеству (с точностью до починки `prefix(8)`, которая при выключенной фиче возвращает те же первые 8 элементов). **Откат — один чекбокс.**

Именно ради этой теоремы в компаратор **не** добавлен тир «недавно созданный сниппет»: любой такой тир срабатывал бы и при выключенной фиче, и тождество перестало бы быть тождеством. Регрессия для новых сниппетов принята и описана в §6.8.

---

## 5. Запись использования

### 5.1 Что считается использованием

| событие | точка | вес | global | binding |
|---|---|---|---|---|
| принятие из панели (Tab / Return / клик) | `expand()` `:994-1003` | 1.0 | ✔ | ✔ |
| авто-раскрытие по AX-ресинку | `expand()` через `:727-732` → `:371` | 1.0 | ✔ | ✘ |
| авто-раскрытие по локальному фолбэку | `expand()` через `handleUnavailableRefreshWithLocalFallback` `:700-711` → `:706` → `:371` | 1.0 | ✔ | ✘ |
| авто-раскрытие из typedBuffer | `expand()` через `:788-799` → `deferExpansion` `:990` | 1.0 | ✔ | ✘ |
| ↩ «Copy Snippet» в приложении | `copySnippetToClipboard` `:264-271` (из `ViewController+Actions.swift:314`) | 0.25 | ✔ | ✘ |
| «Copy Snippet» из контекстного меню | `ViewController+TableView.swift:92` → `:168-170` → тот же `:314` | 0.25 | ✔ | ✘ |
| ⌘↩ вставка во фронтальное приложение | `pasteSnippetIntoFrontmostApp` `:273-286` (из `ViewController+Actions.swift:324`) | 1.0 | ✔ | ✘ |
| «Paste Snippet» из контекстного меню | `ViewController+TableView.swift:93` → `:172-174` → тот же `:324` | 1.0 | ✔ | ✘ |
| принятие, которое сорвалось | `:469-474` | — | ✘ | ✘ |
| принятие, отменённое многоскалярной графемой | `:436` | — | ✘ | ✘ |
| закрытая сессия | до `expand()` не доходит | — | ✘ | ✘ |
| ⇧⌘C копирование share-ссылки | `ViewController+Keyboard.swift:126` → `ViewController+Actions.swift:328` | — | ✘ | ✘ |

Сочетания ⌘C в приложении **нет**: `handleKeyEvent` (`ViewController+Keyboard.swift:41-176`) вешает на ⇧⌘C только Copy Share Link (`:126`), а копирование сниппета — на голый ↩ в контексте списка (`:169-172`) и на пункт контекстного меню. Обе пары маршрутов (клавиша и меню) сходятся в один вызов `engine.copySnippetToClipboard` / `engine.pasteSnippetIntoFrontmostApp`, поэтому точка записи одна.

**Авто-раскрытие намеренно не пишет привязку:** его запрос по определению — точное ключевое слово, которое уже разрешается через `keywordRank == 3`, привязка была бы мёртвым кодом, а таблица росла бы вдвое быстрее у тех, кто больше всех полагается на ключевые слова.

**Копирование share-ссылки не считается** — это публикация, а не использование.

**Копирование/вставка в приложении не пишут никакого контекста приложения** (на случай, если контекстный tier появится в v2): в этот момент фронтальным приложением является сам Snippets, а в таком контексте панель подсказок физически не может появиться — `handle(event:)` (`:293-297`) и `handleEventTap` (`:193`) выходят по `frontmostProcessIsThisApp()`. Записывать `com.khm.snippets` как контекст было бы чистым загрязнением.

### 5.2 Почему именно `expand()`, а не момент нажатия Tab

`acceptSelectedSuggestion(_:)` (`:425-477`) сначала закрывает панель (`:431`), затем в `Task` перечитывает `readAcceptContext` на 18 мс и 60 мс, и **может прерваться без раскрытия** на `:469-474` (`isInjecting = false; return`), когда ни AX-чтение, ни локальное отслеживание не могут поручиться за счётчик удаления, а также раньше — на `:436` из-за многоскалярных графем. Счёт в момент нажатия засчитывал бы каждое такое прерывание. `deferExpansion` (`:980-992`) имеет ту же форму — перепроверяет `deleteCount > 0` внутри асинхронного блока (`:984-987`).

Единственное место, означающее «мы обязались вставить», — внутри `expand()` **после** `guard deleteCount > 0` (`:995`).

Точная вставка (`:999-1002`):

```swift
replaceTypedText(characterCount: adjustedDeleteCount, with: resolvedText)

usage.record(.expansion, snippetID: snippet.id,
             bindingQuery: consumePendingSelectionMemoryQuery())   // НОВОЕ
lastExpansionName = snippet.displayName
statusText = "Expanded \(snippet.displayName)."
```

**После** `replaceTypedText`, потому что эта функция блокирует главный поток: `Thread.sleep(injectedKeyDelay = 0.012)` на каждый удаляемый символ плюс `Thread.sleep(prePasteDelayAfterDelete = 0.02)` (`:1010-1025`, константы `:43, :45`). Запись перед ней отодвинула бы видимую вставку; после — бесплатна.

**Захват и сброс запроса для привязки (PR 3) — четыре точки, не три.**

1. **Установка:** в `acceptSelectedSuggestion` сразу после `let localQuery = suggestionQuery` (`:426`), т.е. **до** `dismissSuggestions()` (`:431`), которая обнуляет `suggestionQuery`. Это покрывает оба явных маршрута: Tab/Return (`handleSuggestionEvent`, `:493+`) и клик по панели (`onSelect` установлен в `:355-357` → `selectSuggestion` `:366` → `acceptSelectedSuggestion` `:376`).
2. **Сброс на раннем выходе `:436`** (`guard !containsMultiScalarGrapheme(localQuery) else { pendingSelectionMemoryQuery = nil; return }`). **Это обязательно.** Запрос захватывается на `:426`, а этот `return` стоит *до* `:472`, поэтому без сброса «висячий» запрос дожил бы до следующего `activateSuggestions()` — а авто-раскрытие через `autoExpandFromTypedBufferIfNeeded` (`:788-799`) `activateSuggestions()` никогда не вызывает и, значит, съело бы его, записав привязку, которую §5.1 явно запрещает для авто-раскрытий.
3. **Сброс на пути прерывания `:469-474`** (`self.pendingSelectionMemoryQuery = nil` рядом с `self.isInjecting = false`).
4. **Сброс в `activateSuggestions()`** (`:353`) — страховка на все прочие способы завершить сессию.

`consumePendingSelectionMemoryQuery()` читает и обнуляет за одну операцию, поэтому даже при промахе в 2-4 значение не может быть использовано дважды. Между установкой и `expand()` ничего вклиниться не может: `isInjecting = true` поднят на `:440`, а `handle(event:)` выходит по нему на `:291`.

Честная семантика, зафиксированная в документации и в тексте настроек: `expand()` выставляет `lastExpansionName`/`statusText` безусловно, а `paste()` может тихо провалиться на `pasteboard.setString` (`:1037-1041`) и лишь восстановить буфер. Поэтому «использовано» = **«мы обязались вставить»**, а не «хост принял». Это ровно та же точность, которую уже заявляет статус-баннер. Никаких «леджеров» на этих числах строить нельзя.

`lastExpansionName` как ключ не годится: это `String` из `displayName` (`:9`), «Untitled Snippet» и одинаковые имена коллизируют. Ключ — `snippet.id`.

### 5.3 Стор

```swift
// snippets/SnippetUsageStore.swift (новый, только цель приложения)
import Foundation

@MainActor
final class SnippetUsageStore {

    enum Event: Int {
        case expansion = 0, pasteFromApp = 1, copyFromApp = 2
        var weight: Double {
            switch self {
            case .expansion, .pasteFromApp: return SnippetFrecency.expandWeight
            case .copyFromApp:              return SnippetFrecency.copyWeight
            }
        }
    }

    /// Скрытый жёсткий рубильник. Отключает чтение, запись, ранжирование
    /// и ВСЕ обращения к файловой системе.
    /// defaults write com.khm.snippets snippets.frecency.killSwitch -bool YES
    static let killSwitchKey = "snippets.frecency.killSwitch"
    /// Видимый переключатель. Отключает только РАНЖИРОВАНИЕ; запись
    /// продолжается, поэтому повторное включение — не холодный старт.
    static let rankingEnabledKey = "snippets.frecency.rankingEnabled"
    /// PR 3.
    static let selectionMemoryEnabledKey = "snippets.frecency.selectionMemoryEnabled"

    /// ОБА переключателя по умолчанию ВКЛЮЧЕНЫ. Регистрации дефолтов в
    /// проекте нет, а UserDefaults.standard.bool(forKey:) на отсутствующем
    /// ключе возвращает false. Поэтому — образец
    /// GlobalHotkeyManager.swift:35-41: отсутствие ключа значит
    /// «пользователь не выбирал», а не «выключено».
    static func flag(_ key: String, default fallback: Bool) -> Bool {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Bool else { return fallback }
        return stored
    }

    var isRankingEnabled: Bool { Self.flag(Self.rankingEnabledKey, default: true) }
    var isSelectionMemoryEnabled: Bool { Self.flag(Self.selectionMemoryEnabledKey, default: true) }

    private(set) var document: SnippetUsageDocument
    private(set) var isReadOnly = false
    private let isKilled: Bool

    /// Инъектируемые часы. Без этого §10 не может протестировать ни
    /// схлопывание, ни debounce, ни потолок устаревания.
    var now: () -> Double = { Date().timeIntervalSince1970 }

    /// Инжектится из AppDelegate. Используется ТОЛЬКО при превышении
    /// maxRecords, чтобы при вынужденном усечении первыми выбрасывать
    /// осиротевшие UUID (§6.3). На штатном пути не читается вовсе.
    var liveSnippetIDs: (() -> Set<UUID>)?

    /// ВСЯ дисковая работа здесь. Никогда не на главном потоке, значит
    /// никогда не в callback'е CGEvent-тапа.
    private let ioQueue = DispatchQueue(label: "com.khm.snippets.usage-io", qos: .utility)

    private var flushWorkItem: DispatchWorkItem?
    private var firstDirtyAt: Double?
    private var isDirty = false
    private var lastRecorded: (id: UUID, eventTag: Int, at: Double)?

    init() {
        isKilled = Self.flag(Self.killSwitchKey, default: false)
        document = .empty(now: Date().timeIntervalSince1970)
        guard !isKilled else { return }
        // Каталог создаётся ЗДЕСЬ, а не лениво при первом flush: см. §2.3.
        try? FileManager.default.createDirectory(
            at: SnippetStorageLocations.usageFolderURL, withIntermediateDirectories: true)
        loadSynchronously()
    }

    // MARK: чтение (горячий путь)

    func makeRankingSnapshot() -> FrecencySnapshot {
        guard !isKilled, isRankingEnabled, !document.records.isEmpty else { return .empty }
        let t = now()
        let growth = SnippetFrecency.growth(epoch: document.epoch, now: t,
                                            halfLifeSeconds: SnippetFrecency.halfLifeSeconds)
        return FrecencySnapshot(
            weights: cachedWeights,            // [UUID: Double], перестраивается только при мутации
            bindings: isSelectionMemoryEnabled ? cachedBindings : [:],
            cutoff: SnippetFrecency.meaningfulnessFloor * growth)
    }

    // MARK: запись

    func record(_ event: Event, snippetID: UUID, bindingQuery: String? = nil) {
        guard !isKilled else { return }
        let t = now()
        guard t.isFinite else { return }

        // Ключ схлопывания — ПАРА (id, тип события). Копирование и
        // раскрытие одного сниппета внутри секунды — два намерения.
        if SnippetFrecency.shouldCoalesce(
            lastID: lastRecorded?.id, lastEventTag: lastRecorded?.eventTag,
            lastAt: lastRecorded?.at, id: snippetID, eventTag: event.rawValue, now: t) { return }
        lastRecorded = (snippetID, event.rawValue, t)

        rebaseIfNeeded(now: t)
        let growth = SnippetFrecency.growth(epoch: document.epoch, now: t,
                                            halfLifeSeconds: SnippetFrecency.halfLifeSeconds)

        var record = document.records[snippetID.uuidString] ?? SnippetUsageRecord()
        record.weight = SnippetFrecency.clamp(weight: record.weight + event.weight * growth)
        record.count = min(record.count &+ 1, Int.max / 2)
        record.lastUsedAt = max(record.lastUsedAt, min(t, SnippetFrecency.maxTimestamp))
        document.records[snippetID.uuidString] = record

        if isSelectionMemoryEnabled, let q = bindingQuery,
           let key = SnippetFrecency.bindingKey(for: q) {
            var table = document.bindings[key] ?? [:]
            for other in table.keys where other != snippetID.uuidString {
                table[other] = (table[other] ?? 0) * SnippetFrecency.bindingCompetitorDecay
            }
            // Насыщение — источник теоремы «одна коррекция» (§3.4).
            let raised = (table[snippetID.uuidString] ?? 0) + growth
            table[snippetID.uuidString] =
                SnippetFrecency.clamp(weight: min(raised, SnippetFrecency.bindingWeightCap * growth))
            document.bindings[key] = table
        }

        rebuildCaches()
        markDirty(at: t)
    }

    // MARK: точечные и полные сбросы

    /// «Reset Usage» из контекстного меню строки. Единственный путь,
    /// удаляющий запись немедленно и по требованию пользователя.
    func forget(snippetID: UUID)   // из records и из ВСЕХ таблиц bindings; кэши; flush сразу

    /// «Reset Usage Data» из настроек. Ставит recordsClearedAt = now(),
    /// чтобы merge не воскресил диск (§6.3), чистит всё и удаляет файл.
    func eraseAll()

    /// Снятие чекбокса selection memory. §8 обещает УДАЛЕНИЕ таблицы, а не
    /// прекращение сбора, поэтому одного `guard isSelectionMemoryEnabled`
    /// в record() недостаточно: без этого метода document.bindings живёт
    /// вечно, а §10 требует b == {} в следующем файле.
    func forgetAllBindings()       // bindings = [:]; bindingsClearedAt = now(); кэши; flush сразу

    // MARK: инвентарь для UI (§7.3, §7.4)

    var trackedSnippetCount: Int
    var mostUsedSummary: (name: String, count: Int)?   // имя резолвится через инъекцию из SnippetStore
    var storageFootprintDescription: String            // "12 KB on this Mac"
    func usageCount(for id: UUID) -> Int?

    // MARK: сохранение

    private func markDirty(at t: Double) {
        guard !isReadOnly, !isKilled else { return }
        isDirty = true
        if firstDirtyAt == nil { firstDirtyAt = t }
        flushWorkItem?.cancel()
        let delay = SnippetFrecency.flushDelay(now: t, firstDirtyAt: firstDirtyAt)
        let item = DispatchWorkItem { MainActor.assumeIsolated { self.flush() } }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// `synchronously: true` обязателен на путях завершения и засыпания:
    /// applicationWillTerminate (AppDelegate.swift:136-139) возвращает
    /// управление и процесс умирает раньше, чем ioQueue.async успеет
    /// выполниться, — то есть асинхронный flush там не записал бы НИЧЕГО.
    /// Синхронный вариант зеркалит store.flushPendingWrites()
    /// (SnippetStore.swift:560-567), который синхронен.
    func flush(synchronously: Bool = false) {
        flushWorkItem?.cancel(); flushWorkItem = nil
        guard isDirty, !isReadOnly, !isKilled else { return }
        isDirty = false; firstDirtyAt = nil
        let snapshot = document                  // value type
        let live = liveSnippetIDs?()
        let work = { SnippetUsageFile.mergeAndWrite(snapshot, liveIDs: live) }
        synchronously ? ioQueue.sync(execute: work) : ioQueue.async(execute: work)
    }
}
```

**Стоимость `record`.** Пара хеш-обращений, один `exp2`, ≤ 5 обращений к таблице привязок. Микросекунды — на пути (`expand()`), который в любом случае только что заблокировал главный поток на десятки-сотни миллисекунд внутри `replaceTypedText`.

**Ничего из этого не достижимо из callback'а тапа.** Доказательство по графу вызовов, а не осмотром:

| путь | достижим из тапа? | почему |
|---|---|---|
| `usage.record` в `expand()` через `deferExpansion` | **нет** | `DispatchQueue.main.async` (`:982`) |
| `usage.record` в `expand()` через принятие | **нет** | ожидающий `Task` в `acceptSelectedSuggestion` (`:442`) |
| `usage.record` в `expand()` через AX-ресинк | **нет** | `Task` в `scheduleSuggestionContextRefresh` (`:637`) |
| `usage.record` в `expand()` через локальный фолбэк | **нет** | `handleUnavailableRefreshWithLocalFallback` (`:700`) вызывается только из того же `Task` (`:668`) и из `refreshSuggestionContextFromFocusedText` (`:740, :751`), сама достижимая только из него |
| `usage.record` в copy/paste | **нет** | вызываются только из `ViewController+Actions` (`:314, :324`) внутри приложения, где `handle(event:)` выходит на `:293-297` |
| `makeRankingSnapshot()` | да | один `exp2` + два COW-retain |
| `snapshot.value(for:)` в компараторах | да | одно хеш-обращение и одно сравнение `Double` |

Ни диска, ни JSON, ни AX, ни блокировок, ни `Date()` на пути нажатия клавиши.

---

## 6. Стабильность и безопасность

### 6.1 Правило заморозки

Снимок берётся **один раз** в `activateSuggestions()` (`:348-364`) и не меняется до `dismissSuggestions()` (`:479-490`). Из этого следуют три вещи:

1. Три вызова `updateSuggestionResults()` на одно нажатие (синхронный из `appendLocalSuggestionCharacter` `:680-685` + ресинки на 18 мс и 60 мс через `refreshSuggestionContextFromFocusedText` `:734`) ранжируют по идентичным данным. Строки не перетасовываются под пальцами.
2. Контракт `SuggestionPanelController.show(items:)` (`:139-194`) сохраняется: подсветка удерживается по id только при `selectionWasUserDriven` (`:140, :184-193`), и frecency не вносит нового движения.
3. Все ключи компаратора — предвычисленные примитивы на `SuggestionItem`, поэтому строгий слабый порядок структурно гарантирован, а не аргументирован.

Изоляция сессии структурная, а не по соглашению: оба маршрута принятия вызывают `dismissSuggestions()` (обнуляющую снимок) **до** `expand()` — `selectSuggestion` на `:370-371` и `acceptSelectedSuggestion` на `:431`. Copy/paste в приложении внутри сессии невозможны, потому что `handle(event:)` рушит сессию, как только это приложение становится фронтальным (`:293-297`).

### 6.2 Сдвиг часов

* **Часы назад.** `now - epoch < 0` → зажим в 0 → множитель ровно 1.0. Использование засчитывается по номиналу (в худшем случае недооценено). `lastUsedAt` берётся через `max(...)` и не откатывается.
* **Часы вперёд.** `elapsed` зажат 400 днями → множитель ≤ `4.0e8`, всё конечно. Так как rebase применяет **общий** множитель, порядок не портится.
* **NaN / Inf невозможны по построению:** `growth` проверяет `isFinite` у всех входов, зажимает показатель и проверяет результат; `clamp(weight:)` возвращает 0 для не-конечного; декодер (`sanitized`) отбрасывает не-конечные. Это важно: не-конечный `Double` в компараторе делает `!=` истинным, а `>` ложным — это **не** строгий слабый порядок, и `Array.sorted` может упасть **внутри callback'а CGEvent-тапа**, после чего macOS отключает тап. Отдельный тест на это обязателен.

### 6.3 Атомарная запись и гонки между процессами

Блокировок в кодовой базе нет нигде; `snippets-cli` делает read → mutate → write без них (`main.swift:15-43`). `flock`, который уважает только один участник, хуже, чем никакого. Поэтому — **полурешётка объединения** (join-semilattice):

```swift
// в snippets/SnippetUsageDocument.swift — чистый, тестируемый одним swiftc
enum SnippetUsageFile {

    /// Приводит документ к системе отсчёта `targetEpoch`. Множитель общий,
    /// поэтому порядок внутри документа сохраняется точно, а потолок
    /// привязок (§3.4) переживает приведение.
    static func rescaled(_ doc: SnippetUsageDocument, toEpoch t: Double) -> SnippetUsageDocument

    /// Монотонное объединение. Каждая компонента — max(), НИКОГДА не sum().
    ///
    /// sum() НЕ идемпотентна: два процесса, каждый из которых сливает файл
    /// другого, раздували бы веса в неограниченной обратной связи, а
    /// восстановление из Time Machine удваивало бы всё. max() недосчитывает
    /// действительно параллельные использования — корректный размен для
    /// подсказки ранжирования, у которой нет ценности пользовательских данных.
    /// Другого корректного правила здесь нет: понятия устройства или владения
    /// в кодовой базе не существует.
    static func join(_ a: SnippetUsageRecord, _ b: SnippetUsageRecord) -> SnippetUsageRecord {
        SnippetUsageRecord(weight: max(a.weight, b.weight),
                           count: max(a.count, b.count),
                           lastUsedAt: max(a.lastUsedAt, b.lastUsedAt))
    }

    /// Параметризовано путями, чтобы §10 могла гонять два «процесса»
    /// над временным каталогом.
    static func mergeAndWrite(_ mine: SnippetUsageDocument,
                              liveIDs: Set<UUID>?,
                              folderURL: URL = SnippetStorageLocations.usageFolderURL,
                              fileURL: URL = SnippetStorageLocations.usageFileURL) {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var merged = sanitized(mine)
        if let data = try? Data(contentsOf: fileURL),
           let probe = try? JSONDecoder().decode(SnippetUsageVersionProbe.self, from: data),
           (probe.v ?? SnippetUsageDocument.currentVersion) <= SnippetUsageDocument.currentVersion,
           let disk = try? JSONDecoder().decode(SnippetUsageDocument.self, from: data) {
            let epoch = max(mine.epoch, disk.epoch)
            let a = rescaled(sanitized(mine), toEpoch: epoch)
            let b = rescaled(sanitized(disk), toEpoch: epoch)
            merged = a
            merged.epoch = epoch

            // Маркеры сброса — тоже max(). Сторона с более поздним сбросом
            // ПОЛНОСТЬЮ вытесняет компоненту другой стороны: иначе «Reset
            // Usage Data» и снятие чекбокса selection memory воскресали бы
            // из файла на первом же merge (join — это max, он не умеет
            // удалять). Коммутативно, ассоциативно, идемпотентно.
            merged.recordsClearedAt = max(a.recordsClearedAt, b.recordsClearedAt)
            merged.bindingsClearedAt = max(a.bindingsClearedAt, b.bindingsClearedAt)

            if b.recordsClearedAt > a.recordsClearedAt {
                merged.records = b.records
            } else if b.recordsClearedAt == a.recordsClearedAt {
                for (k, v) in b.records { merged.records[k] = merged.records[k].map { join($0, v) } ?? v }
            }   // иначе: наши records новее сброса на диске — берём наши

            if b.bindingsClearedAt > a.bindingsClearedAt {
                merged.bindings = b.bindings
            } else if b.bindingsClearedAt == a.bindingsClearedAt {
                for (key, table) in b.bindings {
                    var t = merged.bindings[key] ?? [:]
                    for (k, v) in table { t[k] = max(t[k] ?? 0, v) }
                    merged.bindings[key] = t
                }
            }
        }

        merged = pruned(merged, liveIDs: liveIDs)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let out = try? encoder.encode(merged) else { return }
        // Атомарно: временный файл создаётся в folderURL, rename затрагивает
        // vnode Usage. SnippetStore следит за РОДИТЕЛЕМ (§2.3).
        try? out.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
```

`join` коммутативна, ассоциативна и **идемпотентна**, поэтому любое чередование любого числа писателей сходится. Ошибки записи только логируются, как и в `SnippetStore.writeToDisk` (`:550-558`) — данные использования не имеют права ломать приложение.

**Обрезка (`pruned`) — два разных режима, и путать их нельзя:**

| режим | когда | что делает |
|---|---|---|
| **безусловный, каждый flush** | всегда | удалить записи с весом ниже `pruneThreshold · growth(now)`; то же для каждой таблицы привязок; удалить опустевшие ключи привязок |
| **только при превышении лимита** | `records.count > maxRecords` | оставить топ-5000 по весу, выбрасывая **сначала** UUID, отсутствующих в `liveIDs` (если множество непусто), затем наименьшие по весу среди живых |
| **только при превышении лимита** | `bindings.count > maxBindingKeys` или в ключе > `maxBindingEntriesPerKey` | в каждом ключе — топ-4 по весу; затем топ-400 ключей по сумме |

**Сверка со `SnippetStore` на штатном пути не выполняется вовсе, и это принципиально.** Удалённые сниппеты собираются `pruneThreshold`, то есть естественным распадом за ~140 дней — ровно как обещает §3.2. Если бы осиротевшие UUID вычищались безусловно, то `SnippetStore.delete(snippetID:)` (`:131-135`) → flush → ⌘Z (`undo()`, `:620-627`, восстанавливающий **тот же** UUID из снимка `[Snippet]`) молча обнулял бы историю сниппета, который пользователь только что вернул. Теперь этот сценарий безопасен: запись переживает удаление и возврат, а `liveIDs` влияет только на то, кого выбросить **первым**, когда выбросить кого-то всё равно придётся. Остаточный риск честен и мал: если в момент удаления библиотека уже держит >5000 записей, отменённое удаление истории не вернёт.

`duplicate()` создаёт новый UUID (`SnippetStore.swift:137-155`), правило импорта 1 сохраняет входящий id, правило 2 восстанавливает локальный (`:312-332`) — всё это покрывается членством во множестве и `join`.

### 6.4 Деградация при повреждении

`load()` тотален и никогда не бросает. **Порядок проверок — часть контракта:**

```swift
private func loadSynchronously() {
    guard let data = try? Data(contentsOf: SnippetStorageLocations.usageFileURL) else { return }

    // 1. ЗОНД ВЕРСИИ ИДЁТ ПЕРВЫМ. Полное декодирование будущего формата
    //    может провалиться; провалиться оно обязано в read-only, иначе
    //    старая сборка затрёт данные новой в общем каталоге
    //    (ENABLE_APP_SANDBOX = NO, project.pbxproj:356/393).
    if let probe = try? JSONDecoder().decode(SnippetUsageVersionProbe.self, from: data),
       let v = probe.v, v > SnippetUsageDocument.currentVersion {
        NSLog("Snippets: usage data version \(v) is newer; running read-only.")
        isReadOnly = true
        return
    }

    // 2. Полный декодер тотален (decodeIfPresent по всем ключам), поэтому
    //    сюда попадает только по-настоящему невалидный JSON.
    guard let doc = try? JSONDecoder().decode(SnippetUsageDocument.self, from: data) else {
        NSLog("Snippets: usage data unreadable; starting fresh.")
        return                       // отсутствует == повреждён == пусто
    }
    guard doc.version <= SnippetUsageDocument.currentVersion else {
        isReadOnly = true            // страховка, если зонд не сработал
        return
    }
    document = SnippetUsageFile.rebasedIfNeeded(SnippetUsageFile.sanitized(doc),
                                                now: Date().timeIntervalSince1970)
    rebuildCaches()
}
```

`sanitized(_:)` перепроверяет **каждое** поле:

```swift
static func sanitized(_ doc: SnippetUsageDocument) -> SnippetUsageDocument {
    var out = doc
    out.halfLifeDays = doc.halfLifeDays.isFinite
        ? min(max(doc.halfLifeDays, 1), 365) : SnippetFrecency.halfLifeDays
    out.epoch = doc.epoch.isFinite ? min(max(doc.epoch, 0), SnippetFrecency.maxTimestamp) : 0
    out.recordsClearedAt = doc.recordsClearedAt.isFinite
        ? min(max(doc.recordsClearedAt, 0), SnippetFrecency.maxTimestamp) : 0
    out.bindingsClearedAt = doc.bindingsClearedAt.isFinite
        ? min(max(doc.bindingsClearedAt, 0), SnippetFrecency.maxTimestamp) : 0
    out.records = doc.records.reduce(into: [:]) { acc, e in
        guard UUID(uuidString: e.key) != nil,
              e.value.weight.isFinite, e.value.weight > 0,
              e.value.lastUsedAt.isFinite else { return }
        acc[e.key] = SnippetUsageRecord(
            weight: SnippetFrecency.clamp(weight: e.value.weight),
            count: min(max(e.value.count, 0), Int.max / 2),
            lastUsedAt: min(max(e.value.lastUsedAt, 0), SnippetFrecency.maxTimestamp))
    }
    out.bindings = /* то же: ключ длиной 1...maxBindingPrefixLength, валидный UUID,
                      конечный положительный вес, clamp(weight:) */
    return out
}
```

Загрузка синхронная на главном потоке при старте (один файл ≤ ~600 КБ, один раз) — намеренно, а не асинхронно: асинхронная загрузка означала бы, что первая сессия подсказок после каждого запуска молча ранжирует как при пустых данных. Такой недетерминизм никто никогда не воспроизвёл бы по багрепорту.

### 6.5 Гигиена экспорта и share-ссылок

Гарантия **структурная, а не фильтром**, который можно забыть:

* `exportSnippets(to:)` (`SnippetStore.swift:335-344`) кодирует `SnippetCollection(snippets:)` (`:61-63`), то есть только `Snippet`. Использование не поле `Snippet` → попасть туда физически не может.
* `SnippetDeepLink.Payload` (`SnippetDeepLink.swift:33-40`) — отдельная структура из пяти полей `{version, name, keyword, content, tags?}`. Share-ссылка, раскрывающая частоту использования сниппета, была бы настоящей утечкой; здесь такой поверхности не существует. Обратное тоже верно: подготовленная извне ссылка не может повлиять на ранжирование. Это сильнее, чем позиция «подтверди диалогом» для входящих сниппетов (`AppDelegate.swift:661-700`).
* `SnippetDeepLink.snippet(from:)` (`:108-113`) вызывает мембервайз-инициализатор `Snippet` без `id`, у которого дефолт `id: UUID = UUID()` (`Snippet.swift:15`), поэтому импортированные сниппеты стартуют с нуля. При этом правила upsert 1 и 2 (`SnippetStore.swift:312-332`) сохраняют **локальный** `id` — значит переимпорт собственной share-ссылки или экспорта коллеги **сохраняет** вашу историю. Это правильно: история про *ваши* вставки.

### 6.6 Kill switch

`defaults write com.khm.snippets snippets.frecency.killSwitch -bool YES` — читается один раз в `init` (до создания каталога и до загрузки) и проверяется в начале `record`, `flush`, `makeRankingSnapshot`. Вместе с «удалите `~/Library/Application Support/SnippetsClone/Usage/`» это даёт поддержке двухшаговую бисекцию к доказуемо дофичевому поведению — без даунгрейда и переустановки. При включённом рубильнике каталог не создаётся вовсе.

### 6.7 Взаимодействие с сохранением библиотеки

`record()` не вызывает `SnippetStore.update()`, `persist()`, `pushUndo()` и `onChange`. Следствия, которых мы избегаем:

* нет снимка undo на каждое раскрытие (стек ограничен 50, `SnippetStore.swift:35` — счётчики вымыли бы все реальные правки за секунды);
* нет обновления `updatedAt` (а значит, не едет tie-break `enabledSnippetsSorted()`, `:231`);
* нет `onChange(.local)` → нет `reloadVisibleSnippets` → **нет анимированной перетасовки строк в основном окне, пока пользователь раскрывает сниппет в другом приложении** (`ViewController.swift:206-218` → `ViewController+State.swift:90, 114-138`);
* нет перезаписи всей библиотеки на каждое раскрытие.

### 6.8 Принятые регрессии

Три случая, где новый порядок отличается от старого не в лучшую сторону. Все три приняты сознательно, ни один не лечится кодом без утраты теоремы §4.6.

**1. Только что созданный сниппет тонет в ветке пустого запроса.** Канонический display-order ставит свежесозданный сниппет первым среди незакреплённых по `createdAt`. С frecency выше `displayOrder` он уходит ниже любого сниппета с ненулевой историей — то есть именно тот, чьё ключевое слово пользователь ещё не запомнил, становится труднее всего найти.

Почему это не чинится тиром «создан недавно»: такой тир срабатывал бы и при выключенной фиче, и §4.6 («откат — один чекбокс») перестала бы быть теоремой. Обмен явный: предсказуемость отката дороже.

Чем это смягчено на практике:
* пока у сниппета нет ключевого слова, его в панели вообще нет — `enabledSnippetsForSuggestionDisplay()` фильтрует пустые keyword (`SnippetExpansionEngine.swift:850-853`), а пользователь только что вводил это ключевое слово в редакторе и помнит его;
* как только ключевое слово набрано, `unambiguousExactMatch` (`:763-786`) и `keywordRank == 3` бьют любую frecency;
* закрепление (⌘.) — строгий внешний ключ и мгновенное лекарство.

Текст `informativeText` кнопки сброса намеренно называет альтернативный порядок, чтобы пользователь понимал модель (§7.3).

**2. Переименование ключевого слова.** История привязана к `snippet.id`, поэтому переименование `sig` → `signature` **переносит всю frecency на новое ключевое слово**. Это правильное поведение: сниппет тот же. А вот записи в `bindings` под *старым* префиксом остаются и никем не инвалидируются: специальной сверки нет и не будет (она вернула бы связность двух сторов). Они инертны — старый префикс больше не набирается, — и умирают сами по `pruneThreshold` за ~140 дней либо мгновенно вытесняются `bindingCompetitorDecay`, если пользователь наберёт тот же префикс и выберет что-то другое.

**3. Расхождение счётчика `count` с реальностью.** Из-за `join = max` (§6.3) `count` — нижняя граница, а не бухгалтерия. Он показывается ровно в двух местах (строка статуса в настройках и заголовок пункта контекстного меню) и не используется в ранжировании.

---

## 7. UI и настройки

### 7.1 Что видит пользователь

Ничего нового на экране. Меняется ровно одно: порядок строк в панели, привязанной к каретке. Это модель Raycast — ранжирование *ощущается*, а не отображается, — и одновременно самый низкорисковый выбор:

* `SuggestionCellView` не меняется, значит не трогается измерение `shouldWrapName` через `NSString.size(withAttributes:)` (`SuggestionPanelController.swift:749-755`) и выбор высоты строки 46 / 62 пт (`:29-30`);
* `SnippetRowCellView.configure(with:)` (`SnippetRowViews.swift:108-137`) не меняется, значит нет риска «призрака» бейджа на переиспользованной ячейке (ячейки переиспользуются по идентификатору, `ViewController+TableView.swift:32-39`);
* короткое замыкание `updateTagChips` по `renderedTagState` (`SnippetRowViews.swift:140-141`) не при чём;
* новых `NSView` нет, значит нет и нового долга по доступности.

**Бейдж «часто используется» в строке основного списка отклонён**: основной список в v1 **не** ранжируется по frecency, поэтому бейдж рекламировал бы порядок, которого нет — это активно вводит в заблуждение. В ячейке панели он потребовал бы пересмотра ширинной математики `shouldWrapName` на самом latency-критичном пути. (Если бейдж когда-нибудь появится — место известно: `bottomRow` перед `tagChipsStack`, `SnippetRowViews.swift:76-79`, где спейсер с hugging priority 1 уже поглощает слабину (`:73-74`), а высота строки фиксирована 58 пт (`ViewController+BuildUI.swift:361`); стиль — `.muted` из `TagChipView` (`TagViews.swift:75, 185-187`), цвет — `.secondaryLabelColor`, доступность — по образцу `TagViews.swift:146-149`.)

### 7.2 Как сосуществуют pin и frecency

Правила, исчерпывающе:

1. **Панель, пустой запрос** — `isPinned` строгий внешний ключ. Frecency упорядочивает *внутри* закреплённой и внутри незакреплённой групп.
2. **Панель, есть запрос** — `isPinned` на 3-м месте цепочки, **выше** `bindingWeight` (4) и `frecency` (5). Ни частота, ни память выбора не могут обойти пин.
3. **Основной список и оверлей ⌘F** — не меняются.
4. **Закрепление остаётся чисто ручным.** Никакого авто-пина, никаких предложений «закрепить?», никакого открепления. Пин — единственная жёсткая гарантия, которую даёт приложение, и вся её ценность в том, что система её не трогает. Frecency никогда не пишет `isPinned` и никогда не читает его как вход.

Три маршрута к любому сниппету, полностью независимые от истории (и они же — ответ на регрессию §6.8.1):
* набрать ключевое слово целиком — `unambiguousExactMatch` (`:763-786`) слеп к истории;
* набрать достаточно ключевого слова — `keywordRank == 3` бьёт и привязку, и frecency;
* закрепить — строгий внешний ключ.

### 7.3 Настройки → General, новая секция

Вставляется после настройки подсветки совпадений и перед секцией CLI.

**Свойства** (рядом с остальными контролами General):

```swift
private let frecencyCheckbox = NSButton(
    checkboxWithTitle: "Rank suggestions by how often I use them", target: nil, action: nil)
private let selectionMemoryCheckbox = NSButton(          // PR 3
    checkboxWithTitle: "Remember which snippet I pick for each typed prefix",
    target: nil, action: nil)
private let frecencyStatusLabel = NSTextField(wrappingLabelWithString: "")
private let resetUsageButton = NSButton(title: "Reset Usage Data", target: nil, action: nil)
```

**Сборка** в `loadView()`, сразу после блока подсветки совпадений:

```swift
let frecencySeparator = NSBox()
frecencySeparator.boxType = .separator

let frecencyIntroLabel = makeSecondaryLabel(
    "Snippets you expand most often move to the top of the panel that appears after you type \u{201C}\\\u{201D}. Typing a full keyword always wins over usage, and pinned snippets always stay on top. Usage stays on this Mac \u{2014} it is never included in exports or share links.")

frecencyCheckbox.target = self
frecencyCheckbox.action = #selector(handleFrecencyChanged(_:))
let frecencyRow = NSStackView(views: [frecencyCheckbox, NSView()])
frecencyRow.orientation = .horizontal
frecencyRow.alignment = .centerY

selectionMemoryCheckbox.target = self                    // PR 3
selectionMemoryCheckbox.action = #selector(handleSelectionMemoryChanged(_:))
let selectionMemoryRow = NSStackView(views: [selectionMemoryCheckbox, NSView()])
selectionMemoryRow.orientation = .horizontal
selectionMemoryRow.alignment = .centerY

frecencyStatusLabel.font = .systemFont(ofSize: 12)
frecencyStatusLabel.textColor = .secondaryLabelColor

resetUsageButton.target = self
resetUsageButton.action = #selector(resetUsageData)
LiquidGlassDesign.configureActionButton(resetUsageButton, symbolName: "arrow.counterclockwise")
let resetUsageRow = NSStackView(views: [resetUsageButton, NSView()])
resetUsageRow.orientation = .horizontal
resetUsageRow.alignment = .centerY
```

**Три обязательных места** (пропуск любого — тихий баг):

1. блок `stack.addArrangedSubview` — добавить `frecencySeparator`, `frecencyIntroLabel`, `frecencyRow`, `selectionMemoryRow`, `frecencyStatusLabel`, `resetUsageRow` **после** `matchHighlightSummaryLabel` и **до** `cliSeparator`;
2. блок ширин — `frecencySeparator`, `frecencyIntroLabel`, `frecencyStatusLabel` пристегнуть `widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true`. Строки с чекбоксами не пристёгиваются. **Пропуск ширины схлопывает вид без единого предупреждения.**
3. `reloadFromStorage()` — вызвать `applyFrecencyControls()`; панели ничего не кешируют, состояние надо перечитать, иначе при повторном открытии окна оно устареет.

**Перечитывание состояния:**

```swift
private func applyFrecencyControls() {
    guard let app = NSApp.delegate as? AppDelegate else { return }
    let store = app.usageStore

    frecencyCheckbox.state = store.isRankingEnabled ? .on : .off
    selectionMemoryCheckbox.state = store.isSelectionMemoryEnabled ? .on : .off
    // Память выбора — уточнение ранжирования; без ранжирования она бессмысленна.
    selectionMemoryCheckbox.isEnabled = store.isRankingEnabled && !store.isReadOnly
    let tracked = store.trackedSnippetCount
    if store.isReadOnly {
        frecencyStatusLabel.stringValue = "Usage data was written by a newer version of Snippets. Ranking is paused and nothing is being saved."
    } else if tracked == 0 {
        frecencyStatusLabel.stringValue = "No usage recorded yet."
    } else if let top = store.mostUsedSummary {
        frecencyStatusLabel.stringValue = "Tracking \(tracked) snippet\(tracked == 1 ? "" : "s") \u{2014} \(store.storageFootprintDescription). Most used: \(top.name) (\(top.count) use\(top.count == 1 ? "" : "s"))."
    }
    resetUsageButton.isEnabled = tracked > 0 && !store.isReadOnly
}

@objc private func handleFrecencyChanged(_ sender: NSButton) {
    UserDefaults.standard.set(sender.state == .on, forKey: SnippetUsageStore.rankingEnabledKey)
    applyFrecencyControls()
}

@objc private func handleSelectionMemoryChanged(_ sender: NSButton) {      // PR 3
    let enabled = sender.state == .on
    UserDefaults.standard.set(enabled, forKey: SnippetUsageStore.selectionMemoryEnabledKey)
    // Снятие УДАЛЯЕТ таблицу, а не просто прекращает сбор (§8). Одного
    // guard в record() для этого мало: document.bindings жил бы вечно,
    // а merge (max) воскресил бы её с диска — отсюда bindingsClearedAt.
    if !enabled { (NSApp.delegate as? AppDelegate)?.usageStore.forgetAllBindings() }
    applyFrecencyControls()
}
```

Строка статуса — единственное место, где вообще показываются числа использования, и она же отвечает на вопрос «а оно включено?». Режим read-only **виден в UI**, а не только в `NSLog`.

**Кнопка сброса** — точно по шаблону `BrowserSettingsViewController.clearAll()` (`SettingsWindowController.swift:624-637`): guard на пустоту, `NSAlert` с `alertStyle = .warning`, деструктивная кнопка добавляется **первой**, `guard alert.runModal() == .alertFirstButtonReturn`, затем применение и подтверждение в статус-метке.

```swift
@objc private func resetUsageData() {
    guard let app = NSApp.delegate as? AppDelegate, app.usageStore.trackedSnippetCount > 0 else { return }
    let alert = NSAlert()
    alert.messageText = "Reset Usage Data?"
    alert.informativeText = "Suggestions go back to pinned-then-newest-first order until you start using snippets again. Your snippets are not changed."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Reset Usage Data")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    app.usageStore.eraseAll()
    applyFrecencyControls()
    frecencyStatusLabel.stringValue = "Usage data reset."
}
```

Текст `informativeText` намеренно говорит, **к какому** порядку происходит откат («pinned, then newest first» — это канонический `SnippetDisplayOrder`): это учит модели ранжирования в момент, когда пользователь на неё смотрит.

Значение по умолчанию для обоих чекбоксов — **ВКЛ**, и оно реализуется через `SnippetUsageStore.flag(_:default:)` по образцу `GlobalHotkeyManager.swift:35-41`, а **не** через `UserDefaults.standard.bool(forKey:)`, который на отсутствующем ключе вернул бы `false` и тихо выключил бы фичу для всех. Выключенное состояние доказуемо равно сегодняшнему (§4.6), поэтому чекбокс — настоящий откат в один клик, а не полумера.

### 7.4 Контекстное меню строки — точечный выход

Один застрявший наверху сниппет — реальный сценарий («неделю делал миграцию, теперь `migplan` стоит выше подписи ещё две недели»), а глобальный сброс для него — кувалда.

`makeSnippetContextMenu(for:)` (`ViewController+TableView.swift:86-113`) сегодня строит **неизменяемый литерал** `let items: [NSMenuItem] = [ … ]` (`:91-110`). Поэтому вставка требует смены на `var` — `items.append(...)` на `let`-массиве не компилируется:

```swift
var items: [NSMenuItem] = [ … ]                    // :91, было let
// …
// между Pin/Unpin (:101-106) и подменю Tags (:107):
if let count = usageStore.usageCount(for: snippet.id), count > 0,
   let pinIndex = items.firstIndex(where: { $0.action == #selector(togglePinnedSelectedSnippetFromContextMenu(_:)) }) {
    items.insert(contextMenuItem(
        title: "Reset Usage (\(count) use\(count == 1 ? "" : "s"))",
        symbolName: "arrow.counterclockwise",
        action: #selector(resetUsageForSelectedSnippetFromContextMenu(_:))),
        at: pinIndex + 1)
}
items.forEach(menu.addItem)                         // :112, без изменений
```

`usageStore` доступен во `ViewController` через новый ленивый аксессор, зеркалящий существующие `store` (`ViewController.swift:25-30`) и `engine` (`:32-37`) — см. §9 PR 1.

Заголовок пункта **и есть** раскрытие информации: пользователь узнаёт счётчик и получает исправление одним жестом. При count = 0 пункт скрыт полностью — как это уже сделано с переключением заголовков/символов Pin и Enable (`:97-106`). Обработчик — по форме `togglePinnedSelectedSnippet()` (`ViewController+Actions.swift:275-290`): фиксация редактора (`commitActiveEditorState(endingEditing: true)`) → `usageStore.forget(snippetID:)` → сообщение статуса → `reloadVisibleSnippets(keepSelection: true)` → `closeActionPanel()`. Правый клик уже выделяет строку (`SnippetListTableView.menu(for:)`, `ViewController+TableView.swift:6-17`), поэтому `activeCommandSnippetID()` (`ViewController+State.swift:342-346`) резолвится в кликнутый сниппет — как у всех остальных пунктов этого меню.

Оговорка: `count` — нижняя граница, а не бухгалтерия (объединение по `max`, §6.3, §6.8.3). Не строить на нём статистику.

### 7.5 Новых горячих клавиш нет

Ничего не привязываем. Это полностью обходит карту занятых сочетаний в `handleKeyEvent` (`ViewController+Keyboard.swift:41-176`: ⌘Z ⌘⇧Z ⌘B ⌘F ⌘K ⌘N ⌘⌫ ⇧⌘I ⇧⌘E ⇧⌘C ⌘E ⌘↩ ⌘D ⌘/ ⌘. ⌃N ⌃P ↩), а также массив `ActionPanelContent.shortcuts` (`ViewController+BuildUI.swift:24-42`), у которого нет связи с обработчиками на этапе компиляции. Добавление сочетания здесь было бы чистым обязательством без выгоды.

### 7.6 Локализация

Все новые строки — жёстко зашитые Swift-литералы с интерполяцией и ad-hoc плюрализацией (`"\(n) use\(n == 1 ? "" : "s")"`), как в `TagViews.swift:522`. В кодовой базе нет ни `NSLocalizedString`, ни `.strings`/`.xcstrings`; фича их не вводит. Типографские кавычки — через `\u{201C}` / `\u{201D}`, как уже сделано в `SettingsWindowController.swift:249`.

---

## 8. Приватность

**Что хранится** в `~/Library/Application Support/SnippetsClone/Usage/usage.json`, права `0600`:

* UUID сниппетов;
* три числа на сниппет: масштабированный по эпохе вес, пожизненный счётчик, время последнего использования;
* два числа на файл: моменты последнего сброса статистики и последнего снятия памяти выбора;
* (PR 3) свёрнутые префиксы запросов длиной не более 8 символов.

**Про префиксы — точно.** Префикс попадает в файл только если: сессия подсказок закончилась *подтверждённым* принятием из панели; символы уже прошли `isValidKeywordCharacter` (`SnippetExpansionEngine.swift:950-952`); длина ≤ 8. По построению каждый такой префикс — нечёткое подпоследовательное совпадение с именем или ключевым словом одного из ваших собственных сниппетов (иначе панель не показала бы принятый элемент), то есть производное от текста, который уже лежит открытым в `snippets.json`. Плюс он был набран ровно для того, чтобы через миллисекунду быть удалённым и заменённым. Тем не менее это единственное место, где на диск попадает то, что пользователь напечатал, — поэтому у него отдельный переключатель, снятие которого **удаляет** таблицу, а не просто прекращает сбор. Удаление реализовано `forgetAllBindings()` (§5.3) плюс маркером `bindingsClearedAt` в объединении (§6.3): без маркера `join = max` воскресил бы таблицу с диска на первом же merge, и обещание было бы ложным.

**Что не хранится никогда:**

* текст, набранный вне сессии `\` — `typedBuffer` не доходит до `SnippetUsageStore`;
* имена, содержимое и результат раскрытия сниппетов;
* что-либо прочитанное через Accessibility: сфокусированный текст, заголовки окон, URL, имена документов, содержимое полей;
* содержимое буфера обмена;
* идентификаторы или имена приложений, в которые вы вставляете текст (per-app tier из рассмотренных вариантов **выброшен** — это была самая тяжёлая часть по приватности);
* PID, отпечатки устройства, что-либо про машину;
* префиксы из закрытых сессий, из принятий, сорвавшихся на `:436`, и из сорвавшихся на `:469-474`;
* префиксы из авто-раскрытий (это точные ключевые слова, которые и так лежат открытым текстом в `snippets.json`).

**Данные не покидают машину.** Сетевого кода в фиче нет. Утечка через экспорт или share-ссылку невозможна структурно (§6.5), а не за счёт фильтра, который можно забыть. `snippets-cli` этот файл не читает и не пишет.

**Оговорка про синхронизацию.** iCloud Drive и Dropbox по умолчанию не синхронизируют `~/Library/Application Support`, но пользователи переносят и симлинкают этот каталог, а Backblaze/Arq/Resilio до него добираются. Там объединение по `max` даёт сходящийся, хоть и недосчитывающий результат; `snippets.json` при этом не затрагивается вовсе.

---

## 9. План внедрения

### PR 0 — рефакторинг без изменения поведения

**Файлы:** `snippets/SnippetFrecency.swift` (новый, только `SnippetRankingKey` + `keywordRank` + `ranks` + `foldedForMatching`), `snippets/SuggestionPanelController.swift` (`:3-20`), `snippets/SnippetExpansionEngine.swift` (`:822-841`, `:855-902`), `Tests/SnippetRankingTests.swift` (новый).
**Размер:** ~150 строк, из них ~90 — перенос.

1. Добавить `keywordRank: Int = 0` в `SuggestionItem`.
2. Вынести цепочку компаратора и `keywordMatchRank` в `SnippetFrecency` над `SnippetRankingKey` (примитивы, без AppKit).
3. Считать `foldedQuery` один раз, предвычислять `keywordRank` в `compactMap`, перейти на decorate-sort-undecorate (§4.3).
4. Золотой тест: над фикстурой из 50 элементов с дублями по score / rank / pin новая цепочка даёт поэлементно тот же порядок, что старая.

Отдельный PR намеренно: это код, решающий, какой текст попадёт в чужое приложение, и он не должен прятаться внутри фичи. Побочный эффект — минус O(N log N) свёрток строк на нажатие клавиши.

### PR 1 — ядро frecency ← **МИНИМАЛЬНЫЙ ОТГРУЖАЕМЫЙ СРЕЗ**

**Файлы:**
`snippets/Core/Snippet.swift` (+`SnippetStorageLocations` после `:70`),
`snippets/SnippetStore.swift` (`:75-79` — переход на константы, 3 строки),
`snippets-cli/main.swift` (`:5-10`, 2 строки),
`snippets/SnippetFrecency.swift` (константы, `growth`, `clamp`, `emptyQueryRanks`, `shouldCoalesce`, `flushDelay`, `FrecencySnapshot`),
`snippets/SnippetUsageDocument.swift` (новый; документ + зонд версии + `SnippetUsageFile`),
`snippets/SnippetUsageStore.swift` (новый),
`snippets/SnippetExpansionEngine.swift` (`:14`, `:33`, `:74-77`, `:264-271`, `:273-286`, `:348-364`, `:479-490`, `:819-821`, `:822-841`, `:994-1003`),
**`snippets/ViewController.swift` (`:32-37` и новый аксессор)**,
`snippets/AppDelegate.swift` (`:43-44`, `:136-139`, +2 наблюдателя),
`snippets/SettingsWindowController.swift` (`:94`, `:164`, `:182-197`, `:199-208`, `:242-258`, `:406-410`, новые обработчики),
`Tests/SnippetFrecencyTests.swift`, `Tests/SnippetUsageDocumentTests.swift`.

**`snippets/ViewController.swift` — без него PR 1 не компилируется.** Там есть фолбэчный `lazy var engine` (`:32-37`), строящий `SnippetExpansionEngine(store: store)` напрямую на `:35`; смена инициализатора на `init(store:usage:)` его ломает. Плюс §7.4 обращается к `usageStore` из `ViewController+TableView.swift`, и пути к нему сегодня не существует. Обе правки — один блок по образцу `store` (`:25-30`):

```swift
lazy var usageStore: SnippetUsageStore = {
    if let appDelegate = NSApp.delegate as? AppDelegate {
        return appDelegate.usageStore
    }
    return SnippetUsageStore()
}()

lazy var engine: SnippetExpansionEngine = {
    if let appDelegate = NSApp.delegate as? AppDelegate {
        return appDelegate.expansionEngine
    }
    return SnippetExpansionEngine(store: store, usage: usageStore)   // :35
}()
```

**Размер:** ~650 строк нового кода, ~50 строк правок в существующем.

Порядок работ:

1. `SnippetStorageLocations` + перевод `SnippetStore` и CLI на него.
2. `SnippetFrecency` — математика, константы, `FrecencySnapshot`, `emptyQueryRanks`, чистые `shouldCoalesce` / `flushDelay`. Тесты математики.
3. `SnippetUsageDocument` + `SnippetUsageVersionProbe` + `SnippetUsageFile` (sanitize / rebase / rescale / join / merge / prune / write). Тесты Codable, полурешётки, враждебных значений, зонда версии.
4. `SnippetUsageStore` — создание каталога в `init`, загрузка (зонд → полный декодер), `record`, схлопывание по паре `(id, event)`, debounce с потолком, `flush(synchronously:)` через `ioQueue`, `eraseAll`, `forget`, `forgetAllBindings`, kill switch, инъектируемые `now`.
5. Проводка в `AppDelegate`:
```swift
// ПОРЯДОК ОБЪЯВЛЕНИЯ ЗНАЧИМ: хранимые свойства инициализируются сверху вниз,
// а SnippetStore.init() ставит DispatchSource на SnippetsClone (:82).
// usageStore должен создать Usage/ ДО этого, иначе первое создание каталога
// дёрнет монитор в произвольный момент (§2.3).
let usageStore = SnippetUsageStore()                                            // :43
let store = SnippetStore()                                                      // :44
lazy var expansionEngine = SnippetExpansionEngine(store: store, usage: usageStore)
```
   плюс в `applicationWillTerminate` (`:136-139`) — `usageStore.flush(synchronously: true)` перед `store.flushPendingWrites()` (**синхронно обязательно**: асинхронный `ioQueue.async` не успевает до выхода процесса и не записывает ничего);
   плюс наблюдатели `NSApplication.didResignActiveNotification` → `usageStore.flush()` (асинхронно; раскрытие в другом приложении означает, что мы не фронтальны, поэтому `didResignActive` ловит почти всё) и `NSWorkspace.shared.notificationCenter` `willSleepNotification` → `usageStore.flush(synchronously: true)`;
   плюс `usageStore.liveSnippetIDs = { [weak store] in Set((store?.snippets ?? []).map(\.id)) }` (`SnippetStore.snippets` — `private(set)`, `:15`).
6. Три семейства точек записи + заморозка снимка + ветка пустого запроса + 5-е тире.
7. Секция настроек (все **четыре** обязательных места, §7.3).

**Ручная проверка перед мержем (обязательна):** с открытым приложением и висящим 0.3-секундным debounce редактора выполнить ~20 записей в `SnippetsClone/Usage/usage.json` и брейкпойнтом/логом в `reloadFromDiskIfNeeded` (`SnippetStore.swift:684`) убедиться, что она **не** вызывается и debounce не сбрасывается досрочно. Отдельно проверить первый запуск с **удалённым** `~/Library/Application Support/SnippetsClone/Usage/`: создание каталога должно произойти в `SnippetUsageStore.init()`, то есть до установки `DispatchSource` на `:82`. Затем повторить, положив файл прямо в `SnippetsClone/`, и убедиться, что монитор **срабатывает** — иначе подкаталог был бы карго-культом.

### PR 2 — прозрачность и точечный сброс

**Файлы:** `snippets/ViewController+TableView.swift` (`:86-113`, включая смену `let items` на `var items` на `:91`), `snippets/ViewController+Actions.swift` (новый обработчик по форме `:275-290`), `snippets/SettingsWindowController.swift` (инвентарная строка + режим read-only).
**Размер:** ~90 строк.

### PR 3 — selection memory ← **решение автора: отгружать или остановиться на PR 2**

**Файлы:** `snippets/SnippetFrecency.swift` (`bindingKey`, `bindingWeightCap`, `bindingRecoveryCorrections`), `snippets/SnippetUsageDocument.swift` (таблица `bindings` и маркер `bc` уже в схеме v1 — заполнять), `snippets/SnippetUsageStore.swift` (`bindingQuery` в `record`, насыщение, `forgetAllBindings`), `snippets/SnippetExpansionEngine.swift` (`pendingSelectionMemoryQuery`: `:33`, `:353`, `:426`, **`:436`**, `:469-474`, `:1000`; `bindingWeight` в `:822-841`), `snippets/SettingsWindowController.swift` (второй чекбокс: свойство, `.target`/`.action`, `selectionMemoryRow` в `addArrangedSubview`, состояние в `applyFrecencyControls()`), `Tests/SnippetSelectionMemoryTests.swift`.
**Размер:** ~200 строк.

Схема v1 уже содержит ключи `b` и `bc`, поэтому PR 3 не меняет версию формата.

### PR 4 — опционально, позже

`snippets-cli list --by-frecency` / `snippets-cli usage`. Возможно только потому, что данные — файл, а не `UserDefaults`. Требует добавить `SnippetFrecency.swift` и `SnippetUsageDocument.swift` в Sources цели CLI (`project.pbxproj:206-213`) — и дешевле, чем казалось: `FuzzyMatch.swift` там **уже** есть, так что сопоставление доступно бесплатно.

---

## 10. Тесты

`grep -c "Tests" Snippets.xcodeproj/project.pbxproj` возвращает **0** — каталог `Tests/` по-прежнему не входит ни в одну цель Xcode. Чистое ядро и его тесты подключены к тестовому пакету-оверлею SwiftPM через относительные символические ссылки `CorePackage/Sources/SnippetsCore` и `CorePackage/Tests/SnippetsCoreTests`. Поэтому математика, компараторы, формат файла **и чистая логика записи** (`shouldCoalesce`, `flushDelay`) живут в `snippets/Core/`, а `swift test` проверяет ровно те же исходники, которые компилирует приложение.

Запуск:

```bash
swift test --package-path CorePackage --filter FrecencyRankingTests
```

Тесты слияния, записи и изоляции каталога usage запускаются отдельно через `swift test --package-path CorePackage --filter UsageRecordingTests`; без `--filter` выполняется весь набор `SnippetsCoreTests`.

### Математика распада

```swift
// период полураспада ровно 14 суток
assertClose(SnippetFrecency.growth(epoch: 0, now: 14*86_400,
                                   halfLifeSeconds: SnippetFrecency.halfLifeSeconds),
            2.0, tolerance: 1e-9, "one half-life doubles the epoch-frame weight")
assertClose(SnippetFrecency.growth(epoch: 0, now: 56*86_400, halfLifeSeconds: ...),
            16.0, tolerance: 1e-9, "four half-lives")

// эквивалентность порядка во времени (главная теорема)
// weights, набранные в t0, t0+3d, t0+40d, дают ОДНУ И ТУ ЖЕ перестановку
// при оценке в t0+40d и в t0+400d.

// установившиеся значения — сверить с §3.2 с точностью 0.5%
// 8/день -> 162.08 ; 4/день -> 81.29 ; 2/день -> 40.90 ; 1/день -> 20.70
// 3/неделю -> 9.17 ; 1/неделю -> 3.41 ; 1/месяц -> 1.29

// ритм «рабочий день» ФАЗОЗАВИСИМ — тест обязан фиксировать фазу:
assertClose(businessDaySteadyState(phase: .afterFriday), 15.50, tolerance: 0.01,
            "weekday rhythm peaks right after a Friday use")
assertClose(businessDaySteadyState(phase: .afterMonday), 14.36, tolerance: 0.01,
            "weekday rhythm bottoms right after a Monday use")
// теста «14.93» нет: это непрерывное приближение, оно не воспроизводится
// ни в одной точке цикла.

// затухание разовых всплесков
assertClose(6 * pow(2.0, -45.0/14.0), 0.6465, tolerance: 1e-3, "6 uses 45 days ago")
assertClose(0.25 * pow(2.0, -30.0/14.0), 0.0566, tolerance: 1e-4, "one copy after 30 days")

// одно копирование ниже порога значимости, одно раскрытие — нет
assertTrue(SnippetFrecency.copyWeight < SnippetFrecency.meaningfulnessFloor, "one copy is noise")
assertTrue(SnippetFrecency.expandWeight >= SnippetFrecency.meaningfulnessFloor, "one expansion counts")

// зажимы
// growth(epoch: now + 10 лет) == 1.0 ровно (часы назад)
// growth(epoch: now - 10 лет) конечен и <= 2^(400/14)
// clamp(weight: .nan) == 0 ; clamp(weight: .infinity) == maxWeight ; clamp(-5) == 0

// rebase сохраняет порядок и отношения
// rescaled(doc, toEpoch: doc.epoch + 45d): попарные отношения сохранены до 1e-9,
// перестановка идентична, и потолок привязок (weight <= cap * growth) уцелел.
```

### Компаратор

```swift
// 1. Тождество при выключенной фиче — САМЫЙ ВАЖНЫЙ ТЕСТ.
// 300 случайных библиотек x 40 запросов: с FrecencySnapshot.empty порядок
// поэлементно равен дофичевому.

// 2. Frecency не пересекает более высокий тир (свойство, 5000 троек):
// если различаются score, ИЛИ keywordRank, ИЛИ isPinned — результат ranks()
// ИДЕНТИЧЕН со снимком и без него.

// 3. Точное ключевое слово бьёт горячую frecency (сценарий-катастрофа).
// `sig`/keyword "sig", frecency 0 vs "Signature Block"/keyword "sigblock",
// frecency 500. Запрос "sig": оба score 17, keywordRank 3 > 2 -> row 0 = `sig`.
assertEqual(rankedIDs(query: "sig").first, sigID, "exact keyword outranks hot frecency")

// 4. Pin — строгий внешний ключ, везде.
assertEqual(SnippetFrecency.emptyQueryRanks(lhsPinned: false, lhsFrecency: 1e6, lhsOrder: 99,
                                            rhsPinned: true,  rhsFrecency: 0,   rhsOrder: 0),
            false, "hot unpinned never precedes cold pinned")
// то же для ranks(): bindingWeight 1e6 у незакреплённого не обгоняет закреплённый

// 5. Строгий слабый порядок (фаззинг 10 000 случайных SnippetRankingKey):
// иррефлексивность, антисимметрия, транзитивность самого отношения и
// отношения несравнимости. Без этого Array.sorted не определён.

// 6. Детерминизм: 200 элементов с массовыми дублями, 10 случайных
// перемешиваний -> 10 идентичных результатов (терминатор uuidString).

// 7. Ветка пустого запроса — починка усечения.
// 20 кандидатов -> возвращаются 8 САМЫХ ВЫСОКОРАНЖИРОВАННЫХ, а не первые 8
// в порядке отображения.

// 8. Ветка пустого запроса при всех нулях -> вход возвращается без изменений.

// 9. Не-конечное значение не доходит до компаратора: подсунуть .nan/.infinity
// в records, прогнать sanitized(), затем полную сортировку 100 элементов ->
// нет ловушки, порядок полный.

// 10. Точность ничьих FuzzyMatch (обоснование §3.3): для запросов длиной 1...5
// все сниппеты с префиксным keyword получают ОДИНАКОВЫЙ score (9/12/17/24/33),
// то есть 4-е и 5-е тире реально достижимы.
```

### Авто-раскрытие

```swift
// unambiguousExactMatch НЕ ЗАВИСИТ от frecency.
// Корпус из 200 запросов: результат идентичен при пустых весах и при
// экстремальных (один сниппет = 1e12). Frecency не разрешает ничью между
// несколькими точными совпадениями, не отменяет вето hasLongerPrefix и не
// заставляет авто-раскрытие срабатывать на неточном запросе.
// ЕСЛИ ЭТОТ ТЕСТ ПАДАЕТ — приложение печатает не тот текст в чужой терминал.
```

### Документ и хранилище

```swift
// Codable round-trip + сокращённые ключи: encode(doc) содержит ровно
// ключи v/epoch/h/w/b/rc/bc; записи — s/n/l.

// Позиция деградации: отсутствующий файл, пустой файл, "{{{", "[]", "{}",
// {"v":1} без w, 4 МБ мусора, обрезанный валидный JSON — каждый даёт
// records.isEmpty, isReadOnly == false, без throw, и следующий flush пишет
// валидный документ v1. .corrupt-файл НЕ создаётся.
// ВАЖНО: {"v":1} и {} декодируются (init(from:) тотален), а не падают
// в ветку «повреждён».

// зонд версии идёт ПЕРВЫМ:
//   {"v":99} -> isReadOnly == true, records пусты, и после record()+flush()
//   файл БАЙТ В БАЙТ прежний.
//   {"v":99,"w":"это строка, а не словарь"} -> полный декодер провалился бы,
//   но зонд отрабатывает раньше -> isReadOnly == true (а НЕ «начать с нуля»).
//   Этот случай — вся причина существования зонда.

// halfLifeDays: 30 в файле -> при загрузке rebase по H=30, затем документ
// записан с h=14, а отношения текущих распадных весов сохранены до 1e-9.

// sanitize враждебных значений: s: 1e400 (+Inf), s: NaN, s: -5, epoch: -1e18,
// l: 9e99, n: -3, n: Int.max, rc: NaN, ключ не-UUID, ключ привязки длиной 40 —
// каждое отброшено или зажато; ловушек нет.

// join — полурешётка: для 500 случайных пар
// join(a,b) == join(b,a), join(a,a) == a, join(join(a,b),c) == join(a,join(b,c))
// (веса с допуском 1e-9).

// merge между процессами: два стора над одним временным каталогом (через
// параметры folderURL/fileURL у mergeAndWrite) пишут разные сниппеты;
// flush в обоих порядках и вперемешку -> итоговый файл содержит записи
// обоих, ни один вес не превышает однопроцессное значение, ни один ключ
// не потерян.

// merge с разными epoch: документ с epoch на 45 дней старше нормализуется
// к новой эпохе ДО max(); порядок внутри старого документа сохранён.

// merge НЕ воскрешает сбросы:
//   диск = 200 записей; в памяти eraseAll() (recordsClearedAt = now) + одно
//   новое использование -> после mergeAndWrite в файле РОВНО одна запись.
//   диск = непустая b; в памяти forgetAllBindings() -> в файле b == {}.
//   Обратный порядок (сброс на диске, старая память) -> тоже пусто.
//   Идемпотентность: повторный merge того же файла ничего не меняет.

// обрезка — ДВА РЕЖИМА:
//   безусловно на каждом flush: записи ниже pruneThreshold * growth удалены;
//     привязки ниже порога удалены; опустевшие ключи удалены;
//   только при превышении: 5100 записей -> ровно 5000, ПЕРВЫМИ выброшены
//     осиротевшие UUID, затем наименьшие по весу среди живых;
//     500 ключей привязок -> 400, в каждом ключе -> топ-4.
//   при 4999 записях и 4000 сирот НИ ОДНА сирота не удалена (лимит не
//     превышен) — это и есть защита от «удалил -> flush -> ⌘Z -> история
//     обнулилась»;
//   при пустом или nil liveIDs обрезка сирот НЕ выполняется вовсе.
```

### Запись

```swift
// Всё через инъекцию часов (store.now = { fakeClock }) и чистые
// SnippetFrecency.shouldCoalesce / .flushDelay — иначе эти тесты
// непроверяемы из standalone-бинаря.

// схлопывание по ПАРЕ (id, event):
// два record(.expansion, A) через 0.2 с -> вес A вырос один раз;
// A затем B через 0.2 с -> оба выросли; два A через 2.0 с -> вырос дважды;
// record(.copyFromApp, A) затем record(.expansion, A) через 0.2 с ->
//   ОБА засчитаны (разные типы событий = разные намерения).

// соотношение весов: четыре record(.copyFromApp) вне окна схлопывания
// == один record(.expansion). Допуск 1e-5 ПРИ РЕАЛЬНЫХ ЧАСАХ (за ~3 с
// growth уходит на ~1.7e-6) либо 1e-12 при замороженных.

// сорванное принятие ничего не пишет: прогнать acceptSelectedSuggestion по
// путям .unsafe / .missingTrigger / mismatch, возвращающим на :469-474, и по
// раннему возврату :436 -> records не изменились. Затем успешное принятие ->
// ровно одна запись весом 1.0.

// expand(deleteCount: 0) ничего не пишет (guard на :995 предшествует записи).

// debounce: flushDelay(now:firstDirtyAt:) — 200 событий за 30 симулированных
// секунд -> <= 7 записей на диск.
// потолок устаревания: событие каждые 4 с в течение 200 с -> >= 3 записи.
// flush() без грязного состояния — no-op; с грязным — ровно одна запись.
// flush(synchronously: true) возвращает управление ПОСЛЕ того, как байты
// лежат на диске (проверяется чтением сразу после вызова).

// kill switch: killSwitch = true -> каталог Usage/ НЕ создан, файл не создан,
// records пусты, makeRankingSnapshot() == .empty, 1000 record() -> ноль
// обращений к ФС.
// rankingEnabled = false -> makeRankingSnapshot() == .empty, НО record()
// продолжает мутировать и сохранять (повторное включение — не холодный старт).

// дефолты: при чистых UserDefaults isRankingEnabled == true и
// isSelectionMemoryEnabled == true. Тест сломается, если кто-то заменит
// flag(_:default:) на UserDefaults.standard.bool(forKey:).
```

### Selection memory (PR 3)

```swift
// привязка выигрывает ничью и только ничью:
// "re" -> reply(1.0) vs req(0): при score 12 == 12 и keywordRank 2 == 2 -> reply row 0.
// при score 17 vs 12 -> побеждает score, привязка не читается.

// НАСЫЩЕНИЕ: 50 подряд принятий A под ключом "re" при замороженных часах ->
// bindings["re"][A] == growth, а НЕ 50 * growth.
assertClose(table[A]!, growth, tolerance: 1e-9, "binding weight saturates at cap")

// выход за одну коррекцию ИЗ НАСЫЩЕННОЙ привязки (главный тест §3.4):
// 50 принятий A, затем ОДНО принятие B -> A == 0.7*growth, B == growth,
// ranks() ставит B выше A. Тест со стартом из одного принятия недостаточен —
// он проходил бы и на сломанной безлимитной формуле.
assertEqual(SnippetFrecency.bindingRecoveryCorrections, 1, "cap 1.0 means one correction")

// то же после rebase и после merge: инвариант weight <= cap * growth уцелел,
// и одна коррекция по-прежнему выводит.

// префикс длиной > 8 не пишется и не читается:
// bindingKey(for: "screenshotpath") == nil

// авто-раскрытие не пишет привязку: bindingQuery == nil на ВСЕХ ТРЁХ путях
// (:727-732, :700-711, :788-799) -> bindings остаётся пустым независимо
// от длины запроса.

// висячий запрос не приписывается чужому раскрытию:
// установить pendingSelectionMemoryQuery, уйти по раннему возврату :436,
// затем выполнить авто-раскрытие из typedBuffer (которое НЕ вызывает
// activateSuggestions) -> bindings пусты.

// copy/paste в приложении не пишут ни привязку, ни контекст приложения.

// выключение selectionMemoryEnabled -> makeRankingSnapshot().bindings == [:],
// record не пишет привязок, forgetAllBindings() очищает document.bindings,
// следующий flush сохраняет документ с b == {} ДАЖЕ ЕСЛИ на диске лежит
// непустая таблица (bindingsClearedAt).
```

### Гигиена экспорта

```swift
// exportedSnippetObjectsHaveExactlyNineKeys: экспортировать библиотеку,
// распарсить JSON, у КАЖДОГО объекта сниппета набор ключей ровно
// {id,name,keyword,content,tags,isEnabled,isPinned,createdAt,updatedAt}.
// Падает в тот день, когда кто-то добавит поле использования в Snippet —
// ДО того, как это отгрузится как утечка приватности.

// deepLinkPayloadCarriesNoUsage: набор ключей payload ровно
// {version,name,keyword,content,tags}.

// importPreservesLocalUsage: сниппет с 4412 использованиями; импорт
// share-ссылки с тем же keyword (правило 2, восстанавливает локальный id)
// и экспорта коллеги с тем же id (правило 1) -> запись выживает в обоих
// случаях. Импорт с НОВЫМ UUID -> новый сниппет стартует с нуля.

// snippets.json не тронут: записать 100 использований, завершить приложение,
// сравнить snippets.json побайтово с копией до фичи.
```

### Ручная проверка

1. **Изоляция каталога (блокирует мерж).** См. PR 1, п. «Ручная проверка» — включая сценарий первого запуска с удалённым `Usage/`.
2. **Стабильность сессии под пальцами.** В TextEdit и в Chromium-приложении набрать `\` и затем запрос посимвольно; убедиться, что ни одна строка не двигается иначе как вследствие изменения запроса. Конкретно — что перерисовки на 18 мс и 60 мс не перетасовывают список.
3. **Выделение не крадут.** Открыть панель, спуститься на две строки, продолжить печатать; убедиться, что сохранение по id (`SuggestionPanelController.swift:184-193`) держит строку пользователя.
4. **Тап выживает под нагрузкой.** Удерживать печатную клавишу на автоповторе внутри активной сессии 10+ секунд на библиотеке из 500 сниппетов; убедиться, что в Console нет `.tapDisabledByTimeout` и раскрытие работает после.
5. **Круг через CLI.** Записать 100 использований, запустить установленный `snippets-cli` (добавить и удалить сниппет), перезапустить приложение и убедиться, что ранжирование пережило внешнюю перезагрузку (которая чистит undo/redo, `SnippetStore.swift:706-707`).
6. **Завершение записывает.** Записать использование, немедленно ⌘Q, перезапустить — использование на месте. Проверяет именно `flush(synchronously: true)`: с асинхронным вариантом этот сценарий тихо теряет данные.
7. **Удаление и отмена.** Удалить сниппет с богатой историей, дождаться flush (или вызвать его), нажать ⌘Z, перезапустить приложение — счётчик в контекстном меню на месте.

---

## 11. Открытые вопросы

1. **Вес копирования: 0.25 или 1.0?** Спецификация фиксирует 0.25, чтобы одно копирование лежало ниже порога значимости 0.5. Но если основной рабочий процесс автора — ↩ / «Copy Snippet» из списка приложения, его frecency будет накапливаться вчетверо медленнее, чем у пользователя клавиатурных раскрытий. Это одна константа (`SnippetFrecency.copyWeight`), но **формат файла не различает типы событий**, поэтому задним числом соотношение из сохранённых данных не восстановить. Решать до отгрузки PR 1.

2. **Оверлей ⌘F (и основной список) — что делать в v2?** Сейчас `SearchSuggestionOverlayView` берёт `prefix(8)` от неранжированного массива (`:59-63`), то есть показывает «первые 8 подстрочных совпадений». Два взаимоисключающих варианта: (а) отсортировать *копию* в `updateSearchSuggestionOverlay()` (`ViewController+SearchSuggestions.swift:34-47`) — тогда оверлей и таблица под ним будут показывать разный порядок; (б) добавить в `…`-меню checkmark-подменю «Sort by ▸ Manual / Most Used» с обновлением снимка **только** при активации окна и смене режима — тогда порядок согласован, но каждое обновление может выйти за порог 40 изменений в `applyAnimatedListUpdate` и упасть в полный `reloadData()`, то есть мигнуть при активации окна. В v1 не делается ничего.

3. **PR 3 (selection memory) — отгружать?** Это единственное место, где рецензенты разошлись, и единственное место, где на диск попадает то, что пользователь напечатал. Он специфицирован полностью и совместим со схемой v1 (ключи `b` и `bc` резервируются в PR 1), так что решение «остановиться на PR 2» ничего не ломает и оставляет дверь открытой. Без него панель ранжируется по частоте, но не даёт рефлекса «те же три клавиши — всегда тот же результат», который отличает Raycast.

4. **`bindingWeightCap = 1.0` — не слишком ли грубо?** При потолке 1.0 привязка вырождается в «кого выбрали последним под этим префиксом» и перестаёт различать «выбираю A в 80% случаев» и «выбрал A один раз». Взамен обещание §3.4 становится теоремой с ровно одной коррекцией. Альтернатива `cap = 3` сохраняет градации, но выход занимает 4 коррекции (`⌊ln 3 / ln(1/0.7)⌋ + 1`) — и это уже «панель ведёт себя странно почти неделю». Обе константы читаются из `SnippetFrecency`, файл при их смене не мигрируется (потолок — свойство записи, не данных), поэтому решение обратимо в любой момент. Решать вместе с вопросом 3.
---

## 12. Отклонения при реализации

Реализовано целиком: PR 0, PR 1, PR 2, PR 3. PR 4 (`snippets-cli --by-frecency`) не делался — спека помечает его как опциональный.

Открытые вопросы §11 закрыты значениями по умолчанию из самой спеки: `copyWeight = 0.25`, `bindingWeightCap = 1.0`, selection memory отгружена. Оверлей ⌘F и основной список не тронуты (вопрос 2 — «в v1 не делается ничего»).

Шесть мест, где код сознательно расходится с текстом спеки:

1. **`SnippetFrecency.clamp(weight:)` при `+infinity` возвращает `maxWeight`, а не 0.** Спека противоречила сама себе: §4.2 приводит `guard weight.isFinite else { return 0 }`, а §10 требует `clamp(.infinity) == maxWeight`. Выбран второй вариант: переполнение означает «очень много», и терять из-за него всю историю сниппета — худший отказ, чем насыщение. `NaN` смысла не несёт и по-прежнему даёт 0. Значения **с диска** держатся строже: `SnippetUsageFile.sanitized` отбрасывает любое не-конечное, потому что там это недоверенный ввод, а не результат нашей арифметики.

2. **`forget(snippetID:)` дополнительно ставит `recordsClearedAt` и `bindingsClearedAt`.** Без этого пункт «Reset Usage» из контекстного меню не работал бы: `join` — это `max`, он не умеет удалять, поэтому следующий merge воскресил бы запись прямо с диска. Цена — параллельный второй экземпляр приложения теряет свои несброшенные добавления; `snippets-cli` этот файл не трогает, так что на практике случай сводится к одновременно запущенным debug- и release-сборкам.

3. **`eraseAll()` пишет пустой документ с маркером вместо удаления файла.** Удаление потеряло бы маркер, и параллельный процесс восстановил бы всё при первом же merge. Записанный файл не содержит пользовательских данных вовсе (`w` и `b` пусты), так что приватностного проигрыша нет.

4. **`mergeAndWrite` и `pruned` принимают явный `now:`.** Иначе обрезка по `pruneThreshold · growth(now)` недетерминирована и §10 её не проверить.

5. **`rescaled` принимает целевой `halfLifeDays`.** При смене константы точного преобразования кадра не существует — сохраняются только значения в один момент времени. Параметр делает merge документов с разными периодами полураспада определённым: значения совпадают в точке слияния.

6. **Тест «ритм рабочего дня» обязан отбрасывать использования *после* точки чтения.** Значения §3.2 (15.50 и 14.36) верны, но формулировка не оговаривала это, а наивная симуляция даёт 16.66 и тест выглядит как провал математики.

### Автоматизировано из «ручных проверок» §10

`Tests/UsageDirectoryIsolationTests.swift` заменяет пункт 1 (блокирующий мерж): ставит `DispatchSource` на временную папку ровно как `SnippetStore.startObservingExternalChanges()`, делает 20 атомарных записей в `Usage/`, проверяет, что монитор молчал, — и **негативным контролем** проверяет, что запись прямо в родительскую папку его будит. Без второй половины первая ничего не доказывает.

Пункты 2–7 (стабильность под пальцами, кража выделения, выживание тапа, круг через CLI, запись при ⌘Q, удаление и отмена) требуют GUI и разрешений Accessibility — остаются ручными.
