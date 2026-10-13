/**
 * Agent action: create a return authorization (RMA) in the ERP.
 * The agent must confirm the items and reason with the customer before calling this.
 */
 public with sharing class CreateReturnAction {

    public class Request {
        @InvocableVariable(
            label='Order Number'
            description='The order number the items belong to, in the format SO-123456.'
            required=true)
        public String orderNumber;

        @InvocableVariable(
            label='Items'
            description='Comma-separated line IDs to return, from the Look Up Order result. Add a quantity after a colon if more than 1, for example "2" or "1, 2:3".'
            required=true)
        public String items;

        @InvocableVariable(
            label='Reason'
            description='Exactly one of: DAMAGED, WRONG_ITEM, NOT_AS_DESCRIBED, NO_LONGER_NEEDED, OTHER. Choose the one that best matches what the customer said.'
            required=true)
        public String reason;

        @InvocableVariable(
            label='Case Id'
            description='Optional. The Case record Id for this conversation, if there is one. Used to prevent duplicate returns.')
        public String caseId;
    }

    public class Result {
        @InvocableVariable(label='Success' description='True if the return was authorized.')
        public Boolean success;

        @InvocableVariable(label='RMA Number' description='The return authorization number to give the customer.')
        public String rmaNumber;

        @InvocableVariable(label='Refund Amount' description='Total refund in USD for the returned items.')
        public Decimal refundAmount;

        @InvocableVariable(label='Requires Approval' description='True if the refund is over $1,000 and must be approved by a human before it is paid.')
        public Boolean requiresApproval;

        @InvocableVariable(label='Return Label URL' description='Link to the prepaid return shipping label.')
        public String returnLabelUrl;

        @InvocableVariable(label='Message' description='What to tell the customer and what to do next.')
        public String message;
    }

    @InvocableMethod(
        label='Create Return'
        description='Creates a return authorization for specific items on an order and returns the RMA number, refund amount and label link. Only call after looking up the order and confirming the items and reason with the customer.'
        category='Order Returns')
    public static List<Result> createReturn(List<Request> requests) {
        MockErpService erp = new MockErpService();
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(createOne(erp, req));
        }
        return results;
    }

    private static Result createOne(MockErpService erp, Request req) {
        Result r = new Result();
        try {
            MockErpModels.ReturnRequest rr = new MockErpModels.ReturnRequest(
                req.orderNumber == null ? null : req.orderNumber.trim(),
                req.reason == null ? null : req.reason.trim().toUpperCase());
            rr.lines = parseItems(req.items);

            MockErpModels.ReturnAuthorization rma = erp.createReturn(rr, idempotencyKey(req.caseId, rr));

            r.success = true;
            r.rmaNumber = rma.rmaNumber;
            r.refundAmount = rma.refundTotal;
            r.requiresApproval = rma.requiresApproval;
            r.returnLabelUrl = rma.returnLabelUrl;
            if (rma.requiresApproval == true) {
                r.message = 'Return ' + rma.rmaNumber + ' is authorized, but the refund of $' + rma.refundTotal.setScale(2)
                    + ' needs approval. Tell the customer a specialist will review the refund, then escalate to a human agent.';
            } else {
                r.message = 'Return ' + rma.rmaNumber + ' is authorized. The refund of $' + rma.refundTotal.setScale(2)
                    + ' is issued when the items arrive. Share the return label link.';
            }
        } catch (MockErpException e) {
            r.success = false;
            r.message = ErpActionMessages.forException(e);
        }
        return r;
    }

    /** Accepts "2", "1, 2:3" or "line 2". Quantity defaults to 1. */
    @TestVisible
    private static List<MockErpModels.ReturnLineRequest> parseItems(String items) {
        List<MockErpModels.ReturnLineRequest> lines = new List<MockErpModels.ReturnLineRequest>();
        if (String.isBlank(items)) {
            return lines; // the service rejects an empty list with INVALID_INPUT
        }
        for (String part : items.split(',')) {
            String p = part.trim().toLowerCase().removeStart('line').trim();
            if (p.length() == 0) {
                continue;
            }
            String lineId = p.substringBefore(':').trim();
            Integer quantity = 1;
            if (p.contains(':')) {
                String q = p.substringAfter(':').trim();
                if (!q.isNumeric()) {
                    throw MockErpException.invalidInput('Quantity must be a whole number in "' + part.trim() + '"');
                }
                quantity = Integer.valueOf(q);
            }
            lines.add(new MockErpModels.ReturnLineRequest(lineId, quantity));
        }
        return lines;
    }

    /**
     * Same case + order + items + reason => same key, so if the agent calls twice
     * (or a timeout triggers a retry) the ERP returns the first RMA instead of a duplicate.
     * A different set of items gets a different key, so it is a genuinely new return.
     */
    @TestVisible
    private static String idempotencyKey(String caseId, MockErpModels.ReturnRequest rr) {
        List<String> parts = new List<String>();
        for (MockErpModels.ReturnLineRequest l : rr.lines) {
            parts.add(l.lineId + ':' + l.quantity);
        }
        String basis = (String.isBlank(caseId) ? '' : caseId.trim()) + '|'
            + String.valueOf(rr.orderNumber).toUpperCase() + '|'
            + String.join(parts, ',') + '|' + rr.reason;
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(basis)));
    }
}