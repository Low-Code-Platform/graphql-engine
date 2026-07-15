{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Control.Monad.MemoizeSpec (spec) where

import Control.Monad.MemoizationSpecDefinition
import Control.Monad.Memoize
import Hasura.Prelude
import Test.Hspec

-- We need to add a couple of extra parameters, 'k' and 'v', to align with the
-- shape of a memoizer as understood by 'Memoizer'.
newtype MemoizeWithExtraParamsT k v m a = MemoizeWithExtraParamsT {unMemoizeWithExtraParamsT :: MemoizeT m a}
  deriving newtype (Functor, Applicative, Monad, MonadTrans)

instance Memoizer MemoizeWithExtraParamsT where
  runMemoizer = runMemoizeT . unMemoizeWithExtraParamsT
  memoize name key = MemoizeWithExtraParamsT . memoizeOn name key . unMemoizeWithExtraParamsT

deriving newtype instance (MonadState s m) => MonadState s (MemoizeWithExtraParamsT k v m)

spec :: Spec
spec = do
  memoizationSpec @MemoizeWithExtraParamsT
  persistentCacheSpec

--------------------------------------------------------------------------------
-- Phase 8: persistent memoization (rfcs/phase8-persistent-memo-cache.md)

-- | @root@ embeds @leaf@; each builder bumps a counter in the base monad so we can
-- observe exactly which ones re-ran.
buildRootAndLeaf :: MemoizeT (StateT Int IO) Int
buildRootAndLeaf =
  let leaf = memoizeOn 'buildRootAndLeaf ("leaf" :: String) do
        modify' (+ 1)
        pure (1 :: Int)
      root = memoizeOn 'buildRootAndLeaf ("root" :: String) do
        modify' (+ 1)
        l <- leaf
        pure (l + 1)
   in root

-- | Returns @((value, cache), buildersRun)@.
runCounted :: MemoCache -> MemoizeT (StateT Int IO) a -> IO ((a, MemoCache), Int)
runCounted cache action = runStateT (runMemoizeTWith cache action) 0

persistentCacheSpec :: Spec
persistentCacheSpec = describe "persistent memo cache" do
  it "cold run builds every node and records the dependency edge" do
    ((value, cache), buildersRun) <- runCounted emptyMemoCache buildRootAndLeaf
    value `shouldBe` 2
    buildersRun `shouldBe` 2
    memoCacheNodeCount cache `shouldBe` 2
    -- exactly one edge: leaf's parent is root
    memoCacheEdgeCount cache `shouldBe` 1

  it "seeding from a previous cache reuses everything and rebuilds nothing" do
    ((_, cache), _) <- runCounted emptyMemoCache buildRootAndLeaf
    ((value, cache'), buildersRun) <- runCounted cache buildRootAndLeaf
    value `shouldBe` 2
    -- the whole point of Phase 8: a seeded build does no work
    buildersRun `shouldBe` 0
    memoCacheNodeCount cache' `shouldBe` 2

  it "runMemoizeT is exactly a cold runMemoizeTWith" do
    (viaRunMemoizeT, countA) <- runStateT (runMemoizeT buildRootAndLeaf) 0
    ((viaRunWith, _), countB) <- runCounted emptyMemoCache buildRootAndLeaf
    viaRunMemoizeT `shouldBe` viaRunWith
    countA `shouldBe` countB

  it "records edges through a cycle without diverging" do
    -- a -> b -> a. Both nodes must appear, and the back-edge must be recorded even
    -- though it resolves via the knot-tying placeholder rather than a fresh build.
    let cyclic :: MemoizeT (StateT Int IO) Int
        cyclic =
          let a = memoizeOn 'persistentCacheSpec ("a" :: String) (b >> pure (1 :: Int))
              b = memoizeOn 'persistentCacheSpec ("b" :: String) (a >> pure (2 :: Int))
           in a
    ((_, cache), _) <- runCounted emptyMemoCache cyclic
    memoCacheNodeCount cache `shouldBe` 2
    -- a->b and b->a (the latter hits the in-progress placeholder, and recordEdge
    -- must still fire on that hit or the graph would be incomplete)
    memoCacheEdgeCount cache `shouldBe` 2

  evictionSpec

--------------------------------------------------------------------------------
-- Phase 8 Stage 2: eviction

-- | Does this key's argument equal the given String key?
keyIs :: String -> MemoizationKey t -> Bool
keyIs name k = memoKeyArg @String k == Just name

evictionSpec :: Spec
evictionSpec = describe "eviction" do
  it "evicts a leaf and rebuilds only it" do
    ((_, cache), _) <- runCounted emptyMemoCache buildRootAndLeaf
    let (cache', stats) = evictWith (keyIs "leaf") cache
    -- leaf is directly hit; root embeds leaf so it must go too
    esDirect stats `shouldBe` 1
    esEvicted stats `shouldBe` 2
    esSurvived stats `shouldBe` 0
    -- reseeding rebuilds exactly the evicted pair
    ((value, _), buildersRun) <- runCounted cache' buildRootAndLeaf
    value `shouldBe` 2
    buildersRun `shouldBe` 2

  it "evicting the root leaves the leaf reusable" do
    ((_, cache), _) <- runCounted emptyMemoCache buildRootAndLeaf
    let (cache', stats) = evictWith (keyIs "root") cache
    -- nothing embeds root, so the blast radius is just root
    esDirect stats `shouldBe` 1
    esEvicted stats `shouldBe` 1
    esSurvived stats `shouldBe` 1
    ((value, _), buildersRun) <- runCounted cache' buildRootAndLeaf
    value `shouldBe` 2
    -- only root re-ran; leaf was reused
    buildersRun `shouldBe` 1

  it "evicts nothing when the predicate matches nothing" do
    ((_, cache), _) <- runCounted emptyMemoCache buildRootAndLeaf
    let (cache', stats) = evictWith (const False) cache
    esEvicted stats `shouldBe` 0
    esSurvived stats `shouldBe` 2
    ((_, _), buildersRun) <- runCounted cache' buildRootAndLeaf
    buildersRun `shouldBe` 0

  it "a conservative predicate (const True) degrades to a cold build" do
    ((_, cache), _) <- runCounted emptyMemoCache buildRootAndLeaf
    let (cache', stats) = evictWith (const True) cache
    esEvicted stats `shouldBe` 2
    esSurvived stats `shouldBe` 0
    ((value, _), buildersRun) <- runCounted cache' buildRootAndLeaf
    value `shouldBe` 2
    buildersRun `shouldBe` 2

  it "terminates on a cycle and evicts the whole strongly-connected component" do
    let cyclic :: MemoizeT (StateT Int IO) Int
        cyclic =
          let a = memoizeOn 'evictionSpec ("a" :: String) (b >> pure (1 :: Int))
              b = memoizeOn 'evictionSpec ("b" :: String) (a >> pure (2 :: Int))
           in a
    ((_, cache), _) <- runCounted emptyMemoCache cyclic
    let (_, stats) = evictWith (keyIs "a") cache
    -- b embeds a, and a embeds b: reachability must terminate, not diverge
    esDirect stats `shouldBe` 1
    esEvicted stats `shouldBe` 2
    esSurvived stats `shouldBe` 0

  it "does not reuse node ids after eviction" do
    ((_, cache), _) <- runCounted emptyMemoCache buildRootAndLeaf
    let (cache', _) = evictWith (const True) cache
    ((_, cache''), _) <- runCounted cache' buildRootAndLeaf
    -- ids keep climbing, so stale edges can never alias a rebuilt node
    memoCacheNodeCount cache'' `shouldBe` 2
    memoCacheEdgeCount cache'' `shouldBe` 1

  it "prunes dangling edges for evicted nodes" do
    ((_, cache), _) <- runCounted emptyMemoCache buildRootAndLeaf
    memoCacheEdgeCount cache `shouldBe` 1
    let (cache', _) = evictWith (const True) cache
    -- the only edge pointed at an evicted node; it must not survive
    memoCacheEdgeCount cache' `shouldBe` 0
    memoCacheNodeCount cache' `shouldBe` 0
