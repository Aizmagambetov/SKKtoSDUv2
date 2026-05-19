
/*
SCRIPT: DEFINITELY_COMPLEX_v1
ROLE: PRODUCTION / CALCULATION LAYER
LAYER: transformation / calculation export
SOURCE: Мура
VERSION: v1 (baseline)
STATUS: NOT VALIDATED

DESCRIPTION:
Назначение: сформировать расчетную выгрузку по договорам, классифицированным как
DEFINITELY_COMPLEX, то есть по семьям main-договоров, где есть хотя бы одна карточка
дополнительного соглашения.

Скрипт:
- формирует входной контур через EXECUTED-лоты;
- определяет contract_card в контуре;
- определяет candidate main;
- валидирует candidate main;
- при необходимости восстанавливает main через prev_contract_card_id
  с поиском ADVERT_SECOND_WINNER;
- определяет COMPLEX-семьи по наличию карточек-допников;
- строит seed_items по contract_item внутри COMPLEX-семей;
- исключает branching lots, где несколько предметов ссылаются на один prev_nav;
- выбирает финальный последний item по каждому main_contract_id + lot_id;
- рекурсивно восстанавливает цепочку contract_item через prev_contract_item_id;
- фильтрует цепочку по working_statuses;
- рассчитывает суммы через delta-логику;
- возвращает строки, участвующие в расчете sum_no_nds_calc.

Ключевые фильтры:
- только EXECUTED-лоты: lot_status_history.status = 'EXECUTED'
- только не удаленные contract_item: ci.deleted = false
- только не удаленные contract_card: cc.deleted = false
- только карточки с непустым system_number
- исключаются PKO% contract_type
- исключаются BLOCKED/REVISED contract_card
- в расчетной цепочке используются только item_status из working_statuses

Ключевая логика main:
- если contract_type IN ('ADVERT','ADVERT_SECOND_WINNER')
    → main = сам contract_card_id
- иначе
    → main = main_contract_card_id
- если candidate_main_id невалиден
    → попытка восстановления через prev_contract_card_id
       с поиском ADVERT_SECOND_WINNER.

Ключевая логика COMPLEX:
- семья считается COMPLEX, если среди карточек с одинаковым effective_main_id
  есть хотя бы одна карточка с contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER').

Ключевая логика item-chain:
- для каждого main_contract_id + lot_id выбирается последний предмет по:
  contract_date_time DESC NULLS LAST, contract_item_id DESC
- далее строится цепочка назад через prev_contract_item_id
- для ADVERT_SECOND_WINNER prev_nav принудительно NULL
- цепочка ограничена max_item_chain_depth
- циклы предотвращаются через path.

Ключевая логика сумм:
- если последний item цепочки имеет статус RESCIND или REFUSAL_PERFORM_CONTRACT,
  то для всех строк цепочки sum_for_calc = execution_sum_no_nds
- иначе:
    - для RESCIND / REFUSAL_PERFORM_CONTRACT берется execution_sum_no_nds
    - для остальных статусов берется item_sum_no_nds_raw
- далее считается delta между последовательными значениями цепочки
- в финальный результат попадает:
    - базовая строка цепочки depth = max_depth
    - строки, где delta > 0
- для базовой строки:
    sum_no_nds_calc = sum_for_calc + sum_negative_deltas
- для положительных изменений:
    sum_no_nds_calc = delta

NOTES:
Получено в текущей форме от Муры.
Не валидировалось.
Логика частично дублирует CLASSIFIER_v1 и DEFINITELY_SIMPLE_v1.
Скрипт содержит отдельную расчетную модель по цепочкам contract_item,
которой нет в CLASSIFIER_v1.
SQL следует рассматривать как проверяемую гипотезу, а не как подтвержденную бизнес-логику.

USAGE:
- формирование расчетной выгрузки по сложным договорам;
- анализ цепочек contract_item;
- расчет сумм по изменениям договоров / допсоглашений;
- контроль расхождений с SIMPLE и CLASSIFIER;
- диагностика проблем в prev_contract_item_id и prev_contract_card_id.

LIMITATION:
- логика не прошла бизнес-валидацию;
- CLASSIFIER_v1 не используется напрямую, логика main продублирована;
- возможны расхождения между CLASSIFIER_v1, SIMPLE и COMPLEX;
- разбиение через params может возвращать только часть данных;
- branching lots полностью исключаются из расчета;
- выбор последнего item через contract_date_time/id может быть не бизнес-корректным;
- нормализация UNDER_RESCISSION → SIGNED может искажать исходный статус;
- COALESCE сумм к 0 может скрывать пропуски данных;
- delta-логика требует отдельной сверки с методикой.
*/

WITH RECURSIVE


-- LOGIC_BLOCK: C1_PARAMS
-- PURPOSE: задать технические параметры партиционирования и ограничения глубины рекурсий

-- RULE:
-- используются параметры:
-- - part / parts_total для разбиения COMPLEX main_contract_id на части;
-- - max_prev_depth для обхода prev_contract_card_id;
-- - max_item_chain_depth для обхода prev_contract_item_id.

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
--   - max_prev_depth
--   - max_item_chain_depth

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют
-- BUSINESS:
--   - отсутствуют
-- TECHNICAL:
--   - part должен быть в диапазоне 1..parts_total
--   - max_prev_depth ограничивает рекурсию contract_card
--   - max_item_chain_depth ограничивает рекурсию contract_item

-- RISK:
-- - при parts_total > 1 выгрузка возвращает только часть данных
-- - лимиты глубины могут обрезать реальные цепочки
-- - ручное изменение part может привести к пропускам или дублям при выгрузке

-- FAILURE_MODE:
-- - неполная выгрузка COMPLEX
-- - обрыв цепочек contract_card или contract_item
-- - неверный расчет из-за неполной цепочки

-- TRACE_KEYS:
--   - part
--   - parts_total
--   - max_prev_depth
--   - max_item_chain_depth

-- NOTE:
-- - технический блок
-- - при сверке с CLASSIFIER_v1 нужно учитывать партиционирование
    
    
params AS (
    SELECT
        1::int  AS part,            -- 1..2
        2::int AS parts_total,
        200::int AS max_prev_depth,
        120::int AS max_item_chain_depth
),


-- LOGIC_BLOCK: C2_WORKING_STATUSES
-- PURPOSE: определить список статусов contract_item, допустимых для расчетной цепочки

-- RULE:
-- в расчет допускаются только contract_item со статусами:
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
--   - список статусов, допустимых для расчета
-- TECHNICAL:
--   - unnest массива статусов

