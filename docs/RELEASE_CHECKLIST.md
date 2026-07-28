# Release Checklist

- [ ] Version channel matches evidence: Beta before campus acceptance, RC after controlled Dorm/Teaching acceptance, stable only after platform signing gates.
- [ ] macOS and Windows annotated tags point to the same reviewed immutable `main` commit.
- [ ] Worktree is clean; no `*-local.zip` is renamed or uploaded.
- [ ] macOS/Python tests, shared fixtures/schemas and redaction scans pass.
- [ ] Dorm baseline test count has not decreased.
- [ ] Teaching is default-off and real-campus gaps are marked `PENDING_CAMPUS_VALIDATION`.
- [ ] macOS Release/App build, signature verification and helper CLI self-test pass.
- [ ] Windows tests, dual-PE PyInstaller build, frozen self-tests and package verifier pass in Windows.
- [ ] No release contains the other platform's source/runtime.
- [ ] Configuration and diagnostic permissions/ACLs are verified.
- [ ] Dependency versions are locked; SBOM, LICENSE and third-party notices are included.
- [ ] GitHub Actions are pinned to immutable commits.
- [ ] SHA-256 files, change log, privacy, security, rollback and provenance are included.
- [ ] Release assets contain no source secrets, real config/logs, absolute developer paths or signing credentials.
- [ ] `python3 scripts/scan_repository_secrets.py --source-root . --history` passes on a full-history checkout.
- [ ] Local `reports/`, raw executables, wheelhouses, installers and VM transfer files are excluded.
- [ ] Apple notarization and Windows Authenticode/Defender/SmartScreen are either verified or explicitly marked blocked.
- [ ] Maintainer manually reviews assets; build scripts never auto-publish.
