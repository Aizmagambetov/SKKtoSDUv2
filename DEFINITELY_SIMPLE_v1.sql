WITH RECURSIVE
params AS (
  SELECT 1::int AS part, 2::int AS parts_total  -- part=1..2
),
working_statuses AS (
  SELECT unnest(ARRAY[
    'EXECUTED','REFUSAL_PERFORM_CONTRACT','SIGNED','RESCIND','SUPPLEMENTARY_AGREEMENT'
  ]) AS status
),
executed_lots AS (
  SELECT l.id AS lot_id, l.advert_id, l.tru_history_id
  FROM lot l
  JOIN lot_status_history lsh ON lsh.id = l.status_history_id
  WHERE lsh.status = 'EXECUTED'
),
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
cards_with_candidate_main AS (
  SELECT
    bc.*,
    CASE
      WHEN bc.contract_type IN ('ADVERT','ADVERT_SECOND_WINNER') THEN bc.contract_card_id
      ELSE bc.main_contract_card_id
    END AS candidate_main_id
  FROM base_cards bc
),
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
bad_for_second_winner_search AS (
  SELECT *
  FROM main_ok_eval
  WHERE candidate_main_ok_link = false
    AND prev_contract_card_id IS NOT NULL
),
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
family_flags AS (
  SELECT
    effective_main_id,
    BOOL_OR(contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER')) AS has_any_supp_cards
  FROM card_effective_main
  WHERE effective_main_id IS NOT NULL
  GROUP BY effective_main_id
),
simple_mains_part AS (
  SELECT ff.effective_main_id AS main_contract_id
  FROM family_flags ff
  JOIN params p ON true
  WHERE ff.has_any_supp_cards = false
    AND MOD(ABS(ff.effective_main_id)::bigint, p.parts_total::bigint) = (p.part - 1)::bigint
)
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
