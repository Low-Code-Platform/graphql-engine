{-# LANGUAGE QuasiQuotes #-}

-- | Integration tests for the partial schema cache rebuild path exercised by
-- @run_sql@ when the optional @schema@ field is supplied.
--
-- These tests catch stale-cache bugs by issuing DDL through the Hasura API and
-- asserting that GraphQL introspection reflects the correct schema afterwards.
--
-- Fixture: source "postgres", two schemas
--   * default schema (@hasura@) — 5 tracked tables
--   * @analytics@ schema       — 5 tracked tables
module Test.Schema.PartialSchemaCacheRebuildSpec (spec) where

import Data.Aeson (Value)
import Data.List.NonEmpty qualified as NE
import Harness.Backend.Postgres qualified as Postgres
import Harness.GraphqlEngine
  ( postGraphql,
    postMetadata_,
    postV2Query_,
    reloadMetadata,
  )
import Harness.Quoter.Graphql (graphql)
import Harness.Quoter.Yaml (yaml)
import Harness.Schema (Table (..), TableQualifier (..), table)
import Harness.Schema qualified as Schema
import Harness.Test.Fixture qualified as Fixture
import Harness.TestEnvironment (GlobalTestEnvironment, TestEnvironment)
import Harness.Yaml (shouldReturnYaml)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it)

--------------------------------------------------------------------------------
-- Spec entry point

spec :: SpecWith GlobalTestEnvironment
spec =
  Fixture.run
    ( NE.fromList
        [ (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnvironment, _) ->
                -- Both schemas are passed to a single setupTablesAction so that
                -- the internal setSource call happens only once and both sets of
                -- tables are tracked before any test runs.
                [ Postgres.setupTablesAction (defaultSchemaFixture <> analyticsSchemaFixture) testEnvironment
                ]
            }
        ]
    )
    tests

--------------------------------------------------------------------------------
-- Fixture tables

-- | Five tables in the default @hasura@ schema.  These provide the "untouched
-- schema" baseline: they must remain visible after partial rebuilds that target
-- the @analytics@ schema only.
defaultSchemaFixture :: [Schema.Table]
defaultSchemaFixture =
  map simpleTable ["items", "orders", "users", "products", "categories"]

-- | Five tables in the @analytics@ schema.  Partial rebuilds will target this
-- schema; the tables give the cache a pre-existing state to diff against.
analyticsSchemaFixture :: [Schema.Table]
analyticsSchemaFixture =
  map analyticsTable ["sessions", "page_views", "conversions", "metrics", "funnels"]

simpleTable :: Text -> Schema.Table
simpleTable name =
  (table name)
    { tableColumns = [Schema.column "id" Schema.TInt],
      tablePrimaryKey = ["id"]
    }

analyticsTable :: Text -> Schema.Table
analyticsTable name =
  (simpleTable name)
    { tableQualifiers = [TableQualifier "analytics"]
    }

--------------------------------------------------------------------------------
-- Helpers

-- | Run arbitrary SQL via the Hasura @v2/query@ API against the default
-- Postgres source without specifying a schema (triggers a full-source rebuild
-- when the SQL contains DDL keywords).
runPgSQL :: TestEnvironment -> String -> IO ()
runPgSQL testEnvironment sql =
  postV2Query_ testEnvironment
    [yaml|
      type: pg_run_sql
      args:
        source: postgres
        sql: *sql
        cascade: false
        read_only: false
    |]

-- | Like 'runPgSQL' but supplies the @schema@ field, which causes Hasura to
-- run a *partial* schema cache rebuild limited to that schema only.
runPgSQLWithSchema :: TestEnvironment -> String -> String -> IO ()
runPgSQLWithSchema testEnvironment schemaName sql =
  postV2Query_ testEnvironment
    [yaml|
      type: pg_run_sql
      args:
        source: postgres
        sql: *sql
        schema: *schemaName
        cascade: false
        read_only: false
    |]

-- | Track a table in the default Postgres source via the metadata API.
trackPgTable :: TestEnvironment -> String -> String -> IO ()
trackPgTable testEnvironment schemaName tableName =
  postMetadata_ testEnvironment
    [yaml|
      type: pg_track_table
      args:
        source: postgres
        table:
          schema: *schemaName
          name: *tableName
    |]

