package com.example.repository;

import com.example.model.Document;
import com.example.legacy.*;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;

// Explicit import wins over the repository's own package, which in turn
// wins over wildcards.
public interface ImportingRepository extends JpaRepository<Document, Long> {
}