-- RISK:
-- - список статусов жестко зашит в SQL
-- - отсутствует внешний справочник допустимых статусов
-- - если методика изменилась, SQL может устареть
-- - UNDER_RESCISSION не включен напрямую, но позже нормализуется в SIGNED

-- FAILURE_MODE:
-- - contract_item с новым/нестандартным статусом будет исключен из расчета
-- - сумма по цепочке будет неполной
-- - расхождение с методикой при изменении перечня допустимых статусов

-- TRACE_KEYS:
--   - status

-- NOTE:
-- - в отличие от DEFINITELY_SIMPLE, здесь working_statuses реально используется
-- - используется в seed_items как calc_eligible и в eligible_chain_base
    
    
working_statuses AS (
    SELECT unnest(ARRAY[
        'EXECUTED','REFUSAL_PERFORM_CONTRACT','SIGNED','RESCIND','SUPPLEMENTARY_AGREEMENT'
    ]) AS status
),


-- LOGIC_BLOCK: C3_EXECUTED_LOTS
-- PURPOSE: отобрать EXECUTED-лоты как входной контур данных

-- RULE:
-- выбираются только лоты со статусом lot_status_history.status = 'EXECUTED'

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
--   - INNER JOIN исключает лоты без status_history

-- RISK:
-- - некорректный статус лота приведет к неправильному входному контуру
-- - только EXECUTED-лоты участвуют и в main-логике, и в item-chain расчете

-- FAILURE_MODE:
-- - исполненные лоты могут быть пропущены
-- - неисполненные лоты могут попасть в расчет при ошибочном статусе
-- - downstream классификация и суммы будут искажены

-- TRACE_KEYS:
--   - lot_id
--   - advert_id
--   - tru_history_id

-- NOTE:
-- - аналог L1 CLASSIFIER и S3 SIMPLE
-- - tru_history_id используется в финальном результате
    
    
executed_lots AS (
    SELECT l.id AS lot_id, l.advert_id, l.tru_history_id
    FROM lot l
    JOIN lot_status_history lsh ON lsh.id = l.status_history_id
    WHERE lsh.status = 'EXECUTED'
),


-- LOGIC_BLOCK: C4_CARDS_IN_SCOPE
-- PURPOSE: сформировать множество contract_card, связанных с EXECUTED-лотами

-- RULE:
-- contract_card попадает в контур, если:
-- - имеет не удаленный contract_item;
-- - contract_item относится к EXECUTED lot;
-- - contract_card не удалена;
-- - system_number заполнен;
-- - contract_type не PKO%;
-- - карточка не BLOCKED/REVISED.

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
--   - NOT BLOCKED/REVISED
-- TECHNICAL:
--   - DISTINCT устраняет дубли contract_card_id

-- RISK:
-- - DISTINCT скрывает кратность contract_card → contract_item
-- - допник без EXECUTED lot не попадет в контур
-- - это может ошибочно превратить COMPLEX-семью в SIMPLE в других скриптах или исключить из COMPLEX здесь

-- FAILURE_MODE:
-- - неполный состав contract_card
-- - неверная классификация семьи
-- - расхождение с CLASSIFIER/SIMPLE при различии фильтров

-- TRACE_KEYS:
--   - contract_card_id
--   - lot_id через contract_item

-- NOTE:
-- - первая критическая точка data reduction

    
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


-- LOGIC_BLOCK: C5_BASE_CARDS
-- PURPOSE: обогатить contract_card атрибутами для main-логики и финального расчета

-- RULE:
-- для contract_card из cards_in_scope выбираются необходимые атрибуты.
-- Повторно применяются фильтры качества и бизнес-исключения.

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
--   - contract_sum_no_nds
--   - execution_sum_no_nds
--   - customer_id
--   - supplier_id

-- FILTERS:
-- DATA_QUALITY:
--   - cc.deleted = false
--   - cc.system_number IS NOT NULL AND cc.system_number <> ''
-- BUSINESS:
--   - COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
--   - NOT BLOCKED/REVISED
-- TECHNICAL:
--   - повторная фильтрация из C4

-- RISK:
-- - дублирование фильтров с C4
-- - возможная рассинхронизация логики при будущих изменениях
-- - contract_sum_no_nds находится на уровне карточки, а расчет выполняется на уровне item-chain

-- FAILURE_MODE:
-- - потеря карточек перед main-логикой
-- - неконсистентность сумм при интерпретации grain
-- - расхождение с SIMPLE/CLASSIFIER

-- TRACE_KEYS:
--   - contract_card_id
--   - main_contract_card_id
--   - prev_contract_card_id

-- NOTE:
-- - аналог L3 CLASSIFIER и S5 SIMPLE

    
base_cards AS (
    SELECT
        cc.id AS contract_card_id,
        cc.main_contract_card_id,
        cc.prev_contract_card_id,
        cc.contract_date_time,
        cc.system_number,
        cc.contract_type,
        cc.duration_type,
        cc.sum_no_nds AS contract_sum_no_nds,
        cc.execution_sum_no_nds,
        cc.customer_id,
        cc.supplier_id,
        cc.lock_type,
        cc.lock_type_reason
    FROM contract_card cc
    JOIN cards_in_scope s ON s.contract_card_id = cc.id
    WHERE cc.deleted = false
      AND cc.system_number IS NOT NULL AND cc.system_number <> ''
      AND COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
      AND (cc.lock_type IS DISTINCT FROM 'BLOCKED' OR cc.lock_type_reason IS DISTINCT FROM 'REVISED')
),


-- LOGIC_BLOCK: C6_CANDIDATE_MAIN
-- PURPOSE: определить candidate_main_id для каждой contract_card

-- RULE:
-- если contract_type IN ('ADVERT','ADVERT_SECOND_WINNER')
--   → candidate_main_id = contract_card_id
-- иначе
--   → candidate_main_id = main_contract_card_id

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
--   - main определяется через contract_type
-- TECHNICAL:
--   - CASE-логика

-- RISK:
-- - contract_type может быть ошибочным
-- - main_contract_card_id может быть NULL или битой ссылкой
-- - ADVERT_SECOND_WINNER приравнивается к main

-- FAILURE_MODE:
-- - неверный effective_main_id
-- - неверная COMPLEX-классификация
-- - неправильная сборка item-chain по main_contract_id

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - main_contract_card_id
--   - contract_type

-- NOTE:
-- - аналог L4 CLASSIFIER

    
cards_with_candidate_main AS (
    SELECT
        bc.*,
        CASE
            WHEN bc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER') THEN bc.contract_card_id
            ELSE bc.main_contract_card_id
        END AS candidate_main_id
    FROM base_cards bc
),


