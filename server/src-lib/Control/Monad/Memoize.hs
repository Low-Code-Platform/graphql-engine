{-# LANGUAGE UndecidableInstances #-}
-- ghc 9.6 seems to be doing something screwy with...
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Control.Monad.Memoize
  ( MonadMemoize (..),
    memoize,
    MemoizeT,
    runMemoizeT,

    -- * Persistent memoization (Phase 8)
    -- $persistent
    MemoCache (..),
    MemoTable,
    MemoEntry (..),
    DepGraph,
    emptyMemoCache,
    runMemoizeTWith,
    memoCacheNodeCount,
    memoCacheEdgeCount,

    -- * Eviction (Phase 8 Stage 2)
    MemoizationKey,
    memoKeyName,
    memoKeyArg,
    evictWith,
    EvictionStats (..),
  )
where

import Control.Monad.Except
import Data.Dependent.Map (DMap)
import Data.Dependent.Map qualified as DM
import Data.Functor.Identity
import Data.GADT.Compare.Extended
import Data.IORef
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.Kind qualified as K
import Data.Typeable qualified as Typeable
import Hasura.Prelude
import Language.Haskell.TH qualified as TH
import System.IO.Unsafe (unsafeInterleaveIO)
import Type.Reflection (Typeable, typeRep, (:~:) (Refl))

{- Note [Tying the knot]
~~~~~~~~~~~~~~~~~~~~~~~~
GraphQL type definitions can be mutually recursive, and indeed, they quite often
are! For example, two tables that reference one another will be represented by
types such as the following:

    type author {
      id: Int!
      name: String!
      articles: [article!]!
    }

    type article {
      id: Int!
      title: String!
      content: String!
      author: author!
    }

This doesn’t cause any trouble if the schema is represented by a mapping from
type names to type definitions, but the Parser abstraction is all about avoiding
that kind of indirection to improve type safety — parsers refer to their
sub-parsers directly. This presents two problems during schema generation:

  1. Schema generation needs to terminate in finite time, so we need to ensure
     we don’t try to eagerly construct an infinitely-large schema due to the
     mutually-recursive structure.

  2. To serve introspection queries, we do eventually need to construct a
     mapping from names to types (a TypeMap), so we need to be able to
     recursively walk the entire schema in finite time.

Solving point number 1 could be done with either laziness or sharing, but
neither of those are enough to solve point number 2, which requires /observable/
sharing. We need to construct a Parser graph that contains enough information to
detect cycles during traversal.

It may seem appealing to just use type names to detect cycles, which would allow
us to get away with using laziness rather than true sharing. Unfortunately, that
leads to two further problems:

  * It’s possible to end up with two different types with the same name, which
    is an error and should be reported as such. Using names to break cycles
    prevents us from doing that, since we have no way to check that two types
    with the same name are actually the same.

  * Some Parser constructors can fail — the `column` parser checks that the type
    name is a valid GraphQL name, for example. This extra validation means lazy
    schema construction isn’t viable, since we need to eagerly build the schema
    to ensure all the validation checks hold.

So we’re forced to use sharing. But how do we do it? Somehow, we have to /tie
the knot/ — we have to build a cyclic data structure — and some of the cycles
may be quite large. Doing all this knot-tying by hand would be incredibly
tricky, and it would require a lot of inversion of control to thread the shared
parsers around.

To avoid contorting the program, we instead implement a form of memoization. The
MonadMemoize class provides a mechanism to memoize a parser constructor function,
which allows us to get sharing mostly for free. The memoization strategy also
annotates cached parsers with a Unique that can be used to break cycles while
traversing the graph, so we get observable sharing as well. -}

class (Monad m) => MonadMemoize m where
  -- | Memoizes a parser constructor function for the extent of a single schema
  -- construction process. This is mostly useful for recursive parsers;
  -- see Note [Tying the knot] for more details.
  --
  -- The generality of the type here allows us to use this with multiple concrete
  -- parser types:
  --
  -- @
  -- 'memoizeOn' :: ('MonadMemoize' m, MonadParse n) => 'TH.Name' -> a -> m (Parser n b) -> m (Parser n b)
  -- 'memoizeOn' :: ('MonadMemoize' m, MonadParse n) => 'TH.Name' -> a -> m (FieldParser n b) -> m (FieldParser n b)
  -- @
  memoizeOn ::
    forall a p.
    (Ord a, Typeable a, Typeable p) =>
    -- | A unique name used to identify the function being memoized. There isn’t
    -- really any metaprogramming going on here, we just use a Template Haskell
    -- 'TH.Name' as a convenient source for a static, unique identifier.
    TH.Name ->
    -- | The value to use as the memoization key. It’s the caller’s
    -- responsibility to ensure multiple calls to the same function don’t use
    -- the same key.
    a ->
    m p ->
    m p

instance
  (MonadMemoize m) =>
  MonadMemoize (ReaderT a m)
  where
  memoizeOn name key = mapReaderT (memoizeOn name key)

-- | A wrapper around 'memoizeOn' that memoizes a function by using its argument
-- as the key.
memoize ::
  (MonadMemoize m, Ord a, Typeable a, Typeable p) =>
  TH.Name ->
  (a -> m p) ->
  (a -> m p)
memoize name f a = memoizeOn name a (f a)

-- $persistent
-- Historically 'runMemoizeT' seeded an /empty/ table on every call, so the entire
-- memoized parser graph was rebuilt from scratch on every schema-cache build even
-- though the overwhelming majority of it was unchanged. 'runMemoizeTWith' lets a
-- caller seed the table from a previous build and recover the resulting table, so
-- unchanged parsers can be reused. See @rfcs/phase8-persistent-memo-cache.md@.
--
-- Reuse is only sound if entries invalidated by a metadata change — and everything
-- transitively embedding them — are evicted first. 'DepGraph' records the edges
-- needed to compute that closure. Eviction itself is deliberately NOT implemented
-- here (Phase 8 Stage 2); this module only /records/ what a future evictor needs.

-- | An entry in the 'MemoTable': a memoized value tagged with a graph identity.
--
-- The identity exists so 'DepGraph' can be keyed by 'Int' rather than by
-- 'MemoizationKey'. That matters: a 'MemoizationKey' comparison walks a 'TH.Name'
-- (whose 'Ord' compares the package and module name as cons-list 'String's before
-- reaching the 'OccName'), and already accounts for ~16% of a schema build. Tagging
-- the entry means the single 'DM.lookup' that memoization performs anyway yields
-- both the value and its identity, so dependency recording adds *no* additional key
-- comparisons.
--
-- __The @~@ on the second field is load-bearing.__ This package enables
-- 'StrictData' (@graphql-engine.cabal@ default-extensions), which would otherwise
-- make @f t@ strict. 'memoizeOn' installs an 'unsafeInterleaveIO' placeholder in
-- this field /before/ building the real value (Note [Tying the knot]), and because
-- @f@ is instantiated to the 'Identity' /newtype/ — which has no runtime
-- representation — forcing the field is forcing the placeholder itself. That runs
-- 'readIORef' on a cell that is still 'Nothing' and dies with "parser was forced
-- before being fully constructed", breaking every mutually recursive parser.
--
-- The pre-Phase-8 code stored a bare 'Identity' and was immune by accident:
-- newtypes cannot have strict fields, so 'StrictData' never applied to it. Wrapping
-- the value in a @data@ constructor is what exposes it.
data MemoEntry f t = MemoEntry {-# UNPACK #-} !Int ~(f t)

-- | The memoized parser graph: values keyed by 'MemoizationKey'.
type MemoTable = DMap MemoizationKey (MemoEntry Identity)

-- | Reverse dependency edges over 'MemoEntry' identities: @child -> parents that
-- embed it@. Reverse (rather than forward) because the question eviction asks is
-- "who must be rebuilt if this changed?", answered by reachability from the changed
-- node. Cycles (mutually recursive types — see Note [Tying the knot]) are expected
-- and terminate normally under a visited-set traversal.
type DepGraph = IntMap.IntMap IntSet.IntSet

-- | A memo table plus the dependency graph describing it. Persist this across
-- schema-cache builds and hand it back to 'runMemoizeTWith'.
data MemoCache = MemoCache
  { mcTable :: !MemoTable,
    mcDeps :: !DepGraph,
    -- | Identity counter; kept so ids stay unique across seeded builds.
    mcNextId :: !Int
  }

emptyMemoCache :: MemoCache
emptyMemoCache = MemoCache mempty mempty 0

-- | Number of memoized nodes retained.
memoCacheNodeCount :: MemoCache -> Int
memoCacheNodeCount = DM.size . mcTable

-- | Number of recorded dependency edges.
memoCacheEdgeCount :: MemoCache -> Int
memoCacheEdgeCount = sum . map IntSet.size . IntMap.elems . mcDeps

-- | Internal state threaded through a memoization pass.
data MemoState = MemoState
  { msTable :: !MemoTable,
    msNextId :: !Int,
    -- | Stack of nodes currently under construction; the head is the node whose
    -- builder is running, i.e. the parent of anything requested right now.
    msParents :: [Int],
    msDeps :: !DepGraph
  }

newtype MemoizeT m a = MemoizeT
  { unMemoizeT :: StateT MemoState m a
  }
  deriving (Functor, Applicative, Monad, MonadError e, MonadReader r, MonadTrans)

-- | Allow code in 'MemoizeT' to have access to any underlying state capabilities,
-- hiding the fact that 'MemoizeT' itself is a state monad.
instance (MonadState s m) => MonadState s (MemoizeT m) where
  get = lift get
  put = lift . put

-- | Run a memoization pass with a cold table, discarding the result. Equivalent to
-- @fmap fst . 'runMemoizeTWith' 'emptyMemoCache'@.
runMemoizeT :: forall m a. (Monad m) => MemoizeT m a -> m a
runMemoizeT = fmap fst . runMemoizeTWith emptyMemoCache

-- | Run a memoization pass seeded from a previous 'MemoCache', returning the cache
-- produced by this pass.
--
-- __Seeded entries are reused verbatim.__ Callers are responsible for evicting
-- anything a metadata change invalidated (together with its transitive dependents)
-- /before/ seeding; passing a stale entry here silently yields a stale parser, and
-- reusing a node whose type was also rebuilt elsewhere mints two Uniques for one
-- GraphQL type ("conflicting definitions"). Pass 'emptyMemoCache' when in doubt —
-- that is exactly today's behaviour.
--
-- A rebuilt node is allocated a /fresh/ identity, so edges recorded against its old
-- identity linger in 'mcDeps'. Stale edges can only cause over-eviction (safe, just
-- slower), never under-eviction — but they do accumulate, so the Stage 2 evictor
-- must drop graph entries for identities no longer present in 'mcTable'.
runMemoizeTWith :: forall m a. (Monad m) => MemoCache -> MemoizeT m a -> m (a, MemoCache)
runMemoizeTWith cache action = do
  (a, st) <- runStateT (unMemoizeT action) (seedState cache)
  pure (a, harvest st)
  where
    seedState MemoCache {..} =
      MemoState {msTable = mcTable, msNextId = mcNextId, msParents = [], msDeps = mcDeps}
    harvest MemoState {..} =
      MemoCache {mcTable = msTable, mcDeps = msDeps, mcNextId = msNextId}

-- | The 'TH.Name' a key was memoized under. Together with 'memoKeyArg' this is
-- everything an evictor can observe about a key.
memoKeyName :: MemoizationKey t -> TH.Name
memoKeyName (MemoizationKey n _) = n

-- | View a key's memoization argument at a given type, or 'Nothing' if it has some
-- other type.
--
-- The argument is existential (it carries only @Ord@ + @Typeable@), so it cannot be
-- returned directly — a caller that knows which shapes it cares about casts to each
-- in turn. Callers MUST treat a 'Nothing' from every shape they know as
-- /unclassifiable/ and evict, never as /unaffected/; see 'evictWith'.
memoKeyArg :: forall a t. (Typeable a) => MemoizationKey t -> Maybe a
memoKeyArg (MemoizationKey _ arg) = Typeable.cast arg

data EvictionStats = EvictionStats
  { -- | Nodes the predicate matched outright.
    esDirect :: !Int,
    -- | Nodes evicted in total, i.e. direct plus transitive dependents.
    esEvicted :: !Int,
    -- | Nodes retained for reuse.
    esSurvived :: !Int
  }
  deriving stock (Eq, Show)

-- | Drop every node the predicate matches, plus every node that transitively
-- embeds one, and prune the dependency graph to match.
--
-- __The predicate must be conservative.__ Returning 'False' asserts "this node is
-- provably unaffected by the change" and causes it to be reused verbatim. If a key
-- cannot be classified — an argument shape the caller does not recognise — the
-- predicate must return 'True'. Over-eviction merely costs a rebuild;
-- under-eviction silently serves a stale schema, and (where a type is rebuilt
-- elsewhere but reused here) mints two Uniques for one GraphQL type.
--
-- Reachability is over reversed edges, so it answers "who must be rebuilt because
-- this changed?". Cycles from mutually recursive types are expected and terminate
-- via the visited set.
evictWith :: (forall t. MemoizationKey t -> Bool) -> MemoCache -> (MemoCache, EvictionStats)
evictWith invalidated MemoCache {..} = (cache', stats)
  where
    direct :: IntSet.IntSet
    direct =
      DM.foldrWithKey
        (\k (MemoEntry nodeId _) acc -> if invalidated k then IntSet.insert nodeId acc else acc)
        IntSet.empty
        mcTable

    evicted :: IntSet.IntSet
    evicted = reachable direct

    -- Reverse-BFS over mcDeps (child -> parents).
    reachable :: IntSet.IntSet -> IntSet.IntSet
    reachable = go IntSet.empty
      where
        go seen frontier
          | IntSet.null frontier = seen
          | otherwise =
              let seen' = seen <> frontier
                  parents =
                    IntSet.unions
                      $ map (\n -> IntMap.findWithDefault IntSet.empty n mcDeps)
                      $ IntSet.toList frontier
               in go seen' (parents IntSet.\\ seen')

    cache' =
      MemoCache
        { mcTable = DM.filterWithKey (\_ (MemoEntry nodeId _) -> not (nodeId `IntSet.member` evicted)) mcTable,
          -- Drop edges *keyed* on an evicted node, and drop evicted nodes from the
          -- surviving parent sets, so dead ids cannot accumulate across builds.
          mcDeps =
            IntMap.mapMaybe
              (\parents -> let kept = parents IntSet.\\ evicted in if IntSet.null kept then Nothing else Just kept)
              (IntMap.withoutKeys mcDeps evicted),
          -- Never reuse ids: a rebuilt node must not collide with a stale edge.
          mcNextId = mcNextId
        }

    stats =
      EvictionStats
        { esDirect = IntSet.size direct,
          esEvicted = IntSet.size evicted,
          esSurvived = DM.size mcTable - IntSet.size evicted
        }

-- | Record that the node currently being built embeds @child@. A no-op at the top
-- level, where there is no parent.
--
-- Fires on cache /hits/ as well as misses: a hit still means the parent depends on
-- the child, and omitting that edge would leave the graph incomplete — which is the
-- one thing eviction correctness rests on.
recordEdge :: (Monad m) => Int -> StateT MemoState m ()
recordEdge child = modify' \s ->
  case msParents s of
    [] -> s
    parent : _ -> s {msDeps = IntMap.insertWith IntSet.union child (IntSet.singleton parent) (msDeps s)}

-- | see Note [MemoizeT requires MonadIO]
instance
  (MonadIO m) =>
  MonadMemoize (MemoizeT m)
  where
  memoizeOn name key buildParser = MemoizeT do
    let parserId = MemoizationKey name key
    parsersById <- gets msTable
    case DM.lookup parserId parsersById of
      Just (MemoEntry nodeId (Identity parser)) -> do
        recordEdge nodeId
        pure parser
      Nothing -> do
        -- We manually do eager blackholing here using a MutVar rather than
        -- relying on MonadFix and ordinary thunk blackholing. Why? A few
        -- reasons:
        --
        --   1. We have more control. We aren’t at the whims of whatever
        --      MonadFix instance happens to get used.
        --
        --   2. We can be more precise. GHC’s lazy blackholing doesn’t always
        --      kick in when you’d expect.
        --
        --   3. We can provide more useful error reporting if things go wrong.
        --      Most usefully, we can include a HasCallStack source location.
        cell <- liftIO $ newIORef Nothing

        -- We use unsafeInterleaveIO here, which sounds scary, but
        -- unsafeInterleaveIO is actually far more safe than unsafePerformIO.
        -- unsafeInterleaveIO just defers the execution of the action until its
        -- result is needed, adding some laziness.
        --
        -- That laziness can be dangerous if the action has side-effects, since
        -- the point at which the effect is performed can be unpredictable. But
        -- this action just reads, never writes, so that isn’t a concern.
        parserById <-
          liftIO
            $ unsafeInterleaveIO
            $ readIORef cell
            >>= \case
              Just parser -> pure $ Identity parser
              Nothing ->
                error
                  $ unlines
                    [ "memoize: parser was forced before being fully constructed",
                      "  parser constructor: " ++ TH.pprint name
                    ]
        -- Allocate this node's graph identity, then install the placeholder under it.
        nodeId <- state \s -> (msNextId s, s {msNextId = msNextId s + 1})
        modify' \s -> s {msTable = DM.insert parserId (MemoEntry nodeId parserById) (msTable s)}

        -- Edge from the *enclosing* node to this one; must be recorded before this
        -- node becomes the parent below.
        recordEdge nodeId

        -- Make this node the parent for the duration of its builder, then restore.
        -- Restoring the saved stack (rather than popping) keeps the invariant even
        -- if a builder leaves extra frames behind. A 'QErr' thrown from a builder
        -- aborts the whole schema build and this state is discarded, so no unwinding
        -- is needed.
        enclosing <- gets msParents
        modify' \s -> s {msParents = nodeId : enclosing}
        parser <- unMemoizeT buildParser
        modify' \s -> s {msParents = enclosing}

        liftIO $ writeIORef cell (Just parser)
        pure parser

{- Note [MemoizeT requires MonadIO]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The MonadMemoize instance for MemoizeT requires MonadIO, which is unsatisfying.
The only reason the constraint is needed is to implement knot-tying via IORefs
(see Note [Tying the knot] above), which really only requires the power of
ST. Alternatively, it might be possible to use the ST monad instead, but that
has not been done for historical reasons.
-}

-- | A key used to distinguish calls to 'memoize'd functions. The 'TH.Name'
-- distinguishes calls to completely different parsers, and the @a@ value
-- records the arguments.
data MemoizationKey (t :: K.Type) where
  MemoizationKey :: (Ord a, Typeable a, Typeable p) => TH.Name -> a -> MemoizationKey p

instance GEq MemoizationKey where
  geq
    (MemoizationKey name1 (arg1 :: a1) :: MemoizationKey t1)
    (MemoizationKey name2 (arg2 :: a2) :: MemoizationKey t2)
      | name1 == name2,
        Just Refl <- typeRep @a1 `geq` typeRep @a2,
        arg1 == arg2,
        Just Refl <- typeRep @t1 `geq` typeRep @t2 =
          Just Refl
      | otherwise = Nothing

instance GCompare MemoizationKey where
  gcompare
    (MemoizationKey name1 (arg1 :: a1) :: MemoizationKey t1)
    (MemoizationKey name2 (arg2 :: a2) :: MemoizationKey t2) =
      strengthenOrdering (compare name1 name2)
        `extendGOrdering` gcompare (typeRep @a1) (typeRep @a2)
        `extendGOrdering` strengthenOrdering (compare arg1 arg2)
        `extendGOrdering` gcompare (typeRep @t1) (typeRep @t2)
        `extendGOrdering` GEQ
