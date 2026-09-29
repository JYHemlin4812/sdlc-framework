# Testing Anti-Patterns

Adapted from the `test-driven-development` skill of [obra/superpowers](https://github.com/obra/superpowers).

**Load this reference when** writing or changing tests, adding mocks, or considering a test-only method in production code.

## Overview

Tests verify real behavior, not mock behavior. Mocks are a means to isolate, not the thing under test.

Core principle: test what the code does, not what the mocks do. Following the TDD cycle strictly prevents most of these anti-patterns.

## The rules

```
1. Don't test mock behavior.
2. Don't add test-only methods to production classes.
3. Don't mock a dependency you haven't understood.
```

## Anti-pattern 1: testing mock behavior

**The violation:**
```typescript
// ❌ BAD: Testing that the mock exists
test('renders sidebar', () => {
  render(<Page />);
  expect(screen.getByTestId('sidebar-mock')).toBeInTheDocument();
});
```

**Why it's wrong:**
- It verifies the mock works, not that the component works
- It passes when the mock is present and fails when it isn't
- It says nothing about real behavior

The question to ask: "Are we testing the behavior of a mock?"

**The fix:**
```typescript
// ✅ GOOD: Test the real component, or don't mock it
test('renders sidebar', () => {
  render(<Page />);  // Don't mock sidebar
  expect(screen.getByRole('navigation')).toBeInTheDocument();
});

// OR if the sidebar must be mocked for isolation:
// don't assert on the mock — test Page's behavior with the sidebar present
```

### Check

```
Before asserting on any mock element:
  Ask: "Am I testing real component behavior or just mock existence?"

  If mock existence:
    Remove the assertion or unmock the component.

  Test real behavior instead.
```

## Anti-pattern 2: test-only methods in production

**The violation:**
```typescript
// ❌ BAD: destroy() only used in tests
class Session {
  async destroy() {  // Looks like production API!
    await this._workspaceManager?.destroyWorkspace(this.id);
    // ... cleanup
  }
}

// In tests
afterEach(() => session.destroy());
```

**Why it's wrong:**
- The production class carries test-only code
- It is dangerous if called in production by mistake
- It violates YAGNI and separation of concerns
- It confuses object lifecycle with entity lifecycle

**The fix:**
```typescript
// ✅ GOOD: Test utilities handle test cleanup
// Session has no destroy() - it's stateless in production

// In test-utils/
export async function cleanupSession(session: Session) {
  const workspace = session.getWorkspaceInfo();
  if (workspace) {
    await workspaceManager.destroyWorkspace(workspace.id);
  }
}

// In tests
afterEach(() => cleanupSession(session));
```

### Check

```
Before adding any method to a production class:
  Ask: "Is this only used by tests?"
  If yes: put it in test utilities instead.

  Ask: "Does this class own this resource's lifecycle?"
  If no: this is the wrong class for the method.
```

## Anti-pattern 3: mocking without understanding

**The violation:**
```typescript
// ❌ BAD: Mock breaks test logic
test('detects duplicate server', () => {
  // Mock prevents config write that test depends on!
  vi.mock('ToolCatalog', () => ({
    discoverAndCacheTools: vi.fn().mockResolvedValue(undefined)
  }));

  await addServer(config);
  await addServer(config);  // Should throw - but won't!
});
```

**Why it's wrong:**
- The mocked method had a side effect the test relied on (writing the config)
- Over-mocking "to be safe" breaks actual behavior
- The test passes for the wrong reason or fails mysteriously

**The fix:**
```typescript
// ✅ GOOD: Mock at correct level
test('detects duplicate server', () => {
  // Mock the slow part, preserve behavior test needs
  vi.mock('MCPServerManager'); // Just mock slow server startup

  await addServer(config);  // Config written
  await addServer(config);  // Duplicate detected ✓
});
```

### Check

```
Before mocking any method:
  1. What side effects does the real method have?
  2. Does this test depend on any of them?
  3. Do I understand what this test needs?

  If the test depends on those side effects:
    Mock at a lower level (the actual slow/external operation),
    or use a test double that preserves the needed behavior —
    not the high-level method the test depends on.

  If unsure what the test depends on:
    Run it with the real implementation first,
    observe what actually needs to happen,
    then add minimal mocking at the right level.

  Warning signs:
    - "I'll mock this to be safe"
    - "This might be slow, better mock it"
    - Mocking without knowing the dependency chain
```

## Anti-pattern 4: incomplete mocks

**The violation:**
```typescript
// ❌ BAD: Partial mock - only fields you think you need
const mockResponse = {
  status: 'success',
  data: { userId: '123', name: 'Alice' }
  // Missing: metadata that downstream code uses
};

// Later: breaks when code accesses response.metadata.requestId
```

**Why it's wrong:**
- Partial mocks hide structural assumptions: only the fields you know about are there
- Downstream code may read fields you left out, and fail silently
- Tests pass while integration fails, because the mock is incomplete and the real API isn't
- The test gives false confidence about real behavior

Rule: mock the complete data structure as it exists in reality, not only the fields the immediate test reads.

**The fix:**
```typescript
// ✅ GOOD: Mirror real API completeness
const mockResponse = {
  status: 'success',
  data: { userId: '123', name: 'Alice' },
  metadata: { requestId: 'req-789', timestamp: 1234567890 }
  // All fields real API returns
};
```

### Check

```
Before creating a mock response:
  Ask: "Which fields does the real API response contain?"

  1. Look at an actual response (docs/examples).
  2. Include every field the system might consume downstream.
  3. Make the mock match the real response schema.

  If uncertain: include all documented fields.
```

## Anti-pattern 5: tests as an afterthought

**The violation:**
```
✅ Implementation complete
❌ No tests written
"Ready for testing"
```

**Why it's wrong:**
- Testing is part of implementation, not an optional follow-up
- The TDD cycle would have caught this
- Work isn't complete without tests (the P### can't be marked ✅)

**The fix:**
```
TDD cycle:
1. Write failing test
2. Implement to pass
3. Refactor
4. Then claim complete
```

## When mocks become too complex

Warning signs:
- Mock setup longer than the test logic
- Mocking everything to make the test pass
- Mocks missing methods the real components have
- The test breaks when the mock changes

The question to ask: "Do we need a mock here at all?" Integration tests with real components are often simpler than complex mocks.

## How TDD prevents these

1. **Write the test first** — you decide what you are actually testing.
2. **Watch it fail** — confirms the test exercises real behavior, not mocks.
3. **Minimal implementation** — test-only methods don't creep in.
4. **Real dependencies** — you see what the test needs before mocking anything.

Testing mock behavior usually means mocks were added without first watching the test fail against real code.

## Quick reference

| Anti-pattern | Fix |
|--------------|-----|
| Assert on mock elements | Test the real component or unmock it |
| Test-only methods in production | Move them to test utilities |
| Mock without understanding | Understand dependencies first, mock minimally |
| Incomplete mocks | Mirror the real API completely |
| Tests as afterthought | TDD — tests first |
| Over-complex mocks | Consider integration tests |

## Warning signs

- Assertions on `*-mock` test IDs
- Methods only called from test files
- Mock setup is more than half the test
- The test fails when you remove the mock
- You can't explain why the mock is needed
- Mocking "just to be safe"

## Bottom line

Mocks are tools to isolate, not things to test. If TDD shows you're testing mock behavior, test real behavior instead or question why you're mocking at all.
