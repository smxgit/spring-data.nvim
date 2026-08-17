package com.example;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import lombok.Data;

// Three-level chain: UserEntity -> BaseEntity -> Auditable.
// Lombok is present on purpose: @Data generates accessors but the fields
// themselves are declared, so treesitter sees them.
@Entity
@Data
public class UserEntity extends BaseEntity {
    @Column(unique = true)
    private String name;

    private int age;

    // Not persisted: must never be offered.
    private static final long serialVersionUID = 1L;

    private transient String scratch;
}
