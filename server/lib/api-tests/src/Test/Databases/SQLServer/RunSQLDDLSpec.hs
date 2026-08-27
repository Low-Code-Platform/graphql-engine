{-# LANGUAGE QuasiQuotes #-}

-- | DDL issued through @mssql_run_sql@ against SQL Server: creating, altering,
-- renaming and dropping both tables and views, each followed by an assertion
-- that the GraphQL schema reflects the change.
--
-- These are the SQL Server counterpart to the Postgres coverage in
-- "Test.Schema.PartialSchemaCacheRebuildSpec" and "Test.Schema.ViewsSpec": they
-- catch stale-schema-cache bugs, where DDL succeeds at the database level but
-- the GraphQL schema keeps serving the pre-DDL shape.
--
-- Assertions deliberately use real data queries rather than @__type@
-- introspection: introspection resolves against a single (source, schema) pair,
-- whereas data queries route by root-field name, so a query is the more direct
-- evidence that a field is genuinely usable.
module Test.Databases.SQLServer.RunSQLDDLSpec (spec) where

import Data.Aeson (Value)
import Data.List.NonEmpty qualified as NE
import Harness.Backend.Sqlserver qualified as Sqlserver
import Harness.GraphqlEngine (postGraphql, postMetadata_, postV2Query_)
import Harness.Quoter.Graphql (graphql)
import Harness.Quoter.Yaml (yaml)
import Harness.Schema (Table (..), table)
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
        [ (Fixture.fixture $ Fixture.Backend Sqlserver.backendTypeMetadata)
            { Fixture.setupTeardown = \(testEnvironment, _) ->
                [Sqlserver.setupTablesAction schema testEnvironment]
            }
        ]
    )
    tests

--------------------------------------------------------------------------------
-- Schema

-- | A tracked table that no test modifies. Every test asserts it is still
-- queryable afterwards, so a rebuild that drops unrelated tables is caught.
schema :: [Schema.Table]
schema =
  [ (table "author")
      { tableColumns =
          [ Schema.column "id" Schema.TInt,
            Schema.column "name" Schema.TStr
          ],
        tablePrimaryKey = ["id"],
        tableData =
          [ [Schema.VInt 1, Schema.VStr "Alice"],
            [Schema.VInt 2, Schema.VStr "Bob"]
          ]
      }
  ]

--------------------------------------------------------------------------------
-- Helpers

-- | Run arbitrary SQL against the SQL Server source through the @v2/query@ API,
-- which is what triggers the metadata check and schema cache rebuild.
runSQL :: TestEnvironment -> String -> IO ()
runSQL testEnvironment sql =
  postV2Query_ testEnvironment
    [yaml|
      type: mssql_run_sql
      args:
        source: mssql
        sql: *sql
    |]

trackTable :: TestEnvironment -> String -> IO ()
trackTable testEnvironment tableName =
  postMetadata_ testEnvironment
    [yaml|
      type: mssql_track_table
      args:
        source: mssql
        table:
          schema: hasura
          name: *tableName
    |]

untrackTable :: TestEnvironment -> String -> IO ()
untrackTable testEnvironment tableName =
  postMetadata_ testEnvironment
    [yaml|
      type: mssql_untrack_table
      args:
        source: mssql
        table:
          schema: hasura
          name: *tableName
    |]

-- | Assert the fixture table is still queryable, i.e. the rebuild triggered by
-- the DDL under test did not disturb unrelated tables.
assertFixtureIntact :: TestEnvironment -> IO ()
assertFixtureIntact testEnvironment =
  shouldReturnYaml
    testEnvironment
    ( postGraphql
        testEnvironment
        [graphql|
          query {
            hasura_author(where: { id: { _eq: 1 } }) {
              id
              name
            }
          }
        |]
    )
    [yaml|
      data:
        hasura_author:
        - id: 1
          name: Alice
    |]

--------------------------------------------------------------------------------
-- Tests

