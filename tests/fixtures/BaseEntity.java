package com.example;

import jakarta.persistence.Id;
import jakarta.persistence.MappedSuperclass;
import java.time.LocalDateTime;

@MappedSuperclass
public class BaseEntity extends Auditable {
    @Id
    private Integer id;

    private LocalDateTime createdAt;
}
