package com.example;

import jakarta.persistence.Entity;

// No superclass at all: the walk must terminate immediately with ok=true.
@Entity
public class LoneEntity {
    private String label;
}
