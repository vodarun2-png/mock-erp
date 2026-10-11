// Starts the API on a random port and checks each scenario. Run: npm test
const app = require('./server');
const assert = require('assert');

const KEY = process.env.API_KEY || 'dev-key-change-me';

(async () => {
  const server = app.listen(0);
  const base = `http://localhost:${server.address().port}`;
  const call = (method, path, body, headers = {}) =>
    fetch(base + path, {
      method,
      headers: { 'content-type': 'application/json', 'x-api-key': KEY, ...headers },
      body: body ? JSON.stringify(body) : undefined
    }).then(async r => ({ status: r.status, body: await r.json() }));

  const checks = [
    ['rejects missing API key', async () => {
      const r = await fetch(base + '/api/v1/orders/SO-100001');
      assert.equal(r.status, 401);
    }],
    ['looks up an order', async () => {
      const r = await call('GET', '/api/v1/orders/SO-100001');
      assert.equal(r.status, 200);
      assert.equal(r.body.orderTotal, 278);
      assert.equal(r.body._scenario, undefined);
      assert.equal(r.body.lines[0].returnEligibility.eligible, true);
    }],
    ['404 for unknown order', async () => {
      const r = await call('GET', '/api/v1/orders/SO-999999');
      assert.equal(r.status, 404);
      assert.equal(r.body.error.code, 'ORDER_NOT_FOUND');
    }],
    ['finds orders by email', async () => {
      const r = await call('GET', '/api/v1/orders?email=Priya.Sharma@example.com');
      assert.equal(r.body.totalSize, 2);
    }],
    ['flags outside return window', async () => {
      const r = await call('GET', '/api/v1/orders/SO-100002');
      assert.equal(r.body.lines[0].returnEligibility.reason, 'OUTSIDE_RETURN_WINDOW');
    }],
    ['flags final sale and backordered lines', async () => {
      const a = await call('GET', '/api/v1/orders/SO-100005');
      assert.equal(a.body.lines[0].returnEligibility.reason, 'FINAL_SALE');
      const b = await call('GET', '/api/v1/orders/SO-100003');
      assert.equal(b.body.lines[0].returnEligibility.eligible, true);
      assert.equal(b.body.lines[1].returnEligibility.reason, 'NOT_DELIVERED');
    }],
    ['creates an RMA and updates returned quantity', async () => {
      const r = await call('POST', '/api/v1/returns',
        { orderNumber: 'SO-100001', reason: 'DAMAGED', lines: [{ lineId: '1', quantity: 1 }] });
      assert.equal(r.status, 201);
      assert.match(r.body.rmaNumber, /^RMA-/);
      assert.equal(r.body.refundTotal, 249);
      const again = await call('GET', '/api/v1/orders/SO-100001');
      assert.equal(again.body.lines[0].returnEligibility.reason, 'ALREADY_RETURNED');
      const lookup = await call('GET', `/api/v1/returns/${r.body.rmaNumber}`);
      assert.equal(lookup.status, 200);
    }],
    ['rejects ineligible return with 422 and creates nothing', async () => {
      const r = await call('POST', '/api/v1/returns',
        { orderNumber: 'SO-100012', reason: 'NO_LONGER_NEEDED', lines: [{ lineId: '1' }, { lineId: '3' }] });
      assert.equal(r.status, 422);
      assert.equal(r.body.error.details[0].reason, 'FINAL_SALE');
      const order = await call('GET', '/api/v1/orders/SO-100012');
      assert.equal(order.body.lines[0].returnedQuantity, 0);
    }],
    ['flags high-value refunds for approval', async () => {
      const r = await call('POST', '/api/v1/returns',
        { orderNumber: 'SO-100008', reason: 'NOT_AS_DESCRIBED', lines: [{ lineId: '1' }] });
      assert.equal(r.body.requiresApproval, true);
    }],
    ['idempotency key returns the same RMA', async () => {
      const body = { orderNumber: 'SO-100011', reason: 'OTHER', lines: [{ lineId: '1' }] };
      const a = await call('POST', '/api/v1/returns', body, { 'idempotency-key': 'abc-123' });
      const b = await call('POST', '/api/v1/returns', body, { 'idempotency-key': 'abc-123' });
      assert.equal(a.status, 201);
      assert.equal(b.status, 200);
      assert.equal(a.body.rmaNumber, b.body.rmaNumber);
    }],
    ['simulates ERP failure', async () => {
      const r = await call('GET', '/api/v1/orders/SO-100001', null, { 'x-mock-fail': '503' });
      assert.equal(r.status, 503);
    }],
    ['reset restores seed data', async () => {
      await call('POST', '/api/v1/admin/reset');
      const r = await call('GET', '/api/v1/orders/SO-100001');
      assert.equal(r.body.lines[0].returnEligibility.eligible, true);
    }]
  ];

  let failed = 0;
  for (const [name, fn] of checks) {
    try { await fn(); console.log('PASS', name); }
    catch (e) { failed++; console.log('FAIL', name, '-', e.message); }
  }
  server.close();
  console.log(`\n${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})();
