# Дослідження open-source аналогів Granola: ідеї та баги для Waffle

Жовтень 2026. Прочитано вихідний код і трекери задач ~20 проєктів, плюс документація Apple, форуми розробників і бенчмарки моделей. Номери рядків — для коміту `46e6ab8`.

## Що дивились

| Проєкт | Стек | Системний звук | ASR | Чим цікавий |
|---|---|---|---|---|
| **Hyprnote → [fastrepl/anarlog](https://github.com/fastrepl/anarlog)** | Tauri + Rust + Swift | Core Audio process tap | Parakeet EOU (live) + Parakeet TDT v3 (batch), CoreML | Найзріліший: нейро-AEC + echo gate, watchdog-и, детекція дзвінків, календар, повторний прохід після зустрічі |
| **[Meetily](https://github.com/Zackriya-Solutions/meeting-minutes)** (~31k ★) | Tauri + Rust | Core Audio tap (cidre), SCK вимкнений | Whisper / Parakeet ONNX | Silero VAD, map-reduce саммарі, Bluetooth-трюки |
| **[pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber)** | Swift + FluidAudio + Claude CLI | Per-app CATap | Parakeet TDT v3 | **Найближчий до Waffle.** Словник термінів, впізнавання голосів між зустрічами, монітори «канал замовк», детектор дрейфу частоти |
| **[OpenOats](https://github.com/yazinsai/OpenOats)** (колишній OpenGranola) | Swift + FluidAudio | Global tap | Parakeet / WhisperKit | Silero VAD streaming, суворий echo-фільтр, імена з календаря, watchdog |
| **[Muesli](https://github.com/Muesli-HQ/muesli)** | Swift | Tap, SCK як запасний | Parakeet та ін. | Детекція зустрічі по камері, «Join & Transcribe» з календаря, нейро-AEC |
| **[screenpipe](https://github.com/mediar-ai/screenpipe)** | Rust | Пішов з SCK на tap | — | Accessibility-first читання екрану, OCR тільки при зміні, голосові відбитки, правила іменування з календаря |
| **[FluidAudio](https://github.com/FluidInference/FluidAudio)** | Swift (вже наша залежність) | — | Parakeet v3/ultra на ANE | VAD, офлайн-діаризація, ембедінги голосів |
| Vexa, Attendee | боти | — | — | Як прив'язувати імена до голосів (лаги, пороги) |
| VoiceInk, Hex, WhisperKit, slop-granola, heed, ownscribe, Recap, Vibe | різне | — | — | Окремі прийоми, див. нижче |

**Висновок одним абзацом.** Модель (Parakeet TDT v3) у Waffle правильна — для української альтернатив немає (Kyutai/Moonshine — англ., Voxtral — без української, Apple SpeechAnalyzer — без uk_UA). Виграш не в моделі, а в: (1) межах вікон і логіці фіксації речень, (2) надійності захоплення звуку, (3) другому проході після дзвінка, (4) захопленні звуку через Core Audio tap замість ScreenCaptureKit.

---

## 1. Баги (перевірені по коду)

Відсортовано за шкодою.

### B1. `dropEcho` видаляє справжні короткі репліки «Me» — `Logic.swift:99-106`
Правило: ≥60% моїх слів є в *множині* слів будь-якого рядка «Them» у вікні ±30 с. Однослівна відповідь дає 100% збіг з будь-яким рядком, де це слово є. Відтворено на симуляції — **видаляються**:
«Yes.», «Okay.», «Right, exactly.», «Makes sense.», «No, no, no.», «Я згоден.», «Let's do Monday.», «Can you hear me?» (якщо раніше хтось сказав «Yes, I can hear you»).
Ще гірше: `abs()` дивиться і *вперед* — якщо я продиктував код, а мені його повторили, видаляється *мій* рядок. Видалення остаточне, навіть якщо рядок «Them» потім змінився.

**Як у інших:** OpenOats — вікно 1.75 с, Jaccard ≥ 0.78, мінімум 4 слова; slop-granola — 1.5 с, впорядкований LCS ≥ 0.6, для <3 слів потрібне перекриття в часі; meeting-transcriber — dedup *вимкнений за замовчуванням*, бо «їсть тихі репліки».
**Фікс:** вікно ±2–3 с, ≥3 слова, впорядкований збіг слів (LCS) ≥60%; Me-рядок має бути *після* Them. Симуляція: всі короткі репліки зберігаються, обидва існуючі тести проходять. Краще — позначати `echo=true`, а не видаляти.

### B2. Фільтр `junk` видаляє реальну мову — `Logic.swift:67`
Це фільтр галюцинацій Whisper (титри YouTube). Parakeet — трансдюсер без мовної моделі тексту, таких фраз не вигадує. Зараз видаляються: «Thank you.» (часта фраза в кінці дзвінка), «Thanks for watching the demo, everyone.», «Додайте субтитри до відео.», «Продолжение следует в четверг.», а жадібне `\(.*\)` видаляє «(Laughs) okay, fine (really)».
**Фікс:** лишити тільки `^\W+$` і рядок, що складається *лише* з `[...]`/`(...)`.

### B3. Системний звук може тихо зникнути до кінця зустрічі — `Recorder.swift:344`
`SysOutput` оголошує `SCStreamDelegate`, але не має `stream(_:didStopWithError:)`. SCStream зупиняється при: від'єднанні монітора, сні/пробудженні, -3805/-3821 («stopped by the system»). Waffle бачить це як тишу: запис іде далі тільки з «Me», без попередження. Це той самий баг, що в ListenToMe #107, meet-recorder #22; screenpipe саме через це пішов з SCK.
**Фікс:** обробник + перезапуск з backoff (0.25 → 4 с), заново брати `SCShareableContent`; перезапуск на `NSWorkspace.didWakeNotification`; watchdog «немає буферів N с, а дзвінок іде» → банер «System audio lost, reconnecting…».

### B4. `content.displays[0]` — `Recorder.swift:82`
Порожній масив (headless Mac mini, одразу після пробудження — screenpipe це бачив) → падіння. До того ж `[0]` не обов'язково головний дисплей: якщо це зовнішній монітор, його від'єднання вбиває потік (B3).
**Фікс:** `content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first`, інакше помилка.

### B5. Зупинка під час `start()` лишає мікрофон/потік увімкненими і може обвалити застосунок — `Recorder.swift:45-98, 226, 345`
`start` чекає `requestAccess` і `SCShareableContent`. Якщо в цей момент End Meeting/автостоп → `teardown` (stream ще nil), а потім `start` продовжує: запускає мікрофон, SCStream, таймер і observer *після* зупинки. Помаранчева точка лишається. `SysOutput.rec` і `Segmenter.rec` — `unowned`; коли Model відпускає Recorder, наступний буфер = crash. Те саме, якщо `stopCapture` довше 2 с (семафор, рядок 137).
**Фікс:** `guard !stopped` після кожного `await`; `weak` замість `unowned`; `removeStreamOutput` у teardown.

### B6. Обробник зміни аудіопристрою: падіння/гонки — `Recorder.swift:70, 100-114`
- `queue: nil` → `startMic()` на довільному потоці, без перевірки `stopped`, може виконатись паралельно з `teardown`.
- Без debounce: підключення AirPods дає кілька подій поспіль (Hyprnote #7533 — цикли перезапусків).
- `input.outputFormat(forBus:0)` під час перемикання буває 0 Гц / 0 каналів → `installTap` кидає NSException, яку Swift не ловить → SIGABRT (meeting-transcriber #379).
- Якщо VPIO не може зібрати внутрішній aggregate (мікрофон AirPods + динаміки MacBook: `err=-10875`), `engine.start()` падає і «Me» мертвий до кінця — запасного варіанту без VPIO немає.
**Фікс (як у Hex):** окрема серійна черга, debounce 250–300 мс, лічильник поколінь, перевірка `sampleRate > 0 && channelCount > 0`, при помилці — спробувати без voice processing; watchdog «мікрофон увімкнений, але буферів немає 3 с».

### B7. Час рахується за `Date()` при надходженні буфера — `Recorder.swift:255-263`
- Буфер, що прийшов на >0.3 с пізніше (навантаження GPU від ASR/OCR), — це не втрачене аудіо, але код закриває вікно *посеред речення* і назавжди зсуває годинник вперед.
- Дрейф годинників мікрофона і системного звуку (30–100 ppm ≈ 0.1–0.4 с/год) не коригується у бік «назад»; при повільному мікрофоні кожні кілька хвилин спрацьовує хибна «пауза».
- Це впливає на порядок Me/Them, вікно ехо, прив'язку реплік до голосів.
**Фікс:** брати `AVAudioTime.hostTime` з тапа (зараз `{ buf, _ in` його викидає) і `CMSampleBufferGetPresentationTimeStamp` для SCK; «розрив» = стрибок у часі *семплів*, а не запізнення колбеку (так робить OBS). Мінімум — для мікрофона правило розриву не застосовувати або підняти до ~2 с.

### B8. Діаризатору згодовуються ідеальні нулі — `Recorder.swift:158-162`
Паузи заповнюються точними нулями, до 30 хв за раз (28.8 млн float ≈ 115 MB одним виділенням, ~24 с CPU на обробку тиші). LS-EEND робить *кумулятивну* нормалізацію середнього по всій сесії з `logFloor 1e-10` (`LSEENDPreprocessor.swift:78, 263-274`). FluidAudio #981: на нулях офлайн-діаризатор бачить 32 мовців замість 4 — той самий механізм.
**Фікс (~10 рядків):** додавати дизер ±1e-4 до всього звуку для діаризатора; заповнювати розрив максимум ~2 с, решту — зсувом часу в `emit`.

### B9. Визначення дзвінків — `Recorder.swift:380`, `Panels.swift:229`, `Model.swift:44`
- Фільтр `com.apple.*` відкидає `com.apple.avconferenced` (саме він тримає мікрофон у FaceTime), `callservicesd` (дзвінки з iPhone), `com.apple.WebKit.GPU` (Meet/Teams у **Safari**). Нема промпту і нема автостопу.
- Chrome показується як «Google Chrome Helper» — треба підніматися до батьківського `.app`.
- Промпт з'являється одразу для *будь-якого* застосунку з мікрофоном: диктування (Superwhisper, VoiceInk, Wispr Flow), Raycast, Loom. OpenOats #726 — 11 хибних записів за 45 хв.
- Автостоп через 6 с без мікрофона: Zoom/Teams коротко відпускають мікрофон при зміні пристрою, переході в breakout-кімнату, з waiting room; AirPods перемикаються в HFP 2–5 с.
- `Timer.scheduledTimer` не спрацьовує, поки відкрите меню чи йде скрол/ресайз (потрібен `.common` mode).
**Як у Hyprnote:** список ігнорування (диктування, IDE, рекордери, ChatGPT/Claude), промпт тільки після 15 с активного мікрофона, cooldown 10 хв, автостоп з підтвердженням 5 с і лише від застосунку, що почав сесію; для браузерних зустрічей — спитати.

### B10. Імена з вікна дзвінка — `ScreenNames.swift`, `Logic.swift`, `Model.swift`
- `ScreenNames.swift:42` читає **всі** запущені Zoom/Teams. Teams у фоні під час Zoom-дзвінка → імена з чатів і контактів потрапляють у «People seen in the call» і в саммарі.
- `Logic.swift:503` обрізає на «,»: корпоративне «Petrenko, Oleg» → «Petrenko» (одне слово — не потрапляє в ростер); і губиться «(Host, me)» / «(You)», тож Waffle не знає, яка плитка — користувача.
- `Model.swift:362` викидає *весь* огляд екрану, поки мікрофон чує звук (енергетичний поріг — спрацьовує і на клацання клавіатури). Краще прибирати лише ім'я самого користувача.
- `Logic.swift:557` ім'я, на яке претендують два голоси, не отримує жоден. LS-EEND часто розбиває одну людину на два голоси → людина ніколи не отримує ім'я. Дозволити, якщо голоси ніколи не перекриваються в часі.
- `Logic.swift:521` «not speaking» відкидається тільки англійською; «не говорить» рахується як «говорить».
- `ScreenNames.swift:63` `AXManualAccessibility` вмикається і ніколи не вимикається — Chromium/Teams лишається в режимі accessibility (CPU; screenpipe описує повтор натискань клавіш). Вимикати в `stop()`.
- `ScreenNames.swift:89` вікно 2560 pt знімається з масштабом ~0.7 — рамка 2 pt розмивається до ~1 px тьмяного кольору і може не пройти `frameHue`. Для піксельної перевірки — нативний масштаб.
- Ризики (не перевірені на Mac): Zoom за даними screenpipe не віддає `AXWindow`, лише меню; у Speaker View (за замовчуванням у Zoom) рамки немає взагалі; найбільше вікно ≥300×200 може бути оверлеєм шерингу чи головним вікном Teams, а не вікном зустрічі.

### B11. Дрібні
- `Recorder.swift:184`: збій `parakeet_full` повертає `[]` → якщо це фінальний прохід, текст вікна стирається назавжди. Повертати `nil` / лишати останню гіпотезу.
- `Logic.swift:121-134`: «Mr. Smith will join at 3 p.m. tomorrow.» → три «речення», всі фіксуються; розріз по середині 0–80 мс проміжку потрапляє на початок наступного слова. Грецький «;» не вважається кінцем питання. Потрібен список скорочень (Mr./Dr./p.m./e.g./т.д./ст.).
- `micOn` пишеться з main, читається з аудіопотоку без синхронізації.
- Немає обробки сну: після пробудження `lastSpeech` старіший за 180 с → миттєвий стоп «long silence».
- Ризик: VPIO повертає 3/5/7/9 каналів залежно від заліза; якщо канал 0 нульовий, а інші ні — брати найгучніший.

---

## 2. Ризики якості розпізнавання (дизайн)

1. **Зафіксовані речення розпізнаються без лівого контексту.** Після кожної фіксації вікно починається з розрізу, і коротке «Так.» може бути зафіксоване з вікна ~2.5 с після *одного* проходу. Ваш же коментар: 51% слів правильно на 2 с проти 95% на 15–30 с. Інші: whisper_streaming лишає останнє зафіксоване речення як контекст і фіксує лише текст, що збігся у двох проходах (LocalAgreement-2); WhisperKit не підтверджує 2 останні сегменти; FluidAudio — 2 с ліворуч + 11 с + 2 с праворуч і ≥10 с контексту; NeMo для v3 — `left=10 s, chunk=2 s, right=2 s`.
2. **Плутанина uk/ru на коротких вікнах.** Parakeet v3 не має токена мови; FluidAudio описує «стрибки скрипту» на коротких вікнах (#512). Саме короткі вікна після фіксації — де це трапляється.
3. **Примусовий розріз на 30 с без перекриття** (`Recorder.swift:284`) → розірвані/подвоєні/загублені слова на стику. Пауз-детектор (поріг 0.2× середнього RMS) ламається при помірному шумі: при SNR ~12 дБ *кожне* вікно ріжеться примусово на 30 с.
4. **Обчислень вистачає.** Найгірший випадок ≈ 4.7× реального часу ≈ 6% GPU на джерело. Проблема не в швидкості, а в межах.

---

## 3. Ідеї, відсортовані за користю/зусиллями

### Швидкі перемоги (години)
1. **Переписати `dropEcho`** (B1). Найбільша користь на рядок коду.
2. **Обрізати `junk`** (B2).
3. **`didStopWithError` + перезапуск + `displays.first(main)`** (B3, B4).
4. **`stopped`-перевірки в `start()`, `weak` замість `unowned`** (B5).
5. **Дизер для діаризатора замість нулів** (B8).
6. **Гігієна детекції дзвінків** (B9): avconferenced/callservicesd/WebKit.GPU → FaceTime/iPhone/Safari; хелпери → батьківський `.app`; список ігнорування; поріг 15 с; автостоп 15–20 с або перевірка `kAudioProcessPropertyIsRunningOutput` (якщо застосунок ще відтворює звук — дзвінок іде).
7. **Імена:** тільки процес, що в дзвінку (фільтр через `callApps()`); розпізнавати «(me)/(You)/(Я)/(Вы)» до обрізання; «Прізвище, Ім'я»; вимикати `AXManualAccessibility` на stop.
8. **Дзеркалити mute у Zoom** — Hyprnote читає меню Zoom «Meeting › Mute Audio / Unmute Audio» через AX і вимикає «Me». У Waffle AX вже є.

### Середні (дні)
9. **Silero VAD з FluidAudio замість відносного RMS.** Вже в залежностях, ~1200× реального часу. `VadManager.processStreamingChunk` на 4096 семплів; поріг 0.5 / вихід 0.35, мінімальна тиша 300 мс для оновлень і 0.5–0.75 с для фіналу, паддінг 100 мс. Пропускати ASR на не-мові; паддити фінальні вікна 1 с нулів, як VoiceInk.
10. **Обережніша фіксація речень:** фіксувати, лише якщо текст речення збігся у 2 проходах поспіль і вікно ≥4–5 с; лишати 2–5 с лівого контексту після розрізу (токени з `t0 < cut` відкидати); різати на `last.end + 1–2 кадри` або в енергетичній долині, не посередині. Замість жорсткого 30 с — фіксація на найбільшому проміжку між токенами за 1–8 с до кінця (як `silenceAlignedChunkStarts` у FluidAudio).
11. **Сигнальний echo gate перед ASR (Hyprnote):** для кожного кадру мікрофона — кореляція з системним звуком на лагах ±100 мс; якщо ≥0.55 і залишок ≤0.45 — обнулити кадр. Доповнює текстовий `dropEcho`.
12. **Режим навушників (Hyprnote #7273):** якщо всі активні виходи — навушники (`kAudioStreamPropertyTerminalType`, тип транспорту), вимикати VPIO і `dropEcho`. VPIO погіршує власний голос, може переводити AirPods у HFP і їсть CPU. Бонус: у такому режимі кожне слово «Me» гарантовано користувача.
13. **Час з аудіо-годинника** (B7).
14. **Календар (EventKit):** назва й учасники в промпт саммарі; правило 1:1 (один голос «Them» + один інший учасник → ім'я); обмеження кількості мовців для діаризації; фільтр імен з екрану через список учасників; промпт/автостарт для подій з посиланням на зустріч. Є в Hyprnote, OpenOats, Muesli, screenpipe.
15. **Глосарій:** імена з ростера/календаря + словник користувача → нечітке виправлення транскрипту (edit/фонетична відстань) + передача в промпт саммарі (meeting-transcriber `TerminologyNormalizer.swift`). Справжній CTC-буст у FluidAudio натренований на англійській — для латинських назв продуктів підходить, для кирилиці ні.

### Великі (тиждень+)
16. **ASR через FluidAudio (Parakeet `.ultra` на Neural Engine) замість whisper.cpp з Homebrew.**
    - Ті самі 25 мов з автовизначенням; FLEURS: українська 7.2% WER (v3); `.ultra` кращий за v3 в усіх 24 мовах (середнє 11.7% проти 14.8%) при тій самій швидкості; ~200× реального часу на M4 Pro.
    - Є впевненість для кожного токена (можна використати для фіксації речень).
    - Прибирає Homebrew, `unsafeFlags`, поломки після `brew upgrade`; звільняє GPU.
    - **Підводні камені:** холодний старт 30+ с (компіляція для ANE, кеш скидається після оновлення macOS) → завантажувати при старті застосунку, прогрівати 1 с тиші, *не* створювати заново на кожну зустріч (зараз `Model.swift:318`); вікна ≤15 с (ліміт енкодера 240 000 семплів; #971 — обрізані часові мітки на стиках); всі CoreML-передбачення (ASR, VAD, діаризація) — з однієї серійної черги (#661: паралельні менеджери → EXC_BAD_ACCESS); `autoreleasepool` у циклах (#320). `language:` не задавати для змішаних uk+en зустрічей.
    - Redux-варіант *гірший* для української і компілюється ~7 хв — не брати.
17. **Системний звук через Core Audio process tap замість ScreenCaptureKit.** Так зробили Hyprnote, Meetily, OpenOats, Muesli, screenpipe.
    - Потрібен лише дозвіл «System Audio Recording Only» (`NSAudioCaptureUsageDescription` — зараз його немає в `build.sh`), без повного Screen Recording і без **щомісячного** запиту macOS 15, без фіолетового індикатора запису екрану.
    - **Meetily #496:** поки йде запис екрану, у Safari + Google Meet інші не бачать камеру користувача. Waffle з display-wide SCStream на весь дзвінок майже напевно має цю проблему.
    - Точні `AudioTimeStamp` (вирішує B7 для системного звуку), не залежить від дисплеїв.
    - Взяти global tap з виключенням власного процесу (per-app taps мають баги: Teams тихий — meeting-transcriber #79, Safari VPIO — #671).
    - Tap теж треба перебудовувати (і tap, і aggregate) при зміні виходу / перемиканні AirPods A2DP↔HFP (Biscotti #88). Hyprnote тримає вихід «живим», відтворюючи тишу.
    - SCK лишається тільки для епізодичного OCR імен; як запасний варіант — те саме, але з фільтром `SCContentFilter(display:including: callApps)`.
    - Сурогатний крок без переходу на tap: `cfg.sampleRate = 16000; cfg.channelCount = 1`.
18. **Другий прохід після дзвінка (лише в пам'яті).** heed, Hyprnote, VoiceInk так роблять.
    - Тримати 16 кГц Int16 у RAM (~115 MB/год на джерело; з AAC/Opus ~10–15 MB/год), на диск не писати — обіцянка приватності зберігається.
    - На стопі: перерозпізнати VAD-шматки по ~20 с (макс 25 с) з повним контекстом + **офлайн-діаризація** FluidAudio (`OfflineDiarizerManager`, pyannote Community-1): DER **10.6% проти 20.7%** у LS-EEND, без ліміту в 4 голоси, ~11 с на годину аудіо, кількість мовців з ростера/календаря.
    - Замінювати живий транскрипт, тільки якщо новий не втратив суттєво тексту (Hyprnote: не замінювати, якщо втрачено >200 символів і лишилось <50%). Ручні правки й видалені рядки треба перенести.
    - Це ж вирішує ліміт LS-EEND «до однієї години».
19. **Впізнавання голосів між зустрічами (opt-in).** Офлайн-діаризатор віддає центроїди голосів (256 float, не аудіо). Зберігати тільки для голосів, яким користувач/екран/LLM дали ім'я; матчити з порогами meeting-transcriber (косинусна відстань < 0.40, відрив ≥0.10) або screenpipe (< 0.55, відрив 0.08; <1 с — не матчити, 1–2 с — матчити без оновлення профілю). Біометрія (GDPR ст. 9): лише на пристрої, кнопка «забути голос».
20. **Google Meet.** Найпростіше: заголовок вікна браузера «Meet – …» + OCR; найнадійніше без розширення: регіон субтитрів через AX (`role=region, aria-label="Captions"`), якщо користувач увімкнув субтитри — дає пари (хто, що) з затримкою ~1 с. Найробастніше — розширення браузера (Sussurro). Не перевірено на Mac.
21. **Текст зі слайдів (opt-in, лише текст).** OCR вікна шерингу при зміні dHash → у промпт саммарі. Зображення — лише за окремою згодою (це ламає обіцянку «нічого з екрану не зберігається»).

### Ідеї для нотаток (UX)
- Hyprnote enhance-промпт: знімок нотаток *до* зустрічі окремо від поточних; заголовки й виділення в нотатках = «обов'язково зберегти»; без загальних секцій «Overview/Participants».
- Консервативна LLM-корекція транскрипту: модель повертає лише заміни окремих слів (JSON Patch), а не переписує текст.
- Чат зустрічі через AX (Hyprnote читає чат Zoom/Meet/Teams/Slack з посиланнями) — посилання з чату в саммарі.

---

## 4. Що Waffle вже робить краще за більшість

- Окремі потоки Me/Them (Meetily змішує все в моно — їхній відкритий #642).
- Обмежені вікна з фіксацією речень (у Meetily безперервна мова тримає сегмент відкритим без ліміту — #756).
- Імена з вікна Zoom/Teams з голосуванням у часі — рівень Granola; серед open-source таке є лише в meeting-transcriber (тільки ростер Teams).
- Живий «Ask» під час зустрічі, прапорець «перервана зустріч», аудіо ніколи на диску.

---

## 5. Рекомендований порядок

1. **Тиждень 1 — баги без ризику:** B1, B2, B3+B4, B5, B8, B11 (збій → nil), детекція дзвінків (B9), фікси імен (B10). Усі логічні частини (`dropEcho`, `junk`, `personName`, `screenSpeakers`) покриваються `Tests/main.swift`.
2. **Тиждень 2 — надійність аудіо:** B6 (перезапуск мікрофона як у Hex), B7 (час з аудіо), watchdog-и, сон/пробудження, режим навушників.
3. **Далі — якість:** Silero VAD + обережна фіксація + лівий контекст → другий прохід після дзвінка з офлайн-діаризацією → календар → перехід на FluidAudio ASR (`.ultra`) → Core Audio tap.

---

## Джерела (вибірка)

- Hyprnote/anarlog: `crates/audio-actual/src/speaker/macos.rs`, `crates/aec`, `crates/owhisper-client/src/local_soniqo_live.rs`, `crates/detect/src/{zoom.rs,list/macos.rs}`, `plugins/detect/src/policy.rs`, `crates/transcript/src/batch_refine.rs`, `apps/desktop/src/stt/auto-stop.ts`
- Meetily: `frontend/src-tauri/src/audio/{capture/core_audio.rs,vad.rs,pipeline.rs,recording_manager.rs}`, issues #496, #581, #642, #756
- FluidAudio: `Documentation/{Benchmarks.md,ASR/ParakeetUltra.md,ASR/CustomVocabulary.md,VAD/Segmentation.md,Diarization/LS-EEND.md}`, `SlidingWindowAsrManager.swift:757-830`, `LSEENDPreprocessor.swift:78,263-274`, issues [#661](https://github.com/FluidInference/FluidAudio/issues/661), [#971](https://github.com/FluidInference/FluidAudio/issues/971), [#981](https://github.com/FluidInference/FluidAudio/issues/981)
- meeting-transcriber: `SpeakerMatcher.swift`, `TerminologyNormalizer.swift`, `ChannelFaultMonitor.swift`, `SilentRecordingMonitor.swift`, `SampleRateDriftDetector.swift`, issues #79, #379, #588, #671
- OpenOats: `Transcription/AcousticEchoFilter.swift`, `Audio/SystemAudioCapture.swift:472-490`, `StreamingTranscriber.swift`, `Meeting/SpeakerNameSeeder.swift`, issue #726
- screenpipe: `crates/screenpipe-audio/src/core/process_tap/macos.rs`, `screenpipe-a11y/src/tree/macos.rs`, `screenpipe-engine/src/calendar_speaker_id.rs`, `speaker/identify_gate.rs`
- Vexa: `mixed-pipeline/src/cluster-name-binder.ts` (лаги сигналів, мінімум 35% покриття, ігнор мерехтіння <1 с, перейменування лише при перевазі 2 голоси)
- Hex: `RecordingClient.swift:540-700` (новий AVAudioEngine на кожну зміну пристрою, debounce 250 мс, лічильник поколінь)
- VoiceInk: `FluidAudioStreamingProvider.swift`, `WordAgreementEngine.swift`
- whisper_streaming: `whisper_online.py:371-576`; WhisperKit `AudioStreamTranscriber.swift:55`
- OBS `plugins/mac-capture/mac-sck-common.m:29-50, 336-349`
- [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [NeMo #14430](https://github.com/NVIDIA-NeMo/NeMo/issues/14430), [Biscotti #88](https://github.com/scosman/Biscotti/issues/88), [ListenToMe #107](https://github.com/tomqwu/ListenToMe/issues/107), [Apple forum 772006](https://developer.apple.com/forums/thread/772006), [9to5Mac: щомісячний запит у Sequoia](https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/), [SpeechTranscriber locales](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales)
