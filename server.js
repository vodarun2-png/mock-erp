// Mock ERP: order lookup and return authorization API.
// Built to be called from Salesforce Apex via a Named Credential.
// No dependencies: uses only Node's built-in modules (Node 18+).

const http = require('http');
const crypto = require('crypto');
const path = require('path');
const fs = require('fs');

const PORT = process.env.PORT || 3000;
const API_KEY = process.env.API_KEY || 'dev-key-change-me';
const RETURN_WINDOW_DAYS = Number(process.env.RETURN_WINDOW_DAYS || 30);
// The seed data is written around this date so the edge cases stay stable for demos.
// Set REFERENCE_DATE=today to use the real clock instead.
const REFERENCE_DATE = process.env.REFERENCE_DATE || '2026-10-10';
const VALID_REASONS = ['DAMAGED', 'WRONG_ITEM', 'NOT_AS_DESCRIBED', 'NO_LONGER_NEEDED', 'OTHER'];

const seed = JSON.parse(fs.readFileSync(path.join(__dirname, 'data', 'orders.json'), 'utf8'));
let orders = structuredClone(seed);
let returns = []; // in memory; resets when the server restarts

// ---------- business logic ----------

const round = n => Math.round(n * 100) / 100;

function today() {
  if (REFERENCE_DATE === 'today') return new Date(new Date().toISOString().slice(0, 10));
  return new Date(REFERENCE_DATE);
}

function findOrder(orderNumber) {
  return orders.find(o => o.orderNumber.toUpperCase() === String(orderNumber).toUpperCase());
}

function orderTotal(order) {
  return round(order.lines.reduce((s, l) => s + l.quantity * l.unitPrice, 0));
}

function lineEligibility(order, line) {
  const delivered = line.lineDeliveredDate || (order.status === 'DELIVERED' ? order.deliveredDate : null);
  if (order.status === 'CANCELLED') return { eligible: false, reason: 'ORDER_CANCELLED' };
  if (!delivered || (line.lineStatus && line.lineStatus !== 'DELIVERED')) {
    return { eligible: false, reason: 'NOT_DELIVERED' };
  }
  if (line.finalSale) return { eligible: false, reason: 'FINAL_SALE' };
  const remaining = line.quantity - line.returnedQuantity;
  if (remaining <= 0) return { eligible: false, reason: 'ALREADY_RETURNED' };
  const windowEndsDate = new Date(new Date(delivered).getTime() + RETURN_WINDOW_DAYS * 86400000);
  const windowEnds = windowEndsDate.toISOString().slice(0, 10);
  if (today() > windowEndsDate) return { eligible: false, reason: 'OUTSIDE_RETURN_WINDOW', windowEnds };
  return { eligible: true, returnableQuantity: remaining, windowEnds };
}

// Public view of an order: strip internal test notes, add per-line return eligibility.
function presentOrder(order) {
  const { _scenario, ...rest } = order;
  return {
    ...rest,
    orderTotal: orderTotal(order),
    lines: order.lines.map(l => ({ ...l, returnEligibility: lineEligibility(order, l) }))
  };
}

// ---------- tiny HTTP helpers ----------

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

function fail(res, status, code, message, details) {
  send(res, status, { error: { code, message, ...(details ? { details } : {}) } });
}

function readJson(req) {
  return new Promise(resolve => {
    let data = '';
    req.on('data', c => (data += c));
    req.on('end', () => {
      if (!data) return resolve({});
      try { resolve(JSON.parse(data)); } catch { resolve(null); }
    });
  });
}

// ---------- route handlers ----------

function getOrder(req, res, { orderNumber }) {
  const order = findOrder(orderNumber);
  if (!order) return fail(res, 404, 'ORDER_NOT_FOUND', `No order ${orderNumber}`);
  send(res, 200, presentOrder(order));
}

function searchOrders(req, res, params, query) {
  const email = (query.get('email') || '').toLowerCase().trim();
  if (!email) return fail(res, 400, 'MISSING_PARAMETER', 'Query parameter "email" is required');
  const matches = orders
    .filter(o => o.customer.email.toLowerCase() === email)
    .sort((a, b) => b.orderDate.localeCompare(a.orderDate))
    .map(o => ({
      orderNumber: o.orderNumber,
      orderDate: o.orderDate,
      status: o.status,
      itemCount: o.lines.reduce((s, l) => s + l.quantity, 0),
      orderTotal: orderTotal(o)
    }));
  send(res, 200, { email, totalSize: matches.length, orders: matches });
}

