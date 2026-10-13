/**
 * Turns ERP codes into plain sentences the agent can relay or act on.
 * Keeping wording here (not in each action) gives the agent one consistent voice.
 */
 public with sharing class ErpActionMessages {

    /** Why a single line can't be returned, in customer-friendly words. */
    public static String reasonText(String code) {
        switch on code {
            when 'FINAL_SALE' { return 'final sale items cannot be returned'; }
            when 'OUTSIDE_RETURN_WINDOW' { return 'the 30-day return window has passed'; }
            when 'ALREADY_RETURNED' { return 'it has already been returned'; }
            when 'NOT_DELIVERED' { return 'it has not been delivered yet'; }
            when 'ORDER_CANCELLED' { return 'the order was cancelled'; }
            when 'INVALID_QUANTITY' { return 'that quantity is more than can be returned'; }
            when 'LINE_NOT_FOUND' { return 'there is no such item on this order'; }
            when else { return 'it is not eligible for return'; }
        }
    }

    /** What the agent should tell the customer (and do) when the ERP call failed. */
    public static String forException(MockErpException e) {
        switch on e.errorCode {
            when 'ORDER_NOT_FOUND' {
                return 'No order was found with that number. Ask the customer to check the order number.';
            }
            when 'INVALID_INPUT' {
                return 'The request was incomplete: ' + e.getMessage() + '. Ask the customer for the missing details.';
            }
            when 'RETURN_NOT_ELIGIBLE' {
                List<String> problems = new List<String>();
                for (MockErpModels.ErrorDetail d : e.details) {
                    problems.add('line ' + d.lineId + ' (' + reasonText(d.reason) + ')');
                }
                return 'Nothing was returned. These items cannot be returned: ' + String.join(problems, ', ')
                    + '. Explain why and offer to return only the eligible items.';
            }
            when else {
                if (e.isRetryable()) {
                    return 'The order system is temporarily unavailable. Apologise, and offer to try again shortly '
                        + 'or to pass the request to a human agent. [debug: ' + e.errorCode
                        + (e.statusCode == null ? '' : ' HTTP ' + e.statusCode) + ' - ' + e.getMessage() + ']';
                }
                return 'The request could not be completed (' + e.errorCode + '). Offer to pass it to a human agent.';
            }
        }
    }
}