/**
 * Agent action: look up an order in the ERP and explain which items can be returned.
 * Labels and descriptions are what the Agentforce reasoning engine reads to decide
 * when to call this action and what to pass in, so they are written for the AI.
 */
 public with sharing class LookupOrderAction {

    public class Request {
        @InvocableVariable(
            label='Order Number'
            description='The customer\'s order number, in the format SO-123456.'
            required=true)
        public String orderNumber;
    }

    public class Result {
        @InvocableVariable(label='Found' description='True if the order exists in the ERP.')
        public Boolean found;

        @InvocableVariable(label='Order Summary' description='One-sentence summary: order number, date, status, total and tracking if shipped.')
        public String summary;

        @InvocableVariable(label='Order Status' description='PROCESSING, SHIPPED, PARTIALLY_SHIPPED, DELIVERED or CANCELLED.')
        public String status;

        @InvocableVariable(label='Returnable Items' description='Items that can be returned, one per line, with line ID, quantity allowed and return deadline. "None" if there are none.')
        public String returnableItems;

        @InvocableVariable(label='Non-Returnable Items' description='Items that cannot be returned, one per line, with the reason. "None" if there are none.')
        public String nonReturnableItems;

        @InvocableVariable(label='Message' description='Set when the lookup failed: what to tell the customer and what to do next.')
        public String message;
    }

    @InvocableMethod(
        label='Look Up Order'
        description='Gets an order from the order system by order number. Returns its status, a summary, and which items can or cannot be returned and why. Use before discussing or creating any return.'
        category='Order Returns')
    public static List<Result> lookUp(List<Request> requests) {
        MockErpService erp = new MockErpService();
        List<Result> results = new List<Result>();
        // Agents send one request at a time; Flow could send several. Each needs its own callout.
        for (Request req : requests) {
            results.add(lookUpOne(erp, req.orderNumber));
        }
        return results;
    }

    private static Result lookUpOne(MockErpService erp, String orderNumber) {
        Result r = new Result();
        try {
            MockErpModels.ErpOrder o = erp.getOrder(orderNumber);
            r.found = true;
            r.status = o.status;
            r.summary = summarize(o);

            List<String> returnable = new List<String>();
            List<String> notReturnable = new List<String>();
            for (MockErpModels.ErpOrderLine l : o.lines) {
                MockErpModels.ReturnEligibility e = l.returnEligibility;
                if (e != null && e.eligible == true) {
                    returnable.add('Line ' + l.lineId + ': ' + l.description
                        + ' (up to ' + e.returnableQuantity + ', return by ' + e.windowEnds + ')');
                } else {
                    notReturnable.add('Line ' + l.lineId + ': ' + l.description
                        + ' - ' + ErpActionMessages.reasonText(e == null ? null : e.reason));
                }
            }
            r.returnableItems = returnable.isEmpty() ? 'None' : String.join(returnable, '\n');
            r.nonReturnableItems = notReturnable.isEmpty() ? 'None' : String.join(notReturnable, '\n');
        } catch (MockErpException e) {
            r.found = false;
            r.message = ErpActionMessages.forException(e);
        }
        return r;
    }

    private static String summarize(MockErpModels.ErpOrder o) {
        String text = 'Order ' + o.orderNumber + ' placed ' + String.valueOf(o.orderDate)
            + ', status ' + o.status + ', total $' + o.orderTotal.setScale(2) + '.';
        if (String.isNotBlank(o.trackingNumber)) {
            text += ' Shipped with ' + o.carrier + ', tracking ' + o.trackingNumber + '.';
        }
        if (o.deliveredDate != null) {
            text += ' Delivered ' + String.valueOf(o.deliveredDate) + '.';
        }
        return text;
    }
}