-- LOGIC_BLOCK: C7_MAIN_VALIDATION
-- PURPOSE: проверить корректность candidate_main_id

-- RULE:
-- candidate_main валиден, если:
-- - candidate_main_id не NULL;
-- - main-карточка существует;
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
--   - main_exists_id
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
--   - LEFT JOIN сохраняет строки для проверки несуществующего main

-- RISK:
-- - нет candidate_main_problem / feature_or_problem как в CLASSIFIER
-- - потеря объяснимости причин некорректного main
-- - дублирование логики CLASSIFIER может рассинхронизироваться

-- FAILURE_MODE:
-- - candidate_main_ok_link=false отправит строку в fallback
-- - при неуспешном fallback effective_main_id=NULL
-- - такие строки не попадут в COMPLEX-расчет

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - main_exists_id

-- NOTE:
-- - рекомендуется добавить diagnostic columns для сверки с CLASSIFIER

    
main_ok_eval AS (
    SELECT
        c.*,
        mc.id AS main_exists_id,
        (
            c.candidate_main_id IS NOT NULL
            AND mc.id IS NOT NULL
            AND COALESCE(mc.deleted,true)=false
            AND (mc.system_number IS NOT NULL AND mc.system_number<>'' )
            AND mc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER')
            AND COALESCE(mc.contract_type,'') NOT LIKE 'PKO%'
            AND (mc.lock_type IS DISTINCT FROM 'BLOCKED' OR mc.lock_type_reason IS DISTINCT FROM 'REVISED')
        ) AS candidate_main_ok_link
    FROM cards_with_candidate_main c
    LEFT JOIN contract_card mc ON mc.id = c.candidate_main_id
),


-- LOGIC_BLOCK: C8_BAD_MAIN_FOR_RECOVERY
-- PURPOSE: выделить карточки с невалидным candidate_main_id для восстановления main через prev_contract_card_id

-- RULE:
-- карточка направляется в recovery, если:
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
--   - отбираются только строки, где возможен prev-chain

-- RISK:
-- - проблемные карточки без prev_contract_card_id не восстанавливаются
-- - некорректный prev_contract_card_id приведет к неверному fallback
-- - нет диагностики причины исключения из recovery

-- FAILURE_MODE:
-- - effective_main_id=NULL
-- - карточка не попадет в family_agg
-- - потенциально COMPLEX-договор будет потерян

-- TRACE_KEYS:
--   - contract_card_id
--   - candidate_main_id
--   - prev_contract_card_id

-- NOTE:
-- - аналог L6 CLASSIFIER

    
bad_for_second_winner_search AS (
    SELECT *
    FROM main_ok_eval
    WHERE candidate_main_ok_link = false
      AND prev_contract_card_id IS NOT NULL
),


-- LOGIC_BLOCK: C9_PREV_CARD_CHAIN
-- PURPOSE: рекурсивно построить цепочку contract_card через prev_contract_card_id

-- RULE:
-- выполняется обход:
-- contract_card → prev_contract_card_id → ...
-- пока:
-- - current_card_id не NULL;
-- - depth < max_prev_depth;
-- - не найден цикл.

-- INPUT:
-- primary:
--   - bad_for_second_winner_search
-- lookup:
--   - contract_card
--   - params

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
--   - depth < p.max_prev_depth
--   - NOT (cc.id = ANY(w.path))

-- RISK:
-- - цепочка может быть битой
-- - цепочка может быть циклической
-- - max_prev_depth может обрезать длинные цепочки
-- - prev_contract_card_id может не соответствовать бизнес-цепочке

-- FAILURE_MODE:
-- - fallback ADVERT_SECOND_WINNER не найден
-- - найден неверный fallback
-- - downstream family_agg получит неправильный effective_main_id

-- TRACE_KEYS:
--   - origin_contract_card_id
--   - current_card_id
--   - depth

-- NOTE:
-- - аналог L7 CLASSIFIER, но глубина вынесена в params

    
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
    JOIN params p ON true
    WHERE w.current_card_id IS NOT NULL
      AND w.depth < p.max_prev_depth
      AND NOT (cc.id = ANY(w.path))
),


-- LOGIC_BLOCK: C10_SECOND_WINNER_FOUND
-- PURPOSE: найти fallback-main типа ADVERT_SECOND_WINNER в prev-card-chain

-- RULE:
-- выбирается ближайший по depth ADVERT_SECOND_WINNER, который:
-- - не удален;
-- - имеет system_number;
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
--   - sw.contract_type NOT LIKE 'PKO%'
--   - NOT BLOCKED/REVISED
--   - EXISTS связь с EXECUTED lot
-- TECHNICAL:
--   - DISTINCT ON
--   - ORDER BY origin_contract_card_id, depth

-- RISK:
-- - ближайший ADVERT_SECOND_WINNER может быть не бизнес-main
-- - альтернативные кандидаты теряются
-- - EXISTS по EXECUTED lot может отсеять корректный fallback
-- - логика дублирует CLASSIFIER/SIMPLE

-- FAILURE_MODE:
-- - fallback не найден
-- - effective_main_id=NULL
-- - COMPLEX-семья может быть потеряна

-- TRACE_KEYS:
--   - origin_contract_card_id
--   - found_second_winner_main_id
--   - depth

-- NOTE:
-- - аналог L8 CLASSIFIER

    
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


-- LOGIC_BLOCK: C11_CARD_EFFECTIVE_MAIN
-- PURPOSE: определить effective_main_id для каждой contract_card

-- RULE:
-- effective_main_id выбирается:
-- 1. candidate_main_id, если candidate_main_ok_link = true;
-- 2. found_second_winner_main_id, если fallback найден;
-- 3. NULL, если main определить невозможно.

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
--   - приоритет валидного candidate_main над fallback
-- TECHNICAL:
--   - LEFT JOIN сохраняет карточки без fallback

-- RISK:
-- - нет feature_or_problem
-- - часть диагностических полей отбрасывается
-- - incorrect effective_main_id влияет и на классификацию COMPLEX, и на расчет цепочек

-- FAILURE_MODE:
-- - карточки с NULL effective_main_id не попадут в family_agg
-- - неверное объединение contract_item в main_contract_id
-- - некорректный расчет сумм

-- TRACE_KEYS:
--   - contract_card_id
--   - effective_main_id
--   - prev_contract_card_id

