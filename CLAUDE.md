# FenixKanban — Coding Workflow Rules

**For every coding task in this repo, follow [DELIVERABLES.md](./DELIVERABLES.md).**

That document is the authoritative spec for how work gets done here. Once `CONTRIBUTING.md` and `.github/workflows/swift-pr-check.yml` are generated from it, those become the day-to-day references — but the rules originate in `DELIVERABLES.md`.

## TL;DR

- **TDD: Red → Green → Refactor.** Every coding task starts with a failing test that targets the intended behavior. Write tests using Swift Testing's `@Test` macro (preferred) or XCTest. UI iteration may happen during exploration, but the final state must have test coverage locking in the expected behavior.
- **Definition of done — all checks must pass:**
  - Build succeeds for all platform targets (iOS, macOS, etc.) — ⌘B or `swift build`
  - All tests pass — ⌘U or `swift test`
  - No compiler warnings or errors
  - Code follows project formatting standards
  - CI/CD pipeline passes (GitHub Actions or Xcode Cloud)
- **Hotfix bypass:** TDD may be skipped only with explicit team lead approval, documented in the PR (`HOTFIX:` label + justification). Build and test checks are never bypassed. A follow-up issue must be opened to add tests post-merge.

## Swift & Apple Platform Guidelines

- **Cross-platform first:** Prefer SwiftUI and platform-agnostic APIs. Use `#if os(iOS)` / `#if os(macOS)` conditionals only when necessary.
- **Platform naming:** Use official names: iOS, iPadOS, macOS, watchOS, visionOS (not "Mac", "iPhone OS", etc.).
- **Modern Swift:** Prefer Swift Concurrency (async/await, actors) over legacy patterns (Dispatch, Combine) unless project constraints require otherwise.
- **Testing:**
  - Prefer **Swift Testing** framework with `@Test` macro for new tests
  - Use `@Suite` to organize related tests
  - Use `#expect()` for assertions and `#require()` for unwrapping
  - XCTest is acceptable for legacy tests or when Swift Testing is not available
- **StoreKit, AuthenticationServices, etc.:** When working with Apple frameworks, consult official documentation for current best practices.

## Platform-Specific Considerations

### iOS/iPadOS
- Use `UIColor`, `UIFont`, etc. with `Color(uiColor:)` bridges to SwiftUI
- Test on multiple device sizes when UI layout is critical
- Consider Dynamic Type, Dark Mode, accessibility

### macOS
- Use `NSColor`, `NSFont`, etc. with `Color(nsColor:)` bridges to SwiftUI
- `NSColor.windowBackgroundColor` is the macOS equivalent of `UIColor.systemBackground`
- Test window resizing behavior
- Consider menu bar integration, keyboard shortcuts

### Cross-platform
- Use conditional compilation judiciously:
  ```swift
  #if os(iOS)
  Color(uiColor: .systemBackground)
  #elseif os(macOS)
  Color(nsColor: .windowBackgroundColor)
  #endif
  ```
- Extract platform-specific code into separate files/extensions when practical

## Notes for AI Assistants (Claude, etc.)

- **Batch fixes:** When multiple errors are present, analyze all issues first, then propose a comprehensive fix rather than one-at-a-time iterations.
- **Context awareness:** Check platform targets before suggesting APIs. Don't suggest iOS-only APIs for macOS targets.
- **Documentation:** You have access to current Apple framework documentation via `search_additional_documentation` tool. Use it when needed.
- **Test patterns:** Follow existing test patterns in the project. Check `__tests__` or test target folders for examples.
- **SwiftUI vs UIKit/AppKit:** Default to SwiftUI unless the codebase clearly uses UIKit/AppKit for the feature in question.

## Common Patterns

### Color handling (cross-platform)

On iOS 26 / macOS 26 the system supplies the window background via Liquid Glass. Don't impose your own — let the system render. Custom `.background()` on top of a navigation/chrome surface (toolbars, tab bars, sidebars, sheets, list rows) *suppresses* Liquid Glass and is the #1 visual symptom of an un-audited app. See `docs/apple-technology-overviews.md` for the full rules.

```swift
// ✅ Best — no .background at all on full-bleed views; system handles it
VStack { /* content */ }
    .frame(maxWidth: .infinity, maxHeight: .infinity)

// ✅ Acceptable — for content surfaces that legitimately need a tint,
//                use the cross-platform helper instead of hand-rolled #if
SomeContentView()
    .background(Color.crossPlatformTertiarySystemBackground)

// ❌ Avoid — suppresses Liquid Glass on the underlying window/chrome
SomeView()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    #if os(iOS)
    .background(Color(uiColor: .systemBackground))
    #elseif os(macOS)
    .background(Color(nsColor: .windowBackgroundColor))
    #endif

// ❌ Avoid — also not cross-platform
.background(Color(.systemBackground))
```

### Testing with Swift Testing
```swift
import Testing

@Suite("Feature Name Tests")
struct FeatureTests {
    @Test("Description of test case")
    func testSomething() async throws {
        let result = performAction()
        #expect(result == expectedValue)
    }
    
    @Test("Unwrapping optionals")
    func testOptional() async throws {
        let optional: Int? = getValue()
        let unwrapped = try #require(optional)
        #expect(unwrapped > 0)
    }
}
```

### StoreKit 2 (async/await pattern)
```swift
// Load products
let products = try await Product.products(for: identifiers)

// Purchase
let result = try await product.purchase()
switch result {
case .success(let verification):
    // Handle success
case .userCancelled:
    // Handle cancellation
case .pending:
    // Handle pending
@unknown default:
    break
}
```

## Workflow Summary

1. **Red Phase:**
   - Write failing test first
   - Verify it fails for the right reason
   - Commit the failing test

2. **Green Phase:**
   - Write minimal code to pass the test
   - Verify all tests pass
   - Commit the implementation

3. **Refactor Phase:**
   - Clean up code without changing behavior
   - Verify all tests still pass
   - Verify no warnings, build succeeds
   - Open PR

**TDD rule is in effect.** All coding tasks follow this workflow unless explicitly bypassed via hotfix approval process.
