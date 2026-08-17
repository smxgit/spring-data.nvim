package com.example;

import org.springframework.data.jpa.repository.JpaRepository;

// No import for Document: it lives in this very package. The repository's
// own package is then the only candidate.
public interface DocumentRepository extends JpaRepository<Document, Long> {
}
