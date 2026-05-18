WITH
params AS (
  SELECT
    TIMESTAMP '2024-01-01 00:00:00' AS dt_from,
    TIMESTAMP '2025-12-31 23:59:59' AS dt_to
),
executed_lots AS (
  SELECT
    l.id AS lot_id,
    l.advert_id,
    l.tru_history_id,
    l.single_source_reason_id,
    l.plan_item_id
  FROM lot l
  JOIN lot_status_history lsh ON lsh.id = l.status_history_id
  WHERE lsh.status = 'EXECUTED'
),
seed_in_period AS (
  SELECT DISTINCT
    el.lot_id,
    el.advert_id,
    el.tru_history_id,
    el.single_source_reason_id,

    cc.customer_id  AS cc_customer_id,
    cc.supplier_id  AS supplier_id,
    cc.tender_type  AS tender_type,

    p.client_id     AS plan_customer_id
  FROM contract_item ci
  JOIN contract_card cc ON cc.id = ci.contract_card_id
  JOIN executed_lots el ON el.lot_id = ci.lot_id

  LEFT JOIN plan_item pi2 ON pi2.id = el.plan_item_id
  LEFT JOIN plan p        ON p.id = pi2.plan_id

  JOIN params par ON true
  WHERE ci.deleted = false
    AND cc.deleted = false
    AND cc.system_number IS NOT NULL AND cc.system_number <> ''
    AND COALESCE(cc.contract_type,'') NOT LIKE 'PKO%'
    AND (cc.lock_type IS DISTINCT FROM 'BLOCKED' OR cc.lock_type_reason IS DISTINCT FROM 'REVISED')
    AND cc.contract_date_time >= par.dt_from
    AND cc.contract_date_time <= par.dt_to
)
SELECT
  s.lot_id,
  s.advert_id,
  s.tru_history_id,
  s.tender_type,

  s.cc_customer_id,
  cust_cc.name_ru AS customer_cc_name_ru,
  cust_cc.bin     AS customer_cc_bin,
  CONCAT(COALESCE(cust_cc.bin,''), COALESCE(cust_cc.iin,'')) AS customer_cc_bin_iin,

  s.plan_customer_id,
  cust_plan.name_ru AS customer_plan_name_ru,
  cust_plan.bin     AS customer_plan_bin,
  CONCAT(COALESCE(cust_plan.bin,''), COALESCE(cust_plan.iin,'')) AS customer_plan_bin_iin,

  s.supplier_id,
  supp.name_ru AS supplier_name_ru,
  CONCAT(COALESCE(supp.bin,''), COALESCE(supp.iin,'')) AS supplier_bin_iin,

  th.category AS tru_category,
  th.code     AS enstru_code,
  th.ru       AS tru_name_ru,
  th.brief_ru AS tru_brief_ru,

  COALESCE(
    e.ru IN (
      '59-1-8 (Приобретение товара в рамках реализации Проекта по созданию новых производств)',
      '137-30 (приобретение товара в рамках реализации Проекта по созданию новых производств)',
      '15-1-8 (Приобретение товара в рамках реализации Проекта по созданию новых производств)',
      '12-2-24 (приобретение товара в рамках реализации Проекта по созданию новых производств)',
      'Статья 59 пункт 1 подпункт) 8 Порядка закупок'
    ),
    false
  ) AS is_offtake,
  e.ru AS entry_ru
FROM seed_in_period s
LEFT JOIN company cust_cc   ON cust_cc.id   = s.cc_customer_id
LEFT JOIN company cust_plan ON cust_plan.id = s.plan_customer_id
LEFT JOIN company supp      ON supp.id      = s.supplier_id
LEFT JOIN tru_history th    ON th.id        = s.tru_history_id
LEFT JOIN entry e           ON e.id         = s.single_source_reason_id
ORDER BY s.lot_id, s.cc_customer_id, s.supplier_id;
