#!/usr/bin/env python3
"""Browser journey: a brand-new owner from sign-up to a signed, downloaded Owner Pack.

Drives the real web app, API, worker and auth (see dev/local-stack) with the
Amberside fixtures, as two people: the owner, and an independently invited
reviewer who signs. Fails on any page error or any API 5xx, and on any golden
figure that does not appear where the user reads it.

    E2E_BASE_URL=http://localhost:3000 python tests/e2e/owner_journey.py

Optional: PLAYWRIGHT_CHROMIUM_EXECUTABLE (a pinned Chromium), E2E_ARTIFACTS
(screenshots and a JSON report; default ./e2e-artifacts).
"""

from __future__ import annotations

import json
import os
import re
import sys
import uuid
from pathlib import Path

from playwright.sync_api import Page, expect, sync_playwright

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "fixtures" / "amberside" / "upload_files"
BASE = os.getenv("E2E_BASE_URL", "http://localhost:3000").rstrip("/")
OUT = Path(os.getenv("E2E_ARTIFACTS", "e2e-artifacts"))
PASSWORD = "correct horse battery staple"
TIMEOUT_MS = 30_000
CALC_TIMEOUT_MS = 90_000

# Shortlisted movements: label, driver, diagnosis, lever.
MOVEMENTS = [
    ("Direct Labour", "productivity_intensity", "Rota hours exceeded budget on quiet weekday lunches.", "Weekday lunch rota template"),
    ("Product Cost", "rate_price", "Supplier price rises on proteins exceeded the budgeted rates.", "Protein supplier renegotiation"),
    ("Shared Restaurant Costs", "one_off_structural", "A one-off equipment repair was booked in the month.", "Maintenance contract review"),
]

problems: list[str] = []
step_no = 0


def watch(page: Page, who: str) -> None:
    page.on("pageerror", lambda e: problems.append(f"{who} page error: {str(e)[:300]}"))
    page.on("response", lambda r: r.status >= 500 and problems.append(f"{who} HTTP {r.status} {r.request.method} {r.url}"))


def shot(page: Page, name: str) -> None:
    global step_no
    step_no += 1
    page.wait_for_timeout(400)
    page.screenshot(path=str(OUT / f"{step_no:02d}-{name}.png"), full_page=True)
    print(f"  {step_no:02d} {name}", flush=True)


def settle(page: Page, ms: int = 1200) -> None:
    page.wait_for_load_state("load")
    page.wait_for_timeout(ms)


def register(page: Page, name: str, email: str) -> None:
    page.goto(f"{BASE}/auth/register", wait_until="load")
    page.fill("#name", name)
    page.fill("#email", email)
    page.fill("#password", PASSWORD)
    page.get_by_role("button", name="Create account").click()


def setup_outlet(page: Page, tag: str) -> str:
    page.wait_for_url("**/setup/organisation**", timeout=TIMEOUT_MS); settle(page)
    page.fill("[name=organisation-name]", f"Amberside Group {tag}")
    page.fill("[name=organisation-slug]", f"amberside-{tag}")
    page.get_by_role("button", name="Continue to outlet").click()
    page.wait_for_url("**/setup/outlet**", timeout=TIMEOUT_MS); settle(page)
    page.fill("[name=outlet_name]", "Amberside Kitchen")
    page.fill("[name=currency_code]", "GBP")
    page.fill("[name=timezone]", "Europe/London")
    page.get_by_role("button", name="Create organisation & outlet").click()
    page.wait_for_url("**/setup/context**", timeout=TIMEOUT_MS); settle(page)
    page.fill("[name=service_style]", "Casual dining")
    page.fill("[name=effective_from]", "2026-07-01")
    page.get_by_role("button", name="Save context & continue").click()
    page.wait_for_url("**/setup/period**", timeout=TIMEOUT_MS); settle(page)
    page.fill("[name=label]", "July 2026")
    page.fill("[name=period_start]", "2026-07-01")
    page.fill("[name=period_end]", "2026-07-31")
    page.get_by_role("button", name="Create period").click()
    page.wait_for_url("**/setup/complete**", timeout=TIMEOUT_MS); settle(page)
    shot(page, "setup-complete")
    page.get_by_role("link", name="Go to outlet Home").click()
    page.wait_for_url("**/app/outlets/*", timeout=TIMEOUT_MS); settle(page)
    return page.url.split("/app/outlets/")[1].split("?")[0].split("/")[0]


