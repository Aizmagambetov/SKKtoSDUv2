WITH RECURSIVE
executed_lots AS (
  SELECT l.id AS lot_id, l.advert_id
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
family_flags AS (
  SELECT
    e.effective_main_id,
    BOOL_OR(e.contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER')) AS has_any_supp_cards
  FROM effective_main e
  WHERE e.effective_main_id IS NOT NULL
  GROUP BY e.effective_main_id
),
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
