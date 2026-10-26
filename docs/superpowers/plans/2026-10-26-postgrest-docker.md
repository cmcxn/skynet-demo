# PostgREST Docker integration plan

Goal: install the existing configurable client in the runtime image and document independent self-hosted and CloudBase operation.

- [x] Install upstream Lua sources, adapter, tests and license; allow only the needed build context.
- [x] Keep optional explicit source paths, add normal package-path lookup so packaged business uses client.new().
- [x] Add opt-in Compose overlays: persistent self-hosted database/API, or external CloudBase config. Keep the base demo independent.
- [x] Add no-bind-mount packaged test mode and run the same eight cases against self-hosted and CloudBase targets.
- [x] Write Chinese usage docs in parallel, verify commands and config separation, sync CodeGraph.

Authorized approach: same DB_REST_URL / DB_REST_TOKEN / DB_TIMEOUT_TICKS; credentials remain runtime-only. Do not publish database/API ports or change cloud table permissions. Self-hosted setup provisions only the existing test table and an internal demo role; production authentication is a separate concern.
