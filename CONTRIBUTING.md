# Contributing to FenixKanban

FenixKanban is a cross‑platform Swift application that runs on iOS, iPadOS and macOS.  
The team has adopted a strict TDD Red → Green → Refactor workflow to keep the codebase
robust, maintainable and consistent across all platforms.  Every change must pass
the same quality gates locally and in CI before it can be merged.

---

## TDD Workflow Rule

**All coding tasks must follow the Red → Green → Refactor cycle before a PR is
considered complete.**  
Skipping any phase is only allowed for hotfixes (see the Hotfix Exception Policy).

---

## Phase Checklists

### 🔴 Red Phase
- [ ] Write a failing test that targets the intended behavior using Swift Testing’s `@Test` macro or an XCTest case.
- [ ] Verify the test fails for the correct reason (e.g., `XCTAssertEqual` failure, thrown error).
- [ ] Commit or stage the failing test (no implementation code yet).
- [ ] Ensure the test is not marked as `@Test(.disabled)` or `XCTAssertSkipped`.

### 🟢 Green Phase
- [ ] Implement the minimal code required to make the test pass.
- [ ] Run all tests locally (`⌘U` or `swift test`) and confirm the new test passes.
- [ ] Verify that no other tests are failing or skipped.
- [ ] Commit the changes with a message following our convention:
  ```
  feat: <short description>
  ```
- [ ] Push the branch and let CI run.

### 🔵 Refactor Phase
- [ ] Clean up the code (extract methods, rename variables, remove duplication).
- [ ] Run all tests again to confirm they still pass.
- [ ] Ensure there are no compiler warnings or errors (`swift build`).
- [ ] Verify the project builds for all target platforms (iOS, iPadOS, macOS).
- [ ] Commit the refactor with a clear message (`refactor: <description>`).

---

## Definition of Done

A task is **done** only when all the following pass locally and in CI:

1. Build succeeds for every platform target (iOS, iPadOS, macOS).
2. All tests pass (`⌘U` or `swift test`).
3. No compiler warnings or errors.
4. Code follows the project formatting standards (SwiftFormat or Xcode’s built‑in formatter).
5. The CI/CD pipeline passes (Xcode Cloud or GitHub Actions).

---

## Hotfix Exception Policy

Hotfixes may bypass the Red → Green → Refactor phases **only** under these conditions:

- Explicit written approval from the team lead (comment on the PR or issue).
- The PR description must include a `HOTFIX:` label and a short justification.
- Build and test checks **must still pass** – these are never bypassed.
- A follow‑up issue must be created to add proper tests after the merge.

---

## Branch and PR Guidelines

- **Branch naming**  
  - Features: `feature/<short-name>`  
  - Bug fixes: `fix/<short-name>`  
  - Hotfixes: `hotfix/<short-name>`
- Every PR must pass the CI/CD gate before merging.
- Keep PRs focused on a single change; split large work into multiple PRs.

---

## Platform‑Specific Considerations

- Use `#if os(iOS)` / `#if os(macOS)` conditionals only when platform‑specific APIs are required.
- Test platform‑specific behavior in separate test targets or with `#if` guards.
- Prefer cross‑platform APIs (e.g., SwiftUI) over UIKit/AppKit whenever possible.

---

Happy coding! 🚀
