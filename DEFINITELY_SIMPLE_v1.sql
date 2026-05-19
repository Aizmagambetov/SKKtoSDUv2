
/*
SCRIPT: DEFINITELY_SIMPLE_v1
ROLE: PRODUCTION / EXPORT LAYER
LAYER: transformation / detail export
SOURCE: Мура
VERSION: v1 (baseline)
STATUS: NOT VALIDATED

DESCRIPTION:
Назначение: сформировать детальную выгрузку по договорам, которые классифицируются как
DEFINITELY_SIMPLE, то есть семьи main-договоров без дополнительных соглашений.

Скрипт:
- определяет входной контур через исполненные лоты EXECUTED;
- формирует множество contract_card, связанных с исполненными лотами;
- определяет candidate main;
- валидирует candidate main;
- при необходимости восстанавливает main через цепочку prev_contract_card_id
  с поиском ADVERT_SECOND_WINNER;
- определяет семьи договоров без допников;
- возвращает детальные строки по contract_item для SIMPLE main_contract_id.

Ключевые фильтры:
- только лоты со статусом EXECUTED: lot_status_history.status = 'EXECUTED'
- только не удаленные предметы договора: ci.deleted = false
- только не удаленные карточки договора: cc.deleted = false
- только карточки с непустым system_number
- исключаются PKO% типы: cc.contract_type NOT LIKE 'PKO%'
- исключаются BLOCKED/REVISED:
  NOT (cc.lock_type = 'BLOCKED' AND cc.lock_type_reason = 'REVISED')

Ключевая логика main:
- если contract_type IN ('ADVERT','ADVERT_SECOND_WINNER')
    → main = сам contract_card_id
- иначе
    → main = main_contract_card_id
- если candidate_main_id невалиден
    → попытка восстановления через prev_contract_card_id
       с поиском ADVERT_SECOND_WINNER.

Ключевая логика SIMPLE:
- семья считается SIMPLE, если в группе effective_main_id
  нет ни одной карточки с contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER').

Ключевая логика суммы:
- item_sum_no_nds_no_calc:
    если item_status IN ('RESCIND','REFUSAL_PERFORM_CONTRACT')
        → используется ci.execution_sum_no_nds
    иначе
        → используется ci.sum_no_nds
- статус UNDER_RESCISSION принудительно нормализуется в SIGNED.

NOTES:
Получено в текущей форме от Муры.
Не валидировалось.
Логика частично дублирует CLASSIFIER_v1.
Скрипт используется как реализация выгрузки DEFINITELY_SIMPLE, но SQL следует рассматривать
как проверяемую гипотезу, а не как подтвержденную бизнес-логику.

USAGE:
- формирование выгрузки простых договоров;
- анализ contract_item по SIMPLE main;
- сопоставление с CLASSIFIER_v1;
- контроль расхождений SIMPLE/COMPLEX;
- проверка сумм, статусов и связей contract_card → contract_item → lot.

LIMITATION:
- логика не прошла бизнес-валидацию;
- CLASSIFIER_v1 не используется напрямую, логика продублирована внутри этого скрипта;
- возможны расхождения между CLASSIFIER_v1 и DEFINITELY_SIMPLE_v1 при будущих изменениях;
- выбор SIMPLE зависит от корректности contract_type;
- разбиение через params может возвращать только часть данных;
- working_statuses объявлен, но не используется;
- нормализация UNDER_RESCISSION → SIGNED может искажать исходный статус.
*/

WITH RECURSIVE


-- LOGIC_BLOCK: S1_PARAMS
-- PURPOSE: задать параметры партиционирования выгрузки SIMPLE-договоров

-- RULE:
-- выгрузка делится на parts_total частей.
-- Текущий запуск возвращает только одну часть:
-- - part = 1
-- - parts_total = 2
-- Условие применяется позже через MOD(ABS(effective_main_id), parts_total).

-- INPUT:
-- primary:
--   - константы внутри SQL

-- OUTPUT:
-- dataset: params
-- key_fields:
--   - отсутствуют
-- derived_fields:
--   - part
--   - parts_total

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют
-- BUSINESS:
--   - отсутствуют
-- TECHNICAL:
--   - part должен быть в диапазоне 1..parts_total
--   - используется для технического разбиения выгрузки

