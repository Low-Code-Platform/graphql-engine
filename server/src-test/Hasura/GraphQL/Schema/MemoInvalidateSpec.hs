{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

-- | Tests for the Phase 8 memo-key classifier.
--
-- These pin down which memo key shapes are evicted by a table change and which are
-- reused. Getting this wrong in the "reuse" direction serves a stale GraphQL
-- schema, so the classification is asserted shape by shape rather than inferred
-- from an end-to-end build.
module Hasura.GraphQL.Schema.MemoInvalidateSpec (spec) where

import Control.Monad.Memoize
import Data.HashSet qualified as HS
import Data.Text.NonEmpty (mkNonEmptyTextUnsafe)
-- brings the Backend ('Postgres 'Vanilla) instance into scope, without which the
-- TableName/ScalarType type families do not reduce
import Hasura.Backends.Postgres.Instances.Schema ()
import Hasura.Backends.Postgres.SQL.Types (PGScalarType (..), QualifiedObject (..), SchemaName (..), TableName (..))
import Hasura.GraphQL.Schema.MemoInvalidate (evictTables)
import Hasura.Prelude
import Hasura.RQL.Types.BackendType (BackendType (..), PostgresKind (..))
import Hasura.RQL.Types.Column (ColumnType (..))
import Hasura.RQL.Types.Common (SourceName (..))
import Language.GraphQL.Draft.Syntax qualified as G
import Test.Hspec

type PG = 'Postgres 'Vanilla

src :: SourceName
src = SNDefault

otherSrc :: SourceName
otherSrc = SNName $ mkNonEmptyTextUnsafe "other"

tbl :: Text -> QualifiedObject TableName
tbl t = QualifiedObject (SchemaName "public") (TableName t)

-- | Build a cache containing one node per memo-key shape we care about, so the
-- classifier can be exercised against all of them at once.
--
-- Every node is a top-level request (no parent), so there are no edges and each
-- eviction decision is attributable to the classifier alone rather than to
-- transitive reachability.
buildAllShapes :: MemoizeT IO ()
buildAllShapes = do
  -- class 1: names a table
  void $ memoizeOn 'buildAllShapes (src, tbl "users") (pure (1 :: Int))
  void $ memoizeOn 'buildAllShapes (src, tbl "posts") (pure (2 :: Int))
  void $ memoizeOn 'buildAllShapes (src, tbl "users", G.unsafeMkName "select_users") (pure (3 :: Int))
  -- a table with the same name in a *different* source must not be touched
  void $ memoizeOn 'buildAllShapes (otherSrc, tbl "users") (pure (4 :: Int))
  -- class 2: embeds its content (self-invalidating)
  void $ memoizeOn 'buildAllShapes (PGInteger, G.Nullability True) (pure (5 :: Int))
  void $ memoizeOn 'buildAllShapes (ColumnScalar @PG PGText) (pure (6 :: Int))
  -- class 3: unclassifiable
  void $ memoizeOn 'buildAllShapes (G.unsafeMkName "some_logical_model") (pure (7 :: Int))

evictUsers :: MemoCache -> (MemoCache, EvictionStats)
-- no GQL-identifier-keyed nodes in this fixture, so the changed-identifier set is empty
evictUsers = evictTables @PG src (HS.singleton (tbl "users")) HS.empty

spec :: Spec
spec = describe "memo key classification" do
  it "evicts only the changed table's nodes, and the unclassifiable ones" do
    (_, cache) <- runMemoizeTWith emptyMemoCache buildAllShapes
    memoCacheNodeCount cache `shouldBe` 7
    let (_, stats) = evictUsers cache
    -- (src, users) + (src, users, select_users) + the unclassifiable G.Name node
    esDirect stats `shouldBe` 3
    esEvicted stats `shouldBe` 3
    -- (src, posts), (otherSrc, users), and both content-keyed nodes survive
    esSurvived stats `shouldBe` 4

  it "reuses content-keyed nodes, which is what makes the win possible" do
    -- columnParser/comparisonExps are shared by every table; if a table change
    -- evicted them, reverse reachability would take the whole schema with them.
    (_, cache) <- runMemoizeTWith emptyMemoCache buildAllShapes
    let (cache', _) = evictUsers cache
        contentOnly = do
          void $ memoizeOn 'buildAllShapes (PGInteger, G.Nullability True) (error "columnParser was rebuilt: content-keyed node must be reused" :: MemoizeT IO Int)
          void $ memoizeOn 'buildAllShapes (ColumnScalar @PG PGText) (error "comparisonExps was rebuilt: content-keyed node must be reused" :: MemoizeT IO Int)
    -- the `error` builders must never run: these nodes must come from the cache
    (_, _) <- runMemoizeTWith cache' contentOnly
    pure ()

  it "does not evict a same-named table in a different source" do
    (_, cache) <- runMemoizeTWith emptyMemoCache buildAllShapes
    let (cache', _) = evictUsers cache
        otherSourceNode = void $ memoizeOn 'buildAllShapes (otherSrc, tbl "users") (error "other source was rebuilt: only the named source may be evicted" :: MemoizeT IO Int)
    (_, _) <- runMemoizeTWith cache' otherSourceNode
    pure ()

  it "evicts nothing when the changed set is empty" do
    (_, cache) <- runMemoizeTWith emptyMemoCache buildAllShapes
    let (_, stats) = evictTables @PG src HS.empty HS.empty cache
    -- only the unclassifiable node goes; every table-keyed node is retained
    esDirect stats `shouldBe` 1
    esSurvived stats `shouldBe` 6
