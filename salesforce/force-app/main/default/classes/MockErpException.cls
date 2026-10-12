/**
 * The single exception type MockErpService throws.
 * Callers branch on errorCode (the ERP's machine-readable code), never on the message text.
 */
 public class MockErpException extends Exception {

    public Integer statusCode { get; private set; }      // HTTP status, null if the ERP was never reached
    public String errorCode { get; private set; }        // e.g. ORDER_NOT_FOUND, RETURN_NOT_ELIGIBLE
    public List<MockErpModels.ErrorDetail> details { get; private set; }

    /** True when trying again later might succeed (ERP down or unreachable). */
    public Boolean isRetryable() {
        return errorCode == 'CONNECTION_FAILED' || (statusCode != null && statusCode >= 500);
    }

    /** Builds an exception from a non-2xx ERP response. */
    public static MockErpException fromResponse(HttpResponse res) {
        MockErpException ex;
        try {
            MockErpModels.ErrorEnvelope envelope =
                (MockErpModels.ErrorEnvelope) JSON.deserialize(res.getBody(), MockErpModels.ErrorEnvelope.class);
            ex = new MockErpException(envelope.error.message);
            ex.errorCode = envelope.error.code;
            ex.details = envelope.error.details;
        } catch (Exception parseFailure) {
            // Body wasn't our JSON error contract (e.g. an HTML error page from a proxy)
            ex = new MockErpException('ERP returned HTTP ' + res.getStatusCode() + ' with an unexpected body');
            ex.errorCode = 'UNEXPECTED_RESPONSE';
        }
        ex.statusCode = res.getStatusCode();
        if (ex.details == null) {
            ex.details = new List<MockErpModels.ErrorDetail>();
        }
        return ex;
    }

    /** The callout itself failed: timeout, DNS, TLS, etc. */
    public static MockErpException connectionFailure(Exception cause) {
        MockErpException ex = new MockErpException('Could not reach the ERP: ' + cause.getMessage(), cause);
        ex.errorCode = 'CONNECTION_FAILED';
        ex.details = new List<MockErpModels.ErrorDetail>();
        return ex;
    }

    /** Bad input caught before any callout was made. */
    public static MockErpException invalidInput(String message) {
        MockErpException ex = new MockErpException(message);
        ex.errorCode = 'INVALID_INPUT';
        ex.details = new List<MockErpModels.ErrorDetail>();
        return ex;
    }
}