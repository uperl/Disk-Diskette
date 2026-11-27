# Development Guidelines

Before making changes, read and follow:

- [docs/PERLSTYLE.md](docs/PERLSTYLE.md) — Perl coding, dependency, testing, and distribution conventions.
- [docs/DESIGN.md](docs/DESIGN.md) — project-specific architecture, requirements, public API, CLI, and implementation milestones.

Explicit project-specific decisions in `docs/DESIGN.md` take precedence over defaults in `docs/PERLSTYLE.md`.

Keep the implementation, tests, and documentation consistent with the design. Update `docs/DESIGN.md` when intentional architectural or interface changes are made. Do not modify the reusable Perl style guidelines merely to accommodate project-specific exceptions; document those exceptions in `docs/DESIGN.md` instead.
