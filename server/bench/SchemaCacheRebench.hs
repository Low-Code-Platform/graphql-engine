-- | Black-box HTTP benchmark comparing full vs partial schema cache rebuild.
--
-- Fixture: 1 Postgres source, 5 schemas (s1–s5) × 200 tracked tables = 1 000 total.
-- Apply server/bench/fixtures/schema_cache_bench_setup.sql and run
-- server/bench/fixtures/track_tables.sh before starting this benchmark.
--
-- Environment variables:
--   HASURA_URL           default: http://localhost:8181
--   HASURA_ADMIN_SECRET  default: (empty)
module Main (main) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Char8 qualified as BC
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    defaultManagerSettings,
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
  )
import Network.HTTP.Types.Header (hContentType)
import System.Environment (lookupEnv)
import Test.Tasty.Bench (bench, bgroup, defaultMain, whnfIO)
import Prelude

-- ---------------------------------------------------------------------------
-- HTTP helper

data BenchEnv = BenchEnv
  { beManager :: Manager,
    beUrl :: String,
    beSecret :: String
  }

-- | POST a JSON payload to /v2/query and force the full response body.
postV2Query :: BenchEnv -> Value -> IO ()
postV2Query BenchEnv {..} payload = do
  req0 <- parseRequest (beUrl <> "/v2/query")
  let req =
        req0
          { method = "POST",
            requestBody = RequestBodyLBS (encode payload),
            requestHeaders =
              [ (hContentType, "application/json"),
                ("X-Hasura-Admin-Secret", BC.pack beSecret)
              ]
          }
  _ <- httpLbs req beManager
  pure ()

-- ---------------------------------------------------------------------------
-- Payloads
--
-- Both payloads run the same idempotent DDL: COMMENT ON TABLE matches the
-- \bcomment on\b branch in isSchemaCacheBuildRequiredRunSQL, so Hasura always
-- fires withMetadataCheck and the schema cache rebuild code path is exercised.
--
-- The only difference is the presence/absence of the "schema" field:
--   - absent  → buildSchemaCacheWithInvalidations {ciSources = {default}}
--               → full source rebuild (all 1 000 tables)
--   - present → buildSchemaCacheForDbSchema default s1
--               → partial rebuild (200 tables in s1 only)

-- | No "schema" field — triggers a full-source rebuild (1 000 tables).
fullRebuildPayload :: Value
fullRebuildPayload =
  object
    [ "type" .= ("pg_run_sql" :: String),
      "args"
        .= object
          [ "source" .= ("default" :: String),
            "sql" .= ("COMMENT ON TABLE s1.tbl_1 IS 'bench_full'" :: String),
            "cascade" .= False,
            "read_only" .= False
          ]
    ]

-- | "schema":"s1" — triggers a partial rebuild (200 tables in s1 only).
partialRebuildPayload :: Value
partialRebuildPayload =
  object
    [ "type" .= ("pg_run_sql" :: String),
      "args"
        .= object
          [ "source" .= ("default" :: String),
            "sql" .= ("COMMENT ON TABLE s1.tbl_1 IS 'bench_partial'" :: String),
            "schema" .= ("s1" :: String),
            "cascade" .= False,
            "read_only" .= False
          ]
    ]

-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  baseUrl <- maybe "http://localhost:8181" id <$> lookupEnv "HASURA_URL"
  secret <- maybe "" id <$> lookupEnv "HASURA_ADMIN_SECRET"
  mgr <- newManager defaultManagerSettings
  let env = BenchEnv mgr baseUrl secret
  defaultMain
    [ bgroup
        "schema-cache-rebuild (1 source, 5 schemas × 200 tables = 1000 total)"
        [ bench "full rebuild   (1000 tables, no schema field)" $
            whnfIO (postV2Query env fullRebuildPayload),
          bench "partial rebuild (200 tables, schema=s1)" $
            whnfIO (postV2Query env partialRebuildPayload)
        ]
    ]