def set_materiality(page: Page, outlet: str) -> None:
    page.get_by_role("link", name="Set thresholds").click(); settle(page, 2000)
    page.fill("[name=absolute_threshold]", "1000")
    page.fill("[name=percent_threshold]", "5")
    page.fill("[name=effective_from]", "2026-07-01")
    page.get_by_role("button", name="Create materiality version").click()
    page.wait_for_timeout(2000)
    shot(page, "materiality")


def upload_and_commit(page: Page, template: str, filename: str, scenario: str | None, label: str) -> None:
    page.select_option("#upload-template", template)
    if scenario:
        page.select_option("#upload-scenario", scenario)
    page.set_input_files("#upload-file", str(FIXTURES / filename))
    page.get_by_role("button", name="Upload and read").click()
    page.wait_for_url(re.compile(r".*/data/[0-9a-f-]{36}.*"), timeout=TIMEOUT_MS); settle(page)
    for _ in range(40):
        page.wait_for_timeout(700)
        if page.get_by_role("button", name="Confirm mapping").count():
            shot(page, f"{label}-mapping")
            confirm = page.get_by_role("button", name="Confirm mapping")
            expect(confirm).to_be_enabled(timeout=5000)  # every suggestion must be pre-filled
            confirm.click()
        elif page.get_by_role("button", name="Read file").count():
            page.get_by_role("button", name="Read file").click()
        elif page.get_by_role("button", name="Validate", exact=True).count():
            page.get_by_role("button", name="Validate", exact=True).click()
        elif page.get_by_role("button", name="Commit", exact=True).count():
            page.get_by_role("button", name="Commit", exact=True).click()
        elif page.get_by_text("Committed.").count():
            shot(page, f"{label}-committed")
            return
        elif page.get_by_role("heading", name="Blocked").count():
            shot(page, f"{label}-blocked")
            raise AssertionError(f"{filename} was blocked by validation")
    shot(page, f"{label}-stuck")
    raise AssertionError(f"{filename} did not reach Committed")


def calculate(page: Page, outlet: str) -> None:
    page.goto(f"{BASE}/app/outlets/{outlet}/data", wait_until="load"); settle(page)
    card = page.locator(".card", has=page.get_by_role("heading", name="Calculation"))
    card.get_by_role("button", name=re.compile(r"^(Re)?[Cc]alculate$")).click()
    card.get_by_role("link", name="Open Management P&L").wait_for(timeout=CALC_TIMEOUT_MS)
    card.get_by_role("link", name="Open Management P&L").click(); settle(page, 2000)
    body = page.inner_text("main")
    for figure in ("228,500", "53,549", "-14,671"):
        assert figure in body, f"golden figure {figure} missing from the Management P&L"
    shot(page, "management-pnl")


