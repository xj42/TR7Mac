# Repository Guidance


* Swift
* Follow existing project structure, patterns, API contracts, bindings, and database conventions.
* Read relevant files and nearby implementations before editing.
* Prefer minimal, targeted changes. Do not refactor or redesign unrelated code.
* Reuse existing models, services, components, utilities, and abstractions before introducing new ones.
* Do not modify generated files.
* Do not rename persisted entities, tables, columns, or migrations unless explicitly requested.
* Do not silently change persisted-data semantics.
* Preserve nullable correctness and use async I/O; propagate `CancellationToken` where already supported.
* Keep database queries server-side where practical and avoid N+1 queries.
* Do not add dependencies unless clearly justified.
* Do not remove working functionality or add placeholder implementations.
* Prefer targeted tests before the full suite.
* Build affected projects and run relevant tests after changes.
* Fix failures caused by the change; distinguish pre-existing failures.


## Response

Make changes directly. Keep responses concise and do not paste full files or unchanged code.

At the end give only:

* files changed
* important decisions
* test result