-- RISK:
-- - выгрузка возвращает только часть SIMPLE-договоров, если parts_total > 1
-- - пользователь может ошибочно интерпретировать результат как полный набор данных
-- - ручная смена part создает риск неполной или дублирующей выгрузки

-- FAILURE_MODE:
-- - неполная выгрузка SIMPLE-договоров
-- - несопоставимость с CLASSIFIER_v1, если CLASSIFIER считается полностью, а SIMPLE — частями
-- - пропуск main_contract_id при неправильной настройке part/parts_total

-- TRACE_KEYS:
--   - part
--   - parts_total

-- NOTE:
-- - технический блок
-- - не влияет на бизнес-классификацию, но влияет на полноту финального результата
-- - при сверке с CLASSIFIER_v1 нужно учитывать, что здесь может быть только 1/N часть данных

  
  params AS (
  SELECT 1::int AS part, 2::int AS parts_total  -- part=1..2
),


-- LOGIC_BLOCK: S2_WORKING_STATUSES
-- PURPOSE: объявить список рабочих статусов contract_item

-- RULE:
-- список статусов включает:
-- - EXECUTED
-- - REFUSAL_PERFORM_CONTRACT
-- - SIGNED
-- - RESCIND
-- - SUPPLEMENTARY_AGREEMENT

-- INPUT:
-- primary:
--   - константы внутри SQL

-- OUTPUT:
-- dataset: working_statuses
-- key_fields:
--   - status
-- derived_fields:
--   - отсутствуют

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют
-- BUSINESS:
--   - список потенциально допустимых рабочих статусов предметов договора
-- TECHNICAL:
--   - unnest массива статусов

-- RISK:
-- - блок объявлен, но далее в SQL не используется
-- - может создавать ложное впечатление, что item_status фильтруется по этому списку
-- - фактическая выгрузка включает любые статусы из contract_item_status_history

-- FAILURE_MODE:
-- - в результат могут попасть статусы, которых нет в working_statuses
-- - аналитик может ошибочно считать, что статусы ограничены данным списком
-- - расхождение с методикой, если методика требует фильтрацию по рабочим статусам

-- TRACE_KEYS:
--   - status

-- NOTE:
-- - потенциально мертвый код / unused CTE
-- - требуется бизнес-валидация: должен ли этот список применяться в финальном WHERE
-- - если фильтр по статусам нужен, его необходимо явно подключить к contract_item_status_history
 
working_statuses AS (
  SELECT unnest(ARRAY[
    'EXECUTED','REFUSAL_PERFORM_CONTRACT','SIGNED','RESCIND','SUPPLEMENTARY_AGREEMENT'
  ]) AS status
),


-- LOGIC_BLOCK: S3_EXECUTED_LOTS
-- PURPOSE: отобрать исполненные лоты как входной контур для дальнейшей обработки SIMPLE-договоров

-- RULE:
-- выбираются только лоты, у которых текущий статус в lot_status_history равен EXECUTED

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
--   - tru_history_id

-- FILTERS:
-- DATA_QUALITY:
--   - lot.status_history_id корректно ссылается на lot_status_history.id
-- BUSINESS:
--   - lsh.status = 'EXECUTED'
-- TECHNICAL:
--   - INNER JOIN исключает лоты без связанного status_history

-- RISK:
-- - некорректный lot_status_history приведет к неверному входному контуру
-- - если статус лота хранится/трактуется иначе, часть данных будет потеряна
-- - только EXECUTED-лоты участвуют в определении карточек и fallback main

-- FAILURE_MODE:
-- - неисполненные лоты могут ошибочно попасть в отчет при неверном статусе
-- - исполненные лоты могут быть исключены при ошибках статуса
-- - downstream SIMPLE-выгрузка будет неполной или искаженной

-- TRACE_KEYS:
--   - lot_id
--   - advert_id
--   - tru_history_id

