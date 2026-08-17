package com.example;

// No @MappedSuperclass, no @Entity: a plain utility base class. Its fields
// are part of the object model but not of the persistent state.
public class PlainHelper extends Auditable {
    private String helperNote;
}
