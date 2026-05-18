/*
SCRIPT: CLASSIFIER_v1
ROLE: CONTROL / VALIDATION LAYER
LAYER: transformation
SOURCE: Мура
VERSION: v1 (baseline)
STATUS: NOT VALIDATED

DESCRIPTION:
Назначение: для каждого “эффективного” основного договора определить категорию:
•	DEFINITELY_SIMPLE — у семьи main нет карточек-доп.соглашений
•	DEFINITELY_COMPLEX — у семьи main есть допники
•	SUSPICIOUS_MAIN_LINK — невозможно корректно определить main (плохая ссылка, удалённый main, пустой system_number и т.д.)
Также показывает причину/особенность (feature_or_problem) и даёт “пример” lot_id, advert_id, и sample_item_status (статус предмета).
Ключевые фильтры (внутри)
•	Только лоты со статусом EXECUTED: lot_status_history.status='EXECUTED'
•	Только не удалённые: cc.deleted=false, ci.deleted=false
•	Только карточки с непустым system_number
•	Полностью исключаем PKO% типы: cc.contract_type NOT LIKE 'PKO%'
•	Исключаем BLOCKED/REVISED: NOT (cc.lock_type='BLOCKED' AND cc.lock_type_reason='REVISED')
Ключевая логика main
•	candidate_main_id:
  o	если cc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER') → main = сам cc.id
  o иначе → main = cc.main_contract_card_id
•	Если candidate_main_id невалиден → пытаемся найти ADVERT_SECOND_WINNER в цепочке prev_contract_card_id (рекурсивно).

NOTES:
Получено в текущей форме от Муры
Не валидировалось
Данный скрипт НЕ используется напрямую в процессе формирования витрины.
Требуется декомпозиция на RULE_ID и Логические блоки
Используется как эталонная модель классификации для:
- валидации логики в продукционных скриптах (SIMPLE / COMPLEX)
- поиска расхождений
- анализа проблем (feature_or_problem)

USAGE:
- сравнение результатов классификации
- обратная трассировка ошибок
- анализ корректности методики

LIMITATION:
- логика не является единственным источником истины
- требует синхронизации с продукционными скриптами
*/

WITH RECURSIVE


- LOGIC_BLOCK: L1_EXECUTED_LOTS
-- PURPOSE: отобрать только исполненные (EXECUTED) лоты как входной контур данных

-- RULE: выбираются только лоты со статусом EXECUTED

-- INPUT:
-- primary:
--   - lot
-- lookup:
--   - lot_status_history

-- OUTPUT:
-- dataset: executed_lots
-- key_fields:
--   - lot_id
-- derived_fields:
--   - advert_id

-- FILTERS:
-- DATA_QUALITY:
--   - lot.status_history_id корректно ссылается на lot_status_history
-- BUSINESS:
--   - lsh.status = 'EXECUTED'
-- TECHNICAL:
--   - INNER JOIN исключает лоты без статуса

-- RISK:
-- - некорректное заполнение статуса в lot_status_history
-- - рассинхронизация статуса между lot и status_history

-- FAILURE_MODE:
-- - в отчет попадут неисполненные закупки
-- - часть исполненных закупок будет пропущена
-- - downstream логика будет работать на неполном или искаженном наборе данных

-- TRACE_KEYS:
--   - lot_id
--   - advert_id

-- NOTE:
-- задает входной контур данных для всех последующих расчетов
  
executed_lots AS (
  SELECT l.id AS lot_id, l.advert_id
  FROM lot l
  JOIN lot_status_history lsh ON lsh.id = l.status_history_id
  WHERE lsh.status = 'EXECUTED'
),


-- LOGIC_BLOCK: L2_CARDS_IN_SCOPE
-- PURPOSE: сформировать множество уникальных карточек договоров, попадающих в отчетный контур на основе исполненных лотов

-- RULE:
-- карточка включается в выборку, если:
-- - она связана с предметом договора (contract_item)
-- - предмет относится к исполненному лоту (EXECUTED)
-- - карточка проходит базовые фильтры качества и бизнес-ограничения

-- INPUT:
-- primary:
--   - contract_item
-- lookup:
--   - contract_card
--   - executed_lots

-- OUTPUT:
-- dataset: cards_in_scope
-- key_fields:
--   - contract_card_id
-- derived_fields:
--   - отсутствуют

-- FILTERS:
-- DATA_QUALITY:
--   - ci.deleted = false
--   - cc.deleted = false
--   - cc.system_number IS NOT NULL AND cc.system_number <> ''
-- BUSINESS:
--   - COALESCE(cc.contract_type, '') NOT LIKE 'PKO%'
--   - NOT (cc.lock_type = 'BLOCKED' AND cc.lock_type_reason = 'REVISED')
-- TECHNICAL:
--   - DISTINCT используется для устранения дубликатов contract_card_id

