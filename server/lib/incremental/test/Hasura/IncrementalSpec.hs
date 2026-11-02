{-# LANGUAGE Arrows #-}
-- new warning in 9.6 here mentions constraints not in this file...?:
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Hasura.IncrementalSpec (spec) where

import Control.Arrow.Extended
import Data.HashMap.Strict qualified as HashMap
import Data.HashSet qualified as S
import Hasura.Incremental qualified as Inc
import Hasura.Prelude
import Test.Hspec

-- | Rule used for keyed InvalidationKey memoisation tests.
-- Models a "schema block" keyed by schema name whose body re-runs only when
-- the schema's InvalidationKey changes.  The Writer log records which schema
-- names actually executed so tests can assert memoisation behaviour.
schemaRule ::
  (MonadWriter (S.HashSet String) m, MonadIO m) =>
  Inc.Rule m (HashMap.HashMap String Inc.InvalidationKey) (HashMap.HashMap String ())
schemaRule = proc schemas ->
  (|
    Inc.keyed
      ( \schemaName invKey -> do
          Inc.cache $
            arrM (\(name, _) -> tell (S.singleton name))
              -< (schemaName, invKey)
          returnA -< ()
      )
  |)
    schemas

spec :: Spec
spec = do
  describe "cache" $ do
    it "skips re-running rules if the input didn’t change" $ do
      let add1 :: (MonadState Integer m) => m ()
          add1 = modify' (+ 1)

          rule = proc (a, b) -> do
            Inc.cache $ arrM (\_ -> add1) -< a
            Inc.cache $ arrM (\_ -> add1 *> add1) -< b

      (result1, state1) <- runStateT (Inc.build rule (False, False)) 0
      state1 `shouldBe` 3
      (result2, state2) <- runStateT (Inc.rebuild result1 (True, False)) 0
      state2 `shouldBe` 1
      (_, state3) <- runStateT (Inc.rebuild result2 (True, True)) 0
      state3 `shouldBe` 2

    it "tracks dependencies within nested uses of cache across multiple executions" do
      let rule ::
            (MonadWriter String m, MonadIO m) =>
            Inc.Rule m (Inc.InvalidationKey, Inc.InvalidationKey) ()
          rule = proc (key1, key2) -> do
            dep1 <- Inc.newDependency -< key2
            (key1, dep1)
              >-
                Inc.cache
                  ( proc (_, dep2) ->
                      dep2
                        >-
                          Inc.cache
                            ( proc dep3 -> do
                                Inc.dependOn -< dep3
                                arrM tell -< "executed"
                            )
                  )
            returnA -< ()

      let key1 = Inc.initialInvalidationKey
          key2 = Inc.invalidate key1

      (result1, log1) <- runWriterT $ Inc.build rule (key1, key1)
      log1 `shouldBe` "executed"

      (result2, log2) <- runWriterT $ Inc.rebuild result1 (key2, key1)
      log2 `shouldBe` ""

      (_, log3) <- runWriterT $ Inc.rebuild result2 (key2, key2)
      log3 `shouldBe` "executed"

  describe "keyed" $ do
    it "preserves incrementalization when entries don’t change" $ do
      let rule ::
            (MonadWriter (S.HashSet (String, Integer)) m, MonadIO m) =>
            Inc.Rule m (HashMap.HashMap String Integer) (HashMap.HashMap String Integer)
          rule = proc m ->
            (|
              Inc.keyed
                ( \k v -> do
                    Inc.cache $ arrM (tell . S.singleton) -< (k, v)
                    returnA -< v * 2
                )
            |)
              m

      (result1, log1) <- runWriterT . Inc.build rule $ HashMap.fromList [("a", 1), ("b", 2)]
      Inc.result result1 `shouldBe` HashMap.fromList [("a", 2), ("b", 4)]
      log1 `shouldBe` S.fromList [("a", 1), ("b", 2)]
      (result2, log2) <- runWriterT . Inc.rebuild result1 $ HashMap.fromList [("a", 1), ("b", 3), ("c", 4)]
      Inc.result result2 `shouldBe` HashMap.fromList [("a", 2), ("b", 6), ("c", 8)]
      log2 `shouldBe` S.fromList [("b", 3), ("c", 4)]

  -- RFC §3 — Incremental Pipeline Tests: Inc.cache behaviour with InvalidationKey
  --
  -- These three tests mirror the 'buildTableCacheForSchema' pattern from
  -- Hasura.RQL.DDL.Schema.Cache: each schema block is wrapped in Inc.cache
  -- and keyed by schema name.  The InvalidationKey is the per-schema
  -- invalidation signal drawn from '_ikSourceSchemas'.
  describe "keyed InvalidationKey memoisation" $ do
    let key0 = Inc.initialInvalidationKey
        key1 = Inc.invalidate key0
        initialSchemas = HashMap.fromList [("schemaA", key0), ("schemaB", key0)]

    it "changing schema A's key does not re-run schema B's block" $ do
      (result1, _) <- runWriterT $ Inc.build schemaRule initialSchemas
      (_, log2) <-
        runWriterT $
          Inc.rebuild result1 (HashMap.fromList [("schemaA", key1), ("schemaB", key0)])
      S.member "schemaB" log2 `shouldBe` False

    it "changing schema A's key does re-run schema A's block" $ do
      (result1, _) <- runWriterT $ Inc.build schemaRule initialSchemas
      (_, log2) <-
        runWriterT $
          Inc.rebuild result1 (HashMap.fromList [("schemaA", key1), ("schemaB", key0)])
      S.member "schemaA" log2 `shouldBe` True

    it "full-source invalidation re-runs all schema blocks" $ do
      (result1, _) <- runWriterT $ Inc.build schemaRule initialSchemas
      (_, log2) <-
        runWriterT $
          Inc.rebuild result1 (HashMap.fromList [("schemaA", key1), ("schemaB", key1)])
      log2 `shouldBe` S.fromList ["schemaA", "schemaB"]
