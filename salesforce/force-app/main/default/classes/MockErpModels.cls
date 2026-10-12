/**
 * Typed wrappers for the Mock ERP JSON contract.
 * Field names must match the JSON keys exactly; JSON.deserialize ignores keys it doesn't know.
 */
 public with sharing class MockErpModels {

    // ---------- Orders ----------

    public class Customer {
        public String customerId;
        public String name;
        public String email;
    }

    public class ReturnEligibility {
        public Boolean eligible;
        public String reason;               // FINAL_SALE, OUTSIDE_RETURN_WINDOW, ... (null when eligible)
        public Integer returnableQuantity;  // only when eligible
        public String windowEnds;           // yyyy-MM-dd
    }

    public class ErpOrderLine {
        public String lineId;
        public String sku;
        public String description;
        public Integer quantity;
        public Decimal unitPrice;
        public Boolean finalSale;
        public Integer returnedQuantity;
        public String lineStatus;           // only on partially shipped orders
        public ReturnEligibility returnEligibility;
    }

    public class ErpOrder {
        public String orderNumber;
        public Customer customer;
        public Date orderDate;
        public String status;               // PROCESSING, SHIPPED, PARTIALLY_SHIPPED, DELIVERED, CANCELLED
        public Date deliveredDate;
        public String trackingNumber;
        public String carrier;
        public String paymentReference;
        public Decimal orderTotal;
        public List<ErpOrderLine> lines;
    }

    public class OrderSummary {
        public String orderNumber;
        public Date orderDate;
        public String status;
        public Integer itemCount;
        public Decimal orderTotal;
    }

    public class OrderSearchResult {
        public String email;
        public Integer totalSize;
        public List<OrderSummary> orders;
    }

    // ---------- Returns ----------

    public class ReturnLineRequest {
        public String lineId;
        public Integer quantity;

        public ReturnLineRequest(String lineId, Integer quantity) {
            this.lineId = lineId;
            this.quantity = quantity;
        }
    }

    public class ReturnRequest {
        public String orderNumber;
        public String reason;               // DAMAGED, WRONG_ITEM, NOT_AS_DESCRIBED, NO_LONGER_NEEDED, OTHER
        public List<ReturnLineRequest> lines = new List<ReturnLineRequest>();

        public ReturnRequest(String orderNumber, String reason) {
            this.orderNumber = orderNumber;
            this.reason = reason;
        }

        public ReturnRequest addLine(String lineId, Integer quantity) {
            lines.add(new ReturnLineRequest(lineId, quantity));
            return this;
        }
    }

    public class ReturnAuthorizationLine {
        public String lineId;
        public String sku;
        public String description;
        public Integer quantity;
        public Decimal refundAmount;
    }

    public class ReturnAuthorization {
        public String rmaNumber;
        public String orderNumber;
        public String status;
        public String reason;
        public String createdAt;            // ISO timestamp, kept as text
        public String paymentReference;
        public Decimal refundTotal;
        public Boolean requiresApproval;
        public String returnLabelUrl;
        public List<ReturnAuthorizationLine> lines;
    }

    // ---------- Errors ----------

    public class ErrorDetail {
        public String lineId;
        public String reason;
        public Integer returnableQuantity;
    }

    public class ErrorBody {
        public String code;
        public String message;
        public List<ErrorDetail> details;
    }

    public class ErrorEnvelope {
        public ErrorBody error;
    }
}