-- RISK:
-- - потеря валидных карточек из-за жестких фильтров
-- - скрытие проблем кратности (multiple items → 1 contract) из-за DISTINCT
-- - зависимость от корректности связи contract_item → contract_card → lot

-- FAILURE_MODE:
-- - часть договоров не попадет в downstream обработку (SIMPLE/COMPLEX)
-- - возможное расхождение количества контрактов с витриной
-- - искажение аналитики из-за скрытых дублей

-- TRACE_KEYS:
--   - contract_card_id
--   - lot_id (через contract_item)

-- NOTE:
-- - блок задает множество договоров, участвующих в классификации
-- - является критической точкой фильтрации (data reduction point)
-- - DISTINCT может скрывать мультипликативность связей contract_item → contract_card

  
cards_in_scope AS (
  SELECT DISTINCT cc.id AS contract_card_id
  FROM contract_item ci
  JOIN executed_lots el ON el.lot_id = ci.lot_id
  JOIN contract_card cc ON cc.id = ci.contract_card_id
  WHERE ci.deleted = false
    AND cc.deleted = false
    AND cc.system_number IS NOT NULL AND cc.system_number <> ''
    AND COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
    AND (cc.lock_type IS DISTINCT FROM 'BLOCKED' OR cc.lock_type_reason IS DISTINCT FROM 'REVISED')
),


-- LOGIC_BLOCK: L3_BASE_CARDS
-- PURPOSE: сформировать базовую таблицу контрактов с необходимыми атрибутами для дальнейшей обработки (определение main, классификация)

-- RULE:
-- каждая карточка контракта из cards_in_scope обогащается атрибутами contract_card,
-- при этом повторно применяется фильтрация по качеству и бизнес-правилам

-- INPUT:
-- primary:
--   - contract_card
-- lookup:
--   - cards_in_scope

-- OUTPUT:
-- dataset: base_cards
-- key_fields:
--   - contract_card_id
-- derived_fields:
--   - main_contract_card_id
--   - prev_contract_card_id
--   - contract_type
--   - contract_date_time
--   - суммы и атрибуты контракта

-- FILTERS:
-- DATA_QUALITY:
--   - cc.deleted = false
--   - cc.system_number IS NOT NULL AND cc.system_number <> ''
-- BUSINESS:
--   - COALESCE(cc.contract_type, '') NOT LIKE 'PKO%'
--   - NOT (cc.lock_type = 'BLOCKED' AND cc.lock_type_reason = 'REVISED')
-- TECHNICAL:
--   - повторная фильтрация уже примененных условий из L2

-- RISK:
-- - двойная фильтрация (L2 + L3) может приводить к потере данных
-- - рассинхронизация условий фильтрации между L2 и L3 при будущих изменениях
-- - зависимость от полноты cards_in_scope

-- FAILURE_MODE:
-- - часть контрактов будет отфильтрована повторно и не попадет в downstream обработку
-- - расхождение количества записей между cards_in_scope и base_cards
-- - ошибки классификации SIMPLE/COMPLEX из-за неполного набора контрактов

-- TRACE_KEYS:
--   - contract_card_id

-- NOTE:
-- - блок НЕ расширяет выборку, а только добавляет атрибуты и повторно фильтрует данные
-- - является второй критической точкой редукции данных (после L2)
-- - дублирование фильтров с L2 создает риск расхождения логики при изменениях

  
base_cards AS (
  SELECT
    cc.id AS contract_card_id,
    cc.main_contract_card_id,
    cc.prev_contract_card_id,
    cc.contract_date_time,
    cc.system_number,
    cc.contract_type,
    cc.duration_type,
    cc.customer_id,
    cc.supplier_id,
    cc.sum_no_nds,
    cc.execution_sum_no_nds,
    cc.flag_paper_contract,
    cc.lock_type,
    cc.lock_type_reason
  FROM contract_card cc
  JOIN cards_in_scope s ON s.contract_card_id = cc.id
  WHERE cc.deleted = false
    AND cc.system_number IS NOT NULL AND cc.system_number <> ''
    AND COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
    AND (cc.lock_type IS DISTINCT FROM 'BLOCKED' OR cc.lock_type_reason IS DISTINCT FROM 'REVISED')
),


-- LOGIC_BLOCK: L4_CANDIDATE_MAIN
-- PURPOSE: определить кандидатный основной контракт (main) для каждой карточки договора

-- RULE:
-- основной контракт определяется следующим образом:
-- - если contract_type ∈ ('ADVERT','ADVERT_SECOND_WINNER')
--     → основной контракт = сам contract_card_id
-- - иначе
--     → основной контракт = main_contract_card_id

