from __future__ import annotations

import hashlib
import html
import json
from decimal import Decimal
from typing import Any
from uuid import UUID

PACK_RENDERER_VERSION = "server-html-v1"
PACK_TEMPLATE_VERSION = "owner-pack-v1"


def _text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, Decimal):
        return format(value, "f")
    return str(value)


def canonical_source_bytes(snapshot: dict[str, Any]) -> bytes:
    return json.dumps(
        snapshot,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")


def pack_source_sha256(snapshot: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_source_bytes(snapshot)).hexdigest()


def artifact_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


async def build_pack_artifact_snapshot(conn, pack_id: UUID) -> dict[str, Any] | None:
    result = await conn.execute(
        """
        select
          p.id,p.version_no,p.review_id,p.calc_run_id,p.status::text as status,
          p.reconciliation_disclosure,p.generated_at,
          org.name as organisation_name,
          o.name as outlet_name,btrim(o.currency_code) as currency_code,
          rp.label as period_label,rp.period_start,rp.period_end,
          r.comparator_scenario::text as comparator_scenario
        from pack_version p
        join review r on r.id=p.review_id
        join organisation org on org.id=p.organisation_id
        join outlet o on o.id=p.outlet_id
        join reporting_period rp on rp.id=r.period_id
        where p.id=%s
        """,
        (pack_id,),
    )
    pack = await result.fetchone()
    if pack is None:
        return None

    pnl_result = await conn.execute(
        """
        select
          ll.code,ll.name,ll.display_order,
          cr.grain_type,cr.grain_key->>'scenario' as scenario,
          cr.value_numeric,cr.value_text,cr.unit,
          btrim(cr.currency_code) as currency_code,
          cr.calculation_status,cr.evidence_status
        from calc_result cr
        join ladder_line ll
          on ll.code=cr.grain_key->>'ladder_code'
        where cr.run_id=%s
          and cr.grain_type in ('management_pl','management_pl_variance')
        order by ll.display_order,
          case cr.grain_type when 'management_pl' then 1 else 2 end,
          cr.grain_key->>'scenario',
          cr.id
        """,
        (pack["calc_run_id"],),
    )
    pnl_rows = await pnl_result.fetchall()

    by_line: dict[str, dict[str, Any]] = {}
    for row in pnl_rows:
        line = by_line.setdefault(
            row["code"],
            {
                "code": row["code"],
                "name": row["name"],
                "display_order": row["display_order"],
                "actual": None,
                "comparator": None,
                "variance": None,
                "unit": row["unit"],
                "currency_code": row["currency_code"],
            },
        )
        value = _text(row["value_numeric"] if row["value_numeric"] is not None else row["value_text"])
        if row["grain_type"] == "management_pl_variance":
            line["variance"] = value
        elif row["scenario"] == "actual":
            line["actual"] = value
        elif row["scenario"] == pack["comparator_scenario"]:
            line["comparator"] = value

    claim_result = await conn.execute(
        """
        select
          c.id,c.section_code,c.claim_text,c.claim_status::text as claim_status,
          c.evidence_status,c.reviewed_by,c.reviewed_at
        from claim c
        where c.pack_version_id=%s
        order by c.section_code,c.created_at,c.id
        """,
        (pack_id,),
    )
    claim_rows = await claim_result.fetchall()
    claims: list[dict[str, Any]] = []
    for claim in claim_rows:
        citation_result = await conn.execute(
            """
            select
              cr.calc_id,cr.value_numeric,cr.value_text,cr.unit,
              btrim(cr.currency_code) as currency_code,
              cr.calculation_status,cr.evidence_status
            from claim_citation cc
            join calc_result cr
              on cr.id=cc.calc_result_id
             and cr.run_id=cc.calc_run_id
            where cc.claim_id=%s
            order by cc.created_at,cc.id
            """,
            (claim["id"],),
        )
        citations = [
            {
                "calc_id": row["calc_id"],
                "value": _text(
                    row["value_numeric"]
                    if row["value_numeric"] is not None
                    else row["value_text"]
                ),
                "unit": row["unit"],
                "currency_code": row["currency_code"],
                "calculation_status": row["calculation_status"],
                "evidence_status": row["evidence_status"],
            }
            for row in await citation_result.fetchall()
        ]
        claims.append(
            {
                "id": str(claim["id"]),
                "section_code": claim["section_code"],
                "claim_text": claim["claim_text"],
                "claim_status": claim["claim_status"],
                "evidence_status": claim["evidence_status"],
                "reviewed_by": _text(claim["reviewed_by"]),
                "reviewed_at": (
                    claim["reviewed_at"].isoformat()
                    if claim["reviewed_at"] is not None
                    else None
                ),
                "citations": citations,
            }
        )

    issue_result = await conn.execute(
        """
        select
          ri.id,ri.title,ri.ladder_code,ri.evidence_status,
          d.id as decision_id,d.disposition::text as disposition,
          d.decision_text,d.owner,d.lever,d.guardrail,
          d.verification_metric,d.target_trigger,d.due_date,d.cadence,
          d.forecast_treatment,
          a.id as action_id,a.status::text as action_status,
          a.forecast_effect
        from review_issue ri
        left join decision d on d.id=ri.active_decision_id
        left join action a on a.decision_id=d.id
        where ri.review_id=%s
          and ri.issue_status<>'removed'
        order by ri.shortlist_order,ri.id
        """,
        (pack["review_id"],),
    )
    issues = []
    for row in await issue_result.fetchall():
        issues.append(
            {
                key: (
                    value.isoformat()
                    if hasattr(value, "isoformat")
                    else _text(value)
                )
                for key, value in row.items()
            }
        )

    return {
        "pack": {
            "id": str(pack["id"]),
            "version_no": pack["version_no"],
            "review_id": str(pack["review_id"]),
            "calc_run_id": str(pack["calc_run_id"]),
            "status": pack["status"],
            "generated_at": pack["generated_at"].isoformat(),
            "reconciliation_disclosure": pack["reconciliation_disclosure"],
        },
        "organisation": pack["organisation_name"],
        "outlet": pack["outlet_name"],
        "period": {
            "label": pack["period_label"],
            "start": pack["period_start"].isoformat(),
            "end": pack["period_end"].isoformat(),
        },
        "currency_code": pack["currency_code"],
        "comparator_scenario": pack["comparator_scenario"],
        "management_pl": sorted(by_line.values(), key=lambda item: item["display_order"]),
        "claims": claims,
        "issues": issues,
    }


def _money(value: str | None, currency: str | None) -> str:
    if value is None:
        return "—"
    try:
        number = Decimal(value)
    except Exception:
        return value
    prefix = f"{currency} " if currency else ""
    return f"{prefix}{number:,.2f}"


def render_owner_pack_html(snapshot: dict[str, Any]) -> bytes:
    pack = snapshot["pack"]
    currency = snapshot.get("currency_code")
    esc = lambda value: html.escape("" if value is None else str(value))

    pnl_rows = "".join(
        "<tr>"
        f"<td>{esc(line['name'])}</td>"
        f"<td>{esc(_money(line['actual'], currency))}</td>"
        f"<td>{esc(_money(line['comparator'], currency))}</td>"
        f"<td>{esc(_money(line['variance'], currency))}</td>"
        "</tr>"
        for line in snapshot["management_pl"]
    )

    claim_blocks = []
    for claim in snapshot["claims"]:
        if claim["claim_status"] == "rejected":
            continue
        citations = ", ".join(
            f"{item['calc_id']} ({_money(item['value'], item['currency_code']) if item['unit']=='currency' else item['value']})"
            for item in claim["citations"]
        )
        claim_blocks.append(
            "<article class='claim'>"
            f"<h3>{esc(claim['section_code'])}</h3>"
            f"<p>{esc(claim['claim_text'])}</p>"
            f"<p class='meta'>Evidence: {esc(claim['evidence_status'])} · "
            f"Review: {esc(claim['claim_status'])}</p>"
            f"<p class='citation'>Citations: {esc(citations)}</p>"
            "</article>"
        )

    issue_rows = "".join(
        "<tr>"
        f"<td>{esc(issue.get('title'))}</td>"
        f"<td>{esc(issue.get('disposition'))}</td>"
        f"<td>{esc(issue.get('owner'))}</td>"
        f"<td>{esc(issue.get('decision_text'))}</td>"
        f"<td>{esc(issue.get('action_status'))}</td>"
        "</tr>"
        for issue in snapshot["issues"]
    )

    disclosure = pack.get("reconciliation_disclosure")
    disclosure_html = (
        f"<section class='notice'><strong>Not Reconciled:</strong> {esc(disclosure)}</section>"
        if disclosure
        else "<section class='notice ok'><strong>Reconciliation:</strong> Reconciled</section>"
    )

    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Owner Pack v{pack['version_no']} — {esc(snapshot['outlet'])}</title>
<style>
body{{font-family:Arial,sans-serif;margin:40px;color:#18212f;line-height:1.45}}
h1,h2,h3{{margin:0 0 10px}} h2{{margin-top:28px;border-bottom:1px solid #d9dee7;padding-bottom:6px}}
.meta,.citation{{color:#596273;font-size:12px}} table{{border-collapse:collapse;width:100%;margin-top:12px}}
th,td{{border:1px solid #d9dee7;padding:7px;text-align:left;vertical-align:top}} th{{background:#f4f6f9}}
.notice{{padding:10px 12px;background:#fff4e5;border:1px solid #f0c36d;margin:18px 0}}
.notice.ok{{background:#eef8f0;border-color:#9ac7a2}} .claim{{margin:18px 0}}
.footer{{margin-top:36px;font-size:11px;color:#697386}} @media print{{body{{margin:18mm}}}}
</style>
</head>
<body>
<h1>Owner Pack</h1>
<p><strong>{esc(snapshot['organisation'])} · {esc(snapshot['outlet'])}</strong><br>
{esc(snapshot['period']['label'])} · Version {pack['version_no']}<br>
Calc run: {esc(pack['calc_run_id'])}</p>
{disclosure_html}
<h2>Management P&amp;L</h2>
<table><thead><tr><th>Line</th><th>Actual</th><th>{esc(snapshot['comparator_scenario'])}</th><th>Variance</th></tr></thead>
<tbody>{pnl_rows}</tbody></table>
<h2>Reviewed narrative</h2>
{''.join(claim_blocks) if claim_blocks else '<p>No accepted narrative claims.</p>'}
<h2>Management decisions and actions</h2>
<table><thead><tr><th>Issue</th><th>Disposition</th><th>Owner</th><th>Decision</th><th>Action status</th></tr></thead>
<tbody>{issue_rows}</tbody></table>
<p class="footer">Pack {esc(pack['id'])} · Review {esc(pack['review_id'])} · Renderer {PACK_RENDERER_VERSION} · Template {PACK_TEMPLATE_VERSION}</p>
</body></html>
"""
    return document.encode("utf-8")
