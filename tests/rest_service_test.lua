--- Acceptance suite for the TypeScript REST service archetype (Fastify v5 + pnpm + Vitest).
--- Renders the project, verifies the layout and template substitution, installs it, runs its own
--- Vitest suite, then boots the real service and proves the REST endpoint and the management sidecar
--- (health probes + Prometheus metrics) answer over the wire.
---
--- The default configuration weaves in no resources (persistence/cache/messaging = None): plain
--- HTTP (Fastify) with a management sidecar on a second port, and no database containers. The
--- persistence variants (PostgreSQL/MySQL) each render with a real database container, boot the
--- service against it, and prove REST CRUD calls round-trip into that database. This suite defines
--- the archetype's acceptance bar — its job is to fill the gaps and keep them filled.
---
--- The static tier reads renders with no toolchain; the build and live tiers require `pnpm`
--- (which drives Node) and the CRUD tiers additionally `docker`; each skips cleanly without them.
---
--- Run from the archetype repo root (uses ./prova.toml):   prova

local postgres = require("postgres")
local mysql    = require("mysql")

local SRC = "."

local ANSWERS = {
  author_name    = "Test Author",
  author_email   = "test@example.com",
  org_name       = "acme",
  solution_name  = "platform",
  prefix_name    = "Example",
  suffix_name    = "Service",
  image_registry = "ghcr.io/acme",
}

local function answers_with(extra)
  local out = {}
  for k, v in pairs(ANSWERS) do out[k] = v end
  for k, v in pairs(extra) do out[k] = v end
  return out
end

-- `pnpm install` is idempotent, and on some node builds (e.g. nix nodejs 24 on macOS) pnpm
-- crashes in libuv at process exit (kqueue.c EINTR assert) *after* the install has completed.
-- Retry once: the second run is a fast no-op that confirms success; a genuine install failure
-- fails both attempts.
local PNPM_INSTALL = "pnpm install || pnpm install"

-- prefix Example / suffix Service => project dir `example-service` (project-name), used as the
-- package name and the platform manifest identity. The scaffold CRUD lives at the platform
-- standard base path: versioned, name-derived, kebab-case, naive plural (S2).
local PROJECT_DIR = "example-service"
local BASE = "/api/v1/examples"

local EXPECTED_FILES = {
  "package.json",
  "tsconfig.json",
  "vitest.config.ts",
  "pnpm-workspace.yaml",
  ".npmrc",
  "src/index.ts",
  "src/app.ts",
  "src/logging.ts",
  "src/management.ts",
  "src/otel.ts",
  "src/settings.ts",
  "tests/health.test.ts",
  ".dockerignore",
  ".github/workflows/build.yaml",
  ".platform/docker/local/Dockerfile",
  ".platform/docker/prd/Dockerfile",
}

-- Files the persistence scaffold must produce (relative to the rendered project root) —
-- and that the hollow (None) rendering must NOT.
local SCAFFOLD_FILES = {
  "src/persistence/schema.ts",
  "src/persistence/init.ts",
  "src/api/items.ts",
  "src/plugins/persistence.ts",
}

-- The default (None) rendering, shared by every hollow-variant tier below. No toolchain
-- needed - pure in-process render.
local project = prova.fixture("typescript-rest:project", Scope.Suite, function(ctx)
  local tree = archetect.render{
    source = SRC,
    answers = ANSWERS,
    destination = ctx:tempdir(),
    defaults = true,
  }
  return tree:dir(PROJECT_DIR)
end)

-- Install once (shared by the build tier and the live-service fixture). Only ever reached from
-- pnpm-gated groups, so `pnpm` is guaranteed present here.
local installed = prova.fixture("typescript-rest:installed", Scope.Suite, function(ctx)
  local root = ctx:use(project)
  shell.run(PNPM_INSTALL, { cwd = root.path, timeout = "300s", check = true })
  return root
end)

-- Boot the rendered service on free ports (HOST/SERVER_PORT/MANAGEMENT_PORT come from settings.ts).
-- Waiting on the management sidecar's /health/liveness proves both Fastify servers came up.
local service = prova.fixture("typescript-rest:service", Scope.Suite, function(ctx)
  local root = ctx:use(installed)

  local port, mgmt = net.free_port(), net.free_port()
  ctx:manage(shell.spawn("pnpm exec tsx src/index.ts", {
    cwd = root.path,
    env = {
      HOST            = "127.0.0.1",
      SERVER_PORT     = port,
      MANAGEMENT_PORT = mgmt,
    },
  }))

  local mgmt_url = "http://127.0.0.1:" .. mgmt
  http.wait_for(mgmt_url .. "/health/liveness", { timeout = "60s" })
  return { service_url = "http://127.0.0.1:" .. port, mgmt_url = mgmt_url }
end)

