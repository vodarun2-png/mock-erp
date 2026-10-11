# Mock ERP – Orders & Returns API

A small stand-in for a back-office ERP, built to be called from Salesforce (Apex callouts via a Named Credential) as part of an Agentforce order-and-returns service agent.

No dependencies. Node 18 or newer.

## Run it locally

```bash
npm start          # http://localhost:3000
npm test           # runs every scenario against a throwaway server
```

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `3000` | Port to listen on |
| `API_KEY` | `dev-key-change-me` | Required in the `x-api-key` header on `/api/*` |
| `RETURN_WINDOW_DAYS` | `30` | Return window after delivery |
| `REFERENCE_DATE` | `2026-10-10` | "Today" for eligibility checks, so demo scenarios never expire. Set to `today` for the real clock |

## Endpoints

All `/api` routes need the header `x-api-key`.

| Method | Path | What it does |
|---|---|---|
| GET | `/health` | Liveness check (no key needed) |
| GET | `/api/v1/orders/{orderNumber}` | Full order with per-line `returnEligibility` |
| GET | `/api/v1/orders?email=` | Order summaries for a customer, newest first |
| POST | `/api/v1/returns` | Create a return authorization (RMA) |
| GET | `/api/v1/returns/{rmaNumber}` | Look up an RMA |
| POST | `/api/v1/admin/reset` | Restore seed data (run before a demo) |

### Create a return

```bash
curl -X POST http://localhost:3000/api/v1/returns \
  -H "x-api-key: dev-key-change-me" \
  -H "content-type: application/json" \
  -H "Idempotency-Key: case-00001234" \
  -d '{"orderNumber":"SO-100001","reason":"DAMAGED","lines":[{"lineId":"1","quantity":1}]}'
```

- `reason` is one of `DAMAGED`, `WRONG_ITEM`, `NOT_AS_DESCRIBED`, `NO_LONGER_NEEDED`, `OTHER`.
- All-or-nothing: if any line is ineligible you get `422 RETURN_NOT_ELIGIBLE` with a reason per line, and nothing is created.
- `Idempotency-Key` makes retries safe: the same key returns the original RMA instead of a duplicate. Pass the Case Id from Salesforce.
- `requiresApproval` is `true` when the refund is over $1,000. Use it to route to a human in Salesforce.

### Errors

Every error has the same shape, which keeps the Apex wrapper simple:

```json
{ "error": { "code": "ORDER_NOT_FOUND", "message": "No order SO-999999" } }
```

Eligibility reasons: `NOT_DELIVERED`, `FINAL_SALE`, `ALREADY_RETURNED`, `OUTSIDE_RETURN_WINDOW`, `ORDER_CANCELLED`, plus `LINE_NOT_FOUND` and `INVALID_QUANTITY` on create.

### Simulating failures

Send `X-Mock-Fail: 500`, `503` or `timeout` (responds after 15s) to test Apex error handling and retry logic.

## Test data

Twelve orders across six customers in `data/orders.json`. Each has a `_scenario` note (hidden from API responses):

| Order | Customer email | Scenario |
|---|---|---|
| SO-100001 | priya.sharma@example.com | Happy path, everything returnable |
| SO-100002 | priya.sharma@example.com | Outside the return window |
| SO-100003 | marcus.lee@example.com | Partially shipped: one line delivered, one backordered |
| SO-100004 | marcus.lee@example.com | Already fully returned |
| SO-100005 | ananya.iyer@example.com | One final-sale line, one returnable line |
| SO-100006 | ananya.iyer@example.com | Still processing: cancel, don't return |
| SO-100007 | daniel.okafor@example.com | In transit with tracking number |
| SO-100008 | daniel.okafor@example.com | $1,299 refund, needs approval |
| SO-100009 | sofia.martinez@example.com | Partially returned already |
| SO-100010 | sofia.martinez@example.com | Cancelled order |
| SO-100011 | rahul.verma@example.com | Near the end of the return window |
| SO-100012 | rahul.verma@example.com | Three lines, one final sale: agent must ask which items |

## Deploy (free) on Render

1. Push this folder to a GitHub repo.
2. On render.com: **New → Web Service**, pick the repo.
3. Build command: leave empty (or `npm install`). Start command: `npm start`.
4. Add an environment variable `API_KEY` with a long random value.
5. Check `https://<your-app>.onrender.com/health`.

Free instances sleep when idle, so the first call after a break can take a while. Hit `/health` before a demo, and set a generous timeout on the Apex callout.

## Connecting from Salesforce

1. **External Credential** `MockERP`: authentication protocol *Custom*. Add a principal with an authentication parameter `ApiKey` holding your key, and a custom header `x-api-key` with value `{!$Credential.MockERP.ApiKey}`.
2. **Named Credential** `MockERP`: URL `https://<your-app>.onrender.com`, linked to that External Credential.
3. **Permission set**: grant access to the External Credential principal and assign it to your user (and the Agentforce agent user).
4. Call it from Apex:

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:MockERP/api/v1/orders/SO-100001');
req.setMethod('GET');
req.setTimeout(60000);
HttpResponse res = new Http().send(req);
```

No Remote Site Setting is needed when you use a Named Credential.
