---
# ============================================================================
# BuckOS Specification Template
# ============================================================================
# This is a template for creating new BuckOS specifications. Copy this file
# to create a new spec and fill in all the fields.
#
# REQUIRED FIELDS (Must be present in all specs):
# - id, title, status, version, created, updated, category, authors

# SPEC ID: Unique identifier in SPEC-NNN format
# Number ranges:
#   001-099: Core system specs
#   100-199: Bootstrap specs
#   200-299: Integration specs
#   300-399: Feature specs
#   400-499: Tooling specs
#   500-599: Reserved
id: "SPEC-XXX"

# TITLE: Human-readable title (use Title Case)
title: "Your Specification Title"

# STATUS: Current lifecycle status
# Allowed values: draft | rfc | approved | rejected | deprecated
# State transitions:
#   draft → rfc: Ready for community review
#   rfc → approved: Accepted by maintainers
#   rfc → rejected: Not accepted
#   approved → deprecated: Being replaced
status: "draft"

# VERSION: Semantic versioning (MAJOR.MINOR.PATCH)
# Bump rules:
#   MAJOR: Breaking changes to spec (incompatible changes)
#   MINOR: Backward-compatible additions (new features, status changes)
#   PATCH: Fixes and clarifications (typos, examples)
# Status-based versions:
#   draft: 0.x.x
#   rfc: 0.9.x (release candidate)
#   approved: 1.0.0+ (first stable version)
version: "0.1.0"

# DATES: ISO 8601 format (YYYY-MM-DD)
created: "2024-12-27"
updated: "2024-12-27"

# AUTHORS: List of original authors
# At least one author required
authors:
  - name: "Your Name"
    email: "your.email@example.com"
  - name: "Another Author"
    email: "another@example.com"

# MAINTAINERS: Current maintainers (defaults to authors if not specified)
maintainers:
  - "maintainer@buckos.org"
  - "team@buckos.org"

# CATEGORY: Primary categorization
# Allowed values: core | integration | features | bootstrap | tooling
category: "core"

# TAGS: Additional categorization (lowercase, hyphenated)
# Use for searchability and grouping
tags:
  - "example-tag"
  - "another-tag"
  - "feature-name"

# ============================================================================
# OPTIONAL FIELDS (Recommended for better spec management)
# ============================================================================

# RELATIONSHIPS: Links to other specs
related:
  - "SPEC-001"  # Related specifications
  - "SPEC-002"
superseded_by: null  # Set when deprecated (e.g., "SPEC-010")
replaces: []         # List of spec IDs this spec replaces

# DEPENDENCIES: Specs this one depends on
depends_on:
  - "SPEC-001"  # Must be implemented before this spec

# IMPLEMENTATION: Implementation status tracking
implementation:
  status: "not-started"  # not-started | in-progress | partial | complete
  completeness: 0        # Percentage (0-100)
  tracked_in:            # External tracking (GitHub issues, etc.)
    - "https://github.com/org/repo/issues/123"

# LIFECYCLE: Lifecycle event tracking
lifecycle:
  rfc_date: null        # When moved to RFC (YYYY-MM-DD)
  approved_date: null   # When approved (YYYY-MM-DD)
  deprecated_date: null # When deprecated (YYYY-MM-DD)
  sunset_date: null     # Planned removal date (YYYY-MM-DD)
  deprecation_reason: null  # Why deprecated (if applicable)

# COMPATIBILITY: Version requirements and breaking changes
compatibility:
  buck2_version: ">=2024.11.01"    # Minimum Buck2 version
  buckos_version: ">=1.0.0"        # Minimum BuckOS version
  breaking_changes: false          # Does this introduce breaking changes?
  breaks_compatibility_with: []    # List incompatible spec versions

# REVIEWS: Review history (added during review process)
reviews:
  - reviewer: "reviewer@buckos.org"
    date: "2024-12-27"
    status: "approved"  # approved | changes-requested | rejected
    comments: "Looks good, minor typo fixes needed"

# CHANGELOG: Version history (reverse chronological order)
# Add new entries at the top
changelog:
  - version: "0.1.0"
    date: "2024-12-27"
    changes: "Initial draft"