-- Tier 1 - static: layout, template substitution, and generated k8s manifests. No toolchain.
prova.group("typescript-rest layout", function(g)
  g:test("scaffolds the expected project layout", function(t)
    local root = t:use(project).path
    t:expect_all(function()
      for _, f in ipairs(EXPECTED_FILES) do
        t:expect(fs.exists(root .. "/" .. f), f):is_true()
      end
    end)
  end)

  g:test("wires prefix/suffix, routes, and ports through file contents", function(t)
    local root = t:use(project).path
    -- The REST route is mounted under /api/v1.
    t:expect(fs.read(root .. "/src/app.ts"), "service route"):contains("/api/v1/ping")
    -- project-name lands in the package identity.
    t:expect(fs.read(root .. "/package.json"), "package name"):contains('"name": "example-service"')
    -- The service reads its ports from SERVER_PORT / MANAGEMENT_PORT.
    local settings = fs.read(root .. "/src/settings.ts")
    t:expect(settings, "service port env"):contains("SERVER_PORT")
    t:expect(settings, "management port env"):contains("MANAGEMENT_PORT")
  end)

  g:test("renders valid, non-empty kubernetes manifests", function(t)
    local root = t:use(project).path
    local manifests = fs.glob(root, ".platform/kubernetes/**/*.yaml")
    t:expect(#manifests > 0, "at least one k8s manifest"):is_true()
    t:expect_all(function()
      for _, m in ipairs(manifests) do
        -- Each manifest parses as YAML and declares a kind.
        local docs = yaml.parse_all(fs.read(m))
        t:expect(#docs > 0, m .. " has ≥1 document"):is_true()
      end
    end)
  end)

  g:test("leaves no unrendered template markers", function(t)
    -- The signature archetype check: no bare {{ }}, {% %}, or {# #} in contents or path segments
    -- (GitHub Actions ${{ … }} expressions are excluded by the matcher).
    t:expect(t:use(project)):is_fully_rendered()
  end)

  g:test("the hollow rendering stays hollow: no persistence scaffold files", function(t)
    local root = t:use(project).path
    t:expect_all(function()
      for _, f in ipairs(SCAFFOLD_FILES) do
        t:expect(fs.exists(root .. "/" .. f), f .. " must be absent"):is_false()
      end
    end)
  end)
end)

-- Tier 2 - build + unit: the generated project's own Vitest suite passes.
prova.group("typescript-rest build + unit tests", { requires = { "pnpm" } }, function(g)
  g:test("the generated Vitest suite passes", function(t)
    local root = t:use(installed).path
    local vitest = shell.run("pnpm test", { cwd = root, timeout = "180s" })
    t:expect(vitest.code, "vitest exit code"):equals(0)
    t:expect(vitest.stdout .. vitest.stderr, "vitest reports a passing suite"):contains("passed")
  end)
end)

-- Tier 3 - live HTTP: the running service and its management sidecar answer real requests.
prova.group("typescript-rest HTTP endpoints", { requires = { "pnpm" } }, function(g)
  g:test("the service route answers over the wire", function(t)
    local svc = t:use(service)
    local r = http.get(svc.service_url .. "/api/v1/ping")
    t:expect(r.status):equals(200)
    t:expect(r:json().status, "ping status"):equals("ok")
  end)

  g:test("the management sidecar reports readiness and liveness", function(t)
    local svc = t:use(service)

    local ready = http.get(svc.mgmt_url .. "/health/readiness")
    t:expect(ready.status, "readiness status code"):equals(200)
    t:expect(ready:json().status, "readiness body"):equals("ok")

    local live = http.get(svc.mgmt_url .. "/health/liveness")
    t:expect(live.status, "liveness status code"):equals(200)
    t:expect(live:json().status, "liveness body"):equals("ok")
  end)

  g:test("the management sidecar exposes Prometheus metrics", function(t)
    local svc = t:use(service)
    local r = http.get(svc.mgmt_url .. "/metrics")
    t:expect(r.status, "metrics status code"):equals(200)
    t:expect(r.body, "Prometheus exposition format"):contains("# HELP")
  end)
end)

-- Persistence variants: one entry per rendering variant. `db` is the container recipe
-- namespace; the SQL strings carry each backend's placeholder syntax (the scaffold table is
-- lowercase `items`, so no identifier quoting is needed).
local VARIANTS = {
  {
    persistence = "PostgreSQL",
    db = postgres,
    db_port = 5432,
    count_by_name = "SELECT count(*) FROM items WHERE display_name = $1",
    count_all     = "SELECT count(*) FROM items",
  },
  {
    persistence = "MySQL",
    db = mysql,
    db_port = 3306,
    count_by_name = "SELECT count(*) FROM items WHERE display_name = ?",
    count_all     = "SELECT count(*) FROM items",
  },
}

for _, v in ipairs(VARIANTS) do
  local label = "typescript-rest[" .. v.persistence .. "]"

  -- a) render — one fixture per variant, shared by verify and the black-box tests.
  local variant_project = prova.fixture(label .. ":project", Scope.File, function(ctx)
    return archetect.render{
      source = SRC,
      answers = answers_with{ persistence = v.persistence },
      destination = ctx:tempdir(),
      defaults = true,
    }
  end)

  -- b) verify — layout, fully-rendered, and typecheck against that rendering.
  archetect.verify(variant_project, {
    name = label,
    project_dir = PROJECT_DIR,
    expected_files = {
      "package.json",
      "src/index.ts",
      "src/app.ts",
      "src/settings.ts",
      "drizzle.config.ts",
      SCAFFOLD_FILES[1], SCAFFOLD_FILES[2], SCAFFOLD_FILES[3], SCAFFOLD_FILES[4],
      ".github/workflows/build.yaml",
    },
    yaml_globs = { ".platform/kubernetes/**/*.yaml" },
    requires = { "pnpm" },
    build_steps = { PNPM_INSTALL, "pnpm exec tsc --noEmit" },
  })

  -- c) black-box — provision the database, boot the rendered service against it.
  local variant_service = prova.fixture(label .. ":service", Scope.File, function(ctx)
    local root = ctx:use(variant_project):dir(PROJECT_DIR)
    local db = v.db.container(ctx)

    shell.run(PNPM_INSTALL, { cwd = root.path, timeout = "300s", check = true })

    local port, mgmt = net.free_port(), net.free_port()
    ctx:manage(shell.spawn("pnpm exec tsx src/index.ts", {
      cwd = root.path,
      env = {
        HOST            = "127.0.0.1",
        SERVER_PORT     = port,
        MANAGEMENT_PORT = mgmt,
        DB_HOST         = db.host,
        DB_PORT         = db.port,
        DB_USERNAME     = "prova",
        DB_PASSWORD     = "prova",
        DB_DBNAME       = "prova",
      },
    }))

    -- The management sidecar proves the process is up; the service port only answers after
    -- buildApp finished — i.e. after ensureSchema succeeded against the real database.
    http.wait_for("http://127.0.0.1:" .. mgmt .. "/health/liveness", { timeout = "60s" })
    local api = http.client{ base_url = "http://127.0.0.1:" .. port }
    api:wait_for("/api/v1/ping", { timeout = "60s" })
    return { api = api, db = db.client }
  end)

  prova.group(label .. " CRUD round-trip", { requires = { "docker", "pnpm" } }, function(g)
    g:test("created items land in " .. v.persistence, function(t)
      local svc = t:use(variant_service)

      -- Create through the public API...
      local created = svc.api:post(BASE, { json = { displayName = "widget" } })
      t:expect(created.status):equals(201)
      local body = created:json()
      t:expect(body.displayName):equals("widget")
      t:expect(body.id, "created id"):is_truthy()

      -- ...and prove the row exists in the actual database, not just the API's memory.
      t:expect(svc.db:query_value(v.count_by_name, { "widget" }), "rows in DB"):equals(1)

      -- Read back through every door.
      t:expect(svc.api:get(BASE .. "/" .. body.id):json().displayName):equals("widget")
    end)

    g:test("updates and deletes round-trip into " .. v.persistence, function(t)
      local svc = t:use(variant_service)

      local body = svc.api:post(BASE, { json = { displayName = "ephemeral" } }):json()

      local updated = svc.api:put(BASE .. "/" .. body.id, { json = { displayName = "renamed" } })
      t:expect(updated.status):equals(200)
      t:expect(svc.db:query_value(v.count_by_name, { "renamed" }), "renamed row in DB"):equals(1)
      t:expect(svc.db:query_value(v.count_by_name, { "ephemeral" }), "old name gone"):equals(0)

      t:expect(svc.api:delete(BASE .. "/" .. body.id).status):equals(204)
      t:expect(svc.api:get(BASE .. "/" .. body.id).status):equals(404)
      t:expect(svc.db:query_value(v.count_by_name, { "renamed" }), "row deleted from DB"):equals(0)
    end)
  end)
end