// Body: { orderNumber, reason, lines: [{ lineId, quantity }] }
// Header Idempotency-Key (optional): repeat calls with the same key return the original RMA.
async function createReturn(req, res) {
  const body = await readJson(req);
  if (body === null) return fail(res, 400, 'INVALID_JSON', 'Request body is not valid JSON');
  const { orderNumber, reason, lines } = body;
  const idemKey = req.headers['idempotency-key'];

  if (idemKey) {
    const prior = returns.find(r => r.idempotencyKey === idemKey);
    if (prior) return send(res, 200, prior);
  }
  if (!orderNumber || !Array.isArray(lines) || lines.length === 0) {
    return fail(res, 400, 'INVALID_REQUEST', 'orderNumber and a non-empty lines array are required');
  }
  if (!VALID_REASONS.includes(reason)) {
    return fail(res, 400, 'INVALID_REASON', `reason must be one of ${VALID_REASONS.join(', ')}`);
  }
  const order = findOrder(orderNumber);
  if (!order) return fail(res, 404, 'ORDER_NOT_FOUND', `No order ${orderNumber}`);

  const problems = [];
  const rmaLines = [];
  for (const item of lines) {
    const line = order.lines.find(l => l.lineId === String(item.lineId));
    const qty = Number(item.quantity || 1);
    if (!line) { problems.push({ lineId: item.lineId, reason: 'LINE_NOT_FOUND' }); continue; }
    const elig = lineEligibility(order, line);
    if (!elig.eligible) { problems.push({ lineId: line.lineId, reason: elig.reason }); continue; }
    if (!Number.isInteger(qty) || qty < 1 || qty > elig.returnableQuantity) {
      problems.push({ lineId: line.lineId, reason: 'INVALID_QUANTITY', returnableQuantity: elig.returnableQuantity });
      continue;
    }
    rmaLines.push({ lineId: line.lineId, sku: line.sku, description: line.description,
      quantity: qty, refundAmount: round(qty * line.unitPrice) });
  }

  // All-or-nothing: if any requested line fails, nothing is created.
  if (problems.length) return fail(res, 422, 'RETURN_NOT_ELIGIBLE', 'One or more lines cannot be returned', problems);

  for (const l of rmaLines) order.lines.find(x => x.lineId === l.lineId).returnedQuantity += l.quantity;

  const refundTotal = round(rmaLines.reduce((s, l) => s + l.refundAmount, 0));
  const rma = {
    rmaNumber: 'RMA-' + crypto.randomBytes(4).toString('hex').toUpperCase(),
    orderNumber: order.orderNumber,
    status: 'AUTHORIZED',
    reason,
    createdAt: new Date().toISOString(),
    currency: order.currency,
    paymentReference: order.paymentReference,
    refundTotal,
    requiresApproval: refundTotal > 1000,
    lines: rmaLines,
    returnLabelUrl: `https://example.com/labels/${order.orderNumber}.pdf`,
    ...(idemKey ? { idempotencyKey: idemKey } : {})
  };
  returns.push(rma);
  send(res, 201, rma);
}

function getReturn(req, res, { rmaNumber }) {
  const rma = returns.find(r => r.rmaNumber === rmaNumber.toUpperCase());
  if (!rma) return fail(res, 404, 'RMA_NOT_FOUND', `No return ${rmaNumber}`);
  send(res, 200, rma);
}

function resetData(req, res) {
  orders = structuredClone(seed);
  returns = [];
  send(res, 200, { status: 'reset', orders: orders.length });
}

// ---------- router ----------

const routes = [
  ['GET', /^\/api\/v1\/orders\/([^/]+)$/, ['orderNumber'], getOrder],
  ['GET', /^\/api\/v1\/orders$/, [], searchOrders],
  ['POST', /^\/api\/v1\/returns$/, [], createReturn],
  ['GET', /^\/api\/v1\/returns\/([^/]+)$/, ['rmaNumber'], getReturn],
  ['POST', /^\/api\/v1\/admin\/reset$/, [], resetData]
];

const server = http.createServer(async (req, res) => {
  const started = Date.now();
  res.on('finish', () => console.log(`${req.method} ${req.url} -> ${res.statusCode} (${Date.now() - started}ms)`));

  const url = new URL(req.url, 'http://localhost');

  if (req.method === 'GET' && url.pathname === '/health') {
    return send(res, 200, { status: 'ok', referenceDate: today().toISOString().slice(0, 10) });
  }

  if (url.pathname.startsWith('/api/')) {
    if (req.headers['x-api-key'] !== API_KEY) {
      return fail(res, 401, 'UNAUTHORIZED', 'Missing or invalid x-api-key header');
    }
    // Failure simulation for testing Apex error handling: X-Mock-Fail: 500 | 503 | timeout
    const mode = req.headers['x-mock-fail'];
    if (mode === 'timeout') return setTimeout(() => fail(res, 504, 'TIMEOUT', 'Simulated slow upstream'), 15000);
    if (mode === '503') return fail(res, 503, 'SERVICE_UNAVAILABLE', 'Simulated ERP maintenance window');
    if (mode) return fail(res, 500, 'INTERNAL_ERROR', 'Simulated ERP failure');
  }

  for (const [method, pattern, names, handler] of routes) {
    const m = url.pathname.match(pattern);
    if (m && req.method === method) {
      const params = Object.fromEntries(names.map((n, i) => [n, decodeURIComponent(m[i + 1])]));
      try { return await handler(req, res, params, url.searchParams); }
      catch (e) { console.error(e); return fail(res, 500, 'INTERNAL_ERROR', 'Unexpected server error'); }
    }
  }
  fail(res, 404, 'NOT_FOUND', `No route ${req.method} ${url.pathname}`);
});

if (require.main === module) {
  server.listen(PORT, () => console.log(`Mock ERP listening on http://localhost:${PORT} (reference date ${REFERENCE_DATE})`));
}

module.exports = server;
