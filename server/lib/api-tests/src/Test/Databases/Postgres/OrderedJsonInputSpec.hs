{-# LANGUAGE QuasiQuotes #-}

-- |
-- Tests that the @ordered_json_input@ experimental feature preserves the key
-- order a client sent when writing to a Postgres @json@ column.
--
-- Two things are being distinguished throughout, and they are easy to conflate:
--
--   * @jsonb@ is a decomposed binary format. Postgres re-sorts its keys (by
--     length, then bytewise) and drops duplicates no matter what we send, so
--     nothing upstream can preserve order for it. The @jsonb@ cases here are
--     controls asserting that normalization still happens.
--
--   * @json@ stores the document verbatim, so the only thing that reordered its
--     keys was the engine. That is what this feature changes.
--
-- Assertions are made against the stored text via @run_sql@ rather than through
-- a GraphQL read, because the YAML comparison helpers parse both sides into
-- aeson values, and that comparison cannot see key order at all.
--
-- See @rfcs/ordered-json-input.md@.
module Test.Databases.Postgres.OrderedJsonInputSpec (spec) where

import Data.Aeson (Value)
import Data.ByteString.Lazy.Char8 qualified as Char8
import Data.Text qualified as T
import Data.List.NonEmpty qualified as NE
import Harness.Backend.Postgres qualified as Postgres
import Harness.GraphqlEngine (postGraphqlRaw, postV2Query)
import Harness.Quoter.Yaml (yaml)
import Harness.Schema qualified as Schema
import Harness.Test.Fixture qualified as Fixture
import Harness.TestEnvironment (GlobalTestEnvironment, TestEnvironment)
import Harness.Yaml (shouldReturnYaml)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it)