-- NOTE:
-- - аналогичен L1_EXECUTED_LOTS в CLASSIFIER_v1
-- - добавляет tru_history_id, который используется в финальной выгрузке SIMPLE

  
executed_lots AS (
  SELECT l.id AS lot_id, l.advert_id, l.tru_history_id
  FROM lot l
  JOIN lot_status_history lsh ON lsh.id = l.status_history_id
  WHERE lsh.status = 'EXECUTED'
),


-- LOGIC_BLOCK: S4_CARDS_IN_SCOPE
-- PURPOSE: сформировать множество уникальных contract_card, связанных с исполненными лотами

-- RULE:
-- карточка договора включается в контур, если:
-- - имеет хотя бы один не удаленный contract_item;
-- - contract_item относится к EXECUTED lot;
-- - contract_card не удалена;
-- - system_number заполнен;
-- - contract_type не относится к PKO%;
-- - карточка не заблокирована как BLOCKED/REVISED.

-- INPUT:
-- primary:
--   - contract_item
-- lookup:
--   - executed_lots
--   - contract_card

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
--   - COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
--   - NOT (cc.lock_type = 'BLOCKED' AND cc.lock_type_reason = 'REVISED')
-- TECHNICAL:
--   - DISTINCT устраняет дубли contract_card_id из-за multiple contract_item

-- RISK:
-- - DISTINCT скрывает кратность связи contract_card → contract_item
-- - жесткие фильтры могут исключить договоры, которые методика должна учитывать
-- - фильтр по EXECUTED lot ограничивает состав contract_card только исполненными лотами

-- FAILURE_MODE:
-- - часть карточек не попадет в SIMPLE-классификацию
-- - возможны расхождения с CLASSIFIER_v1 или витриной при различии фильтров
-- - потеря информации о множественности предметов договора на этом этапе

-- TRACE_KEYS:
--   - contract_card_id
--   - lot_id через contract_item

-- NOTE:
-- - аналогичен L2_CARDS_IN_SCOPE в CLASSIFIER_v1
-- - является первой критической точкой редукции данных
  
  
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


-- LOGIC_BLOCK: S5_BASE_CARDS
-- PURPOSE: обогатить contract_card базовыми атрибутами, необходимыми для определения main и финальной выгрузки SIMPLE

-- RULE:
-- для карточек из cards_in_scope извлекаются атрибуты contract_card.
-- Повторно применяются базовые фильтры качества и бизнес-исключения.

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
--   - contract_date_time
--   - system_number
--   - contract_type
--   - duration_type
--   - customer_id
--   - supplier_id
--   - contract_sum_no_nds
--   - execution_sum_no_nds

-- FILTERS:
-- DATA_QUALITY:
--   - cc.deleted = false
--   - cc.system_number IS NOT NULL AND cc.system_number <> ''
-- BUSINESS:
--   - COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
--   - NOT (cc.lock_type = 'BLOCKED' AND cc.lock_type_reason = 'REVISED')
-- TECHNICAL:
--   - повторная фильтрация условий из S4

-- RISK:
-- - дублирование фильтров с S4 создает риск рассинхронизации при будущих изменениях
-- - повторная фильтрация может исключить карточки при изменении данных между CTE
-- - contract_sum_no_nds берется с уровня карточки и может не совпадать с суммой item

-- FAILURE_MODE:
-- - расхождение количества записей между cards_in_scope и base_cards
-- - потеря карточек перед определением main
-- - некорректные суммы на уровне выгрузки при неправильном использовании contract_sum_no_nds

-- TRACE_KEYS:
--   - contract_card_id
--   - main_contract_card_id
--   - prev_contract_card_id

-- NOTE:
-- - аналогичен L3_BASE_CARDS в CLASSIFIER_v1
-- - содержит поля, которые далее выходят в финальный SELECT

  
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
    cc.sum_no_nds AS contract_sum_no_nds,
    cc.execution_sum_no_nds,
    cc.lock_type,
    cc.lock_type_reason
  FROM contract_card cc
  JOIN cards_in_scope s ON s.contract_card_id = cc.id
  WHERE cc.deleted=false
    AND cc.system_number IS NOT NULL AND cc.system_number <> ''
    AND COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
    AND (cc.lock_type IS DISTINCT FROM 'BLOCKED' OR cc.lock_type_reason IS DISTINCT FROM 'REVISED')
),