---

# {Specification Title}

**Status**: {status} | **Version**: {version} | **Last Updated**: {updated}

## Abstract

A brief 2-3 sentence summary of what this specification defines. This should be concise and give readers an immediate understanding of the spec's purpose and scope.

Example: "This specification defines the package manager integration layer for BuckOS, detailing how external package management tools should interact with the Buck2 build system, query package metadata, and manage system configuration."

## Table of Contents

1. [Overview](#overview)
2. [Motivation](#motivation)
3. [Specification](#specification)
   - [Architecture](#architecture)
   - [Data Structures](#data-structures)
   - [API Reference](#api-reference)
   - [Requirements](#requirements)
4. [Examples](#examples)
   - [Basic Example](#basic-example)
   - [Advanced Example](#advanced-example)
5. [Implementation](#implementation)
   - [Implementation Status](#implementation-status)
   - [Implementation Notes](#implementation-notes)
   - [Testing Requirements](#testing-requirements)
6. [Migration Guide](#migration-guide) *(if applicable)*
7. [Security Considerations](#security-considerations)
8. [Performance Considerations](#performance-considerations)
9. [Alternatives Considered](#alternatives-considered)
10. [References](#references)
11. [Appendices](#appendices) *(if needed)*

---

## Overview

Provide a high-level overview of what this specification covers:

- **Purpose**: What does this spec define or standardize?
- **Scope**: What is included and what is explicitly out of scope?
- **Target Audience**: Who should read and implement this spec? (e.g., package manager developers, build system maintainers, AI tools)
- **Key Concepts**: Brief introduction to the main concepts

Example:
```markdown
This specification defines the formal specification system for BuckOS itself. It establishes how specifications are formatted, versioned, reviewed, and lifecycled through various states from initial draft to final approval or deprecation. The spec system enables consistent documentation, facilitates tool integration (including AI assistants), and provides a clear contract for implementation.
```

---

## Motivation

Explain why this specification exists:

### Problems Solved

What specific problems or pain points does this spec address?

- Problem 1: Description
- Problem 2: Description
- Problem 3: Description

### Use Cases

What real-world scenarios does this spec enable?

**Use Case 1**: Brief description
- Actor: Who benefits?
- Scenario: What do they do?
- Outcome: What do they achieve?

**Use Case 2**: Brief description
- Actor: Who benefits?
- Scenario: What do they do?
- Outcome: What do they achieve?

### Goals

What are the explicit goals of this specification?

1. **Goal 1**: Description
2. **Goal 2**: Description
3. **Goal 3**: Description

### Non-Goals

What is explicitly out of scope?

1. **Non-Goal 1**: Description of what is not covered and why
2. **Non-Goal 2**: Description of what is not covered and why

---

## Specification

This section contains the detailed technical specification.

### Architecture

Describe the overall architecture and system components:

```
┌─────────────────────────────────────────┐
│         Component A                      │
├─────────────────────────────────────────┤
│  Subcomponent 1  │  Subcomponent 2      │
└────────┬─────────┴──────────┬───────────┘
         │                    │
         ▼                    ▼
┌─────────────────┐   ┌─────────────────┐
│   Component B   │   │   Component C   │
└─────────────────┘   └─────────────────┘
```

Explain:
- How components interact
- Data flow between components
- Integration points

### Data Structures

Define all data structures, file formats, or schemas:

#### Structure Name

```python
# Example using Python-like syntax
StructureName = {
    "field1": "string",      # Description of field1
    "field2": 123,           # Description of field2
    "field3": ["array"],     # Description of field3
    "nested": {              # Nested structure
        "subfield": "value"
    }
}
```

**Fields:**
- `field1` (string, required): Description and constraints
- `field2` (integer, optional): Description and default value
- `field3` (array, required): Description of array contents

### API Reference

Document all functions, methods, or interfaces:

#### Function Name

```python
def function_name(param1, param2, optional_param=None):
    """
    Brief description of what this function does.

    Args:
        param1 (type): Description of param1
        param2 (type): Description of param2
        optional_param (type, optional): Description. Defaults to None.

    Returns:
        type: Description of return value

    Raises:
        ExceptionType: When this exception is raised

    Example:
        >>> result = function_name("value1", 42)
        >>> print(result)
        Expected output
    """
    pass
```

### Requirements

Use RFC 2119 keywords (MUST, MUST NOT, SHOULD, SHOULD NOT, MAY) to define requirements:

#### Mandatory Requirements

1. **REQ-001**: Implementations MUST validate all input parameters
2. **REQ-002**: Implementations MUST handle errors gracefully
3. **REQ-003**: Implementations MUST NOT expose sensitive information in error messages

#### Recommended Practices

1. **REC-001**: Implementations SHOULD cache frequently accessed data
2. **REC-002**: Implementations SHOULD provide progress indicators for long operations
3. **REC-003**: Implementations SHOULD log warnings for deprecated features

#### Optional Features

1. **OPT-001**: Implementations MAY provide a plugin system for extensibility
2. **OPT-002**: Implementations MAY support multiple output formats

---

## Examples

Provide concrete, working examples that demonstrate the specification.

### Basic Example

Show the simplest possible usage:

```python
# Example: Basic usage
from buckos.specs import validate_spec

spec_file = "specs/core/SPEC-001-package-manager-integration.md"
result = validate_spec(spec_file)

if result.is_valid:
    print(f"✓ Spec {result.spec_id} is valid")
else:
    print(f"✗ Validation failed: {result.errors}")
```

**Expected Output:**
```
✓ Spec SPEC-001 is valid
```

### Advanced Example

Show more complex usage with multiple features:

```python
# Example: Advanced usage with lifecycle management
from buckos.specs import SpecLifecycle

lifecycle = SpecLifecycle()

# Transition spec from draft to RFC
result = lifecycle.transition(
    spec_id="SPEC-006",
    from_status="draft",
    to_status="rfc",
    comment="Ready for community review",
    reviewer="maintainer@buckos.org"
)

if result.success:
    print(f"Spec {result.spec_id} transitioned to {result.new_status}")
    print(f"New version: {result.new_version}")
    print(f"Changelog entry: {result.changelog_entry}")
else:
    print(f"Transition failed: {result.error}")
```

### Real-World Use Case

Demonstrate a complete real-world scenario:

```markdown
**Scenario**: A package manager needs to find all specs that define its requirements.

1. Read the registry
2. Filter by relevant tags
3. Check status (only use approved specs)
4. Verify compatibility
5. Implement requirements
```

```python
import json

# Load spec registry
with open("/etc/buckos/specs/REGISTRY.json") as f:
    registry = json.load(f)

# Find package manager specs
pkg_mgr_specs = [
    spec for spec in registry["specs"]
    if "package-manager" in spec["tags"]
    and spec["status"] == "approved"
]

# Check compatibility
for spec in pkg_mgr_specs:
    compat = spec["compatibility"]
    if meets_version_requirement(compat["buckos_version"]):
        print(f"Implementing {spec['id']}: {spec['title']}")
        implement_spec(spec)
```

---

## Implementation

### Implementation Status

**Current Status**: not-started

**Completeness**: 0%

**What is Implemented:**
- Nothing yet

**What is Planned:**
- Feature 1
- Feature 2

**What is Out of Scope:**
- Feature X (reason)
- Feature Y (reason)

### Implementation Notes

Guidance for implementers:

#### Best Practices

1. **Practice 1**: Description and rationale
2. **Practice 2**: Description and rationale

#### Common Pitfalls

**Pitfall 1**: Description
- **Problem**: What goes wrong
- **Solution**: How to avoid it
- **Example**: Code showing the correct approach

**Pitfall 2**: Description
- **Problem**: What goes wrong
- **Solution**: How to avoid it

#### Performance Tips

1. **Tip 1**: Optimization strategy and expected improvement
2. **Tip 2**: Optimization strategy and expected improvement

### Testing Requirements

Specifications should be verifiable through testing:

#### Unit Tests

Required unit tests:

```python
def test_validation_rejects_invalid_spec():
    """Spec with missing required fields should fail validation"""
    spec = create_spec(title="Test", status="draft")  # Missing id
    result = validate_spec(spec)
    assert not result.is_valid
    assert "missing required field: id" in result.errors
```

#### Integration Tests

Required integration tests:

```python
def test_spec_package_installs_correctly():
    """buckos-specs package should install all specs to /etc/buckos/specs"""
    build_package("system//specs:buckos-specs")
    assert path_exists("/etc/buckos/specs/INDEX.md")
    assert path_exists("/etc/buckos/specs/REGISTRY.json")
    assert path_exists("/etc/buckos/specs/core/SPEC-001-package-manager-integration.md")
```

#### Compliance Tests

Tests to verify implementations meet the spec:

- Test REQ-001: Input validation
- Test REQ-002: Error handling
- Test REC-001: Caching behavior

---

## Migration Guide

*(Include this section only if the spec introduces changes that require migration)*

### Breaking Changes

List all breaking changes introduced by this specification:

1. **Change 1**: Description
   - **Impact**: Who/what is affected
   - **Migration**: How to adapt

2. **Change 2**: Description
   - **Impact**: Who/what is affected
   - **Migration**: How to adapt

### Migration Steps

Step-by-step guide for migrating from previous approach:

**Step 1**: Description of first step
```bash
# Example command or code
```

**Step 2**: Description of second step
```bash
# Example command or code
```

**Step 3**: Verification
```bash
# How to verify migration succeeded
```

### Compatibility Matrix

| Component | Old Version | New Version | Compatible? | Notes |
|-----------|-------------|-------------|-------------|-------|
| Package Manager | 1.0.0 | 2.0.0 | Partial | Requires config update |
| Build System | 1.5.0 | 2.0.0 | Yes | Fully backward compatible |

### Deprecation Timeline

| Date | Event |
|------|-------|
| 2024-12-27 | Spec approved |
| 2025-01-27 | Old API deprecated |
| 2025-06-27 | Old API removed |

---

## Security Considerations

Discuss security implications of this specification:

### Threat Model

Identify potential threats:

1. **Threat 1**: Description
   - **Attack Vector**: How the attack could occur
   - **Impact**: What damage could result
   - **Likelihood**: High/Medium/Low

2. **Threat 2**: Description
   - **Attack Vector**: How the attack could occur
   - **Impact**: What damage could result
   - **Likelihood**: High/Medium/Low

### Security Requirements

Security-specific requirements:

1. **SEC-001**: Implementations MUST validate and sanitize all user input
2. **SEC-002**: Implementations MUST NOT execute arbitrary code from spec files
3. **SEC-003**: Implementations SHOULD use cryptographic signatures for spec verification

### Mitigations

How to mitigate identified threats:

| Threat | Mitigation | Effectiveness |
|--------|------------|---------------|
| Threat 1 | Mitigation strategy | High |
| Threat 2 | Mitigation strategy | Medium |

### Secure Defaults

Default configuration should be secure:

```python
DEFAULT_CONFIG = {
    "allow_unsigned_specs": False,  # Require signatures
    "validate_on_load": True,       # Always validate
    "sandbox_execution": True,      # Run in sandbox
}
```

---

## Performance Considerations

Discuss performance implications:

### Time Complexity

Analysis of algorithmic complexity:

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Validate spec | O(n) | Linear in file size |
| Generate index | O(n log n) | Sort all specs |
| Query by tag | O(1) | Hash table lookup |

### Space Complexity

Memory and storage requirements:

- **Memory**: Approximately X MB per Y specs
- **Storage**: Approximately Z KB per spec

### Scalability Limits

Known scalability limitations:

1. **Limit 1**: Description and workaround
2. **Limit 2**: Description and workaround

### Optimization Strategies

Recommended optimizations:

1. **Strategy 1**: Description and expected improvement
2. **Strategy 2**: Description and expected improvement

### Benchmarks

Performance benchmarks (if available):

| Operation | Input Size | Time | Memory |
|-----------|-----------|------|--------|
| Validate | 100 specs | 2.5s | 15 MB |
| Generate index | 100 specs | 1.2s | 8 MB |

---

## Alternatives Considered

Document alternative approaches and why they were not chosen:

### Alternative 1: {Alternative Name}

**Description**: Brief description of the alternative approach

**Pros:**
- Advantage 1
- Advantage 2
- Advantage 3

**Cons:**
- Disadvantage 1
- Disadvantage 2
- Disadvantage 3

**Why Rejected**: Explanation of why this approach was not selected

### Alternative 2: {Alternative Name}

**Description**: Brief description of the alternative approach

**Pros:**
- Advantage 1
- Advantage 2

**Cons:**
- Disadvantage 1
- Disadvantage 2

**Why Rejected**: Explanation of why this approach was not selected

### Alternative 3: Keep Status Quo

**Description**: Don't implement this spec at all

**Pros:**
- No implementation cost
- No migration required

**Cons:**
- Problems remain unsolved
- Pain points continue

**Why Rejected**: The benefits of this spec outweigh the costs

---

## References

Links to related resources:

### Related Specifications

- [SPEC-001: Package Manager Integration](core/SPEC-001-package-manager-integration.md)
- [SPEC-002: USE Flags](core/SPEC-002-use-flags.md)

### External Resources

- [Buck2 Documentation](https://buck2.build/)
- [RFC 2119: Key words for use in RFCs](https://tools.ietf.org/html/rfc2119)
- [Semantic Versioning 2.0.0](https://semver.org/)

### Implementation Code

- Repository: https://github.com/org/repo
- Implementation file: path/to/file.py
- Tests: path/to/tests/

### Standards

- ISO 8601: Date and time format
- YAML 1.2: YAML syntax
- CommonMark: Markdown specification

---

## Appendices

*(Optional: Include additional supporting information)*

### Appendix A: Complete Code Example

Full working example:

```python
# Complete implementation example
```

### Appendix B: Data Schema

Complete JSON schema:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "field1": {"type": "string"},
    "field2": {"type": "integer"}
  },
  "required": ["field1"]
}
```

### Appendix C: Command Reference

Complete command-line reference:

```bash
# List all specs
buckos-spec list [--status STATUS] [--category CATEGORY]

# Show spec details
buckos-spec show SPEC-ID

# Validate spec
buckos-spec validate PATH

# Transition spec
buckos-spec transition SPEC-ID --to STATUS
```

### Appendix D: FAQ

**Q: Question 1?**
A: Answer to question 1.

**Q: Question 2?**
A: Answer to question 2.

---

## Revision History

Detailed version history is maintained in the YAML frontmatter `changelog` field. Major revisions:

- **v1.0.0** (2024-12-27): Initial approved specification
- **v0.9.0** (2024-12-20): Release candidate for review
- **v0.1.0** (2024-12-01): Initial draft

---

**Document End**

---

## Notes for Spec Authors

When creating a new spec from this template:

1. **Copy this file** to the appropriate category directory with proper naming:
   - Format: `SPEC-{NNN}-{slug}.md`
   - Example: `specs/core/SPEC-006-binary-packages.md`

2. **Fill in YAML frontmatter**:
   - Choose next available SPEC-NNN in appropriate range
   - Set status to "draft" initially
   - Use current date for created/updated
   - Add your name to authors
   - Choose appropriate category and tags

3. **Write the content**:
   - Replace all {placeholders} with actual content
   - Remove sections that don't apply (mark as "N/A" if required)
   - Keep all required sections even if brief
   - Add appendices as needed

4. **Validate the spec**:
   ```bash
   ./scripts/validate-spec.py specs/category/SPEC-XXX-name.md
   ```

5. **Request review** when ready for RFC:
   ```bash
   ./scripts/spec-lifecycle.py SPEC-XXX --transition rfc
   ```

6. **Incorporate feedback** and iterate until approved

Remember:
- Be precise and unambiguous
- Use MUST/SHOULD/MAY consistently
- Provide concrete examples
- Consider security and performance
- Document alternatives considered
- Keep the target audience in mind
