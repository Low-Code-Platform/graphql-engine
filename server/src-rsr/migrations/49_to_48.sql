-- Downgrade of the Phase 2 metadata partitioning (see 48_to_49.sql). The
-- Haskell migration (from49To48) first reassembles the partitions back into the
-- single hdb_catalog.hdb_metadata blob; this drops the now-empty partition table.
DROP TABLE hdb_catalog.hdb_metadata_partition;
