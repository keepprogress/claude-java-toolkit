# PMD Violation Auto-Fix Reference

Claude reads this file to decide how to auto-fix PMD violations.

## Contributing New Rules

Each rule entry must include:

**For auto-fixable rules:**
- `### RuleName` — exact PMD rule name
- `Pattern:` — code pattern that triggers the violation
- `Fix:` — transformation to apply
- Code example with `// Before` and `// After`
- `IMPORTANT:` / `NOTE:` — edge cases where the fix should NOT be applied (e.g., side effects, special contexts)
- If the class might already use Lombok `@Slf4j` or have an existing logger, note how to handle

**For non-auto-fixable rules:**
- `### RuleName` — exact PMD rule name
- `WHY:` — why auto-fix is unsafe (e.g., requires human judgement, side effects, domain knowledge)
- `REPORT:` — what information to show the user

**Decision criteria:** A rule is auto-fixable only if the transformation is **semantically equivalent** in all cases. If there is any scenario where the fix changes runtime behavior, mark it as not auto-fixable.

---

## Auto-fixable (Claude applies directly)

### NoLoggerStringConcatenation
Pattern: `logger.X("text" + var)` or `logger.X("text" + var + "more")`
Fix: Replace `+` concatenation with `{}` placeholders

```java
// Before
logger.debug("step5 list.size: " + list.size());
logger.error("處理失敗, orderdetailId: " + id + ", " + e.getMessage());

// After
logger.debug("step5 list.size: {}", list.size());
logger.error("處理失敗, orderdetailId: {}, {}", id, e.getMessage());
```

IMPORTANT: Exception objects go as last argument WITHOUT `{}`:
```java
// Before
logger.error("非預期錯誤: " + e.getMessage(), e);
// After
logger.error("非預期錯誤: {}", e.getMessage(), e);
```

### AvoidFullyQualifiedName
Pattern: `new java.util.ArrayList<>()` or `java.util.Map<String, String>`
Fix: Add import at top of file, use short class name

```java
// Before
java.util.List<String> items = new java.util.ArrayList<>();

// After (add import)
import java.util.List;
import java.util.ArrayList;
// ... (use short name)
List<String> items = new ArrayList<>();
```

### NoSystemPrintln
Pattern: `System.out.println(...)` or `System.err.println(...)`
Fix: Replace with SLF4J logger call. Add logger field if not present.

```java
// Before
System.out.println("debug: " + value);

// After (ensure logger field exists)
private static final Logger logger = LoggerFactory.getLogger(ClassName.class);
// ...
logger.debug("debug: {}", value);
```

NOTE: Skip if inside `public static void main(String[] args)` — allowed by rule.
NOTE: If the class already has `@Slf4j` (Lombok) or an existing `Logger` field, do NOT add a duplicate logger field.

## Not auto-fixable (report to user)

### EmptyCatchBlock
WHY: Need human judgement on whether to log, rethrow, or add comment.
REPORT: Show the catch block and ask what to do.

### UnusedLocalVariable
WHY: If variable captures a method call with side effects, deleting it changes behavior.
REPORT: Show the variable and its assignment. If RHS is a pure expression (literal, constructor), suggest deletion. If RHS is a method call, ask user.

### CPD (Copy-Paste Duplication)
WHY: Extraction strategy depends on domain knowledge.
REPORT: Show the duplicated blocks and their locations.

### Suppression count mismatch
WHY: Security guard — only humans should modify the allowlist.
REPORT: Show which files have mismatched counts.
