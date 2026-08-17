package com.example;

// A record is not a class_declaration: extraction must return nil rather
// than an empty list, so the result is never cached as "zero field".
public record PointRecord(String label, int weight) {
}