-- INPUT:
-- primary:
--   - base_cards

-- OUTPUT:
-- dataset: cards_with_candidate_main
-- key_fields:
--   - contract_card_id
-- derived_fields:
--   - candidate_main_id

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют (используется результат L3)
-- BUSINESS:
--   - классификация по contract_type
-- TECHNICAL:
--   - CASE-логика определения main

-- RISK:
-- - поле main_contract_card_id может быть NULL или некорректным
-- - contract_type может быть неконсистентным или заполнен неверно
-- - логика предполагает, что ADVERT всегда является корневым элементом

-- FAILURE_MODE:
-- - candidate_main_id = NULL → запись уйдет в блок восстановления (L6, recursion)
-- - неправильный candidate_main_id приведет к неверной классификации всей семьи контрактов
-- - downstream блоки (L5–L9) будут работать с неправильной структурой связей

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - main_contract_card_id

-- NOTE:
-- - первый блок, где формируется бизнес-сущность "основной контракт"
-- - определяет структуру "семьи" контрактов (main + допники)
-- - ошибки здесь критически влияют на классификацию SIMPLE / COMPLEX

  
  cards_with_candidate_main AS (
  SELECT
    bc.*,
    CASE
      WHEN bc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER') THEN bc.contract_card_id
      ELSE bc.main_contract_card_id
    END AS candidate_main_id
  FROM base_cards bc
),
 

-- LOGIC_BLOCK: L5_MAIN_VALIDATION
-- PURPOSE: проверить корректность candidate_main_id и диагностировать причины некорректных связей

-- RULE:
-- candidate_main считается корректным, если:
-- - candidate_main_id не NULL
-- - соответствующая запись в contract_card существует
-- - запись не удалена
-- - заполнен system_number
-- - contract_type ∈ ('ADVERT','ADVERT_SECOND_WINNER')
-- - contract_type не начинается с 'PKO%'
-- - запись не находится в статусе BLOCKED/REVISED

-- INPUT:
-- primary:
--   - cards_with_candidate_main
-- lookup:
--   - contract_card (mc — кандидат на main)

-- OUTPUT:
-- dataset: main_ok_eval
-- key_fields:
--   - contract_card_id
-- derived_fields:
--   - candidate_main_ok_link (boolean)
--   - candidate_main_problem (text)
--   - main_exists_id
--   - main_contract_type
--   - main_deleted

-- FILTERS:
-- DATA_QUALITY:
--   - проверка существования mc.id
--   - проверка mc.deleted
--   - проверка заполненности system_number
-- BUSINESS:
--   - допустимые contract_type для main
--   - исключение PKO%
--   - исключение BLOCKED/REVISED
-- TECHNICAL:
--   - LEFT JOIN допускает отсутствие main для диагностики

-- RISK:
-- - чрезмерно строгие условия могут пометить валидные записи как некорректные
-- - различия в логике фильтров между этим блоком и предыдущими (L2/L3)
-- - зависимость от качества данных в contract_card

-- FAILURE_MODE:
-- - candidate_main_ok_link = false → запись уходит в блок восстановления (L6)
-- - неправильная диагностика причины (candidate_main_problem)
-- - downstream логика (effective_main) использует fallback вместо корректного main
-- - рост доли SUSPICIOUS_MAIN_LINK

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - main_exists_id

-- NOTE:
-- - ключевой диагностический блок всей системы
-- - формирует причину некорректности (candidate_main_problem)
-- - используется для анализа качества данных и логики main
-- - первый блок, где появляется explainability (объяснимость результата)

  
main_ok_eval AS (
  SELECT
    c.*,
    mc.id AS main_exists_id,
    mc.deleted AS main_deleted,
    mc.contract_type AS main_contract_type,
    (mc.system_number IS NOT NULL AND mc.system_number <> '') AS main_has_system_number,
    (mc.lock_type='BLOCKED' AND mc.lock_type_reason='REVISED') AS main_is_blocked_revised,
    (
      c.candidate_main_id IS NOT NULL
      AND mc.id IS NOT NULL
      AND COALESCE(mc.deleted,true)=false
      AND (mc.system_number IS NOT NULL AND mc.system_number <> '')
      AND mc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER')
      AND COALESCE(mc.contract_type,'') NOT LIKE 'PKO%'
      AND (mc.lock_type IS DISTINCT FROM 'BLOCKED' OR mc.lock_type_reason IS DISTINCT FROM 'REVISED')
    ) AS candidate_main_ok_link,
    CASE
      WHEN c.candidate_main_id IS NULL THEN 'MAIN_CONTRACT_CARD_ID_IS_NULL'
      WHEN mc.id IS NULL THEN 'MAIN_NOT_FOUND'
      WHEN mc.deleted = true THEN 'MAIN_DELETED'
      WHEN (mc.system_number IS NULL OR mc.system_number='') THEN 'MAIN_EMPTY_SYSTEM_NUMBER'
      WHEN mc.contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER') THEN 'MAIN_WRONG_CONTRACT_TYPE:'||COALESCE(mc.contract_type,'<NULL>')
      WHEN (mc.lock_type='BLOCKED' AND mc.lock_type_reason='REVISED') THEN 'MAIN_BLOCKED_REVISED'
      ELSE NULL
    END AS candidate_main_problem
  FROM cards_with_candidate_main c
  LEFT JOIN contract_card mc ON mc.id = c.candidate_main_id
),
  

