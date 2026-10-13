@IsTest
private class ErpAgentActionsTest {

    /** Canned ERP response that also records the request it received. */
    private class ErpMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;
        public HttpRequest lastRequest;

        public ErpMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            lastRequest = req;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(body);
            return res;
        }
    }

    private static ErpMock mockResponse(Integer statusCode, String body) {
        ErpMock mock = new ErpMock(statusCode, body);
        Test.setMock(HttpCalloutMock.class, mock);
        return mock;
    }

    private static final String ORDER_SO_100003 =
        '{"orderNumber":"SO-100003","orderDate":"2026-10-01","status":"PARTIALLY_SHIPPED","orderTotal":488,' +
        '"lines":[' +
        '{"lineId":"1","description":"27-inch 4K monitor","quantity":1,"returnEligibility":{"eligible":true,"returnableQuantity":1,"windowEnds":"2026-11-03"}},' +
        '{"lineId":"2","description":"Dual monitor arm","quantity":1,"returnEligibility":{"eligible":false,"reason":"NOT_DELIVERED"}}]}';

    private static String rmaBody(Decimal refund, Boolean approval) {
        return '{"rmaNumber":"RMA-1A2B3C4D","orderNumber":"SO-100012","status":"AUTHORIZED","refundTotal":' + refund +
            ',"requiresApproval":' + approval + ',"returnLabelUrl":"https://example.com/labels/SO-100012.pdf","lines":[]}';
    }

    private static CreateReturnAction.Request returnRequest(String items, String reason) {
        CreateReturnAction.Request req = new CreateReturnAction.Request();
        req.orderNumber = 'SO-100012';
        req.items = items;
        req.reason = reason;
        return req;
    }

    // ---------- Look Up Order ----------

    @IsTest
    static void lookUp_splitsReturnableAndNonReturnableItems() {
        mockResponse(200, ORDER_SO_100003);
        LookupOrderAction.Request req = new LookupOrderAction.Request();
        req.orderNumber = 'SO-100003';

        Test.startTest();
        LookupOrderAction.Result r = LookupOrderAction.lookUp(new List<LookupOrderAction.Request>{ req })[0];
        Test.stopTest();

        Assert.isTrue(r.found);
        Assert.areEqual('PARTIALLY_SHIPPED', r.status);
        Assert.isTrue(r.summary.contains('SO-100003'), r.summary);
        Assert.isTrue(r.summary.contains('$488.00'), r.summary);
        Assert.isTrue(r.returnableItems.contains('Line 1: 27-inch 4K monitor'), r.returnableItems);
        Assert.isTrue(r.nonReturnableItems.contains('not been delivered'), r.nonReturnableItems);
        Assert.isNull(r.message);
    }

    @IsTest
    static void lookUp_unknownOrder_tellsAgentToAskAgain() {
        mockResponse(404, '{"error":{"code":"ORDER_NOT_FOUND","message":"No order SO-999999"}}');
        LookupOrderAction.Request req = new LookupOrderAction.Request();
        req.orderNumber = 'SO-999999';

        Test.startTest();
        LookupOrderAction.Result r = LookupOrderAction.lookUp(new List<LookupOrderAction.Request>{ req })[0];
        Test.stopTest();

        Assert.isFalse(r.found);
        Assert.isTrue(r.message.contains('check the order number'), r.message);
    }

    @IsTest
    static void lookUp_erpDown_offersHuman() {
        mockResponse(503, '{"error":{"code":"SERVICE_UNAVAILABLE","message":"Maintenance"}}');
        LookupOrderAction.Request req = new LookupOrderAction.Request();
        req.orderNumber = 'SO-100003';

        Test.startTest();
        LookupOrderAction.Result r = LookupOrderAction.lookUp(new List<LookupOrderAction.Request>{ req })[0];
        Test.stopTest();

        Assert.isFalse(r.found);
        Assert.isTrue(r.message.contains('temporarily unavailable'), r.message);
    }

    // ---------- Create Return ----------

    @IsTest
    static void createReturn_success_sendsParsedLinesAndKey() {
        ErpMock mock = mockResponse(201, rmaBody(49, false));

        Test.startTest();
        CreateReturnAction.Result r = CreateReturnAction.createReturn(
            new List<CreateReturnAction.Request>{ returnRequest('line 1, 2:2', 'damaged') })[0];
        Test.stopTest();

        Assert.isTrue(r.success);
        Assert.areEqual('RMA-1A2B3C4D', r.rmaNumber);
        Assert.areEqual(49, r.refundAmount.intValue());
        Assert.isFalse(r.requiresApproval);
        Assert.isTrue(r.message.contains('return label'), r.message);

        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.areEqual('DAMAGED', sent.get('reason'), 'Reason is normalised to upper case');
        List<Object> lines = (List<Object>) sent.get('lines');
        Assert.areEqual(2, lines.size());
        Map<String, Object> second = (Map<String, Object>) lines[1];
        Assert.areEqual('2', second.get('lineId'));
        Assert.areEqual(2, second.get('quantity'));
        Assert.isNotNull(mock.lastRequest.getHeader('Idempotency-Key'));
    }

    @IsTest
    static void createReturn_highValue_flagsEscalation() {
        mockResponse(201, rmaBody(1299, true));

        Test.startTest();
        CreateReturnAction.Result r = CreateReturnAction.createReturn(
            new List<CreateReturnAction.Request>{ returnRequest('1', 'NOT_AS_DESCRIBED') })[0];
        Test.stopTest();

        Assert.isTrue(r.success);
        Assert.isTrue(r.requiresApproval);
        Assert.isTrue(r.message.contains('escalate to a human'), r.message);
    }

    @IsTest
    static void createReturn_notEligible_explainsEachLine() {
        mockResponse(422,
            '{"error":{"code":"RETURN_NOT_ELIGIBLE","message":"One or more lines cannot be returned",' +
            '"details":[{"lineId":"3","reason":"FINAL_SALE"}]}}');

        Test.startTest();
        CreateReturnAction.Result r = CreateReturnAction.createReturn(
            new List<CreateReturnAction.Request>{ returnRequest('1, 3', 'NO_LONGER_NEEDED') })[0];
        Test.stopTest();

        Assert.isFalse(r.success);
        Assert.isTrue(r.message.contains('line 3 (final sale items cannot be returned)'), r.message);
        Assert.isTrue(r.message.startsWith('Nothing was returned'), r.message);
    }

    @IsTest
    static void createReturn_badQuantity_failsWithoutCallout() {
        ErpMock mock = mockResponse(201, rmaBody(49, false));

        CreateReturnAction.Result r = CreateReturnAction.createReturn(
            new List<CreateReturnAction.Request>{ returnRequest('2:two', 'DAMAGED') })[0];

        Assert.isFalse(r.success);
        Assert.isTrue(r.message.contains('whole number'), r.message);
        Assert.isNull(mock.lastRequest);
    }

    @IsTest
    static void createReturn_unknownReason_failsWithoutCallout() {
        ErpMock mock = mockResponse(201, rmaBody(49, false));

        CreateReturnAction.Result r = CreateReturnAction.createReturn(
            new List<CreateReturnAction.Request>{ returnRequest('1', 'changed my mind') })[0];

        Assert.isFalse(r.success);
        Assert.isTrue(r.message.startsWith('The request was incomplete'), r.message);
        Assert.isNull(mock.lastRequest);
    }

    // ---------- Helpers ----------

    @IsTest
    static void idempotencyKey_sameInputsSameKey_differentItemsDifferentKey() {
        MockErpModels.ReturnRequest a = new MockErpModels.ReturnRequest('SO-100012', 'DAMAGED').addLine('1', 1);
        MockErpModels.ReturnRequest b = new MockErpModels.ReturnRequest('SO-100012', 'DAMAGED').addLine('1', 1);
        MockErpModels.ReturnRequest c = new MockErpModels.ReturnRequest('SO-100012', 'DAMAGED').addLine('2', 1);

        Assert.areEqual(CreateReturnAction.idempotencyKey(null, a), CreateReturnAction.idempotencyKey(null, b));
        Assert.areNotEqual(CreateReturnAction.idempotencyKey(null, a), CreateReturnAction.idempotencyKey(null, c));
        Assert.areNotEqual(CreateReturnAction.idempotencyKey(null, a), CreateReturnAction.idempotencyKey('500XX0000000001', a));
    }

    @IsTest
    static void parseItems_handlesBlankAndSpacing() {
        Assert.areEqual(0, CreateReturnAction.parseItems('  ').size());
        List<MockErpModels.ReturnLineRequest> lines = CreateReturnAction.parseItems(' 1 ,, Line 3 : 2 ');
        Assert.areEqual(2, lines.size());
        Assert.areEqual('3', lines[1].lineId);
        Assert.areEqual(2, lines[1].quantity);
    }
}