-- LOGIC_BLOCK: S6_CANDIDATE_MAIN
-- PURPOSE: определить кандидатный основной договор для каждой карточки

-- RULE:
-- candidate_main_id определяется так:
-- - если contract_type IN ('ADVERT','ADVERT_SECOND_WINNER')
--     → candidate_main_id = contract_card_id
-- - иначе
--     → candidate_main_id = main_contract_card_id

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
--   - отсутствуют
-- BUSINESS:
--   - contract_type определяет, является ли карточка main
-- TECHNICAL:
--   - CASE-логика

-- RISK:
-- - contract_type может быть заполнен неверно
-- - main_contract_card_id может быть NULL или ссылаться на некорректную карточку
-- - ADVERT_SECOND_WINNER приравнивается к main

-- FAILURE_MODE:
-- - неверный candidate_main_id приведет к ошибочной SIMPLE-классификации
-- - карточка может попасть в fallback-логику без необходимости
-- - семья договоров будет собрана вокруг неправильного main

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - main_contract_card_id
--   - contract_type

-- NOTE:
-- - аналогичен L4_CANDIDATE_MAIN в CLASSIFIER_v1

  
cards_with_candidate_main AS (
  SELECT
    bc.*,
    CASE
      WHEN bc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER') THEN bc.contract_card_id
      ELSE bc.main_contract_card_id
    END AS candidate_main_id
  FROM base_cards bc
),


-- LOGIC_BLOCK: S7_MAIN_VALIDATION
-- PURPOSE: проверить корректность candidate_main_id

-- RULE:
-- candidate_main_id считается валидным, если:
-- - candidate_main_id не NULL;
-- - соответствующая contract_card существует;
-- - main-карточка не удалена;
-- - system_number заполнен;
-- - contract_type IN ('ADVERT','ADVERT_SECOND_WINNER');
-- - contract_type не PKO%;
-- - main-карточка не BLOCKED/REVISED.

-- INPUT:
-- primary:
--   - cards_with_candidate_main
-- lookup:
--   - contract_card mc

-- OUTPUT:
-- dataset: main_ok_eval
-- key_fields:
--   - contract_card_id
-- derived_fields:
--   - candidate_main_ok_link

-- FILTERS:
-- DATA_QUALITY:
--   - candidate_main_id IS NOT NULL
--   - mc.id IS NOT NULL
--   - mc.deleted = false
--   - mc.system_number IS NOT NULL AND mc.system_number <> ''
-- BUSINESS:
--   - mc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER')
--   - COALESCE(mc.contract_type,'') NOT LIKE 'PKO%'
--   - NOT BLOCKED/REVISED
-- TECHNICAL:
--   - LEFT JOIN используется для проверки существования main

-- RISK:
-- - в отличие от CLASSIFIER_v1, здесь не формируется candidate_main_problem
-- - потеря explainability: невозможно понять причину невалидного main из финального результата
-- - логика проверки дублирует CLASSIFIER_v1 и может рассинхронизироваться

-- FAILURE_MODE:
-- - candidate_main_ok_link = false отправляет запись в fallback-логику
-- - при невозможности восстановления effective_main_id станет NULL
-- - такие записи далее не попадут в simple_mains_part, так как family_flags строится только по non-null main

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id

-- NOTE:
-- - аналогичен L5_MAIN_VALIDATION в CLASSIFIER_v1, но без диагностических полей
-- - для анализа проблем рекомендуется добавить candidate_main_problem, как в CLASSIFIER_v1
  

main_ok_eval AS (
  SELECT
    c.*,
    (
      c.candidate_main_id IS NOT NULL
      AND mc.id IS NOT NULL
      AND COALESCE(mc.deleted,true)=false
      AND (mc.system_number IS NOT NULL AND mc.system_number <> '')
      AND mc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER')
      AND COALESCE(mc.contract_type,'') NOT LIKE 'PKO%'
      AND (mc.lock_type IS DISTINCT FROM 'BLOCKED' OR mc.lock_type_reason IS DISTINCT FROM 'REVISED')
    ) AS candidate_main_ok_link
  FROM cards_with_candidate_main c
  LEFT JOIN contract_card mc ON mc.id = c.candidate_main_id
),


