/**
 * The only class that talks to the Mock ERP.
 * URL and API key come from the MockERP Named Credential; nothing secret lives here.
 */
 public with sharing class MockErpService {

    @TestVisible private static final String ENDPOINT_BASE = 'callout:MockERP/api/v1';
    private static final Integer TIMEOUT_MS = 60000; // free hosting can take a while to wake up
    private static final Set<String> VALID_REASONS = new Set<String>{
        'DAMAGED', 'WRONG_ITEM', 'NOT_AS_DESCRIBED', 'NO_LONGER_NEEDED', 'OTHER'
    };

    // ---------- Public API ----------

    public MockErpModels.ErpOrder getOrder(String orderNumber) {
        if (String.isBlank(orderNumber)) {
            throw MockErpException.invalidInput('Order number is required');
        }
        HttpResponse res = send('GET', '/orders/' + encode(orderNumber.trim()), null, null);
        return (MockErpModels.ErpOrder) JSON.deserialize(res.getBody(), MockErpModels.ErpOrder.class);
    }

    public MockErpModels.OrderSearchResult findOrdersByEmail(String email) {
        if (String.isBlank(email)) {
            throw MockErpException.invalidInput('Email is required');
        }
        HttpResponse res = send('GET', '/orders?email=' + encode(email.trim()), null, null);
        return (MockErpModels.OrderSearchResult) JSON.deserialize(res.getBody(), MockErpModels.OrderSearchResult.class);
    }

    /**
     * Creates a return authorization.
     * @param idempotencyKey pass something stable per business action (e.g. the Case Id)
     *        so a retry after a timeout returns the original RMA instead of creating a second one.
     */
    public MockErpModels.ReturnAuthorization createReturn(MockErpModels.ReturnRequest request, String idempotencyKey) {
        validate(request);
        HttpResponse res = send('POST', '/returns', JSON.serialize(request, true), idempotencyKey);
        return (MockErpModels.ReturnAuthorization) JSON.deserialize(res.getBody(), MockErpModels.ReturnAuthorization.class);
    }

    public MockErpModels.ReturnAuthorization getReturn(String rmaNumber) {
        if (String.isBlank(rmaNumber)) {
            throw MockErpException.invalidInput('RMA number is required');
        }
        HttpResponse res = send('GET', '/returns/' + encode(rmaNumber.trim()), null, null);
        return (MockErpModels.ReturnAuthorization) JSON.deserialize(res.getBody(), MockErpModels.ReturnAuthorization.class);
    }

    // ---------- Internals ----------

    private HttpResponse send(String method, String path, String body, String idempotencyKey) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT_BASE + path);
        req.setMethod(method);
        req.setTimeout(TIMEOUT_MS);
        req.setHeader('Accept', 'application/json');
        if (body != null) {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(body);
        }
        if (String.isNotBlank(idempotencyKey)) {
            req.setHeader('Idempotency-Key', idempotencyKey);
        }

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            throw MockErpException.connectionFailure(e);
        }

        Integer status = res.getStatusCode();
        if (status >= 200 && status < 300) {
            return res;
        }
        throw MockErpException.fromResponse(res);
    }

    private static void validate(MockErpModels.ReturnRequest request) {
        if (request == null || String.isBlank(request.orderNumber)) {
            throw MockErpException.invalidInput('Order number is required');
        }
        if (!VALID_REASONS.contains(request.reason)) {
            throw MockErpException.invalidInput('Reason must be one of ' + String.join(new List<String>(VALID_REASONS), ', '));
        }
        if (request.lines == null || request.lines.isEmpty()) {
            throw MockErpException.invalidInput('At least one line is required');
        }
    }

    private static String encode(String value) {
        return EncodingUtil.urlEncode(value, 'UTF-8');
    }
}