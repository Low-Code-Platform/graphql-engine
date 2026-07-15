{-# LANGUAGE DataKinds #-}

-- | Tests for Phase 9's per-table field cache.
--
-- The reuse assertions use @error@ builders rather than hit counters: a wrongly
-- rebuilt table fails loudly instead of moving a number nobody reads. The
-- invalidation assertions do the opposite — they assert the builder DOES run,
-- because a missed rebuild is the silent stale-schema bug.
module Hasura.GraphQL.Schema.TableFieldCacheSpec (spec) where

import Data.Aeson (Value, toJSON)
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text.NonEmpty (mkNonEmptyTextUnsafe)
import Hasura.Authentication.Role (adminRoleName)
import Hasura.Backends.Postgres.Instances.Schema ()
import Hasura.Backends.Postgres.SQL.Types (QualifiedTable, SchemaName (..))
import Hasura.GraphQL.Schema.TableFieldCache
import Hasura.Prelude
import Hasura.RQL.Types.BackendType (BackendType (..), PostgresKind (..))
import Hasura.RQL.Types.Common (SourceName (..))
import Test.Hspec
import Test.Parser.Internal (mkTable)

type PG = 'Postgres 'Vanilla

pairKey :: PairKey
pairKey = (SNDefault, SchemaName "public", adminRoleName)

tbl :: Text -> QualifiedTable
tbl = mkTable

-- album embeds track; unrelated embeds nothing
depGraph :: HashMap QualifiedTable (HashSet QualifiedTable)
depGraph =
  HashMap.fromList
    [ (tbl "album", HS.singleton (tbl "track")),
      (tbl "track", HS.empty),
      (tbl "unrelated", HS.empty)
    ]

fingerprints :: [(Text, Int)] -> HashMap QualifiedTable Value
fingerprints xs = HashMap.fromList [(tbl name, toJSON v) | (name, v) <- xs]

-- | v1: everything at version 1.
v1 :: HashMap QualifiedTable Value
v1 = fingerprints [("album", 1), ("track", 1), ("unrelated", 1)]

-- | track bumped to 2; album and unrelated untouched.
trackChanged :: HashMap QualifiedTable Value
trackChanged = fingerprints [("album", 1), ("track", 2), ("unrelated", 1)]

spec :: Spec
spec = describe "per-table field cache" do
  it "cold: every table is changed, nothing retained" do
    store <- newTableFieldStore
    stats <- prepareForBuild @PG store pairKey depGraph v1
    tfsTables stats `shouldBe` 3
    tfsChanged stats `shouldBe` 3 -- no stored fingerprints yet
    tfsInvalidated stats `shouldBe` 3
    tfsRetained stats `shouldBe` 0

  it "second build with no change retains every entry and runs no builder" do
    store <- newTableFieldStore
    _ <- prepareForBuild @PG store pairKey depGraph v1
    for_ ["album", "track", "unrelated"] \t ->
      withTableFields @Int @PG store pairKey "query" (tbl t) (pure 1)
    stats <- prepareForBuild @PG store pairKey depGraph v1
    tfsChanged stats `shouldBe` 0
    tfsRetained stats `shouldBe` 3
    -- these must all come from the cache
    for_ ["album", "track", "unrelated"] \t ->
      withTableFields @Int @PG store pairKey "query" (tbl t) (error ("rebuilt " <> show t))
        `shouldReturn` 1

  it "a changed table invalidates itself AND its embedder, but not unrelated tables" do
    store <- newTableFieldStore
    _ <- prepareForBuild @PG store pairKey depGraph v1
    for_ ["album", "track", "unrelated"] \t ->
      withTableFields @Int @PG store pairKey "query" (tbl t) (pure 1)

    stats <- prepareForBuild @PG store pairKey depGraph trackChanged
    tfsChanged stats `shouldBe` 1 -- track
    tfsInvalidated stats `shouldBe` 2 -- track + album (which embeds it)
    tfsRetained stats `shouldBe` 1 -- unrelated

    -- unrelated must be reused: this is where the win comes from
    withTableFields @Int @PG store pairKey "query" (tbl "unrelated") (error "unrelated rebuilt")
      `shouldReturn` 1
    -- track and album must both rebuild; reusing album would serve track's OLD
    -- definition, which is the whole reason the dependency graph exists
    withTableFields @Int @PG store pairKey "query" (tbl "track") (pure 2) `shouldReturn` 2
    withTableFields @Int @PG store pairKey "query" (tbl "album") (pure 2) `shouldReturn` 2

  it "slots are independent: a query entry is not served to a mutation" do
    store <- newTableFieldStore
    _ <- prepareForBuild @PG store pairKey depGraph v1
    _ <- withTableFields @Int @PG store pairKey "query" (tbl "track") (pure 1)
    -- different slot, same table: must miss
    withTableFields @Int @PG store pairKey "mutation" (tbl "track") (pure 99) `shouldReturn` 99

  it "a type mismatch is a miss, not a wrong answer" do
    store <- newTableFieldStore
    _ <- prepareForBuild @PG store pairKey depGraph v1
    _ <- withTableFields @Int @PG store pairKey "query" (tbl "track") (pure 1)
    -- same slot+table, different type: fromDynamic fails => rebuild
    withTableFields @Text @PG store pairKey "query" (tbl "track") (pure "rebuilt")
      `shouldReturn` "rebuilt"

  it "counts builder runs across a realistic edit cycle" do
    runs <- newIORef (0 :: Int)
    store <- newTableFieldStore
    let build t = withTableFields @Int @PG store pairKey "query" (tbl t) do
          modifyIORef' runs (+ 1)
          pure 1
        buildAll = for_ ["album", "track", "unrelated"] build

    _ <- prepareForBuild @PG store pairKey depGraph v1
    buildAll
    readIORef runs `shouldReturn` 3 -- cold

    _ <- prepareForBuild @PG store pairKey depGraph trackChanged
    buildAll
    -- only track + album; unrelated reused
    readIORef runs `shouldReturn` 5
