namespace HerdrOps.Infrastructure.Storage;

public sealed partial class SqliteHerdrStateStore
{
    private const string ComplianceReviewMigrationName =
        "role-distinct-compliance-review-workflow";

    private const string ComplianceReviewMigrationSql = """
        CREATE TABLE compliance_review_incidents (
            incident_id TEXT NOT NULL PRIMARY KEY CHECK (length(incident_id) BETWEEN 1 AND 128),
            contract_version INTEGER NOT NULL CHECK (contract_version = 1),
            task_id TEXT NOT NULL CHECK (length(task_id) BETWEEN 1 AND 128),
            subject_actor_id TEXT NOT NULL CHECK (length(subject_actor_id) BETWEEN 1 AND 128),
            registered_utc TEXT NOT NULL,
            registration_sha256 TEXT NOT NULL UNIQUE CHECK (length(registration_sha256) = 64),
            registration_json TEXT NOT NULL CHECK (
                json_valid(registration_json) = 1 AND
                json_type(registration_json, '$.initialEvidenceIdentitySha256s') = 'array'
            ),
            state INTEGER NOT NULL CHECK (state BETWEEN 1 AND 5),
            sequence INTEGER NOT NULL CHECK (sequence >= 0),
            updated_utc TEXT NOT NULL,
            last_audit_event_id TEXT NULL CHECK (last_audit_event_id IS NULL OR length(last_audit_event_id) = 36),
            last_audit_sha256 TEXT NULL CHECK (last_audit_sha256 IS NULL OR length(last_audit_sha256) = 64),
            CHECK (
                (sequence = 0 AND state = 1 AND last_audit_event_id IS NULL AND last_audit_sha256 IS NULL) OR
                (sequence > 0 AND last_audit_event_id IS NOT NULL AND last_audit_sha256 IS NOT NULL)
            )
        ) STRICT;

        CREATE INDEX ix_compliance_review_incidents_state_updated
            ON compliance_review_incidents(state, updated_utc);

        CREATE TABLE compliance_review_incident_evidence (
            incident_id TEXT NOT NULL CHECK (length(incident_id) BETWEEN 1 AND 128),
            evidence_identity_sha256 TEXT NOT NULL CHECK (length(evidence_identity_sha256) = 64),
            PRIMARY KEY(incident_id, evidence_identity_sha256),
            FOREIGN KEY(incident_id) REFERENCES compliance_review_incidents(incident_id),
            FOREIGN KEY(evidence_identity_sha256) REFERENCES evidence_items(evidence_identity_sha256)
        ) STRICT;

        CREATE INDEX ix_compliance_review_incident_evidence_identity
            ON compliance_review_incident_evidence(evidence_identity_sha256, incident_id);

        CREATE TABLE compliance_review_events (
            audit_event_id TEXT NOT NULL PRIMARY KEY CHECK (length(audit_event_id) = 36),
            contract_version INTEGER NOT NULL CHECK (contract_version = 1),
            incident_id TEXT NOT NULL CHECK (length(incident_id) BETWEEN 1 AND 128),
            task_id TEXT NOT NULL CHECK (length(task_id) BETWEEN 1 AND 128),
            subject_actor_id TEXT NOT NULL CHECK (length(subject_actor_id) BETWEEN 1 AND 128),
            sequence INTEGER NOT NULL CHECK (sequence > 0),
            reviewer_actor_id TEXT NOT NULL CHECK (length(reviewer_actor_id) BETWEEN 1 AND 128),
            reviewer_role INTEGER NOT NULL CHECK (reviewer_role BETWEEN 1 AND 2),
            authority_provenance_event_id TEXT NOT NULL CHECK (length(authority_provenance_event_id) = 36),
            authority_provenance_sequence INTEGER NOT NULL CHECK (authority_provenance_sequence > 0),
            authority_provenance_sha256 TEXT NOT NULL CHECK (length(authority_provenance_sha256) = 64),
            decision_kind INTEGER NOT NULL CHECK (decision_kind BETWEEN 1 AND 4),
            previous_state INTEGER NOT NULL CHECK (previous_state BETWEEN 1 AND 5),
            result_state INTEGER NOT NULL CHECK (result_state BETWEEN 1 AND 5),
            reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 2048),
            occurred_utc TEXT NOT NULL,
            evidence_set_sha256 TEXT NOT NULL CHECK (length(evidence_set_sha256) = 64),
            previous_audit_sha256 TEXT NULL CHECK (previous_audit_sha256 IS NULL OR length(previous_audit_sha256) = 64),
            audit_sha256 TEXT NOT NULL UNIQUE CHECK (length(audit_sha256) = 64),
            audit_json TEXT NOT NULL,
            audit_json_sha256 TEXT NOT NULL CHECK (length(audit_json_sha256) = 64),
            UNIQUE(incident_id, sequence),
            FOREIGN KEY(incident_id) REFERENCES compliance_review_incidents(incident_id),
            FOREIGN KEY(authority_provenance_event_id) REFERENCES assignment_lifecycle_events(event_id)
        ) STRICT;

        CREATE INDEX ix_compliance_review_events_incident_sequence
            ON compliance_review_events(incident_id, sequence);

        CREATE INDEX ix_compliance_review_events_reviewer
            ON compliance_review_events(reviewer_actor_id, reviewer_role, occurred_utc);

        CREATE TABLE compliance_review_event_evidence (
            audit_event_id TEXT NOT NULL CHECK (length(audit_event_id) = 36),
            evidence_identity_sha256 TEXT NOT NULL CHECK (length(evidence_identity_sha256) = 64),
            PRIMARY KEY(audit_event_id, evidence_identity_sha256),
            FOREIGN KEY(audit_event_id) REFERENCES compliance_review_events(audit_event_id),
            FOREIGN KEY(evidence_identity_sha256) REFERENCES evidence_items(evidence_identity_sha256)
        ) STRICT;

        CREATE INDEX ix_compliance_review_event_evidence_identity
            ON compliance_review_event_evidence(evidence_identity_sha256, audit_event_id);

        CREATE TRIGGER assignment_current_actor_roles_v4_validate_insert
        BEFORE INSERT ON assignment_current_actor_roles
        WHEN NOT EXISTS (
            SELECT 1
            FROM assignment_actor_role_history history
            WHERE history.actor_id = NEW.actor_id
              AND history.actor_role = NEW.actor_role
              AND history.task_id = NEW.task_id
              AND history.event_id = NEW.event_id
              AND history.sequence = NEW.sequence
              AND history.accepted_utc = NEW.accepted_utc
              AND history.provenance_event_sha256 = NEW.provenance_event_sha256
              AND history.sequence = (
                  SELECT MAX(latest.sequence)
                  FROM assignment_actor_role_history latest
                  WHERE latest.actor_id = NEW.actor_id
              )
        )
        BEGIN
            SELECT RAISE(ABORT, 'assignment_current_actor_roles requires the latest immutable role observation');
        END;

        CREATE TRIGGER assignment_current_actor_roles_v4_validate_update
        BEFORE UPDATE ON assignment_current_actor_roles
        WHEN OLD.actor_id <> NEW.actor_id OR
             NEW.sequence <= OLD.sequence OR
             NOT EXISTS (
                 SELECT 1
                 FROM assignment_actor_role_history history
                 WHERE history.actor_id = NEW.actor_id
                   AND history.actor_role = NEW.actor_role
                   AND history.task_id = NEW.task_id
                   AND history.event_id = NEW.event_id
                   AND history.sequence = NEW.sequence
                   AND history.accepted_utc = NEW.accepted_utc
                   AND history.provenance_event_sha256 = NEW.provenance_event_sha256
                   AND history.sequence = (
                       SELECT MAX(latest.sequence)
                       FROM assignment_actor_role_history latest
                       WHERE latest.actor_id = NEW.actor_id
                   )
             )
        BEGIN
            SELECT RAISE(ABORT, 'assignment_current_actor_roles can advance only to the latest immutable role observation');
        END;

        CREATE TRIGGER assignment_current_actor_roles_v4_reject_delete
        BEFORE DELETE ON assignment_current_actor_roles
        BEGIN
            SELECT RAISE(ABORT, 'assignment_current_actor_roles cannot be deleted');
        END;

        CREATE TRIGGER compliance_review_incidents_reject_delete
        BEFORE DELETE ON compliance_review_incidents
        BEGIN
            SELECT RAISE(ABORT, 'compliance_review_incidents cannot be deleted');
        END;

        CREATE TRIGGER compliance_review_incidents_guard_update
        BEFORE UPDATE ON compliance_review_incidents
        WHEN
            OLD.incident_id <> NEW.incident_id OR
            OLD.contract_version <> NEW.contract_version OR
            OLD.task_id <> NEW.task_id OR
            OLD.subject_actor_id <> NEW.subject_actor_id OR
            OLD.registered_utc <> NEW.registered_utc OR
            OLD.registration_sha256 <> NEW.registration_sha256 OR
            OLD.registration_json <> NEW.registration_json OR
            NEW.sequence <> OLD.sequence + 1 OR
            NOT EXISTS (
                SELECT 1
                FROM compliance_review_events event
                WHERE event.audit_event_id = NEW.last_audit_event_id
                  AND event.incident_id = NEW.incident_id
                  AND event.sequence = NEW.sequence
                  AND event.previous_state = OLD.state
                  AND event.result_state = NEW.state
                  AND event.occurred_utc = NEW.updated_utc
                  AND event.audit_sha256 = NEW.last_audit_sha256
                  AND (
                      (OLD.last_audit_sha256 IS NULL AND event.previous_audit_sha256 IS NULL) OR
                      event.previous_audit_sha256 = OLD.last_audit_sha256
                  )
            )
        BEGIN
            SELECT RAISE(ABORT, 'compliance_review_incidents can advance only through a matching immutable audit event');
        END;

        CREATE TRIGGER compliance_review_incident_evidence_validate_insert
        BEFORE INSERT ON compliance_review_incident_evidence
        WHEN NOT EXISTS (
            SELECT 1
            FROM compliance_review_incidents incident,
                 json_each(incident.registration_json, '$.initialEvidenceIdentitySha256s') declared
            WHERE incident.incident_id = NEW.incident_id
              AND json_type(incident.registration_json, '$.initialEvidenceIdentitySha256s') = 'array'
              AND declared.type = 'text'
              AND declared.value = NEW.evidence_identity_sha256
        )
        BEGIN
            SELECT RAISE(ABORT, 'compliance review incident evidence is not declared by the immutable registration JSON');
        END;

        CREATE TRIGGER compliance_review_incident_evidence_reject_update
        BEFORE UPDATE ON compliance_review_incident_evidence
        BEGIN
            SELECT RAISE(ABORT, 'compliance_review_incident_evidence is append-only');
        END;

        CREATE TRIGGER compliance_review_incident_evidence_reject_delete
        BEFORE DELETE ON compliance_review_incident_evidence
        BEGIN
            SELECT RAISE(ABORT, 'compliance_review_incident_evidence is append-only');
        END;

        CREATE TRIGGER compliance_review_events_validate_insert
        BEFORE INSERT ON compliance_review_events
        WHEN
            herdrops_review_audit_valid(
                NEW.contract_version,
                NEW.audit_event_id,
                NEW.incident_id,
                NEW.task_id,
                NEW.subject_actor_id,
                NEW.sequence,
                NEW.reviewer_actor_id,
                NEW.reviewer_role,
                NEW.authority_provenance_event_id,
                NEW.authority_provenance_sequence,
                NEW.authority_provenance_sha256,
                NEW.decision_kind,
                NEW.previous_state,
                NEW.result_state,
                NEW.reason,
                NEW.occurred_utc,
                NEW.evidence_set_sha256,
                NEW.previous_audit_sha256,
                NEW.audit_sha256,
                NEW.audit_json,
                NEW.audit_json_sha256) <> 1 OR
            NOT EXISTS (
                SELECT 1
                FROM compliance_review_incidents incident
                WHERE incident.incident_id = NEW.incident_id
                  AND incident.task_id = NEW.task_id
                  AND incident.subject_actor_id = NEW.subject_actor_id
                  AND incident.sequence + 1 = NEW.sequence
                  AND incident.state = NEW.previous_state
                  AND incident.updated_utc <= NEW.occurred_utc
                  AND (
                      (incident.last_audit_sha256 IS NULL AND NEW.previous_audit_sha256 IS NULL) OR
                      incident.last_audit_sha256 = NEW.previous_audit_sha256
                  )
            ) OR
            NEW.reviewer_actor_id = NEW.subject_actor_id OR
            NOT EXISTS (
                SELECT 1
                FROM assignment_current_actor_roles authority
                WHERE authority.actor_id = NEW.reviewer_actor_id
                  AND authority.event_id = NEW.authority_provenance_event_id
                  AND authority.sequence = NEW.authority_provenance_sequence
                  AND authority.accepted_utc <= NEW.occurred_utc
                  AND authority.provenance_event_sha256 = NEW.authority_provenance_sha256
                  AND authority.sequence = (
                      SELECT MAX(history.sequence)
                      FROM assignment_actor_role_history history
                      WHERE history.actor_id = authority.actor_id
                  )
                  AND EXISTS (
                      SELECT 1
                      FROM assignment_actor_role_history history
                      WHERE history.actor_id = authority.actor_id
                        AND history.actor_role = authority.actor_role
                        AND history.task_id = authority.task_id
                        AND history.event_id = authority.event_id
                        AND history.sequence = authority.sequence
                        AND history.accepted_utc = authority.accepted_utc
                        AND history.provenance_event_sha256 = authority.provenance_event_sha256
                  )
                  AND (
                      (NEW.reviewer_role = 1 AND authority.actor_role = 'Project Manager') OR
                      (NEW.reviewer_role = 2 AND authority.actor_role IN (
                          'Leader',
                          'Backend Leader',
                          'Frontend Leader',
                          'Test Leader',
                          'DevOps Leader',
                          'Security Leader',
                          'Data Leader',
                          'Documentation Leader'
                      ))
                  )
            ) OR
            NOT (
                (NEW.previous_state = 1 AND NEW.reviewer_role = 1 AND NEW.decision_kind = 1 AND NEW.result_state = 4) OR
                (NEW.previous_state = 1 AND NEW.reviewer_role = 1 AND NEW.decision_kind = 2 AND NEW.result_state = 2) OR
                (NEW.previous_state = 1 AND NEW.reviewer_role = 1 AND NEW.decision_kind = 4 AND NEW.result_state = 5) OR
                (NEW.previous_state = 2 AND NEW.reviewer_role = 2 AND NEW.decision_kind = 3 AND NEW.result_state = 3) OR
                (NEW.previous_state = 3 AND NEW.reviewer_role = 1 AND NEW.decision_kind = 1 AND NEW.result_state = 4) OR
                (NEW.previous_state = 3 AND NEW.reviewer_role = 1 AND NEW.decision_kind = 2 AND NEW.result_state = 2) OR
                (NEW.previous_state = 3 AND NEW.reviewer_role = 1 AND NEW.decision_kind = 4 AND NEW.result_state = 5)
            )
        BEGIN
            SELECT RAISE(ABORT, 'compliance review event is not a current-authority incident transition');
        END;

        CREATE TRIGGER compliance_review_events_advance_incident
        AFTER INSERT ON compliance_review_events
        BEGIN
            UPDATE compliance_review_incidents
            SET state = NEW.result_state,
                sequence = NEW.sequence,
                updated_utc = NEW.occurred_utc,
                last_audit_event_id = NEW.audit_event_id,
                last_audit_sha256 = NEW.audit_sha256
            WHERE incident_id = NEW.incident_id;
        END;

        CREATE TRIGGER compliance_review_events_reject_update
        BEFORE UPDATE ON compliance_review_events
        BEGIN
            SELECT RAISE(ABORT, 'compliance_review_events is append-only');
        END;

        CREATE TRIGGER compliance_review_events_reject_delete
        BEFORE DELETE ON compliance_review_events
        BEGIN
            SELECT RAISE(ABORT, 'compliance_review_events is append-only');
        END;

        CREATE TRIGGER compliance_review_event_evidence_validate_insert
        BEFORE INSERT ON compliance_review_event_evidence
        WHEN NOT EXISTS (
            SELECT 1
            FROM compliance_review_events event,
                 json_each(event.audit_json, '$.evidenceIdentitySha256s') declared
            WHERE event.audit_event_id = NEW.audit_event_id
              AND json_type(event.audit_json, '$.evidenceIdentitySha256s') = 'array'
              AND declared.type = 'text'
              AND declared.value = NEW.evidence_identity_sha256
        )
        BEGIN
            SELECT RAISE(ABORT, 'compliance review event evidence is not declared by the immutable audit JSON');
        END;

        CREATE TRIGGER compliance_review_event_evidence_reject_update
        BEFORE UPDATE ON compliance_review_event_evidence
        BEGIN
            SELECT RAISE(ABORT, 'compliance_review_event_evidence is append-only');
        END;

        CREATE TRIGGER compliance_review_event_evidence_reject_delete
        BEFORE DELETE ON compliance_review_event_evidence
        BEGIN
            SELECT RAISE(ABORT, 'compliance_review_event_evidence is append-only');
        END;
        """;
}