-- LOGIC_BLOCK: S8_BAD_MAIN_FOR_RECOVERY
-- PURPOSE: выделить карточки с невалидным candidate_main_id, для которых возможно восстановление main через prev_contract_card_id

-- RULE:
-- карточка направляется в восстановление, если:
-- - candidate_main_ok_link = false
-- - prev_contract_card_id IS NOT NULL

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
--   - prev_contract_card_id IS NOT NULL
-- TECHNICAL:
--   - отбор только записей, по которым возможно построить prev-chain

-- RISK:
-- - проблемные карточки без prev_contract_card_id не будут восстановлены
-- - некорректная prev-ссылка приведет к ошибочному восстановлению
-- - отсутствует диагностика причин исключения из recovery

-- FAILURE_MODE:
-- - effective_main_id останется NULL
-- - карточка не попадет в SIMPLE-выгрузку
-- - потенциально валидные договоры будут потеряны

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - prev_contract_card_id

-- NOTE:
-- - аналогичен L6_BAD_MAIN в CLASSIFIER_v1
  
  
bad_for_second_winner_search AS (
  SELECT *
  FROM main_ok_eval
  WHERE candidate_main_ok_link = false
    AND prev_contract_card_id IS NOT NULL
),


-- LOGIC_BLOCK: S9_PREV_CHAIN_RECURSION
-- PURPOSE: построить рекурсивную цепочку prev_contract_card_id для поиска fallback-main

-- RULE:
-- выполняется обход:
-- исходная карточка → prev_contract_card_id → prev_contract_card_id → ...
-- до обрыва цепочки, цикла или глубины 200.

-- INPUT:
-- primary:
--   - bad_for_second_winner_search
-- lookup:
--   - contract_card

-- OUTPUT:
-- dataset: prev_walk
-- key_fields:
--   - origin_contract_card_id
-- derived_fields:
--   - current_card_id
--   - depth
--   - path

-- FILTERS:
-- DATA_QUALITY:
--   - w.current_card_id IS NOT NULL
-- BUSINESS:
--   - отсутствуют
-- TECHNICAL:
--   - depth < 200
--   - NOT (cc.id = ANY(w.path))

-- RISK:
-- - prev_contract_card_id может быть битым или бизнес-неверным
-- - глубина 200 является техническим ограничением
-- - цепочка может содержать циклы
-- - path начинается с origin_contract_card_id, но не содержит current_card_id стартового шага до JOIN

-- FAILURE_MODE:
-- - fallback-main не будет найден
-- - будет найден неверный ADVERT_SECOND_WINNER
-- - часть цепочки может быть обрезана лимитом depth

-- TRACE_KEYS:
--   - origin_contract_card_id
--   - current_card_id
--   - depth

-- NOTE:
-- - аналогичен L7_PREV_CHAIN_RECURSION в CLASSIFIER_v1
  
  
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


-- LOGIC_BLOCK: S10_SECOND_WINNER_FOUND
-- PURPOSE: найти fallback-main типа ADVERT_SECOND_WINNER в цепочке prev_contract_card_id

-- RULE:
-- для каждой исходной проблемной карточки выбирается ближайший по depth контракт,
-- который:
-- - существует в prev-chain;
-- - не удален;
-- - имеет system_number;
-- - contract_type = 'ADVERT_SECOND_WINNER';
-- - не PKO%;
-- - не BLOCKED/REVISED;
-- - имеет хотя бы один не удаленный contract_item в EXECUTED lot.

-- INPUT:
-- primary:
--   - prev_walk
-- lookup:
--   - contract_card sw
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
--   - ci.deleted = false
-- BUSINESS:
--   - sw.contract_type = 'ADVERT_SECOND_WINNER'
--   - COALESCE(sw.contract_type,'') NOT LIKE 'PKO%'
--   - NOT BLOCKED/REVISED
--   - EXISTS связь с EXECUTED lot
-- TECHNICAL:
--   - DISTINCT ON (origin_contract_card_id)
--   - ORDER BY origin_contract_card_id, depth

