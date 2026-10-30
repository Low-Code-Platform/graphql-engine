-- | This module defines all functions that convert between different
-- representations of values in the schema; most commonly: GraphQL literals,
-- JSON values, and 'InputValue', a type that provides an abstraction above both
-- of those.
module Hasura.GraphQL.Parser.Internal.Convert
  ( jsonToGraphQL,
    valueToJSON,
    valueToOrderedJSON,
    graphQLToJSON,
    graphQLToOrderedJSON,
  )
where

import Data.Aeson qualified as J
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Ordered qualified as JO
import Data.Bifunctor (bimap)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Scientific (toBoundedInteger)
import Data.Traversable (for)
import Data.Vector qualified as V
import Data.Void (Void, absurd)
import Hasura.Base.ErrorMessage
import Hasura.Base.ToErrorValue
import Hasura.GraphQL.Parser.Class
import Hasura.GraphQL.Parser.Internal.TypeChecking
import Hasura.GraphQL.Parser.Variable
import Language.GraphQL.Draft.Syntax qualified as G

-- Disable custom prelude warnings in preparation for extracting this module into a separate package.
{-# ANN module ("HLint: ignore Use onNothing" :: String) #-}

-- | Convert an input value to aeson, as every scalar parser but Postgres @json@
-- does. Defined via 'valueToOrderedJSON' so there is only one conversion to keep
-- correct; 'JO.fromOrdered' then re-imposes aeson's own (alphabetical) key order,
-- making this exactly as order-lossy as it has always been.
valueToJSON :: (MonadParse m) => G.GType -> InputValue Variable -> m J.Value
valueToJSON expectedType = fmap JO.fromOrdered . valueToOrderedJSON expectedType

-- | As 'valueToJSON', but retains the key order carried by variable values.
--
-- Only the Postgres @json@ column parser uses this. Note that the order is
-- faithful for values supplied as /variables/; inline object literals have
-- already lost theirs upstream in the GraphQL parser AST (see
-- 'graphQLToOrderedJSON').
valueToOrderedJSON :: (MonadParse m) => G.GType -> InputValue Variable -> m JO.Value
valueToOrderedJSON expectedType inputVal = do
  peeledVal <- peelVariable expectedType inputVal
  pure $ valueToOrderedJSON' peeledVal
  where
    valueToOrderedJSON' :: InputValue Variable -> JO.Value
    valueToOrderedJSON' = \case
      JSONValue j -> j
      GraphQLValue g -> graphQLToOrderedJSON g

graphQLToJSON :: G.Value Variable -> J.Value
graphQLToJSON = JO.fromOrdered . graphQLToOrderedJSON

graphQLToOrderedJSON :: G.Value Variable -> JO.Value
graphQLToOrderedJSON = \case
  G.VNull -> JO.Null
  G.VInt i -> JO.Number $ fromInteger i
  G.VFloat f -> JO.Number f
  G.VString t -> JO.String t
  G.VBoolean b -> JO.Bool b
  G.VEnum (G.EnumValue n) -> JO.String $ G.unName n
  G.VList values -> JO.array $ graphQLToOrderedJSON <$> values
  -- An inline object literal is a 'HashMap' by the time it reaches us, so its
  -- source order is already gone. Emit the keys sorted, which is what aeson's
  -- @KeyMap@ did with them before — an arbitrary hash order here would be a
  -- behaviour change, and a non-deterministic one.
  G.VObject objects ->
    JO.object
      $ sortOn fst
      $ map (bimap G.unName graphQLToOrderedJSON)
      $ HashMap.toList objects
  G.VVariable variable -> case vValue variable of
    -- TODO: Absent values can be encoded as nulls, but this arguably breaks GraphQL spec June 2018, section 2.9.5.
    Nothing -> JO.Null
    Just (JSONValue j) -> j
    Just (GraphQLValue g) -> graphQLToOrderedJSON (absurd <$> g)

jsonToGraphQL :: J.Value -> Either ErrorMessage (G.Value Void)
jsonToGraphQL = \case
  J.Null -> Right G.VNull
  J.Bool val -> Right $ G.VBoolean val
  J.String val -> Right $ G.VString val
  J.Number val -> case toBoundedInteger val of
    Just intVal -> Right $ G.VInt $ fromIntegral @Int64 intVal
    Nothing -> Right $ G.VFloat val
  J.Array vals -> G.VList <$> traverse jsonToGraphQL (V.toList vals)
  J.Object vals ->
    G.VObject . HashMap.fromList <$> for (KM.toList vals) \(key, val) -> do
      graphQLName <- maybe (invalidName key) Right $ G.mkName (K.toText key)
      (graphQLName,) <$> jsonToGraphQL val
  where
    invalidName key =
      Left $ "variable value contains an object with key " <> toErrorValue key <> ", which is not a legal GraphQL name"
