package com.example;

import jakarta.persistence.Entity;

// Redeclares `version`, already declared in Auditable as Long. Java
// shadowing rules apply: the child's declaration wins.
@Entity
public class ShadowEntity extends Auditable {
    private String version;
}