-- RISK:
-- - ближайший ADVERT_SECOND_WINNER не обязательно является корректным бизнес-main
-- - альтернативные кандидаты теряются из-за DISTINCT ON
-- - EXISTS по EXECUTED lot может исключить потенциально корректный fallback-main
-- - логика полностью дублирует CLASSIFIER_v1

-- FAILURE_MODE:
-- - fallback-main не найден → effective_main_id = NULL
-- - выбран неправильный second winner
-- - SIMPLE-договор может быть потерян или ошибочно отнесен к другой семье

-- TRACE_KEYS:
--   - origin_contract_card_id
--   - found_second_winner_main_id
--   - depth через prev_walk

-- NOTE:
-- - аналогичен L8_SECOND_WINNER в CLASSIFIER_v1
  
  
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


-- LOGIC_BLOCK: S11_CARD_EFFECTIVE_MAIN
-- PURPOSE: определить финальный effective_main_id для каждой карточки договора

-- RULE:
-- effective_main_id выбирается по приоритету:
-- 1. если candidate_main_ok_link = true
--     → candidate_main_id
-- 2. иначе, если найден found_second_winner_main_id
--     → found_second_winner_main_id
-- 3. иначе
--     → NULL

-- INPUT:
-- primary:
--   - main_ok_eval
-- lookup:
--   - second_winner_found

-- OUTPUT:
-- dataset: card_effective_main
-- key_fields:
--   - contract_card_id
-- derived_fields:
--   - effective_main_id

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют
-- BUSINESS:
--   - приоритет валидного candidate_main перед fallback
-- TECHNICAL:
--   - LEFT JOIN сохраняет карточки без найденного fallback

-- RISK:
-- - отсутствует поле feature_or_problem, в отличие от CLASSIFIER_v1
-- - потери explainability в производственной SIMPLE-выгрузке
-- - effective_main_id = NULL далее фактически исключается из SIMPLE

-- FAILURE_MODE:
-- - карточки с NULL effective_main_id не попадут в family_flags
-- - потенциально простые договоры могут быть потеряны
-- - сложно диагностировать причины отсутствия в финальной выгрузке

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - effective_main_id
--   - found_second_winner_main_id

-- NOTE:
-- - аналогичен L9_EFFECTIVE_MAIN в CLASSIFIER_v1, но без feature_or_problem
-- - рекомендуется добавить diagnostic columns для сверки с CLASSIFIER
  
  
card_effective_main AS (
  SELECT
    m.*,
    CASE
      WHEN m.candidate_main_ok_link THEN m.candidate_main_id
      WHEN sw.found_second_winner_main_id IS NOT NULL THEN sw.found_second_winner_main_id
      ELSE NULL
    END AS effective_main_id
  FROM main_ok_eval m
  LEFT JOIN second_winner_found sw ON sw.origin_contract_card_id = m.contract_card_id
),


-- LOGIC_BLOCK: S12_FAMILY_FLAGS
-- PURPOSE: определить, есть ли в семье effective_main_id дополнительные соглашения

-- RULE:
-- семья считается имеющей допники, если среди карточек с одинаковым effective_main_id
-- есть хотя бы одна карточка, у которой:
-- contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER').

-- INPUT:
-- primary:
--   - card_effective_main

-- OUTPUT:
-- dataset: family_flags
-- key_fields:
--   - effective_main_id
-- derived_fields:
--   - has_any_supp_cards

-- FILTERS:
-- DATA_QUALITY:
--   - effective_main_id IS NOT NULL
-- BUSINESS:
--   - все contract_type, кроме ADVERT и ADVERT_SECOND_WINNER, считаются допниками
-- TECHNICAL:
--   - BOOL_OR агрегирует признак наличия допников

-- RISK:
-- - classification SIMPLE/COMPLEX полностью зависит от корректности contract_type
-- - нестандартные типы contract_type будут считаться допниками
-- - NULL effective_main_id исключаются из анализа семьи
-- - если допник не попал в cards_in_scope из-за отсутствия EXECUTED lot, семья может ошибочно стать SIMPLE

