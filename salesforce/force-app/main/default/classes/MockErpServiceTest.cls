@IsTest
private class MockErpServiceTest {

    // ---------- Test double ----------

    /** Returns a canned response and remembers the request so tests can inspect it. */
    private class ErpMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;
        public Boolean throwTimeout = false;
        public HttpRequest lastRequest;

        public ErpMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            lastRequest = req;
            if (throwTimeout) {
                throw new CalloutException('Read timed out');
            }
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

    // ---------- Sample payloads (trimmed copies of real ERP responses) ----------

    private static final String ORDER_SO_100003 =
        '{"orderNumber":"SO-100003","customer":{"customerId":"C-5002","name":"Marcus Lee","email":"marcus.lee@example.com"},' +
        '"orderDate":"2026-10-01","status":"PARTIALLY_SHIPPED","deliveredDate":null,"paymentReference":"pi_mock_100003","orderTotal":488,' +
        '"lines":[' +
        '{"lineId":"1","sku":"MON-27-4K","description":"27-inch 4K monitor","quantity":1,"unitPrice":399,"finalSale":false,"returnedQuantity":0,' +
        '"lineStatus":"DELIVERED","returnEligibility":{"eligible":true,"returnableQuantity":1,"windowEnds":"2026-11-03"}},' +
        '{"lineId":"2","sku":"ARM-MON-02","description":"Dual monitor arm","quantity":1,"unitPrice":89,"finalSale":false,"returnedQuantity":0,' +
        '"lineStatus":"BACKORDERED","returnEligibility":{"eligible":false,"reason":"NOT_DELIVERED"}}]}';

    private static final String RMA_CREATED =
        '{"rmaNumber":"RMA-1A2B3C4D","orderNumber":"SO-100001","status":"AUTHORIZED","reason":"DAMAGED",' +
        '"createdAt":"2026-10-11T23:11:22.452Z","paymentReference":"pi_mock_100001","refundTotal":249,"requiresApproval":false,' +
        '"returnLabelUrl":"https://example.com/labels/SO-100001.pdf",' +
        '"lines":[{"lineId":"1","sku":"HP-NC700","description":"Noise-cancelling headphones","quantity":1,"refundAmount":249}]}';

    // ---------- getOrder ----------

    @IsTest
    static void getOrder_parsesOrderAndLines() {
        ErpMock mock = mockResponse(200, ORDER_SO_100003);

        Test.startTest();
        MockErpModels.ErpOrder order = new MockErpService().getOrder(' SO-100003 ');
        Test.stopTest();

        Assert.areEqual('callout:MockERP/api/v1/orders/SO-100003', mock.lastRequest.getEndpoint(), 'Trims input and uses the Named Credential');
        Assert.areEqual('GET', mock.lastRequest.getMethod());
        Assert.areEqual('SO-100003', order.orderNumber);
        Assert.areEqual(Date.newInstance(2026, 10, 1), order.orderDate);
        Assert.areEqual('Marcus Lee', order.customer.name);
        Assert.areEqual(2, order.lines.size());
        Assert.isTrue(order.lines[0].returnEligibility.eligible);
        Assert.areEqual('NOT_DELIVERED', order.lines[1].returnEligibility.reason);
    }

    @IsTest
    static void getOrder_notFound_throwsNonRetryableError() {
        mockResponse(404, '{"error":{"code":"ORDER_NOT_FOUND","message":"No order SO-999999"}}');

        Test.startTest();
        try {
            new MockErpService().getOrder('SO-999999');
            Assert.fail('Expected MockErpException');
        } catch (MockErpException e) {
            Assert.areEqual(404, e.statusCode);
            Assert.areEqual('ORDER_NOT_FOUND', e.errorCode);
            Assert.areEqual('No order SO-999999', e.getMessage());
            Assert.isFalse(e.isRetryable(), '4xx errors must not be retried');
        }
        Test.stopTest();
    }

    @IsTest
    static void getOrder_blankInput_failsWithoutCallout() {
        ErpMock mock = mockResponse(200, ORDER_SO_100003);

        try {
            new MockErpService().getOrder('  ');
            Assert.fail('Expected MockErpException');
        } catch (MockErpException e) {
            Assert.areEqual('INVALID_INPUT', e.errorCode);
        }
        Assert.isNull(mock.lastRequest, 'No callout should be made for invalid input');
    }

    // ---------- findOrdersByEmail ----------

    @IsTest
    static void findOrdersByEmail_encodesEmail() {
        ErpMock mock = mockResponse(200,
            '{"email":"priya.sharma@example.com","totalSize":1,' +
            '"orders":[{"orderNumber":"SO-100001","orderDate":"2026-09-20","status":"DELIVERED","itemCount":2,"orderTotal":278}]}');

        Test.startTest();
        MockErpModels.OrderSearchResult result = new MockErpService().findOrdersByEmail('priya.sharma@example.com');
        Test.stopTest();

        Assert.isTrue(mock.lastRequest.getEndpoint().endsWith('/orders?email=priya.sharma%40example.com'), 'The @ must be URL-encoded');
        Assert.areEqual(1, result.totalSize);
        Assert.areEqual(278, result.orders[0].orderTotal.intValue());
    }

    // ---------- createReturn ----------