-- | Untrack a table from the default Postgres source via the metadata API.
untrackPgTable :: TestEnvironment -> String -> String -> IO ()
untrackPgTable testEnvironment schemaName tableName =
  postMetadata_ testEnvironment
    [yaml|
      type: pg_untrack_table
      args:
        source: postgres
        table:
          schema: *schemaName
          name: *tableName
        cascade: false
    |]

-- | Assert that a GraphQL named type IS present in introspection.
assertTypeVisible :: TestEnvironment -> String -> IO ()
assertTypeVisible testEnvironment typeName = do
  let expected :: Value
      expected =
        [yaml|
          data:
            __type:
              name: *typeName
        |]
      actual :: IO Value
      actual =
        postGraphql
          testEnvironment
          [graphql|
            query { __type(name: "#{typeName}") { name } }
          |]
  shouldReturnYaml testEnvironment actual expected

-- | Assert that a GraphQL named type is NOT present in introspection.
assertTypeAbsent :: TestEnvironment -> String -> IO ()
assertTypeAbsent testEnvironment typeName = do
  let expected :: Value
      expected =
        [yaml|
          data:
            __type: null
        |]
      actual :: IO Value
      actual =
        postGraphql
          testEnvironment
          [graphql|
            query { __type(name: "#{typeName}") { name } }
          |]
  shouldReturnYaml testEnvironment actual expected

--------------------------------------------------------------------------------
-- Tests