def run_review(page: Page, outlet: str) -> str:
    page.goto(f"{BASE}/app/outlets/{outlet}/reviews", wait_until="load"); settle(page)
    page.get_by_role("button", name="Start review").click(); settle(page)
    shot(page, "frame")
    page.get_by_role("button", name="Confirm FRAME").click()
    page.wait_for_url(re.compile(r".*/reviews/[0-9a-f-]{36}.*"), timeout=TIMEOUT_MS); settle(page, 2500)
    review_url = page.url
    for label, *_ in MOVEMENTS:
        page.get_by_role("button", name=f"Shortlist {label}").click()
        page.wait_for_timeout(1500)
    shot(page, "shortlisted")
    for label, driver, summary, lever in MOVEMENTS:
        page.goto(review_url, wait_until="load"); settle(page)
        page.locator("li", has_text=f"{label} vs Budget").get_by_role("link").first.click(); settle(page)
        page.select_option("#diagnosis-driver", driver)
        page.fill("#diagnosis-summary", summary)
        page.get_by_role("button", name="Save diagnosis").click()
        expect(page.locator("input[name=disposition][value=ACT]")).to_be_enabled(timeout=TIMEOUT_MS)
        page.locator("input[name=disposition][value=ACT]").check()
        page.fill("#decision-text", f"Change the {lever.lower()} and check it next month.")
        page.fill("#decision-owner", "General Manager")
        page.fill("#decision-lever", lever)
        page.fill("#decision-guardrail", "Guest scores stay at or above target")
        page.fill("#decision-verification_metric", f"{label} vs budget")
        page.fill("#decision-due_date", "2026-08-31")
        page.get_by_role("button", name="Record decision").click()
        page.get_by_role("button", name="Add to action register").click()
        expect(page.get_by_role("link", name="Open the action register")).to_be_visible(timeout=TIMEOUT_MS)
        shot(page, f"decided-{label.split()[0].lower()}")
    page.goto(review_url, wait_until="load"); settle(page)
    page.get_by_role("button", name="Create Owner Pack").click()
    page.get_by_role("link", name="Open Owner Pack").click(); settle(page, 2500)
    while page.get_by_role("button", name="Add statement").count():
        page.get_by_role("button", name="Add statement").first.click()
        page.wait_for_timeout(1800)
    checks = page.get_by_text("Check passed")
    expect(checks).to_have_count(len(MOVEMENTS), timeout=TIMEOUT_MS)  # server checked every number
    page.get_by_role("button", name="Submit for review").click()
    expect(page.locator(".page-head .chip").first).to_have_text("With reviewer", timeout=TIMEOUT_MS)
    shot(page, "pack-submitted")
    return page.url


def invite_reviewer(page: Page, reviewer_email: str) -> str:
    page.goto(f"{BASE}/app", wait_until="load"); settle(page)
    page.get_by_role("link", name="Users & roles").first.click(); settle(page, 2000)
    page.fill("[name=email]", reviewer_email)
    page.select_option("[name=role]", "reviewer")
    page.get_by_role("button", name="Create invitation").click()
    link = page.locator(".banner.info p.mono")
    expect(link).to_be_visible(timeout=TIMEOUT_MS)
    return link.inner_text().strip()


def review_and_sign(page: Page, reviewer_email: str, invite: str, pack_url: str) -> None:
    register(page, "Riley Reviewer", reviewer_email)
    page.wait_for_url("**/setup/organisation**", timeout=TIMEOUT_MS)
    page.goto(invite if invite.startswith("http") else f"{BASE}{invite}", wait_until="load"); settle(page, 2000)
    page.get_by_role("button", name="Accept").click()
    page.wait_for_url("**/app**", timeout=TIMEOUT_MS)
    page.goto(pack_url, wait_until="load"); settle(page, 2500)
    shot(page, "reviewer-pack")
    accept = page.get_by_role("button", name=re.compile(r"^Accept statement"))
    while accept.count():
        accept.first.click()
        page.wait_for_timeout(2000)
    page.fill("#comment-body", "Please confirm the protein price rise is reflected in the August forecast.")
    page.get_by_role("button", name="Post comment").click()
    page.get_by_role("button", name="Resolve…").click()
    page.fill("[id^=resolve-]", "Confirmed with the GM; included in the August forecast.")
    page.get_by_role("button", name="Resolve", exact=True).click()
    page.get_by_role("button", name=re.compile(r"^(Re)?[Gg]enerate file$")).click()
    expect(page.get_by_text("Every sign-off check passes.")).to_be_visible(timeout=TIMEOUT_MS)
    shot(page, "gate-passed")
    page.get_by_role("button", name="Sign the Owner Pack").click()
    expect(page.locator(".page-head .chip").first).to_have_text("Signed", timeout=TIMEOUT_MS)
    shot(page, "signed")


