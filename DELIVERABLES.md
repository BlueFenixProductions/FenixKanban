# FenixKanban — Development Workflow Specification

You are a senior Swift developer with deep expertise in SwiftUI, UIKit, AppKit, Swift Testing, XCTest, Xcode Cloud, and TDD workflows spanning iOS, iPadOS, macOS, watchOS, and visionOS. Your task is to produce two ready-to-use deliverables for the FenixKanban project.

---

## CONTEXT

FenixKanban is a Swift application targeting multiple Apple platforms (iOS, iPadOS, macOS). The project is managed by a small team of developers who are already familiar with TDD principles. The project uses the following toolchain:

- **Language:** Swift (latest stable)
- **Frameworks:** SwiftUI, StoreKit, AuthenticationServices, Foundation
- **Test framework:** Swift Testing (preferred) and/or XCTest
- **Platform targets:** iOS, iPadOS, macOS (cross-platform where applicable)
- **Build system:** Xcode / Swift Package Manager
- **Required checks:**
  - Build succeeds for all targets (⌘B in Xcode or `swift build`)
  - All tests pass (`⌘U` in Xcode or `swift test`)
  - No compiler warnings or errors
  - Code formatting follows project conventions (SwiftFormat or built-in Xcode formatting)

The team wants to enforce a mandatory TDD Red → Green → Refactor workflow for all coding tasks, with a phase-by-phase checklist so developers have a clear definition of "done." Hotfixes may bypass the TDD requirement **only with explicit team lead approval**, which must be documented.

---

## DELIVERABLES

Produce exactly two artifacts:

### DELIVERABLE 1 — `CONTRIBUTING.md`

Write a complete, professional `CONTRIBUTING.md` file for the repository. It must include:

1. **Introduction** — A brief statement of why this workflow exists and what it protects (code quality, regression safety, consistent patterns across platforms).

2. **TDD Workflow Rule** — A clearly titled section stating that ALL coding tasks MUST follow the Red → Green → Refactor cycle before being considered done.

3. **Phase Checklists** — Three clearly labeled checklists (use GitHub-flavored Markdown task-list syntax `- [ ]`) covering each TDD phase:
   - **🔴 Red Phase** checklist: what a developer must do and verify before moving on (e.g., write a failing test that targets the intended behavior using Swift Testing's `@Test` macro or XCTest, confirm the test fails for the right reason, commit or stage the failing test).
   - **🟢 Green Phase** checklist: what constitutes minimal passing code, confirm all tests pass (⌘U), no skipped or disabled tests, commit message follows convention.
   - **🔵 Refactor Phase** checklist: code cleaned up without changing behavior, all tests still pass after refactor, no compiler warnings, build succeeds for all targets, PR is ready to open.

4. **Definition of Done** — A concise, numbered list stating that a task is only "done" when ALL of the following pass locally and in CI:
   - Build succeeds for all platform targets (iOS, macOS, etc.)
   - All tests pass (`⌘U` or `swift test`)
   - No compiler warnings or errors
   - Code follows project formatting standards
   - CI/CD pipeline passes (Xcode Cloud or GitHub Actions)

5. **Hotfix Exception Policy** — A clearly marked section explaining that hotfixes MAY bypass the TDD Red→Green→Refactor phases ONLY under these conditions:
   - Explicit written approval from the team lead (comment on the PR or issue)
   - The PR description must include a `HOTFIX:` label and a short justification
   - Build and test checks must STILL pass — these are never bypassed
   - A follow-up issue must be created to add proper tests post-merge

6. **Branch and PR Guidelines** — Brief guidance on branch naming (e.g., `feature/`, `fix/`, `hotfix/`) and the expectation that every PR must pass the CI/CD gate before merge.

7. **Platform-Specific Considerations** — Guidance on handling cross-platform code:
   - Use `#if os(iOS)` / `#if os(macOS)` conditionals appropriately
   - Test platform-specific behavior separately when needed
   - Prefer cross-platform APIs when available (e.g., SwiftUI over UIKit/AppKit)

8. **Tone:** Professional, clear, and direct. Written for experienced Swift developers already familiar with TDD — no need to explain what TDD is from scratch, but the checklists should be specific enough that there is no ambiguity about what "done" means.

---

### DELIVERABLE 2 — `.github/workflows/swift-pr-check.yml`

Write a complete, production-ready GitHub Actions workflow YAML file that:

1. **Triggers** on `pull_request` events targeting the `main` branch (and optionally `develop` if present). It must NOT run on direct pushes to `main` — this is a PR gate only.

2. **Job name:** `swift-pr-quality-gate`

3. **Matrix strategy:** Test on multiple platform/OS combinations if needed (e.g., macOS runner for iOS/macOS builds, different Xcode versions if required).

4. **Steps must include:**
   - Checkout the repository (`actions/checkout@v4`)
   - Select Xcode version if needed (`maxim-lobanov/setup-xcode@v1` or `xcode-select`)
   - Build all targets: `xcodebuild -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 15' build` (adjust scheme/destination as needed)
   - Run tests: `xcodebuild test -scheme FenixKanban -destination 'platform=iOS Simulator,name=iPhone 15'` or `swift test` for SPM projects
   - Check for warnings: Parse xcodebuild output or use `-quiet` flag and check exit codes
   - Each step must have a clear `name:` label

5. **Hotfix bypass:** Do NOT implement any automatic bypass in the workflow. The workflow must always run all checks. The hotfix policy is a human-approval process documented in `CONTRIBUTING.md`, not a CI skip.

6. **YAML quality:** Use correct indentation (2 spaces), include comments explaining each major section, and ensure the file is copy-paste ready with no placeholder values that need substitution (or clearly mark what needs customization).

---

## OUTPUT FORMAT REQUIREMENTS

- Return both deliverables in full — do not summarize or truncate.
- Clearly separate them with a heading for each (e.g., `## DELIVERABLE 1: CONTRIBUTING.md` and `## DELIVERABLE 2: .github/workflows/swift-pr-check.yml`).
- Use fenced code blocks with the correct language identifier (`markdown` for the CONTRIBUTING.md content, `yaml` for the workflow).
- Do not add any explanation or commentary outside the two deliverables — the output should be ready to copy and paste directly into the repository.

---

## CONSTRAINTS

- Do not invent new tooling or suggest replacing Swift Testing, XCTest, or Xcode.
- Do not add test coverage thresholds or other gates not mentioned — keep scope to what was specified.
- The CONTRIBUTING.md must be self-contained; do not reference external wiki pages or assume additional tooling.
- The GitHub Actions file must be compatible with GitHub-hosted runners (`macos-latest` or specific macOS versions for Xcode).
- Respect Apple platform naming conventions: iOS, iPadOS, macOS, watchOS, visionOS (not "Mac", "iPhone", etc.).