tests :: SpecWith TestEnvironment
tests = do
  describe "run_sql with schema field (partial schema cache rebuild)" do
    describe "CREATE TABLE" do
      it "is visible in GraphQL after partial rebuild of the target schema" \testEnvironment -> do
        -- Issue DDL in the analytics schema, supplying "schema" to trigger a
        -- partial cache rebuild for analytics only.
        runPgSQLWithSchema
          testEnvironment
          "analytics"
          "CREATE TABLE analytics.events (id int PRIMARY KEY)"
        -- Track the table so it is exposed in GraphQL.
        trackPgTable testEnvironment "analytics" "events"
        assertTypeVisible testEnvironment "analytics_events"
        -- Cleanup
        untrackPgTable testEnvironment "analytics" "events"
        runPgSQL testEnvironment "DROP TABLE IF EXISTS analytics.events"

      it "is absent from GraphQL after DROP TABLE with partial rebuild" \testEnvironment -> do
        -- Setup: create and track a table that we will subsequently drop.
        runPgSQL testEnvironment "CREATE TABLE analytics.dropped_table (id int PRIMARY KEY)"
        trackPgTable testEnvironment "analytics" "dropped_table"
        assertTypeVisible testEnvironment "analytics_dropped_table"
        -- Untrack, then issue the DROP via run_sql with the schema field.
        untrackPgTable testEnvironment "analytics" "dropped_table"
        runPgSQLWithSchema
          testEnvironment
          "analytics"
          "DROP TABLE IF EXISTS analytics.dropped_table"
        assertTypeAbsent testEnvironment "analytics_dropped_table"

    it "leaves the default schema untouched after partial rebuild of analytics" \testEnvironment -> do
      -- DDL in analytics must not disturb the default-schema fixture tables.
      runPgSQLWithSchema
        testEnvironment
        "analytics"
        "CREATE TABLE analytics.side_effect_check (id int PRIMARY KEY)"
      -- The fixture table "items" (in the default hasura schema) must still be visible.
      assertTypeVisible testEnvironment "hasura_items"
      -- Cleanup
      runPgSQL testEnvironment "DROP TABLE IF EXISTS analytics.side_effect_check"

    it "works correctly without the schema field (full-source fallback path)" \testEnvironment -> do
      -- Omitting the schema field triggers a full-source rebuild instead of a
      -- partial one.  The result must still be correct.
      runPgSQL testEnvironment "CREATE TABLE analytics.fallback_tbl (id int PRIMARY KEY)"
      trackPgTable testEnvironment "analytics" "fallback_tbl"
      assertTypeVisible testEnvironment "analytics_fallback_tbl"
      -- Cleanup
      untrackPgTable testEnvironment "analytics" "fallback_tbl"
      runPgSQL testEnvironment "DROP TABLE IF EXISTS analytics.fallback_tbl"

    it "does not reflect column additions when the wrong schema is specified (known limitation)" \testEnvironment -> do
      -- When DDL mutates a table in schema A but the schema field names schema B,
      -- only schema B is partially rebuilt.  Changes to schema A are therefore NOT
      -- reflected until schema A is rebuilt separately.  This is a known
      -- limitation: the schema field must match the schema where the DDL actually
      -- executes.
      --
      -- We add a column to the tracked "items" table in the hasura schema via
      -- run_sql but claim the schema is "analytics".  The hasura schema cache is
      -- not updated, so the new column must not appear in GraphQL.
      runPgSQLWithSchema
        testEnvironment
        "analytics" -- wrong schema for the ALTER TABLE below
        "ALTER TABLE hasura.items ADD COLUMN mismatch_col text"
      -- Introspect hasura_items: the cache should still show only the original
      -- "id" column because the hasura schema was not rebuilt.
      let expectedFields :: Value
          expectedFields =
            [yaml|
              data:
                __type:
                  fields:
                    - name: id
            |]
          actualFields :: IO Value
          actualFields =
            postGraphql
              testEnvironment
              [graphql|
                query {
                  __type(name: "hasura_items") {
                    fields { name }
                  }
                }
              |]
      shouldReturnYaml testEnvironment actualFields expectedFields
      -- Cleanup: drop the column directly via the backend connection so that no
      -- additional schema cache rebuild is triggered for this test's scope.
      Postgres.run_ testEnvironment "ALTER TABLE hasura.items DROP COLUMN IF EXISTS mismatch_col"

  describe "Cache consistency after multiple operations" do
    it "two successive partial rebuilds on different schemas both become visible" \testEnvironment -> do
      -- First partial rebuild: analytics schema.
      runPgSQLWithSchema
        testEnvironment
        "analytics"
        "CREATE TABLE analytics.multi_a (id int PRIMARY KEY)"
      trackPgTable testEnvironment "analytics" "multi_a"
      -- Second partial rebuild: a new ad-hoc reporting schema.
      runPgSQL testEnvironment "CREATE SCHEMA IF NOT EXISTS reporting"
      runPgSQLWithSchema
        testEnvironment
        "reporting"
        "CREATE TABLE reporting.multi_b (id int PRIMARY KEY)"
      trackPgTable testEnvironment "reporting" "multi_b"
      -- Both tables must be visible in GraphQL.
      assertTypeVisible testEnvironment "analytics_multi_a"
      assertTypeVisible testEnvironment "reporting_multi_b"
      -- The default-schema fixture tables must remain visible.
      assertTypeVisible testEnvironment "hasura_items"
      -- Cleanup
      untrackPgTable testEnvironment "analytics" "multi_a"
      untrackPgTable testEnvironment "reporting" "multi_b"
      runPgSQL testEnvironment "DROP TABLE IF EXISTS analytics.multi_a"
      runPgSQL testEnvironment "DROP TABLE IF EXISTS reporting.multi_b"
      runPgSQL testEnvironment "DROP SCHEMA IF EXISTS reporting"

    it "partial rebuild followed by reload_metadata leaves all schemas consistent" \testEnvironment -> do
      -- Start with a partial rebuild on analytics.
      runPgSQLWithSchema
        testEnvironment
        "analytics"
        "CREATE TABLE analytics.before_reload (id int PRIMARY KEY)"
      trackPgTable testEnvironment "analytics" "before_reload"
      assertTypeVisible testEnvironment "analytics_before_reload"
      -- A full reload_metadata must not disturb the cached state.
      reloadMetadata testEnvironment
      -- All schemas must remain consistent after the reload.
      assertTypeVisible testEnvironment "analytics_before_reload"
      assertTypeVisible testEnvironment "hasura_items"
      -- Cleanup
      untrackPgTable testEnvironment "analytics" "before_reload"
      runPgSQL testEnvironment "DROP TABLE IF EXISTS analytics.before_reload"