-- LOGIC_BLOCK: L6_BAD_MAIN
-- PURPOSE: выделить записи с некорректным candidate_main_id для последующего восстановления через цепочку prev_contract_card_id

-- RULE:
-- запись считается проблемной, если:
-- - candidate_main_ok_link = false
-- - при этом есть prev_contract_card_id (т.е. существует возможность восстановить main через цепочку)

-- INPUT:
-- primary:
--   - main_ok_eval

-- OUTPUT:
-- dataset: bad_for_second_winner_search
-- key_fields:
--   - contract_card_id
-- derived_fields:
--   - prev_contract_card_id

-- FILTERS:
-- DATA_QUALITY:
--   - candidate_main_ok_link = false
-- BUSINESS:
--   - prev_contract_card_id IS NOT NULL (есть связь с предыдущим контрактом)
-- TECHNICAL:
--   - отбор только тех записей, где возможно построение цепочки

-- RISK:
-- - часть проблемных записей не попадет в восстановление (если prev_contract_card_id IS NULL)
-- - возможна передача в рекурсию записей с некорректными или "шумными" связями
-- - зависимость от корректности prev_contract_card_id

-- FAILURE_MODE:
-- - записи с некорректным main и без prev_contract_card_id будут безвозвратно потеряны (останутся с NULL main)
-- - в случае некорректной цепочки восстановление main завершится неуспешно
-- - рост сегмента SUSPICIOUS_MAIN_LINK

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - prev_contract_card_id

-- NOTE:
-- - точка входа в механизм восстановления (recovery logic)
-- - делит поток на два сценария:
--     1) candidate_main корректен → идем дальше напрямую
--     2) candidate_main некорректен → пробуем восстановить через prev_chain
-- - если запись не проходит этот блок, она не участвует в recusive восстановлении

  
bad_for_second_winner_search AS (
  SELECT *
  FROM main_ok_eval
  WHERE candidate_main_ok_link = false
    AND prev_contract_card_id IS NOT NULL
),
  

-- LOGIC_BLOCK: L7_PREV_CHAIN_RECURSION
-- PURPOSE: построить рекурсивную цепочку контрактов через prev_contract_card_id для восстановления основного контракта (main)

-- RULE:
-- рекурсивно выполняется обход цепочки:
-- contract_card → prev_contract_card_id → prev_contract_card_id → ...
-- до тех пор, пока:
-- - цепочка не обрывается (NULL)
-- - не достигнут лимит глубины
-- - не обнаружен цикл

-- INPUT:
-- primary:
--   - bad_for_second_winner_search
-- lookup:
--   - contract_card

-- OUTPUT:
-- dataset: prev_walk
-- key_fields:
--   - origin_contract_card_id  (исходная карточка, для которой ищем main)
-- derived_fields:
--   - current_card_id
--   - depth
--   - path (массив пройденных узлов)

-- FILTERS:
-- DATA_QUALITY:
--   - w.current_card_id IS NOT NULL (обрыв цепочки)
-- BUSINESS:
--   - отсутствуют (чистая навигация по данным)
-- TECHNICAL:
--   - depth < 200 (ограничение рекурсии)
--   - NOT (cc.id = ANY(w.path)) (предотвращение циклов)

-- RISK:
-- - цепочка может быть обрывочной или неполной (битые ссылки)
-- - возможны циклические зависимости между контрактами
-- - глубина цепочки может превышать установленный лимит (200)
-- - prev_contract_card_id может не отражать реальную бизнес-цепочку

-- FAILURE_MODE:
-- - цепочка обрывается → восстановление main невозможно
-- - превышение глубины → цепочка обрезается → main не найден
-- - циклы → часть цепочки игнорируется
-- - некорректная цепочка → найден неправильный main в downstream логике

-- TRACE_KEYS:
--   - origin_contract_card_id
--   - current_card_id
--   - depth

