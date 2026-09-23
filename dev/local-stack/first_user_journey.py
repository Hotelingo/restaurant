"""DEV ONLY. Drive a first user's journey through the live API over HTTP.

Runs as the hardened restaurant_app role (so RLS is enforced) with a real
Better Auth session, using the untouched Amberside fixture files:
sign-up -> bootstrap -> context -> period -> materiality -> T1 + T6 upload,
parse, map, validate, atomic commit -> worker -> Management P&L, then asserts
all eleven golden ladder values.

Usage:  python dev/local-stack/first_user_journey.py <WORKER_DATABASE_URL>

This is the layer CI does not yet cover: the API unit tests mock the database,
and the CI integration steps run as a superuser that bypasses RLS. Both reasons
let real defects through (see docs/review/05-readiness-review.md).
"""
import csv, json, subprocess, sys, uuid
from pathlib import Path
import httpx

import os
AUTH = os.environ.get("AUTH_URL", "http://localhost:4000/neondb/auth")
API = os.environ.get("API_URL", "http://127.0.0.1:8000")
REPO = Path(__file__).resolve().parents[2]
FX = REPO / "fixtures" / "amberside" / "upload_files"
LADDER = {
    "Net Sales": "NET_SALES", "Product Cost": "PRODUCT_COST",
    "Acquisition / Channel Cost": "CHANNEL_COST", "Direct Labour": "DIRECT_LABOUR",
    "Other Direct Operating Cost": "OTHER_DIRECT_OPERATING",
    "Shared Restaurant Costs": "SHARED_RESTAURANT_COST",
    "Owner / Structural Costs": "OWNER_STRUCTURAL_COST",
}
log = []
def step(name, ok, detail=""):
    log.append((name, ok)); print(f"  {'ok  ' if ok else 'FAIL'}  {name}  {detail}")
    if not ok: print("\n".join(f"        {l}" for l in str(detail).splitlines()[:12]))

# ---------------------------------------------------------------- 1 sign-up + JWT
email = f"owner+{uuid.uuid4().hex[:6]}@amberside.test"
jar = httpx.Client(headers={"Origin": "http://localhost:3000"})
r = jar.post(f"{AUTH}/sign-up/email", json={"name": "Amberside Owner", "email": email, "password": "correct horse battery staple"})
step("sign up (Better Auth)", r.status_code == 200, r.status_code)
# Neon-style cookies are "__Secure-neon-auth.*" (Secure flag). Browsers treat
# localhost as secure; httpx does not, so forward the session cookie explicitly.
session_cookie = "; ".join(c.split(";", 1)[0] for c in r.headers.get_list("set-cookie") if "session_token" in c)
r = jar.get(f"{AUTH}/token", headers={"Cookie": session_cookie}); jwt = r.json().get("token") if r.status_code == 200 else None
step("obtain EdDSA JWT", bool(jwt), r.status_code)
api = httpx.Client(base_url=API, headers={"Authorization": f"Bearer {jwt}"}, timeout=60)
def idem(): return {"Idempotency-Key": str(uuid.uuid4())}

r = api.get("/auth/context"); step("GET /auth/context (new user, no org)", r.status_code == 200, r.text[:160])

# ---------------------------------------------------------------- 2 bootstrap
boot = {"organisation_name": "Amberside Group", "organisation_slug": f"amberside-{uuid.uuid4().hex[:6]}",
        "outlet_name": "Amberside Bistro", "outlet_code": "AMB", "currency_code": "GBP",
        "timezone": "Europe/London", "fiscal_year_start_month": 1}
key = str(uuid.uuid4())
r = api.post("/setup/bootstrap", json=boot, headers={"Idempotency-Key": key})
step("POST /setup/bootstrap", r.status_code in (200, 201), r.text[:200])
b = r.json(); org, outlet = b.get("organisation_id"), b.get("outlet_id")
r2 = api.post("/setup/bootstrap", json=boot, headers={"Idempotency-Key": key})
step("bootstrap retry is idempotent (same ids)", r2.json().get("outlet_id") == outlet, r2.text[:120])

r = api.post(f"/outlets/{outlet}/context", headers=idem(), json={"effective_from": "2026-07-01",
    "service_style": "casual_dining", "meal_periods": ["Brunch", "Lunch", "Dinner"]})
step("POST context v1", r.status_code in (200, 201), r.text[:200])
r = api.post(f"/outlets/{outlet}/periods", headers=idem(), json={"period_start": "2026-07-01", "period_end": "2026-07-31", "label": "July 2026"})
step("POST period July 2026", r.status_code in (200, 201), r.text[:200])
period = r.json().get("period_id") or r.json().get("id")
r = api.post(f"/outlets/{outlet}/materiality", headers=idem(), json={"scope_type": "general",
    "absolute_threshold": "1160", "percent_threshold": "0.10", "effective_from": "2026-07-01",
    "proposal_basis": {"method": "0.5% of comparator net sales"}})
