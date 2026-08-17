package com.example;

import jakarta.persistence.MappedSuperclass;

// Third level, to prove the walk doesn't stop at the first parent.
@MappedSuperclass
public class Auditable {
    private Long version;
}