-- NOTE:
-- - критический блок восстановления структуры контрактов
-- - работает на предположении, что prev_contract_card_id формирует линейную цепочку
-- - не гарантирует корректность найденного main, только предоставляет варианты
-- - качество результата напрямую зависит от качества связей в contract_card
-- - глубина (depth) может использоваться для анализа качества данных (аномально длинные цепочки)


prev_walk AS (
  SELECT
    b.contract_card_id AS origin_contract_card_id,
    b.prev_contract_card_id AS current_card_id,
    1 AS depth,
    ARRAY[b.contract_card_id]::bigint[] AS path
  FROM bad_for_second_winner_search b
  UNION ALL
  SELECT
    w.origin_contract_card_id,
    cc.prev_contract_card_id,
    w.depth + 1,
    w.path || cc.id
  FROM prev_walk w
  JOIN contract_card cc ON cc.id = w.current_card_id
  WHERE w.current_card_id IS NOT NULL
    AND w.depth < 200
    AND NOT (cc.id = ANY(w.path))
),


-- LOGIC_BLOCK: L8_SECOND_WINNER
-- PURPOSE: найти альтернативный основной контракт (main) среди цепочки prev_contract_card_id, используя контракт типа ADVERT_SECOND_WINNER как fallback

-- RULE:
-- из цепочки prev_walk выбирается первый (наиболее близкий) контракт,
-- который удовлетворяет условиям корректного main:
-- - contract_type = 'ADVERT_SECOND_WINNER'
-- - запись не удалена
-- - заполнен system_number
-- - не относится к PKO
-- - не в статусе BLOCKED/REVISED
-- - имеет хотя бы один связанный contract_item в EXECUTED лоте
-- выбор осуществляется по минимальной глубине (depth)

-- INPUT:
-- primary:
--   - prev_walk
-- lookup:
--   - contract_card (sw)
--   - contract_item
--   - executed_lots

-- OUTPUT:
-- dataset: second_winner_found
-- key_fields:
--   - origin_contract_card_id
-- derived_fields:
--   - found_second_winner_main_id

-- FILTERS:
-- DATA_QUALITY:
--   - sw.deleted = false
--   - sw.system_number IS NOT NULL AND sw.system_number <> ''
-- BUSINESS:
--   - sw.contract_type = 'ADVERT_SECOND_WINNER'
--   - COALESCE(sw.contract_type, '') NOT LIKE 'PKO%'
--   - NOT (sw.lock_type = 'BLOCKED' AND sw.lock_type_reason = 'REVISED')
--   - EXISTS контрактный предмет в EXECUTED лоте
-- TECHNICAL:
--   - DISTINCT ON (origin_contract_card_id)
--   - ORDER BY depth (выбор ближайшего кандидата)

-- RISK:
-- - выбор ближайшего элемента в цепочке не гарантирует корректный бизнес-main
-- - возможное наличие нескольких валидных кандидатов → выбирается только один (теряется альтернатива)
-- - зависимость от корректности prev_chain
-- - зависимость от наличия contract_item в EXECUTED лоте (фильтр может исключить валидные main)

-- FAILURE_MODE:
-- - fallback main не найден → effective_main_id будет NULL
-- - выбран неправильный second winner → искажена структура семьи контрактов
-- - downstream классификация (SIMPLE/COMPLEX) выполняется на неверной базе
-- - расхождения с методикой при множественных допустимых цепочках

-- TRACE_KEYS:
--   - origin_contract_card_id
--   - found_second_winner_main_id
--   - depth (из prev_walk)

-- NOTE:
-- - ключевой блок выбора альтернативного main
-- - реализует стратегию "лучшего доступного кандидата" (best-effort recovery)
-- - зависит от допущения, что ближайший ADVERT_SECOND_WINNER в цепочке является корректным main
-- - DISTINCT ON + ORDER BY depth фактически выбирают первый найденный вариант без полного анализа цепочки
  
second_winner_found AS (
  SELECT DISTINCT ON (w.origin_contract_card_id)
    w.origin_contract_card_id,
    sw.id AS found_second_winner_main_id
  FROM prev_walk w
  JOIN contract_card sw ON sw.id = w.current_card_id
  WHERE sw.deleted = false
    AND sw.system_number IS NOT NULL AND sw.system_number <> ''
    AND sw.contract_type = 'ADVERT_SECOND_WINNER'
    AND COALESCE(sw.contract_type,'') NOT LIKE 'PKO%'
    AND (sw.lock_type IS DISTINCT FROM 'BLOCKED' OR sw.lock_type_reason IS DISTINCT FROM 'REVISED')
    AND EXISTS (
      SELECT 1
      FROM contract_item ci
      JOIN executed_lots el ON el.lot_id = ci.lot_id
      WHERE ci.deleted=false AND ci.contract_card_id = sw.id
      LIMIT 1
    )
  ORDER BY w.origin_contract_card_id, w.depth
),