-- NOTE:
-- - аналог L9 CLASSIFIER, но без explainability

    
card_effective_main AS (
    SELECT
        m.contract_card_id,
        m.contract_type,
        m.duration_type,
        m.contract_date_time,
        m.system_number AS contract_system_number,
        m.customer_id,
        m.supplier_id,
        m.contract_sum_no_nds,
        m.execution_sum_no_nds,
        m.prev_contract_card_id,
        CASE
            WHEN m.candidate_main_ok_link THEN m.candidate_main_id
            WHEN sw.found_second_winner_main_id IS NOT NULL THEN sw.found_second_winner_main_id
            ELSE NULL
        END AS effective_main_id
    FROM main_ok_eval m
    LEFT JOIN second_winner_found sw ON sw.origin_contract_card_id = m.contract_card_id
),


-- LOGIC_BLOCK: C12_FAMILY_AGG
-- PURPOSE: определить наличие допников в семье effective_main_id

-- RULE:
-- семья считается COMPLEX, если среди contract_card с одинаковым effective_main_id
-- есть хотя бы одна карточка с contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER').

-- INPUT:
-- primary:
--   - card_effective_main

-- OUTPUT:
-- dataset: family_agg
-- key_fields:
--   - effective_main_id
-- derived_fields:
--   - has_any_supp_cards

-- FILTERS:
-- DATA_QUALITY:
--   - effective_main_id IS NOT NULL
-- BUSINESS:
--   - все типы кроме ADVERT/ADVERT_SECOND_WINNER считаются допниками
-- TECHNICAL:
--   - BOOL_OR

-- RISK:
-- - классификация зависит от contract_type
-- - если допник не попал в cards_in_scope, семья может быть ошибочно не COMPLEX
-- - нестандартные contract_type автоматически считаются допниками

-- FAILURE_MODE:
-- - SIMPLE/COMPLEX misclassification
-- - потеря COMPLEX-договоров
-- - расхождение с CLASSIFIER

-- TRACE_KEYS:
--   - effective_main_id

