WITH RECURSIVE
params AS (
    SELECT
        1::int  AS part,            -- 1..2
        2::int AS parts_total,
        200::int AS max_prev_depth,
        120::int AS max_item_chain_depth
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
    JOIN params p ON true
    WHERE w.current_card_id IS NOT NULL
      AND w.depth < p.max_prev_depth
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

family_agg AS (
    SELECT
        cem.effective_main_id,
        BOOL_OR(cem.contract_type NOT IN ('ADVERT','ADVERT_SECOND_WINNER')) AS has_any_supp_cards
    FROM card_effective_main cem
    WHERE cem.effective_main_id IS NOT NULL
    GROUP BY cem.effective_main_id
),

complex_main_ids_part AS (
    SELECT fa.effective_main_id AS main_contract_id
    FROM family_agg fa
    JOIN params p ON true
    WHERE fa.has_any_supp_cards = true
      AND MOD(ABS(fa.effective_main_id)::bigint, p.parts_total::bigint) = (p.part - 1)::bigint
),

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

eligible_chain_base AS (
    SELECT ch.*
    FROM chain_all ch
    WHERE ch.item_status IN (SELECT status FROM working_statuses)
),

/* Флаг: последний (depth=0) предмет в цепочке расторгнут/отказ */
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

sum_neg AS (
    SELECT
        wd.*,
        SUM(CASE WHEN wd.delta < 0 THEN wd.delta ELSE 0 END) OVER (
            PARTITION BY wd.main_contract_id, wd.lot_id
        ) AS sum_negative_deltas
    FROM with_deltas wd
),

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