-- LOGIC_BLOCK: L9_EFFECTIVE_MAIN
-- PURPOSE: определить финальный основной контракт (effective_main_id) на основе candidate_main и fallback-логики

-- RULE:
-- основной контракт выбирается по приоритету:
-- 1. если candidate_main валиден (candidate_main_ok_link = true)
--     → используется candidate_main_id
-- 2. если найден fallback (second_winner)
--     → используется found_second_winner_main_id
-- 3. иначе
--     → NULL (невозможно определить main)

-- INPUT:
-- primary:
--   - main_ok_eval
-- lookup:
--   - second_winner_found

-- OUTPUT:
-- dataset: effective_main
-- key_fields:
--   - contract_card_id
-- derived_fields:
--   - effective_main_id
--   - found_second_winner_main_id
--   - feature_or_problem

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют (использует результат проверки L5)
-- BUSINESS:
--   - приоритет использования валидного candidate_main
--   - fallback только при невалидности candidate_main
-- TECHNICAL:
--   - LEFT JOIN позволяет учитывать отсутствие fallback

-- RISK:
-- - fallback main (second_winner) может быть выбран некорректно
-- - разные типы ошибок агрегируются в один NULL (потеря детализации)
-- - зависимость от корректности L5 и L8 (prerequisite logic)
-- - возможны несогласованные результаты при расхождении логики validation и recovery

-- FAILURE_MODE:
-- - effective_main_id = NULL → запись классифицируется как SUSPICIOUS_MAIN_LINK
-- - выбор fallback вместо реального main → искажается структура семейства контрактов
-- - downstream классификация (SIMPLE/COMPLEX) выполняется на неверной основе
-- - возможны расхождения с методикой при сложных цепочках

-- TRACE_KEYS:
--   - contract_card_id
--   - effective_main_id
--   - candidate_main_id
--   - found_second_winner_main_id

-- NOTE:
-- - ключевая точка принятия решения (decision point) во всей логике
-- - объединяет validation (L5) и recovery (L6–L8)
-- - формирует поле feature_or_problem, которое объясняет путь определения main
-- - является основой для дальнейшей классификации контрактов
  
  
effective_main AS (
  SELECT
    m.*,
    sw.found_second_winner_main_id,
    CASE
      WHEN m.candidate_main_ok_link THEN m.candidate_main_id
      WHEN sw.found_second_winner_main_id IS NOT NULL THEN sw.found_second_winner_main_id
      ELSE NULL
    END AS effective_main_id,
    CASE
      WHEN m.candidate_main_ok_link THEN 'MAIN_OK_LINK'
      WHEN sw.found_second_winner_main_id IS NOT NULL THEN 'MAIN_FROM_PREV_CHAIN:ADVERT_SECOND_WINNER'
      ELSE COALESCE(m.candidate_main_problem,'NO_VALID_SECOND_WINNER_FOUND_IN_PREV_CHAIN')
    END AS feature_or_problem
  FROM main_ok_eval m
  LEFT JOIN second_winner_found sw ON sw.origin_contract_card_id = m.contract_card_id
),


-- LOGIC_BLOCK: L10_FAMILY_FLAGS
-- PURPOSE: определить наличие дополнительных соглашений (supplementary contracts) в семье контрактов и подготовить признак для классификации SIMPLE / COMPLEX

-- RULE:
-- семья контрактов считается COMPLEX, если:
-- - в группе с одинаковым effective_main_id есть хотя бы один контракт,
--   у которого contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER')
-- иначе семья считается SIMPLE

-- INPUT:
-- primary:
--   - effective_main

-- OUTPUT:
-- dataset: family_flags
-- key_fields:
--   - effective_main_id
-- derived_fields:
--   - has_any_supp_cards (boolean)

-- FILTERS:
-- DATA_QUALITY:
--   - effective_main_id IS NOT NULL (исключаются записи без определенного main)
-- BUSINESS:
--   - contract_type используется для определения “основной” vs “допник”
-- TECHNICAL:
--   - BOOL_OR агрегирует наличие хотя бы одного допника

-- RISK:
-- - contract_type может быть некорректно заполнен → ложная классификация
-- - все типы, кроме ADVERT/SECOND_WINNER, считаются допниками (жесткое допущение)
-- - потеря записей с NULL effective_main_id (не участвуют в классификации)

-- FAILURE_MODE:
-- - неправильная классификация SIMPLE ↔ COMPLEX
-- - расхождение с методикой при нестандартных contract_type
-- - договоры с проблемным main не попадут в семейный анализ
-- - downstream витрина будет строиться на ошибочной категории