-- FAILURE_MODE:
-- - COMPLEX ошибочно классифицируется как SIMPLE
-- - SIMPLE ошибочно исключается как COMPLEX
-- - расхождение с CLASSIFIER_v1 при различии состава card_effective_main

-- TRACE_KEYS:
--   - effective_main_id

-- NOTE:
-- - аналогичен L10_FAMILY_FLAGS в CLASSIFIER_v1
-- - ключевой блок отбора DEFINITELY_SIMPLE
  
  
family_flags AS (
  SELECT
    effective_main_id,
    BOOL_OR(contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER')) AS has_any_supp_cards
  FROM card_effective_main
  WHERE effective_main_id IS NOT NULL
  GROUP BY effective_main_id
),


-- LOGIC_BLOCK: S13_SIMPLE_MAINS_PART
-- PURPOSE: выбрать main_contract_id, классифицированные как SIMPLE, с учетом технического партиционирования

-- RULE:
-- main_contract_id попадает в выгрузку, если:
-- - has_any_supp_cards = false;
-- - effective_main_id попадает в текущую часть выгрузки по MOD.

-- INPUT:
-- primary:
--   - family_flags
-- lookup:
--   - params

-- OUTPUT:
-- dataset: simple_mains_part
-- key_fields:
--   - main_contract_id
-- derived_fields:
--   - отсутствуют

-- FILTERS:
-- DATA_QUALITY:
--   - effective_main_id IS NOT NULL через family_flags
-- BUSINESS:
--   - ff.has_any_supp_cards = false
-- TECHNICAL:
--   - MOD(ABS(ff.effective_main_id)::bigint, p.parts_total::bigint) = (p.part - 1)::bigint

-- RISK:
-- - возвращается не вся SIMPLE-совокупность, а только одна техническая часть
-- - если effective_main_id отрицательный или выходит за bigint, возможны технические ошибки
-- - партиционирование по id может давать неравномерные части

-- FAILURE_MODE:
-- - неполная выгрузка
-- - ошибки сверки с CLASSIFIER_v1 при сравнении полного CLASSIFIER с одной частью SIMPLE
-- - дубли/пропуски при запуске нескольких частей с неправильными params

-- TRACE_KEYS:
--   - main_contract_id
--   - part
--   - parts_total

-- NOTE:
-- - это точка, где DEFINITELY_SIMPLE фактически отбирается из всех семей
-- - для полной выгрузки нужно выполнить все part = 1..parts_total или убрать партиционирование
  
  
simple_mains_part AS (
  SELECT ff.effective_main_id AS main_contract_id
  FROM family_flags ff
  JOIN params p ON true
  WHERE ff.has_any_supp_cards = false
    AND MOD(ABS(ff.effective_main_id)::bigint, p.parts_total::bigint) = (p.part - 1)::bigint
)


-- LOGIC_BLOCK: S14_FINAL_SIMPLE_EXPORT
-- PURPOSE: сформировать детальную выгрузку contract_item для SIMPLE main_contract_id

-- RULE:
-- для каждого SIMPLE main_contract_id возвращаются связанные карточки и предметы договора:
-- - contract_card attributes из card_effective_main;
-- - lot/adverts/tru_history из executed_lots;
-- - contract_item attributes;
-- - item_status из contract_item_status_history;
-- - расчетная сумма item_sum_no_nds_no_calc по статусу item.

-- INPUT:
-- primary:
--   - card_effective_main
-- lookup:
--   - simple_mains_part
--   - contract_item
--   - executed_lots
--   - contract_item_status_history

-- OUTPUT:
-- dataset: definitely_simple_export
-- grain:
--   - одна строка на contract_item, связанный с карточкой SIMPLE-семьи и EXECUTED lot
-- key_fields:
--   - main_contract_id
--   - contract_card_id
--   - contract_item_id
--   - lot_id
-- derived_fields:
--   - prev_contract_item_id
--   - item_status
--   - item_sum_no_nds_no_calc

-- FILTERS:
-- DATA_QUALITY:
--   - ci.deleted = false
--   - ci.contract_card_id = cem.contract_card_id
--   - ci.lot_id должен быть в executed_lots
-- BUSINESS:
--   - только SIMPLE main_contract_id из simple_mains_part
--   - только contract_item по EXECUTED lot
--   - UNDER_RESCISSION нормализуется в SIGNED
--   - для ADVERT_SECOND_WINNER prev_contract_item_id принудительно NULL
--   - для RESCIND/REFUSAL_PERFORM_CONTRACT сумма берется из execution_sum_no_nds
-- TECHNICAL:
--   - JOIN simple_mains_part отсекает COMPLEX и NULL main
--   - LEFT JOIN cish допускает отсутствие статуса contract_item
--   - ORDER BY используется только для представления результата

-- RISK:
-- - working_statuses не применяется, поэтому статусы contract_item не ограничены заявленным списком
-- - LEFT JOIN cish может дать item_status = NULL
-- - нормализация UNDER_RESCISSION → SIGNED может исказить исходное состояние предмета
-- - item_sum_no_nds_no_calc может стать NULL, если execution_sum_no_nds NULL для RESCIND/REFUSAL
-- - prev_contract_item_id обнуляется для ADVERT_SECOND_WINNER без проверки бизнес-основания
-- - SIMPLE-семья может содержать несколько contract_item, что важно для downstream агрегаций
-- - contract_sum_no_nds и item_sum_no_nds_no_calc находятся на разных grain

-- FAILURE_MODE:
-- - неверные суммы в отчетности
-- - потеря или искажение статусов предметов
-- - ошибочная интерпретация contract_sum как суммы строки item
-- - расхождение с методикой, если должны фильтроваться только working_statuses
-- - неполная выгрузка из-за params part/parts_total

-- TRACE_KEYS:
--   - main_contract_id
--   - contract_card_id
--   - contract_item_id
--   - lot_id
--   - advert_id
--   - tru_history_id

-- NOTE:
-- - финальный слой выгрузки SIMPLE
-- - GRAIN: contract_item_id в рамках SIMPLE main_contract_id
-- - не является агрегированной витриной
-- - требует отдельной сверки сумм на уровне item и contract_card
-- - для контроля качества рекомендуется добавить диагностические поля:
--     candidate_main_ok_link,
--     candidate_main_id,
--     effective_main_id,
--     normalized_status_flag,
--     sum_source_flag
  
  
SELECT
  cem.effective_main_id AS main_contract_id,

  cem.contract_card_id,
  cem.system_number AS contract_system_number,
  cem.contract_date_time,
  cem.duration_type,
  cem.contract_type,

  cem.customer_id,
  cem.supplier_id,
  cem.contract_sum_no_nds,

  ci.lot_id,
  el.advert_id,
  el.tru_history_id,

  ci.id AS contract_item_id,
  CASE WHEN cem.contract_type='ADVERT_SECOND_WINNER' THEN NULL ELSE ci.prev_contract_item_id END AS prev_contract_item_id,

  CASE WHEN cish.status='UNDER_RESCISSION' THEN 'SIGNED' ELSE cish.status END AS item_status,

  ci.sum_no_nds AS item_sum_no_nds_raw,
  ci.execution_sum_no_nds,

  CASE
    WHEN (CASE WHEN cish.status='UNDER_RESCISSION' THEN 'SIGNED' ELSE cish.status END)
         IN ('RESCIND','REFUSAL_PERFORM_CONTRACT')
      THEN ci.execution_sum_no_nds
    ELSE ci.sum_no_nds
  END AS item_sum_no_nds_no_calc
FROM card_effective_main cem
JOIN simple_mains_part sp ON sp.main_contract_id = cem.effective_main_id
JOIN contract_item ci ON ci.contract_card_id = cem.contract_card_id AND ci.deleted=false
JOIN executed_lots el ON el.lot_id = ci.lot_id
LEFT JOIN contract_item_status_history cish ON cish.id = ci.status_history_id
ORDER BY main_contract_id, ci.lot_id, cem.contract_date_time, ci.id;
