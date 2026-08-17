package com.example;

import jakarta.persistence.Entity;
import org.springframework.data.jpa.domain.AbstractPersistable;

// Parent lives in a jar and is not resolvable as a source buffer. The walk
// must return the own fields with ok=false: usable for suggestions, but
// never cached and never good enough to emit a full signature.
@Entity
public class OrphanEntity extends AbstractPersistable {
    private String title;
}
