package com.reservtix.common.exception;

public class InvalidWebhookSignatureException extends RuntimeException{
    public InvalidWebhookSignatureException(String message) {
        super(message);
    }
}
