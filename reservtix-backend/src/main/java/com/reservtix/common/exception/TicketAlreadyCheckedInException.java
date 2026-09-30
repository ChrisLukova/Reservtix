package com.reservtix.common.exception;

public class TicketAlreadyCheckedInException extends RuntimeException{
    public TicketAlreadyCheckedInException(String message) {
        super(message);
    }
}