spec :: SpecWith GlobalTestEnvironment
spec = do
  Fixture.hgeWithEnv [("HASURA_GRAPHQL_EXPERIMENTAL_FEATURES", "ordered_json_input")]
    $ Fixture.run (NE.fromList [postgresFixture]) orderPreservedTests

  -- The same mutations with the feature off: the historical alphabetical
  -- behaviour must be exactly what it always was.
  Fixture.run (NE.fromList [postgresFixture]) orderSortedTests
  where
    postgresFixture =
      (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
        { Fixture.setupTeardown = \(testEnv, _) ->
            [ Postgres.setupTablesAction schema testEnv
            ]
        }

--------------------------------------------------------------------------------
-- Schema

jsonType :: Schema.ScalarType
jsonType =
  Schema.TCustomType
    $ Schema.defaultBackendScalarType {Schema.bstPostgres = Just "JSON"}

jsonbType :: Schema.ScalarType
jsonbType =
  Schema.TCustomType
    $ Schema.defaultBackendScalarType {Schema.bstPostgres = Just "JSONB"}

schema :: [Schema.Table]
schema =
  [ (Schema.table "payloads")
      { Schema.tableColumns =
          [ Schema.column "id" Schema.defaultSerialType,
            Schema.column "doc" jsonType,
            Schema.column "docb" jsonbType
          ],
        Schema.tablePrimaryKey = ["id"]
      }
  ]

--------------------------------------------------------------------------------
-- Helpers

-- | A deliberately out-of-order document. Sorted alphabetically this is
-- @aardvark, apple, b, zebra@; sorted the way @jsonb@ does it (length first)
-- it is @b, apple, zebra, aardvark@. All three orders are distinct, so whichever
-- one comes back identifies which code path ran.
outOfOrderDoc :: Text
outOfOrderDoc = "{\"zebra\":1,\"apple\":2,\"b\":3,\"aardvark\":4}"

-- | Insert via a GraphQL mutation, sending the body as raw bytes so the key
-- order survives the client.
insertRaw :: TestEnvironment -> Int -> Text -> Text -> IO Value
insertRaw testEnvironment rowId doc docb =
  postGraphqlRaw testEnvironment
    $ Char8.pack
    $ T.unpack
    $ "{\"query\":\"mutation ($d: json!, $db: jsonb!) { insert_hasura_payloads(objects: [{id: "
    <> tshow rowId
    <> ", doc: $d, docb: $db}]) { affected_rows } }\","
    <> "\"variables\":{\"d\":"
    <> doc
    <> ",\"db\":"
    <> docb
    <> "}}"

-- | Read the stored column back as text, which is the only way to observe key
-- order: anything that parses the value loses it. @run_sql@ returns every
-- column as a string already.
storedText :: TestEnvironment -> Int -> IO Value
storedText testEnvironment rowId =
  postV2Query 200 testEnvironment
    [yaml|
      type: pg_run_sql
      args:
        source: postgres
        sql: *sqlText
        cascade: false
        read_only: true
    |]
  where
    sqlText :: String
    sqlText =
      "SELECT doc::text, docb::text FROM hasura.payloads WHERE id = "
        <> show rowId

--------------------------------------------------------------------------------
-- Tests

orderPreservedTests :: SpecWith TestEnvironment
orderPreservedTests = describe "with ordered_json_input enabled" do
  it "preserves variable key order in a json column, and normalizes jsonb" \testEnvironment -> do
    _ <- insertRaw testEnvironment 1 outOfOrderDoc outOfOrderDoc

    shouldReturnYaml
      testEnvironment
      (storedText testEnvironment 1)
      [yaml|
        result_type: TuplesOk
        result:
          - - doc
            - docb
          - - '{"zebra":1,"apple":2,"b":3,"aardvark":4}'
            - '{"b": 3, "apple": 2, "zebra": 1, "aardvark": 4}'
      |]

  it "preserves key order in nested objects" \testEnvironment -> do
    _ <-
      insertRaw
        testEnvironment
        2
        "{\"outer\":{\"zebra\":1,\"apple\":2},\"list\":[{\"z\":1,\"a\":2}]}"
        "{}"

    shouldReturnYaml
      testEnvironment
      (storedText testEnvironment 2)
      [yaml|
        result_type: TuplesOk
        result:
          - - doc
            - docb
          - - '{"outer":{"zebra":1,"apple":2},"list":[{"z":1,"a":2}]}'
            - '{}'
      |]

  it "still sorts an inline literal, which loses its order in the GraphQL AST" \testEnvironment -> do
    -- Documented limitation, not an accident: 'G.VObject' is a HashMap, so an
    -- inline object literal has no order left to preserve by the time any of
    -- this code runs. Asserting it keeps the boundary honest.
    _ <-
      postGraphqlRaw testEnvironment
        $ Char8.pack
        $ T.unpack
          ( "{\"query\":\"mutation { insert_hasura_payloads(objects: [{id: 3, "
              <> "doc: {zebra: 1, apple: 2, b: 3, aardvark: 4}, docb: {}}]) { affected_rows } }\"}" ::
              Text
          )

    shouldReturnYaml
      testEnvironment
      (storedText testEnvironment 3)
      [yaml|
        result_type: TuplesOk
        result:
          - - doc
            - docb
          - - '{"aardvark":4,"apple":2,"b":3,"zebra":1}'
            - '{}'
      |]

orderSortedTests :: SpecWith TestEnvironment
orderSortedTests = describe "with ordered_json_input disabled (default)" do
  it "sorts json column keys alphabetically, as it always has" \testEnvironment -> do
    _ <- insertRaw testEnvironment 1 outOfOrderDoc outOfOrderDoc

    shouldReturnYaml
      testEnvironment
      (storedText testEnvironment 1)
      [yaml|
        result_type: TuplesOk
        result:
          - - doc
            - docb
          - - '{"aardvark":4,"apple":2,"b":3,"zebra":1}'
            - '{"b": 3, "apple": 2, "zebra": 1, "aardvark": 4}'
      |]