-- TRACE_KEYS:
--   - effective_main_id

-- NOTE:
-- - ключевой блок бизнес-классификации
-- - агрегирует контракты в "семью" через effective_main_id
-- - переводит структуру связей в бинарный признак (SIMPLE/COMPLEX)
-- - чувствителен к корректности contract_type и предыдущих этапов (L4–L9)
  
  
family_flags AS (
  SELECT
    e.effective_main_id,
    BOOL_OR(e.contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER')) AS has_any_supp_cards
  FROM effective_main e
  WHERE e.effective_main_id IS NOT NULL
  GROUP BY e.effective_main_id
),


-- LOGIC_BLOCK: L11_SAMPLE_LOT
-- PURPOSE: выбрать репрезентативный (условный) пример лота и объявления (advert) для каждого main_contract_id для целей анализа и отладки

-- RULE:
-- для каждого effective_main_id:
-- - выбирается минимальный lot_id
-- - выбирается соответствующий минимальный advert_id
-- значения используются как "пример", а не как полный набор

-- INPUT:
-- primary:
--   - effective_main
-- lookup:
--   - contract_item
--   - executed_lots

-- OUTPUT:
-- dataset: sample_lot_advert
-- key_fields:
--   - effective_main_id
-- derived_fields:
--   - sample_lot_id
--   - sample_advert_id

-- FILTERS:
-- DATA_QUALITY:
--   - ci.deleted = false
-- BUSINESS:
--   - используются только записи, связанные с EXECUTED лотами
-- TECHNICAL:
--   - MIN(ci.lot_id)
--   - MIN(el.advert_id)
--   - GROUP BY effective_main_id

-- RISK:
-- - MIN() не гарантирует репрезентативность (может выбрать случайный/наименее показательный лот)
-- - sample может не отражать реальную структуру семьи контрактов
-- - разные выборки могут давать разные sample (при изменении данных)

-- FAILURE_MODE:
-- - аналитик делает выводы на основе нерепрезентативного примера
-- - mismatch между sample и фактическими данными в семье контрактов
-- - затрудняется отладка (пример не соответствует проблемной записи)

-- TRACE_KEYS:
--   - effective_main_id
--   - sample_lot_id
--   - sample_advert_id

-- NOTE:
-- - блок используется ТОЛЬКО для удобства анализа и дебага
-- - не должен использоваться как источник бизнес-данных
-- - является lossy-представлением (сильное упрощение данных)
-- - при анализе ошибок рекомендуется работать с полным набором contract_item, а не с sample

  
sample_lot_advert AS (
  SELECT
    e.effective_main_id,
    MIN(ci.lot_id) AS sample_lot_id,
    MIN(el.advert_id) AS sample_advert_id
  FROM effective_main e
  JOIN contract_item ci ON ci.contract_card_id = e.contract_card_id AND ci.deleted=false
  JOIN executed_lots el ON el.lot_id = ci.lot_id
  WHERE e.effective_main_id IS NOT NULL
  GROUP BY e.effective_main_id
), 


-- LOGIC_BLOCK: L12_SAMPLE_STATUS
-- PURPOSE: выбрать примерный статус предмета договора для каждого main_contract_id для целей анализа и диагностики

-- RULE:
-- для каждого effective_main_id:
-- - выбирается последний (по ci.id DESC) предмет договора
-- - статус предмета определяется по contract_item_status_history
-- - если статус = 'UNDER_RESCISSION', он принудительно заменяется на 'SIGNED'

-- INPUT:
-- primary:
--   - effective_main
-- lookup:
--   - contract_item
--   - contract_item_status_history
--   - executed_lots

-- OUTPUT:
-- dataset: sample_item_status
-- key_fields:
--   - effective_main_id
-- derived_fields:
--   - sample_item_status

-- FILTERS:
-- DATA_QUALITY:
--   - ci.deleted = false
--   - наличие связи ci → cish через status_history_id
-- BUSINESS:
--   - используются только предметы из EXECUTED лотов
-- TECHNICAL:
--   - DISTINCT ON (effective_main_id)
--   - ORDER BY ci.id DESC (выбор "последнего" предмета)

-- RISK:
-- - статус UNDER_RESCISSION принудительно заменяется на SIGNED (искажение исходных данных)
-- - выбор "последнего" предмета по ci.id не гарантирует корректную временную последовательность
-- - sample может не отражать реальную ситуацию по всей семье контрактов
-- - возможна зависимость от порядка загрузки данных (ci.id)

-- FAILURE_MODE:
-- - аналитик неправильно интерпретирует состояние контракта
-- - разночтения между фактическим статусом и sample_item_status
-- - ввод в заблуждение при анализе проблем (feature_or_problem)
-- - расхождения с другими отчетами, где используется реальный статус

-- TRACE_KEYS:
--   - effective_main_id
--   - contract_item_id (через ci.id)

-- NOTE:
-- - блок предназначен только для отображения примера статуса
-- - НЕ должен использоваться для расчетов или бизнес-логики
-- - содержит преднамеренное упрощение (normalization) статусов
-- - является lossy-представлением и может скрывать реальные состояния договоров

  
sample_item_status AS (
  SELECT DISTINCT ON (e.effective_main_id)
    e.effective_main_id,
    CASE WHEN cish.status='UNDER_RESCISSION' THEN 'SIGNED' ELSE cish.status END AS sample_item_status
  FROM effective_main e
  JOIN contract_item ci ON ci.contract_card_id = e.contract_card_id AND ci.deleted=false
  JOIN executed_lots el ON el.lot_id = ci.lot_id
  LEFT JOIN contract_item_status_history cish ON cish.id = ci.status_history_id
  WHERE e.effective_main_id IS NOT NULL
  ORDER BY e.effective_main_id, ci.id DESC
)


-- LOGIC_BLOCK: L13_FINAL
-- PURPOSE: сформировать итоговую классификацию контрактов по main_contract_id с указанием категории и диагностической информации

-- RULE:
-- категория определяется следующим образом:
-- - если effective_main_id IS NULL
--     → 'SUSPICIOUS_MAIN_LINK'
-- - если has_any_supp_cards = true
--     → 'DEFINITELY_COMPLEX'
-- - иначе
--     → 'DEFINITELY_SIMPLE'

-- INPUT:
-- primary:
--   - effective_main
-- lookup:
--   - family_flags
--   - sample_lot_advert
--   - sample_item_status

-- OUTPUT:
-- dataset: classifier_result
-- key_fields:
--   - main_contract_id
-- derived_fields:
--   - category
--   - feature_or_problem
--   - advert_id
--   - lot_id
--   - sample_item_status
--   - sample_contract_card_id
--   - sample_contract_system_number

-- FILTERS:
-- DATA_QUALITY:
--   - effective_main_id может быть NULL (сохраняется для диагностики)
-- BUSINESS:
--   - классификация на основе наличия допников (family_flags)
-- TECHNICAL:
--   - GROUP BY выполняет агрегацию до уровня main_contract_id
--   - MIN() используется для выбора произвольных примеров contract_card и system_number

-- RISK:
-- - агрегация (GROUP BY) может скрывать вариативность данных внутри одного main
-- - использование MIN() дает нерепрезентативные значения
-- - зависимость результата от корректности всех upstream блоков (L4–L10)
-- - возможна неконсистентность между sample данными и реальной структурой контрактов

-- FAILURE_MODE:
-- - неправильное определение effective_main_id → полностью ложная классификация
-- - ошибка в family_flags → неверная категория (SIMPLE/COMPLEX)
-- - NULL main → рост сегмента SUSPICIOUS_MAIN_LINK
-- - аналитические выводы делаются на основе sample-полей, не отражающих реальность

-- TRACE_KEYS:
--   - main_contract_id
--   - feature_or_problem

-- NOTE:
-- - финальный слой представления (presentation layer)
-- - выполняет преобразование структуры контрактов в отчетный формат
-- - является агрегирующим и упрощающим слой (lossy transformation)
-- - объединяет результат логики (main) и визуализацию (sample данные)
-- - должен использоваться как точка входа для анализа, а не как источник детальных данных
-- - GRAIN: main_contract_id

  
SELECT
  e.effective_main_id AS main_contract_id,
  CASE
    WHEN e.effective_main_id IS NULL THEN 'SUSPICIOUS_MAIN_LINK'
    WHEN ff.has_any_supp_cards THEN 'DEFINITELY_COMPLEX'
    ELSE 'DEFINITELY_SIMPLE'
  END AS category,
  e.feature_or_problem,
  sla.sample_advert_id AS advert_id,
  sla.sample_lot_id AS lot_id,
  sis.sample_item_status,
  MIN(e.contract_card_id) AS sample_contract_card_id,
  MIN(e.system_number)    AS sample_contract_system_number
FROM effective_main e
LEFT JOIN family_flags ff ON ff.effective_main_id = e.effective_main_id
LEFT JOIN sample_lot_advert sla ON sla.effective_main_id = e.effective_main_id
LEFT JOIN sample_item_status sis ON sis.effective_main_id = e.effective_main_id
GROUP BY
  e.effective_main_id,
  category,
  e.feature_or_problem,
  sla.sample_advert_id,
  sla.sample_lot_id,
  sis.sample_item_status
ORDER BY category, main_contract_id;
