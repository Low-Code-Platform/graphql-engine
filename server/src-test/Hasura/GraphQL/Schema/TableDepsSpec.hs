{-# LANGUAGE DataKinds #-}

-- | Tests for Phase 9's table-level invalidation.
--
-- Under-invalidation here means reusing a table's parsers after a table it embeds
-- changed — i.e. silently serving a stale schema. So the direction of the graph
-- and the reachability closure are asserted explicitly rather than inferred from
-- an end-to-end build.
module Hasura.GraphQL.Schema.TableDepsSpec (spec) where

import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as HS
import Data.Text.NonEmpty (mkNonEmptyTextUnsafe)
import Hasura.Backends.Postgres.Instances.Schema ()
import Hasura.Backends.Postgres.SQL.Types (QualifiedTable, TableName (..))
import Hasura.GraphQL.Schema.TableDeps (invalidatedTables, tableDependencyGraph)
import Hasura.Prelude
import Hasura.RQL.Types.BackendType (BackendType (..), PostgresKind (..))
import Hasura.RQL.Types.Common (InsertOrder (..), RelName (..), RelType (..))
import Hasura.RQL.Types.Relationships.Local (RelInfo (..), RelMapping (..), RelTarget (..))
import Hasura.Table.Cache (TableCache, TableCoreInfoG (_tciName), TableInfo (_tiCoreInfo))
import Test.Hspec
import Test.Parser.Internal (TableInfoBuilder (relations), buildTableInfo, mkTable, tableInfoBuilder)

type PG = 'Postgres 'Vanilla

relTo :: Text -> QualifiedTable -> RelInfo PG
relTo name target =
  RelInfo
    { riName = RelName (mkNonEmptyTextUnsafe name),
      riType = ArrRel,
      riMapping = RelMapping mempty,
      riTarget = RelTargetTable target,
      riIsManual = False,
      riInsertOrder = AfterParent
    }

tbl :: Text -> QualifiedTable
tbl = mkTable

-- | @tableWith "album" ["track"]@ : album has a relationship to track, so album's
-- parsers embed track's.
tableWith :: Text -> [Text] -> TableInfo PG
tableWith name targets =
  buildTableInfo (tableInfoBuilder (tbl name)) {relations = [relTo ("to_" <> t) (tbl t) | t <- targets]}

mkCache :: [TableInfo PG] -> TableCache PG
mkCache tis = HashMap.fromList [(_tciName (_tiCoreInfo ti), ti) | ti <- tis]

spec :: Spec
spec = describe "table dependency invalidation" do
  describe "tableDependencyGraph" do
    it "records an edge from the embedder to the embedded" do
      let graph = tableDependencyGraph @PG (mkCache [tableWith "album" ["track"], tableWith "track" []])
      HashMap.lookup (tbl "album") graph `shouldBe` Just (HS.singleton (tbl "track"))
      HashMap.lookup (tbl "track") graph `shouldBe` Just HS.empty

  describe "invalidatedTables" do
    it "always includes the changed table itself" do
      let graph = tableDependencyGraph @PG (mkCache [tableWith "album" ["track"], tableWith "track" []])
      invalidatedTables @PG graph (HS.singleton (tbl "track")) `shouldBe` HS.fromList [tbl "track", tbl "album"]

    it "propagates against the edge: changing track rebuilds album, not vice versa" do
      -- This is the whole point. album embeds track, so a change to track
      -- invalidates album. A change to album must NOT invalidate track.
      let graph = tableDependencyGraph @PG (mkCache [tableWith "album" ["track"], tableWith "track" []])
      invalidatedTables @PG graph (HS.singleton (tbl "album")) `shouldBe` HS.singleton (tbl "album")

    it "is transitive across a chain" do
      -- a -> b -> c : changing c must rebuild b and a
      let graph =
            tableDependencyGraph @PG
              (mkCache [tableWith "a" ["b"], tableWith "b" ["c"], tableWith "c" []])
      invalidatedTables @PG graph (HS.singleton (tbl "c")) `shouldBe` HS.fromList [tbl "a", tbl "b", tbl "c"]
      invalidatedTables @PG graph (HS.singleton (tbl "b")) `shouldBe` HS.fromList [tbl "a", tbl "b"]

    it "terminates on a cycle and takes the whole component" do
      let graph = tableDependencyGraph @PG (mkCache [tableWith "a" ["b"], tableWith "b" ["a"]])
      invalidatedTables @PG graph (HS.singleton (tbl "a")) `shouldBe` HS.fromList [tbl "a", tbl "b"]

    it "leaves unrelated tables alone — this is where the win comes from" do
      let graph =
            tableDependencyGraph @PG
              (mkCache [tableWith "album" ["track"], tableWith "track" [], tableWith "unrelated" []])
      invalidatedTables @PG graph (HS.singleton (tbl "track"))
        `shouldSatisfy` not
        . HS.member (tbl "unrelated")

    it "evicts nothing when nothing changed" do
      let graph = tableDependencyGraph @PG (mkCache [tableWith "album" ["track"], tableWith "track" []])
      invalidatedTables @PG graph HS.empty `shouldBe` HS.empty