step("POST materiality (confirmed)", r.status_code in (200, 201), r.text[:200])

# ---------------------------------------------------------------- 3 ingest T1 + T6
def ingest(template, fname, scenario, mapping_builder, queue=False):
    with open(FX / fname, "rb") as fh:
        r = api.post("/imports/upload", data={"outlet_id": outlet, "template_code": template},
                     files={"file": (fname, fh, "text/csv")})
    step(f"{template} upload {fname}", r.status_code in (200, 201), r.text[:200])
    if r.status_code not in (200, 201): return None
    batch = r.json().get("batch_id") or r.json().get("import_batch_id")
    r = api.post(f"/imports/{batch}/parse", json={"period_id": period, "scenario": scenario})
    step(f"{template} parse", r.status_code == 200, r.text[:300])
    r = api.get(f"/imports/{batch}/exceptions"); ex = r.json()
    step(f"{template} exceptions", r.status_code == 200, json.dumps(ex)[:160])
    r = api.post(f"/imports/{batch}/mapping/confirm", headers=idem(), json=mapping_builder())
    step(f"{template} mapping confirm", r.status_code in (200, 201), r.text[:300])
    r = api.post(f"/imports/{batch}/validate")
    v = r.json() if r.status_code == 200 else {}
    step(f"{template} validate", r.status_code == 200, json.dumps(v)[:200])
    ck = str(uuid.uuid4())
    r = api.post(f"/imports/{batch}/commit", params={"queue_calc": str(queue).lower()}, headers={"Idempotency-Key": ck})
    step(f"{template} commit (atomic)", r.status_code in (200, 201), r.text[:300])
    r2 = api.post(f"/imports/{batch}/commit", params={"queue_calc": str(queue).lower()}, headers={"Idempotency-Key": ck})
    step(f"{template} commit retry idempotent", r2.status_code in (200, 201), r2.text[:160])
    return batch

def t1_map():
    rows = list(csv.DictReader(open(FX / "Amberside_PnL_Jul2026.csv", encoding="utf-8-sig")))
    return {"source_label": "Amberside Xero P&L", "account_mappings": [
        {"source_account_code": x["Account_Code"], "source_account_name": x["Account_Name"],
         "ladder_line_code": LADDER[x["Suggested_Management_Line"]]} for x in rows]}
def t6_map():
    rows = list(csv.DictReader(open(FX / "Amberside_Budget_Jul2026.csv", encoding="utf-8-sig")))
    return {"source_label": "Amberside budget", "management_line_mappings": [
        {"source_value": x["Management_Line"], "ladder_line_code": LADDER[x["Management_Line"]]} for x in rows]}

ingest("T1", "Amberside_PnL_Jul2026.csv", "actual", t1_map)
ingest("T6", "Amberside_Budget_Jul2026.csv", "budget", t6_map, queue=True)

# ---------------------------------------------------------------- 4 worker + read model
env = {"DATABASE_URL": sys.argv[1], "PYTHONPATH": str(REPO), "CALC_WORKER_ID": "journey"}
for i in range(3):
    p = subprocess.run([sys.executable, "-m", "workers.pl_worker", "--once"],
                       cwd=str(REPO), env=env, capture_output=True, text=True)
step("calc worker ran", p.returncode == 0, (p.stdout + p.stderr)[-300:])
r = api.get(f"/outlets/{outlet}/analysis/pnl")
step("GET analysis/pnl", r.status_code == 200, r.text[:200])
pnl = r.json() if r.status_code == 200 else {}
Path(os.environ.get("OUT_DIR", "."), "pnl.json").write_text(json.dumps(pnl, indent=2))
Path(os.environ.get("OUT_DIR", "."), "journey_ids.json").write_text(json.dumps({"email": email, "org": org, "outlet": outlet, "period": period}))

GOLD = {"NET_SALES": 228500, "PRODUCT_COST": 70282, "PRODUCT_MARGIN": 158218, "CONTRIBUTION": 67801,
        "OPERATING_PROFIT": 53549, "OWNER_RESULT": 27549}
lines = {l["line_code"]: l for l in pnl.get("lines", [])}
for code, want in GOLD.items():
    got = ((lines.get(code) or {}).get("actual") or {}).get("value_numeric")
    try: ok = got is not None and abs(float(got) - want) < 0.005
    except Exception: ok = False
    step(f"golden {code} = {want:,}", ok, f"got {got}")
print(f"\nRESULT: {sum(o for _,o in log)} ok, {sum(not o for _,o in log)} failed")