    @IsTest
    static void createReturn_sendsBodyAndIdempotencyKey() {
        ErpMock mock = mockResponse(201, RMA_CREATED);
        MockErpModels.ReturnRequest request = new MockErpModels.ReturnRequest('SO-100001', 'DAMAGED').addLine('1', 1);

        Test.startTest();
        MockErpModels.ReturnAuthorization rma = new MockErpService().createReturn(request, '500XX0000000001');
        Test.stopTest();

        Assert.areEqual('POST', mock.lastRequest.getMethod());
        Assert.areEqual('500XX0000000001', mock.lastRequest.getHeader('Idempotency-Key'));
        Assert.areEqual('application/json', mock.lastRequest.getHeader('Content-Type'));
        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.areEqual('SO-100001', sent.get('orderNumber'));
        Assert.areEqual('DAMAGED', sent.get('reason'));

        Assert.areEqual('RMA-1A2B3C4D', rma.rmaNumber);
        Assert.areEqual(249, rma.refundTotal.intValue());
        Assert.isFalse(rma.requiresApproval);
        Assert.areEqual(1, rma.lines.size());
    }

    @IsTest
    static void createReturn_notEligible_exposesLineReasons() {
        mockResponse(422,
            '{"error":{"code":"RETURN_NOT_ELIGIBLE","message":"One or more lines cannot be returned",' +
            '"details":[{"lineId":"3","reason":"FINAL_SALE"}]}}');
        MockErpModels.ReturnRequest request = new MockErpModels.ReturnRequest('SO-100012', 'NO_LONGER_NEEDED')
            .addLine('1', 1)
            .addLine('3', 1);

        Test.startTest();
        try {
            new MockErpService().createReturn(request, null);
            Assert.fail('Expected MockErpException');
        } catch (MockErpException e) {
            Assert.areEqual(422, e.statusCode);
            Assert.areEqual('RETURN_NOT_ELIGIBLE', e.errorCode);
            Assert.areEqual(1, e.details.size());
            Assert.areEqual('3', e.details[0].lineId);
            Assert.areEqual('FINAL_SALE', e.details[0].reason);
            Assert.isFalse(e.isRetryable());
        }
        Test.stopTest();
    }

    @IsTest
    static void createReturn_invalidReason_failsWithoutCallout() {
        ErpMock mock = mockResponse(201, RMA_CREATED);
        MockErpModels.ReturnRequest request = new MockErpModels.ReturnRequest('SO-100001', 'CHANGED_MIND').addLine('1', 1);

        try {
            new MockErpService().createReturn(request, null);
            Assert.fail('Expected MockErpException');
        } catch (MockErpException e) {
            Assert.areEqual('INVALID_INPUT', e.errorCode);
        }
        Assert.isNull(mock.lastRequest);
    }

    @IsTest
    static void createReturn_noLines_failsWithoutCallout() {
        ErpMock mock = mockResponse(201, RMA_CREATED);

        try {
            new MockErpService().createReturn(new MockErpModels.ReturnRequest('SO-100001', 'DAMAGED'), null);
            Assert.fail('Expected MockErpException');
        } catch (MockErpException e) {
            Assert.areEqual('INVALID_INPUT', e.errorCode);
        }
        Assert.isNull(mock.lastRequest);
    }

    // ---------- getReturn ----------

    @IsTest
    static void getReturn_parsesRma() {
        ErpMock mock = mockResponse(200, RMA_CREATED);

        Test.startTest();
        MockErpModels.ReturnAuthorization rma = new MockErpService().getReturn('RMA-1A2B3C4D');
        Test.stopTest();

        Assert.areEqual('callout:MockERP/api/v1/returns/RMA-1A2B3C4D', mock.lastRequest.getEndpoint());
        Assert.areEqual('AUTHORIZED', rma.status);
    }

    // ---------- Failures ----------

    @IsTest
    static void serverError_isRetryable() {
        mockResponse(503, '{"error":{"code":"SERVICE_UNAVAILABLE","message":"Simulated ERP maintenance window"}}');

        Test.startTest();
        try {
            new MockErpService().getOrder('SO-100001');
            Assert.fail('Expected MockErpException');
        } catch (MockErpException e) {
            Assert.areEqual('SERVICE_UNAVAILABLE', e.errorCode);
            Assert.isTrue(e.isRetryable(), '5xx errors may succeed on retry');
        }
        Test.stopTest();
    }

    @IsTest
    static void unexpectedBody_isHandled() {
        mockResponse(502, '<html>Bad Gateway</html>');

        Test.startTest();
        try {
            new MockErpService().getOrder('SO-100001');
            Assert.fail('Expected MockErpException');
        } catch (MockErpException e) {
            Assert.areEqual('UNEXPECTED_RESPONSE', e.errorCode);
            Assert.areEqual(502, e.statusCode);
            Assert.isTrue(e.isRetryable());
        }
        Test.stopTest();
    }

    @IsTest
    static void timeout_becomesConnectionFailure() {
        ErpMock mock = mockResponse(200, ORDER_SO_100003);
        mock.throwTimeout = true;

        Test.startTest();
        try {
            new MockErpService().getOrder('SO-100001');
            Assert.fail('Expected MockErpException');
        } catch (MockErpException e) {
            Assert.areEqual('CONNECTION_FAILED', e.errorCode);
            Assert.isNull(e.statusCode);
            Assert.isTrue(e.isRetryable());
            Assert.isTrue(e.getCause() instanceof CalloutException);
        }
        Test.stopTest();
    }
}