def confirm_as_owner(page: Page, outlet: str) -> None:
    page.goto(f"{BASE}/app/outlets/{outlet}/reports", wait_until="load"); settle(page, 2500)
    shot(page, "owner-packs")
    with page.expect_popup(timeout=TIMEOUT_MS) as popup:
        page.get_by_role("button", name="Download").first.click()
    pack = popup.value
    pack.wait_for_load_state()
    assert pack.title().startswith("Owner Pack"), f"downloaded file title was {pack.title()!r}"
    assert "53,549" in pack.inner_text("body"), "signed Owner Pack does not show Operating Profit"
    pack.screenshot(path=str(OUT / "owner-pack-file.png"), full_page=True)
    page.goto(f"{BASE}/app/outlets/{outlet}/actions", wait_until="load"); settle(page, 2000)
    expect(page.locator(".card", has_text="General Manager")).to_have_count(len(MOVEMENTS), timeout=TIMEOUT_MS)
    page.goto(f"{BASE}/app/outlets/{outlet}", wait_until="load"); settle(page, 2500)
    expect(page.get_by_text("This period's review is complete.")).to_be_visible(timeout=TIMEOUT_MS)
    shot(page, "home-complete")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    tag = uuid.uuid4().hex[:6]
    owner_email = f"owner-{tag}@example.com"
    reviewer_email = f"reviewer-{tag}@example.com"
    executable = os.getenv("PLAYWRIGHT_CHROMIUM_EXECUTABLE") or None
    outcome = "failed"
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=executable)
        owner = browser.new_context(viewport={"width": 1366, "height": 900}).new_page()
        reviewer = browser.new_context(viewport={"width": 1366, "height": 900}).new_page()
        owner.set_default_timeout(TIMEOUT_MS)
        reviewer.set_default_timeout(TIMEOUT_MS)
        watch(owner, "owner")
        watch(reviewer, "reviewer")
        current = owner
        try:
            print("owner: sign-up and setup", flush=True)
            register(owner, "Amberside Owner", owner_email)
            outlet = setup_outlet(owner, tag)
            set_materiality(owner, outlet)
            print("owner: data in", flush=True)
            owner.goto(f"{BASE}/app/outlets/{outlet}/data", wait_until="load"); settle(owner)
            upload_and_commit(owner, "T1", "Amberside_PnL_Jul2026.csv", None, "pnl")
            owner.goto(f"{BASE}/app/outlets/{outlet}/data", wait_until="load"); settle(owner)
            upload_and_commit(owner, "T6", "Amberside_Budget_Jul2026.csv", "budget", "budget")
            calculate(owner, outlet)
            print("owner: review and Owner Pack", flush=True)
            pack_url = run_review(owner, outlet)
            invite = invite_reviewer(owner, reviewer_email)
            print("reviewer: accept, gate, sign", flush=True)
            current = reviewer
            review_and_sign(reviewer, reviewer_email, invite, pack_url)
            print("owner: signed pack, actions, home", flush=True)
            current = owner
            confirm_as_owner(owner, outlet)
            outcome = "passed" if not problems else "failed"
        except Exception as exc:  # report, keep the evidence, fail
            problems.append(f"{type(exc).__name__}: {str(exc)[:600]}")
            try:
                current.screenshot(path=str(OUT / "failure.png"), full_page=True)
            except Exception:
                pass
        finally:
            browser.close()
    report = {"outcome": outcome, "owner": owner_email, "reviewer": reviewer_email, "problems": problems}
    (OUT / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0 if outcome == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