-- NOTE:
-- - аналог L10 CLASSIFIER / S12 SIMPLE

    
family_agg AS (
    SELECT
        cem.effective_main_id,
        BOOL_OR(cem.contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER')) AS has_any_supp_cards
    FROM card_effective_main cem
    WHERE cem.effective_main_id IS NOT NULL
    GROUP BY cem.effective_main_id
),


-- LOGIC_BLOCK: C13_COMPLEX_MAIN_IDS_PART
-- PURPOSE: выбрать COMPLEX main_contract_id с учетом технического партиционирования

-- RULE:
-- main_contract_id включается, если:
-- - has_any_supp_cards = true;
-- - effective_main_id попадает в текущую часть по MOD.

-- INPUT:
-- primary:
--   - family_agg
-- lookup:
--   - params

-- OUTPUT:
-- dataset: complex_main_ids_part
-- key_fields:
--   - main_contract_id
-- derived_fields:
--   - отсутствуют

-- FILTERS:
-- DATA_QUALITY:
--   - effective_main_id IS NOT NULL через family_agg
-- BUSINESS:
--   - fa.has_any_supp_cards = true
-- TECHNICAL:
--   - MOD(ABS(fa.effective_main_id), parts_total) = part - 1

-- RISK:
-- - выгрузка возвращает только часть COMPLEX-договоров
-- - партиционирование по id может быть неравномерным
-- - при сверке с CLASSIFIER можно получить ложные расхождения

-- FAILURE_MODE:
-- - неполная выгрузка
-- - пропуски/дубли при неправильном запуске частей
-- - некорректная сверка с полным набором данных

-- TRACE_KEYS:
--   - main_contract_id
--   - part
--   - parts_total

-- NOTE:
-- - фактическая точка отбора DEFINITELY_COMPLEX

    
complex_main_ids_part AS (
    SELECT fa.effective_main_id AS main_contract_id
    FROM family_agg fa
    JOIN params p ON true
    WHERE fa.has_any_supp_cards = true
      AND MOD(ABS(fa.effective_main_id)::bigint, p.parts_total::bigint) = (p.part - 1)::bigint
),


-- LOGIC_BLOCK: C14_SEED_ITEMS
-- PURPOSE: сформировать исходный набор contract_item для COMPLEX main_contract_id

-- RULE:
-- для contract_card из COMPLEX-семей выбираются связанные contract_item по EXECUTED lot.
-- Рассчитываются:
-- - prev_nav: навигационная ссылка для построения item-chain;
-- - prev_raw: исходная prev_contract_item_id;
-- - item_status с нормализацией UNDER_RESCISSION → SIGNED;
-- - calc_eligible: входит ли normalized status в working_statuses.

-- INPUT:
-- primary:
--   - card_effective_main
-- lookup:
--   - complex_main_ids_part
--   - contract_card
--   - contract_item
--   - executed_lots
--   - contract_item_status_history
--   - working_statuses

-- OUTPUT:
-- dataset: seed_items
-- key_fields:
--   - main_contract_id
--   - contract_card_id
--   - contract_item_id
--   - lot_id
-- derived_fields:
--   - prev_nav
--   - prev_raw
--   - item_status
--   - calc_eligible

-- FILTERS:
-- DATA_QUALITY:
--   - cc.deleted = false
--   - ci.deleted = false
--   - cc.system_number IS NOT NULL AND cc.system_number <> ''
-- BUSINESS:
--   - только COMPLEX main_contract_id
--   - только EXECUTED lot
--   - contract_type NOT LIKE 'PKO%'
--   - NOT BLOCKED/REVISED
--   - UNDER_RESCISSION нормализуется в SIGNED
--   - для ADVERT_SECOND_WINNER prev_nav = NULL
-- TECHNICAL:
--   - calc_eligible считается через IN working_statuses, но пока не фильтрует строки

-- RISK:
-- - seed_items может содержать calc_eligible=false, которые позже отсекаются
-- - LEFT JOIN cish может дать item_status=NULL
-- - нормализация UNDER_RESCISSION → SIGNED скрывает исходный статус
-- - prev_nav искусственно обнуляется для ADVERT_SECOND_WINNER
-- - повторный JOIN contract_card после card_effective_main дублирует фильтры

-- FAILURE_MODE:
-- - часть item не попадет в расчетную цепочку
-- - цепочка оборвется из-за prev_nav=NULL
-- - неправильный стартовый item по лоту
-- - потеря explainability по статусам

-- TRACE_KEYS:
--   - main_contract_id
--   - contract_card_id
--   - contract_item_id
--   - lot_id
--   - prev_raw
--   - prev_nav

-- NOTE:
-- - начало специфичной для COMPLEX расчетной логики
-- - grain: contract_item_id

    
seed_items AS (
    SELECT
        cem.effective_main_id AS main_contract_id,

        cc.id AS contract_card_id,
        cc.system_number AS contract_system_number,
        cc.contract_type,
        cc.contract_date_time,
        cc.duration_type,

        cc.customer_id,
        cc.supplier_id,
        cc.sum_no_nds AS contract_sum_no_nds,

        ci.id AS contract_item_id,
        el.lot_id,
        el.advert_id,
        el.tru_history_id,

        ci.sum_no_nds AS item_sum_no_nds_raw,
        ci.execution_sum_no_nds,

        CASE WHEN cc.contract_type='ADVERT_SECOND_WINNER' THEN NULL ELSE ci.prev_contract_item_id END AS prev_nav,
        ci.prev_contract_item_id AS prev_raw,

        /* статус предмета (лот/предмет) */
        CASE WHEN cish.status='UNDER_RESCISSION' THEN 'SIGNED' ELSE cish.status END AS item_status,

        (
          (CASE WHEN cish.status='UNDER_RESCISSION' THEN 'SIGNED' ELSE cish.status END)
          IN (SELECT status FROM working_statuses)
        ) AS calc_eligible
    FROM card_effective_main cem
    JOIN complex_main_ids_part mp ON mp.main_contract_id = cem.effective_main_id
    JOIN contract_card cc ON cc.id = cem.contract_card_id AND cc.deleted=false
    JOIN contract_item ci ON ci.contract_card_id = cc.id AND ci.deleted=false
    JOIN executed_lots el ON el.lot_id = ci.lot_id
    LEFT JOIN contract_item_status_history cish ON cish.id = ci.status_history_id
    WHERE cc.system_number IS NOT NULL AND cc.system_number <> ''
      AND COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
      AND (cc.lock_type IS DISTINCT FROM 'BLOCKED' OR cc.lock_type_reason IS DISTINCT FROM 'REVISED')
),


-- LOGIC_BLOCK: C15_BRANCHING_LOTS
-- PURPOSE: выявить лоты с ветвлением item-chain, которые невозможно однозначно рассчитать текущей линейной логикой

-- RULE:
-- branching lot определяется, если в рамках main_contract_id + lot_id
-- существует один и тот же prev_nav, на который ссылается более одной строки seed_items.

-- INPUT:
-- primary:
--   - seed_items

-- OUTPUT:
-- dataset: branching_lots
-- key_fields:
--   - main_contract_id
--   - lot_id

-- FILTERS:
-- DATA_QUALITY:
--   - calc_eligible = true
--   - prev_nav IS NOT NULL
-- BUSINESS:
--   - неоднозначная цепочка исключается из расчета
-- TECHNICAL:
--   - GROUP BY main_contract_id, lot_id, prev_nav
--   - HAVING COUNT(*) > 1

-- RISK:
-- - весь lot исключается из расчета при обнаружении ветвления
-- - причина исключения не попадает в финальный результат
-- - возможна потеря значимой суммы
-- - ветвление может быть валидным бизнес-сценарием, но SQL его не поддерживает

-- FAILURE_MODE:
-- - COMPLEX-договор будет недорассчитан
-- - отсутствующие строки в calc_output без явной диагностики
-- - расхождение с методикой, если ветвления нужно обрабатывать, а не исключать

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - prev_nav

-- NOTE:
-- - важная точка исключения данных
-- - рекомендуется формировать отдельную diagnostic выгрузку branching_lots

    
branching_lots AS (
    SELECT DISTINCT main_contract_id, lot_id
    FROM (
        SELECT main_contract_id, lot_id, prev_nav
        FROM seed_items
        WHERE calc_eligible=true AND prev_nav IS NOT NULL
        GROUP BY main_contract_id, lot_id, prev_nav
        HAVING COUNT(*) > 1
    ) t
),


-- LOGIC_BLOCK: C16_FINAL_ITEM
-- PURPOSE: выбрать стартовый последний item для построения обратной цепочки по каждому main_contract_id + lot_id

-- RULE:
-- для каждого main_contract_id + lot_id выбирается одна строка:
-- - только calc_eligible=true;
-- - исключаются branching_lots;
-- - выбирается последняя по contract_date_time DESC NULLS LAST, contract_item_id DESC.

-- INPUT:
-- primary:
--   - seed_items
-- lookup:
--   - branching_lots

-- OUTPUT:
-- dataset: final_item
-- key_fields:
--   - main_contract_id
--   - lot_id
-- derived_fields:
--   - contract_item_id как стартовая точка chain_all
--   - prev_raw
--   - prev_nav

-- FILTERS:
-- DATA_QUALITY:
--   - calc_eligible = true
-- BUSINESS:
--   - исключение неоднозначных branching lots
--   - выбор последнего contract_item как актуального состояния лота
-- TECHNICAL:
--   - DISTINCT ON (main_contract_id, lot_id)
--   - ORDER BY contract_date_time DESC NULLS LAST, contract_item_id DESC

-- RISK:
-- - contract_date_time может не отражать фактическую последовательность item
-- - при одинаковых датах используется contract_item_id DESC как tie-breaker
-- - исключение branching_lots может скрыть проблемные данные
-- - выбор одного item делает представление lossy

-- FAILURE_MODE:
-- - цепочка строится не от актуального item
-- - расчет суммы идет по неверной версии договора
-- - часть лотов полностью исчезает из расчета

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
--   - prev_nav

-- NOTE:
-- - critical decision point для item-chain
-- - определяет, откуда начинается обратный обход

    
final_item AS (
    SELECT DISTINCT ON (s.main_contract_id, s.lot_id)
        s.main_contract_id,
        s.lot_id,
        s.advert_id,
        s.tru_history_id,

        s.contract_card_id,
        s.contract_system_number,
        s.contract_type,
        s.contract_date_time,
        s.duration_type,

        s.customer_id,
        s.supplier_id,

        s.contract_sum_no_nds,

        s.contract_item_id,
        s.item_status,
        s.item_sum_no_nds_raw,
        s.execution_sum_no_nds,

        s.prev_raw,
        s.prev_nav
    FROM seed_items s
    WHERE s.calc_eligible=true
      AND NOT EXISTS (
          SELECT 1
          FROM branching_lots bl
          WHERE bl.main_contract_id = s.main_contract_id
            AND bl.lot_id = s.lot_id
      )
    ORDER BY s.main_contract_id, s.lot_id, s.contract_date_time DESC NULLS LAST, s.contract_item_id DESC
),


-- LOGIC_BLOCK: C17_ITEM_CHAIN_RECURSION
-- PURPOSE: построить обратную цепочку contract_item через prev_contract_item_id

-- RULE:
-- chain_all строится от final_item назад:
-- current item → prev_nav → prev_nav → ...
-- Рекурсия продолжается, пока:
-- - prev_nav IS NOT NULL;
-- - depth < max_item_chain_depth;
-- - previous item не удален;
-- - previous card не удалена;
-- - previous item относится к тому же lot_id;
-- - previous card проходит фильтры PKO / BLOCKED / system_number;
-- - не обнаружен цикл.

-- INPUT:
-- primary:
--   - final_item
-- lookup:
--   - contract_item pci
--   - contract_card pcc
--   - contract_item_status_history pcish
--   - params

-- OUTPUT:
-- dataset: chain_all
-- key_fields:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
-- derived_fields:
--   - depth
--   - path
--   - prev_raw
--   - prev_nav
--   - item_status

-- FILTERS:
-- DATA_QUALITY:
--   - pci.deleted = false
--   - pcc.deleted = false
--   - pcc.system_number IS NOT NULL AND pcc.system_number <> ''
--   - pci.lot_id = c.lot_id
-- BUSINESS:
--   - pcc.contract_type NOT LIKE 'PKO%'
--   - NOT BLOCKED/REVISED
--   - UNDER_RESCISSION нормализуется в SIGNED
--   - ADVERT_SECOND_WINNER обрывает навигацию prev_nav=NULL
-- TECHNICAL:
--   - depth < max_item_chain_depth
--   - NOT (pci.id = ANY(c.path))

-- RISK:
-- - цепочка может быть оборвана из-за фильтра pci.lot_id = c.lot_id
-- - prev_contract_item_id может ссылаться на item другого lot
-- - depth limit может обрезать длинную цепочку
-- - циклы скрываются, но не диагностируются в результате
-- - статусы фильтруются позже, а не на этапе рекурсии

-- FAILURE_MODE:
-- - неполная item-chain
-- - неверный delta-расчет
-- - потеря исторических изменений
-- - отсутствие диагностики причин обрыва цепочки

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
--   - prev_raw
--   - prev_nav
--   - depth

-- NOTE:
-- - центральный расчетный блок COMPLEX
-- - depth=0 соответствует выбранному последнему item
-- - чем больше depth, тем более ранний item в цепочке

    
chain_all AS (
    SELECT
        f.main_contract_id,
        f.lot_id,
        f.advert_id,
        f.tru_history_id,

        f.contract_item_id,
        f.contract_card_id,
        f.contract_system_number,
        f.contract_type,
        f.contract_date_time,
        f.duration_type,

        f.customer_id,
        f.supplier_id,

        f.contract_sum_no_nds,
        f.item_sum_no_nds_raw,
        f.execution_sum_no_nds,

        f.item_status,

        f.prev_raw,
        f.prev_nav,

        0 AS depth,
        ARRAY[f.contract_item_id]::bigint[] AS path
    FROM final_item f

    UNION ALL

    SELECT
        c.main_contract_id,
        c.lot_id,
        c.advert_id,
        c.tru_history_id,

        pci.id AS contract_item_id,
        pcc.id AS contract_card_id,
        pcc.system_number AS contract_system_number,
        pcc.contract_type,
        pcc.contract_date_time,
        pcc.duration_type,

        pcc.customer_id,
        pcc.supplier_id,

        pcc.sum_no_nds AS contract_sum_no_nds,
        pci.sum_no_nds AS item_sum_no_nds_raw,
        pci.execution_sum_no_nds,

        CASE WHEN pcish.status='UNDER_RESCISSION' THEN 'SIGNED' ELSE pcish.status END AS item_status,

        pci.prev_contract_item_id AS prev_raw,
        CASE WHEN pcc.contract_type='ADVERT_SECOND_WINNER' THEN NULL ELSE pci.prev_contract_item_id END AS prev_nav,

        c.depth + 1,
        c.path || pci.id
    FROM chain_all c
    JOIN params p ON true
    JOIN contract_item pci ON pci.id = c.prev_nav
    JOIN contract_card pcc ON pcc.id = pci.contract_card_id
    LEFT JOIN contract_item_status_history pcish ON pcish.id = pci.status_history_id
    WHERE c.prev_nav IS NOT NULL
      AND c.depth < p.max_item_chain_depth
      AND pci.deleted=false
      AND pcc.deleted=false
      AND pci.lot_id = c.lot_id
      AND COALESCE(pcc.contract_type,'') NOT LIKE 'PKO%'
      AND (pcc.lock_type IS DISTINCT FROM 'BLOCKED' OR pcc.lock_type_reason IS DISTINCT FROM 'REVISED')
      AND pcc.system_number IS NOT NULL AND pcc.system_number <> ''
      AND NOT (pci.id = ANY(c.path))
),


-- LOGIC_BLOCK: C18_ELIGIBLE_CHAIN_BASE
-- PURPOSE: оставить в item-chain только строки с допустимыми рабочими статусами

-- RULE:
-- из chain_all выбираются только строки, где item_status входит в working_statuses.

-- INPUT:
-- primary:
--   - chain_all
-- lookup:
--   - working_statuses

-- OUTPUT:
-- dataset: eligible_chain_base
-- key_fields:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
-- derived_fields:
--   - отсутствуют

-- FILTERS:
-- DATA_QUALITY:
--   - item_status IS NOT NULL implicitly через IN
-- BUSINESS:
--   - item_status IN working_statuses
-- TECHNICAL:
--   - WHERE item_status IN subquery

-- RISK:
-- - если промежуточный item в цепочке имеет недопустимый статус, он отсекается после построения цепочки
-- - удаление строки из середины цепочки может исказить delta-расчет
-- - нет отдельной диагностики excluded statuses

-- FAILURE_MODE:
-- - расчет выполняется по неполной цепочке
-- - delta считается между не соседними историческими состояниями
-- - суммы могут быть завышены или занижены

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
--   - item_status
--   - depth

-- NOTE:
-- - важная расчетная фильтрация
-- - рекомендуется анализировать excluded statuses отдельно

    
eligible_chain_base AS (
    SELECT ch.*
    FROM chain_all ch
    WHERE ch.item_status IN (SELECT status FROM working_statuses)
),

/* Флаг: последний (depth=0) предмет в цепочке расторгнут/отказ */


-- LOGIC_BLOCK: C19_ELIGIBLE_CHAIN_SUM_RULES
-- PURPOSE: рассчитать признаки расторжения последнего item и сумму sum_for_calc для каждой строки цепочки

-- RULE:
-- chain_last_rescinded = true, если depth=0 имеет статус:
-- - RESCIND
-- - REFUSAL_PERFORM_CONTRACT

-- last_chain_status:
-- - 'РАСТОРГНУТ', если chain_last_rescinded = true
-- - NULL иначе

-- sum_for_calc:
-- - если chain_last_rescinded = true:
--     COALESCE(execution_sum_no_nds, 0) для всех строк цепочки
-- - иначе если item_status IN ('RESCIND','REFUSAL_PERFORM_CONTRACT'):
--     COALESCE(execution_sum_no_nds, 0)
-- - иначе:
--     COALESCE(item_sum_no_nds_raw, 0)

-- INPUT:
-- primary:
--   - eligible_chain_base

-- OUTPUT:
-- dataset: eligible_chain
-- key_fields:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
-- derived_fields:
--   - chain_last_rescinded
--   - last_chain_status
--   - sum_for_calc

-- FILTERS:
-- DATA_QUALITY:
--   - COALESCE NULL сумм в 0
-- BUSINESS:
--   - специальные правила для RESCIND/REFUSAL
--   - если последняя строка расторгнута, execution_sum применяется ко всей цепочке
-- TECHNICAL:
--   - window MAX по main_contract_id + lot_id

-- RISK:
-- - COALESCE(...,0) скрывает пропуски сумм
-- - применение execution_sum ко всей цепочке при last rescinded требует бизнес-валидации
-- - last_chain_status одинаковый для всех строк лота, но не показывает конкретный item расторжения
-- - нормализованный UNDER_RESCISSION уже стал SIGNED и не участвует как отдельный статус

-- FAILURE_MODE:
-- - неверная база для delta-расчета
-- - нулевые суммы вместо NULL искажают итог
-- - расторжение может быть обработано не по методике

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
--   - item_status
--   - depth
--   - sum_for_calc

-- NOTE:
-- - ключевой бизнес-расчетный блок
-- - требует обязательной сверки с методикой
     

eligible_chain AS (
    SELECT
        ecb.*,

        /* chain_last_rescinded: одинаковый для всех строк лота */
        (MAX(CASE
              WHEN ecb.depth = 0 AND ecb.item_status IN ('RESCIND','REFUSAL_PERFORM_CONTRACT') THEN 1
              ELSE 0
            END
        ) OVER (PARTITION BY ecb.main_contract_id, ecb.lot_id) = 1) AS chain_last_rescinded,

        /* поле-статус по требованию: в каждой строке цепочки */
        CASE
          WHEN (MAX(CASE
                    WHEN ecb.depth = 0 AND ecb.item_status IN ('RESCIND','REFUSAL_PERFORM_CONTRACT') THEN 1
                    ELSE 0
                  END
                ) OVER (PARTITION BY ecb.main_contract_id, ecb.lot_id) = 1)
          THEN 'РАСТОРГНУТ'
          ELSE NULL
        END AS last_chain_status,

        /* sum_for_calc:
           - если цепочка заканчивается расторжением → берем execution для ВСЕХ строк цепочки
           - иначе: только для RESCIND/REFUSAL берем execution, для остальных sum_no_nds
        */
        CASE
          WHEN (MAX(CASE
                    WHEN ecb.depth = 0 AND ecb.item_status IN ('RESCIND','REFUSAL_PERFORM_CONTRACT') THEN 1
                    ELSE 0
                  END
                ) OVER (PARTITION BY ecb.main_contract_id, ecb.lot_id) = 1)
          THEN COALESCE(ecb.execution_sum_no_nds, 0::numeric)
          WHEN ecb.item_status IN ('RESCIND','REFUSAL_PERFORM_CONTRACT')
          THEN COALESCE(ecb.execution_sum_no_nds, 0::numeric)
          ELSE COALESCE(ecb.item_sum_no_nds_raw, 0::numeric)
        END AS sum_for_calc
    FROM eligible_chain_base ecb
),


-- LOGIC_BLOCK: C20_WITH_DELTAS
-- PURPOSE: рассчитать изменения суммы между соседними состояниями цепочки

-- RULE:
-- delta считается как:
-- sum_for_calc текущей строки - sum_for_calc предыдущей строки
-- при сортировке ORDER BY depth DESC.

-- Также рассчитывается max_depth по main_contract_id + lot_id.

-- INPUT:
-- primary:
--   - eligible_chain

-- OUTPUT:
-- dataset: with_deltas
-- key_fields:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
-- derived_fields:
--   - prev_sum_for_calc
--   - delta
--   - max_depth

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют
-- BUSINESS:
--   - расчет прироста/уменьшения суммы по цепочке
-- TECHNICAL:
--   - LAG по PARTITION BY main_contract_id, lot_id ORDER BY depth DESC
--   - MAX(depth) window

-- RISK:
-- - порядок depth DESC означает движение от самой ранней строки к последней
-- - если из eligible_chain_base удалены промежуточные статусы, delta считается через разрыв
-- - LAG default 0 создает первую delta относительно нуля

-- FAILURE_MODE:
-- - неверные delta
-- - завышение начальной суммы
-- - неправильная итоговая сумма при неполной цепочке

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
--   - depth
--   - sum_for_calc
--   - delta

-- NOTE:
-- - центральная delta-логика расчета COMPLEX
    

with_deltas AS (
    SELECT
        ec.*,
        LAG(ec.sum_for_calc, 1, 0::numeric) OVER (
            PARTITION BY ec.main_contract_id, ec.lot_id
            ORDER BY ec.depth DESC
        ) AS prev_sum_for_calc,
        (ec.sum_for_calc - LAG(ec.sum_for_calc, 1, 0::numeric) OVER (
            PARTITION BY ec.main_contract_id, ec.lot_id
            ORDER BY ec.depth DESC
        )) AS delta,
        MAX(ec.depth) OVER (PARTITION BY ec.main_contract_id, ec.lot_id) AS max_depth
    FROM eligible_chain ec
),



-- LOGIC_BLOCK: C21_SUM_NEGATIVE_DELTAS
-- PURPOSE: накопить сумму отрицательных delta по цепочке

-- RULE:
-- sum_negative_deltas = сумма всех delta < 0 внутри main_contract_id + lot_id.

-- INPUT:
-- primary:
--   - with_deltas

-- OUTPUT:
-- dataset: sum_neg
-- key_fields:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
-- derived_fields:
--   - sum_negative_deltas

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют
-- BUSINESS:
--   - отрицательные изменения учитываются в базовой строке цепочки
-- TECHNICAL:
--   - SUM(CASE WHEN delta < 0 THEN delta ELSE 0 END) OVER (...)

-- RISK:
-- - отрицательные delta не выводятся отдельными строками
-- - они агрегируются и применяются к строке max_depth
-- - если отрицательные изменения должны показываться отдельно, текущая логика их скрывает

-- FAILURE_MODE:
-- - потеря детализации уменьшений суммы
-- - неверная интерпретация результата пользователем
-- - возможное расхождение с методикой представления отрицательных изменений

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
--   - delta
--   - sum_negative_deltas

-- NOTE:
-- - блок меняет форму представления расчета: negative deltas схлопываются

    
sum_neg AS (
    SELECT
        wd.*,
        SUM(CASE WHEN wd.delta < 0 THEN wd.delta ELSE 0 END) OVER (
            PARTITION BY wd.main_contract_id, wd.lot_id
        ) AS sum_negative_deltas
    FROM with_deltas wd
),


-- LOGIC_BLOCK: C22_CALC_OUTPUT
-- PURPOSE: сформировать расчетные строки результата по COMPLEX item-chain

-- RULE:
-- в результат попадают строки:
-- - depth = max_depth, то есть самая ранняя строка цепочки;
-- - или строки с delta > 0.

-- sum_no_nds_calc:
-- - для depth = max_depth:
--     sum_for_calc + sum_negative_deltas
-- - для delta > 0:
--     delta
-- - иначе:
--     NULL

-- INPUT:
-- primary:
--   - sum_neg

-- OUTPUT:
-- dataset: calc_output
-- grain:
--   - расчетная строка item-chain
-- key_fields:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
-- derived_fields:
--   - prev_contract_item_id
--   - status
--   - last_chain_status
--   - sum_no_nds_calc

-- FILTERS:
-- DATA_QUALITY:
--   - отсутствуют
-- BUSINESS:
--   - выводится базовая строка и положительные изменения
--   - отрицательные изменения включаются в базовую строку
-- TECHNICAL:
--   - WHERE depth = max_depth OR delta > 0

-- RISK:
-- - строки с delta <= 0, кроме базовой, не выводятся
-- - отрицательные изменения не видны как отдельные события
-- - sum_no_nds_calc может стать отрицательным на базовой строке
-- - если max_depth строка имеет NULL/нулевую сумму из-за COALESCE, расчет искажается

-- FAILURE_MODE:
-- - неполное объяснение расчета
-- - несходство с бухгалтерской/методической логикой
-- - затрудненная отладка цепочек

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
--   - prev_contract_item_id
--   - depth
--   - sum_no_nds_calc

-- NOTE:
-- - итоговый расчетный слой перед финальным SELECT
-- - для аудита рекомендуется сохранять delta, prev_sum_for_calc, sum_for_calc, max_depth

    
calc_output AS (
    SELECT
        sn.main_contract_id,
        sn.lot_id,
        sn.advert_id,
        sn.tru_history_id,

        sn.contract_card_id,
        sn.contract_system_number,
        sn.contract_type,
        sn.contract_date_time,
        sn.duration_type,

        sn.contract_item_id,
        sn.prev_raw AS prev_contract_item_id,

        sn.item_status AS status,

        /* НОВОЕ поле: одинаковое для всех строк цепочки, если последний расторгнут */
        sn.last_chain_status,

        sn.customer_id,
        sn.supplier_id,

        sn.contract_sum_no_nds,
        sn.item_sum_no_nds_raw,
        sn.execution_sum_no_nds,

        sn.depth,

        CASE
            WHEN sn.depth = sn.max_depth
                THEN sn.sum_for_calc + sn.sum_negative_deltas
            WHEN sn.delta > 0
                THEN sn.delta
            ELSE NULL
        END AS sum_no_nds_calc
    FROM sum_neg sn
    WHERE (sn.depth = sn.max_depth) OR (sn.delta > 0)
)


-- LOGIC_BLOCK: C23_FINAL_COMPLEX_EXPORT
-- PURPOSE: вернуть финальную расчетную выгрузку DEFINITELY_COMPLEX

-- RULE:
-- финальный SELECT возвращает расчетные строки calc_output с атрибутами:
-- - main_contract_id
-- - lot_id / advert_id / tru_history_id
-- - contract_card
-- - contract_item
-- - status / last_chain_status
-- - customer / supplier
-- - исходные и расчетные суммы
-- - depth цепочки

-- INPUT:
-- primary:
--   - calc_output

-- OUTPUT:
-- dataset: definitely_complex_export
-- grain:
--   - расчетная строка item-chain после delta-фильтрации
-- key_fields:
--   - main_contract_id
--   - lot_id
--   - contract_item_id
-- derived_fields:
--   - sum_no_nds_calc
--   - last_chain_status

-- FILTERS:
-- DATA_QUALITY:
--   - применены upstream
-- BUSINESS:
--   - применены upstream
-- TECHNICAL:
--   - ORDER BY main_contract_id, lot_id, depth DESC, contract_item_id DESC

-- RISK:
-- - результат не содержит все строки цепочки, только расчетные строки
-- - нет diagnostic полей delta / sum_for_calc / max_depth / chain_last_rescinded
-- - нет признаков исключения branching_lots и excluded statuses
-- - невозможно полностью восстановить расчет без промежуточных CTE

-- FAILURE_MODE:
-- - пользователь может принять расчетную выгрузку за полный список item-chain
-- - сложная отладка расхождений
-- - потеря объяснимости итоговой суммы

-- TRACE_KEYS:
--   - main_contract_id
--   - lot_id
--   - contract_card_id
--   - contract_item_id
--   - prev_contract_item_id
--   - depth

-- NOTE:
-- - финальный production/export layer
-- - GRAIN: расчетная строка, а не полный contract_item
-- - для контроля качества рекомендуется расширить финальный SELECT диагностическими полями


SELECT
    main_contract_id,
    lot_id,
    advert_id,
    tru_history_id,

    contract_card_id,
    contract_system_number,
    contract_type,
    contract_date_time,
    duration_type,

    contract_item_id,
    prev_contract_item_id,

    status,
    last_chain_status,

    customer_id,
    supplier_id,

    contract_sum_no_nds,
    item_sum_no_nds_raw,
    execution_sum_no_nds,
    sum_no_nds_calc,

    depth
FROM calc_output
ORDER BY main_contract_id, lot_id, depth DESC, contract_item_id DESC;
