-- Phase 2 (per-(source, schema) metadata storage): partition the metadata
-- catalog. The whole-metadata blob in hdb_catalog.hdb_metadata becomes a
-- skeleton; each (source, DB schema)'s table groups move into their own row
-- here. See rfcs/per-schema-gql-context.md §11.
CREATE TABLE hdb_catalog.hdb_metadata_partition
(
  source_name      TEXT    NOT NULL,
  schema_name      TEXT    NOT NULL,
  partition        JSONB   NOT NULL,
  resource_version INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (source_name, schema_name)
);
