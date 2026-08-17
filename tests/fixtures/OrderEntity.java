package com.example;

import jakarta.persistence.Entity;

// Parent is NOT annotated: per the Jakarta Persistence spec, its state is
// not persisted. The chain must be walked THROUGH it (PlainHelper itself
// extends an annotated @MappedSuperclass) but its own fields dropped.
@Entity
public class OrderEntity extends PlainHelper {
    private String reference;
}
