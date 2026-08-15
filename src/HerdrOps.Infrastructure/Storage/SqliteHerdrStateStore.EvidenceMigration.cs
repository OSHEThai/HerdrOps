namespace HerdrOps.Infrastructure.Storage;

public sealed partial class SqliteHerdrStateStore
{
    private const string EvidenceAuditMigrationName = "evidence-metadata-review-retention-audit";
    private const string EvidenceAuditMigrationSql = """
        CREATE TABLE evidence_items (
            evidence_identity_sha256 TEXT NOT NULL PRIMARY KEY CHECK (length(evidence_identity_sha256) = 64),
            contract_version INTEGER NOT NULL CHECK (contract_version = 1),
            task_id TEXT NOT NULL CHECK (length(task_id) BETWEEN 1 AND 128),
            actor_id TEXT NOT NULL CHECK (length(actor_id) BETWEEN 1 AND 128),
            source_event_id TEXT NOT NULL CHECK (length(source_event_id) BETWEEN 1 AND 128),
            source TEXT NOT NULL CHECK (length(source) BETWEEN 1 AND 64),
            source_reference TEXT NOT NULL CHECK (length(source_reference) BETWEEN 1 AND 2048),
            observed_utc TEXT NOT NULL,
            ingested_utc TEXT NOT NULL,
            retain_until_utc TEXT NOT NULL,
            availability INTEGER NOT NULL CHECK (availability BETWEEN 1 AND 2),
            storage_kind INTEGER NOT NULL CHECK (storage_kind BETWEEN 1 AND 2),
            content_length INTEGER NULL CHECK (content_length IS NULL OR content_length >= 0),
            content_sha256 TEXT NULL CHECK (content_sha256 IS NULL OR length(content_sha256) = 64),
            managed_relative_path TEXT NULL CHECK (managed_relative_path IS NULL OR length(managed_relative_path) BETWEEN 1 AND 512),
            metadata_json TEXT NOT NULL,
            metadata_json_sha256 TEXT NOT NULL CHECK (length(metadata_json_sha256) = 64),
            metadata_sha256 TEXT NOT NULL UNIQUE CHECK (length(metadata_sha256) = 64),
            CHECK (
                (availability = 1 AND content_length IS NOT NULL AND content_sha256 IS NOT NULL AND
                    ((storage_kind = 1 AND managed_relative_path IS NULL) OR
                     (storage_kind = 2 AND managed_relative_path IS NOT NULL))) OR
                (availability = 2 AND storage_kind = 1 AND content_length IS NULL AND
                    content_sha256 IS NULL AND managed_relative_path IS NULL)
            )
        ) STRICT;

        CREATE INDEX ix_evidence_items_task_observed
            ON evidence_items(task_id, observed_utc);

        CREATE INDEX ix_evidence_items_retention
            ON evidence_items(storage_kind, availability, retain_until_utc);

        CREATE TABLE review_audit_events (
            audit_event_id TEXT NOT NULL PRIMARY KEY CHECK (length(audit_event_id) = 36),
            contract_version INTEGER NOT NULL CHECK (contract_version = 1),
            review_case_id TEXT NOT NULL CHECK (length(review_case_id) BETWEEN 1 AND 128),
            sequence INTEGER NOT NULL CHECK (sequence > 0),
            reviewer_actor_id TEXT NOT NULL CHECK (length(reviewer_actor_id) BETWEEN 1 AND 128),
            reviewer_role TEXT NOT NULL CHECK (length(reviewer_role) BETWEEN 1 AND 128),
            action_kind INTEGER NOT NULL CHECK (action_kind BETWEEN 1 AND 4),
            review_state INTEGER NOT NULL CHECK (review_state BETWEEN 1 AND 2),
            reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 2048),
            occurred_utc TEXT NOT NULL,
            evidence_set_sha256 TEXT NOT NULL CHECK (length(evidence_set_sha256) = 64),
            previous_audit_sha256 TEXT NULL CHECK (previous_audit_sha256 IS NULL OR length(previous_audit_sha256) = 64),
            audit_sha256 TEXT NOT NULL UNIQUE CHECK (length(audit_sha256) = 64),
            audit_json TEXT NOT NULL,
            audit_json_sha256 TEXT NOT NULL CHECK (length(audit_json_sha256) = 64),
            UNIQUE(review_case_id, sequence)
        ) STRICT;

        CREATE INDEX ix_review_audit_events_case_sequence
            ON review_audit_events(review_case_id, sequence);

        CREATE TABLE review_audit_evidence (
            audit_event_id TEXT NOT NULL CHECK (length(audit_event_id) = 36),
            evidence_identity_sha256 TEXT NOT NULL CHECK (length(evidence_identity_sha256) = 64),
            PRIMARY KEY(audit_event_id, evidence_identity_sha256),
            FOREIGN KEY(audit_event_id) REFERENCES review_audit_events(audit_event_id),
            FOREIGN KEY(evidence_identity_sha256) REFERENCES evidence_items(evidence_identity_sha256)
        ) STRICT;

        CREATE INDEX ix_review_audit_evidence_identity
            ON review_audit_evidence(evidence_identity_sha256, audit_event_id);

        CREATE TABLE evidence_retention_events (
            retention_event_id TEXT NOT NULL PRIMARY KEY CHECK (length(retention_event_id) = 36),
            evidence_identity_sha256 TEXT NOT NULL UNIQUE CHECK (length(evidence_identity_sha256) = 64),
            occurred_utc TEXT NOT NULL,
            outcome INTEGER NOT NULL CHECK (outcome BETWEEN 1 AND 2),
            managed_relative_path TEXT NOT NULL CHECK (length(managed_relative_path) BETWEEN 1 AND 512),
            expected_content_length INTEGER NOT NULL CHECK (expected_content_length >= 0),
            expected_content_sha256 TEXT NOT NULL CHECK (length(expected_content_sha256) = 64),
            retention_audit_sha256 TEXT NOT NULL UNIQUE CHECK (length(retention_audit_sha256) = 64),
            FOREIGN KEY(evidence_identity_sha256) REFERENCES evidence_items(evidence_identity_sha256)
        ) STRICT;

        CREATE INDEX ix_evidence_retention_events_occurred
            ON evidence_retention_events(occurred_utc);

        CREATE TRIGGER evidence_items_reject_update
        BEFORE UPDATE ON evidence_items
        BEGIN
            SELECT RAISE(ABORT, 'evidence_items is append-only');
        END;

        CREATE TRIGGER evidence_items_reject_delete
        BEFORE DELETE ON evidence_items
        BEGIN
            SELECT RAISE(ABORT, 'evidence_items is append-only');
        END;

        CREATE TRIGGER review_audit_events_reject_update
        BEFORE UPDATE ON review_audit_events
        BEGIN
            SELECT RAISE(ABORT, 'review_audit_events is append-only');
        END;

        CREATE TRIGGER review_audit_events_reject_delete
        BEFORE DELETE ON review_audit_events
        BEGIN
            SELECT RAISE(ABORT, 'review_audit_events is append-only');
        END;

        CREATE TRIGGER review_audit_evidence_reject_update
        BEFORE UPDATE ON review_audit_evidence
        BEGIN
            SELECT RAISE(ABORT, 'review_audit_evidence is append-only');
        END;

        CREATE TRIGGER review_audit_evidence_reject_delete
        BEFORE DELETE ON review_audit_evidence
        BEGIN
            SELECT RAISE(ABORT, 'review_audit_evidence is append-only');
        END;

        CREATE TRIGGER evidence_retention_events_reject_update
        BEFORE UPDATE ON evidence_retention_events
        BEGIN
            SELECT RAISE(ABORT, 'evidence_retention_events is append-only');
        END;

        CREATE TRIGGER evidence_retention_events_reject_delete
        BEFORE DELETE ON evidence_retention_events
        BEGIN
            SELECT RAISE(ABORT, 'evidence_retention_events is append-only');
        END;
        """;
}
