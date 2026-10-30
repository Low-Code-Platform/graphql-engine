# CLAUDE.md

## Pull Requests

When creating pull requests, always read `.github/PULL_REQUEST_TEMPLATE.md`
first and use it as the basis for the PR body. Make sure to fill in the correct
checkboxes and put your changelog entry in the appropriate spot. This is used
for release automation so the structure needs to stay intact.

## Building and typechecking

For any haskell code changes use `cabal build all --enable-tests --enable-benchmarks` 
to check your work and iterate until it builds cleanly.

Fix warnings, don't leave them. CI compiles with `-Werror` (see `cabal.project`),
and several packages set it themselves (`schema-parsers`, `test-harness`,
`upgrade-tests`, `resource-pool`), so an unused import left behind after a
refactor is a build failure even when it only warns locally.

A clean build is not evidence that the engine works. It is routine for the
engine to compile and then fail to boot, so verify behaviour as well as types:
`server/CONTRIBUTING.md` has the unit and integration suite commands, and
`server/lib/api-tests/README.md` covers api-tests (note the harness spawns its
own engine from `$GRAPHQL_ENGINE` rather than using one you already have
running). When a change alters runtime behaviour, exercise it against a live
engine too.

## Experimental features

Behaviour changes that are risky, opt-in, or only valuable to some deployments
go behind a constructor of `ExperimentalFeature`
(`server/src-lib/Hasura/Server/Types.hs`), **defaulting to off**, with its
metadata key added to `experimentalFeatureKey`. There are 13 of these; follow
the existing pattern rather than changing behaviour unconditionally.

Document on the constructor what it does and why it is not the default -- that
comment is where the next reader looks. If the GraphQL schema depends on the
flag, thread it through `SchemaOptions`
(`server/src-lib/Hasura/RQL/Types/Schema/Options.hs`) as its own option type and
set it in `buildSchemaOptions`, rather than reading the feature set directly
from schema-building code; `soPostgresArrays` and `soOrderedJsonInput` are
worked examples.