tests :: SpecWith TestEnvironment
tests = do
  describe "Tables" do
    it "exposes a table created by run_sql once it is tracked" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_items (id int NOT NULL PRIMARY KEY, name nvarchar(50) NOT NULL)"
      runSQL testEnvironment "INSERT INTO hasura.ddl_items (id, name) VALUES (1, 'widget')"
      trackTable testEnvironment "ddl_items"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_items {
                  id
                  name
                }
              }
            |]
        )
        [yaml|
          data:
            hasura_ddl_items:
            - id: 1
              name: widget
        |]

      assertFixtureIntact testEnvironment

      untrackTable testEnvironment "ddl_items"
      runSQL testEnvironment "DROP TABLE hasura.ddl_items"

    it "exposes a column added by ALTER TABLE" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_altered (id int NOT NULL PRIMARY KEY)"
      runSQL testEnvironment "INSERT INTO hasura.ddl_altered (id) VALUES (1)"
      trackTable testEnvironment "ddl_altered"

      runSQL testEnvironment "ALTER TABLE hasura.ddl_altered ADD note nvarchar(50) NULL"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_altered {
                  id
                  note
                }
              }
            |]
        )
        [yaml|
          data:
            hasura_ddl_altered:
            - id: 1
              note: null
        |]

      untrackTable testEnvironment "ddl_altered"
      runSQL testEnvironment "DROP TABLE hasura.ddl_altered"

    it "removes a column dropped by ALTER TABLE" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_dropped_col (id int NOT NULL PRIMARY KEY, note nvarchar(50) NULL)"
      trackTable testEnvironment "ddl_dropped_col"

      runSQL testEnvironment "ALTER TABLE hasura.ddl_dropped_col DROP COLUMN note"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_dropped_col {
                  note
                }
              }
            |]
        )
        [yaml|
          errors:
          - extensions:
              path: $.selectionSet.hasura_ddl_dropped_col.selectionSet.note
              code: validation-failed
            message: |-
              field 'note' not found in type: 'hasura_ddl_dropped_col'
        |]

      untrackTable testEnvironment "ddl_dropped_col"
      runSQL testEnvironment "DROP TABLE hasura.ddl_dropped_col"

    it "follows a table renamed by sp_rename" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_before_rename (id int NOT NULL PRIMARY KEY)"
      runSQL testEnvironment "INSERT INTO hasura.ddl_before_rename (id) VALUES (1)"
      trackTable testEnvironment "ddl_before_rename"

      runSQL testEnvironment "EXEC sp_rename 'hasura.ddl_before_rename', 'ddl_after_rename'"

      -- The metadata follows the rename, so the old root field is gone...
      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_before_rename {
                  id
                }
              }
            |]
        )
        [yaml|
          errors:
          - extensions:
              path: $
              code: validation-failed
            message: |-
              root field hasura_ddl_before_rename is not part of any GraphQL schema
        |]

      -- ...and the table is queryable under its new name without re-tracking.
      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_after_rename {
                  id
                }
              }
            |]
        )
        [yaml|
          data:
            hasura_ddl_after_rename:
            - id: 1
        |]

      untrackTable testEnvironment "ddl_after_rename"
      runSQL testEnvironment "DROP TABLE hasura.ddl_after_rename"

    it "removes the root field of a dropped table" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_doomed (id int NOT NULL PRIMARY KEY)"
      trackTable testEnvironment "ddl_doomed"

      -- Dropping a tracked table untracks it as part of the metadata check.
      runSQL testEnvironment "DROP TABLE hasura.ddl_doomed"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_doomed {
                  id
                }
              }
            |]
        )
        [yaml|
          errors:
          - extensions:
              path: $
              code: validation-failed
            message: |-
              root field hasura_ddl_doomed is not part of any GraphQL schema
        |]

      assertFixtureIntact testEnvironment

  describe "Views" do
    it "exposes a view created by run_sql once it is tracked" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_view_base (id int NOT NULL PRIMARY KEY, qty int NOT NULL)"
      runSQL testEnvironment "INSERT INTO hasura.ddl_view_base (id, qty) VALUES (1, 3), (2, 7)"
      runSQL testEnvironment "CREATE VIEW hasura.ddl_view AS SELECT id, qty FROM hasura.ddl_view_base WHERE qty > 5"
      trackTable testEnvironment "ddl_view"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_view {
                  id
                  qty
                }
              }
            |]
        )
        [yaml|
          data:
            hasura_ddl_view:
            - id: 2
              qty: 7
        |]

      untrackTable testEnvironment "ddl_view"
      runSQL testEnvironment "DROP VIEW hasura.ddl_view"
      runSQL testEnvironment "DROP TABLE hasura.ddl_view_base"

    it "aggregates over a view" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_agg_base (id int NOT NULL PRIMARY KEY, qty int NOT NULL)"
      runSQL testEnvironment "INSERT INTO hasura.ddl_agg_base (id, qty) VALUES (1, 3), (2, 7), (3, 11)"
      runSQL testEnvironment "CREATE VIEW hasura.ddl_agg_view AS SELECT id, qty FROM hasura.ddl_agg_base WHERE qty > 5"
      trackTable testEnvironment "ddl_agg_view"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_agg_view_aggregate {
                  aggregate {
                    count
                    sum {
                      qty
                    }
                  }
                }
              }
            |]
        )
        [yaml|
          data:
            hasura_ddl_agg_view_aggregate:
              aggregate:
                count: 2
                sum:
                  qty: 18
        |]

      untrackTable testEnvironment "ddl_agg_view"
      runSQL testEnvironment "DROP VIEW hasura.ddl_agg_view"
      runSQL testEnvironment "DROP TABLE hasura.ddl_agg_base"

    it "exposes a column added by ALTER VIEW" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_altered_view_base (id int NOT NULL PRIMARY KEY, qty int NOT NULL)"
      runSQL testEnvironment "INSERT INTO hasura.ddl_altered_view_base (id, qty) VALUES (1, 7)"
      runSQL testEnvironment "CREATE VIEW hasura.ddl_altered_view AS SELECT id, qty FROM hasura.ddl_altered_view_base"
      trackTable testEnvironment "ddl_altered_view"

      runSQL testEnvironment "ALTER VIEW hasura.ddl_altered_view AS SELECT id, qty, qty * 2 AS double_qty FROM hasura.ddl_altered_view_base"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_altered_view {
                  id
                  qty
                  double_qty
                }
              }
            |]
        )
        [yaml|
          data:
            hasura_ddl_altered_view:
            - id: 1
              qty: 7
              double_qty: 14
        |]

      untrackTable testEnvironment "ddl_altered_view"
      runSQL testEnvironment "DROP VIEW hasura.ddl_altered_view"
      runSQL testEnvironment "DROP TABLE hasura.ddl_altered_view_base"

    it "keeps a tracked view working across ALTER TABLE on its base table" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_stable_base (id int NOT NULL PRIMARY KEY, qty int NOT NULL)"
      runSQL testEnvironment "INSERT INTO hasura.ddl_stable_base (id, qty) VALUES (1, 7)"
      runSQL testEnvironment "CREATE VIEW hasura.ddl_stable_view AS SELECT id, qty FROM hasura.ddl_stable_base"
      trackTable testEnvironment "ddl_stable_view"

      -- Adding then dropping a base-table column rebuilds the schema twice; the
      -- view's own columns are untouched by both and must survive.
      runSQL testEnvironment "ALTER TABLE hasura.ddl_stable_base ADD note nvarchar(50) NULL"
      runSQL testEnvironment "ALTER TABLE hasura.ddl_stable_base DROP COLUMN note"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_stable_view {
                  id
                  qty
                }
              }
            |]
        )
        [yaml|
          data:
            hasura_ddl_stable_view:
            - id: 1
              qty: 7
        |]

      assertFixtureIntact testEnvironment

      untrackTable testEnvironment "ddl_stable_view"
      runSQL testEnvironment "DROP VIEW hasura.ddl_stable_view"
      runSQL testEnvironment "DROP TABLE hasura.ddl_stable_base"

    it "removes the root field of a dropped view" \testEnvironment -> do
      runSQL testEnvironment "CREATE TABLE hasura.ddl_doomed_view_base (id int NOT NULL PRIMARY KEY)"
      runSQL testEnvironment "CREATE VIEW hasura.ddl_doomed_view AS SELECT id FROM hasura.ddl_doomed_view_base"
      trackTable testEnvironment "ddl_doomed_view"

      runSQL testEnvironment "DROP VIEW hasura.ddl_doomed_view"

      shouldReturnYaml
        testEnvironment
        ( postGraphql
            testEnvironment
            [graphql|
              query {
                hasura_ddl_doomed_view {
                  id
                }
              }
            |]
        )
        [yaml|
          errors:
          - extensions:
              path: $
              code: validation-failed
            message: |-
              root field hasura_ddl_doomed_view is not part of any GraphQL schema
        |]

      runSQL testEnvironment "DROP TABLE hasura.ddl_doomed_view_base"
