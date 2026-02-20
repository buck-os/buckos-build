# BuckOS Formal Specification System

This directory contains the formal specifications for the BuckOS Linux distribution. Specifications define how various components of the distribution are supposed to work and serve as the authoritative reference for package managers, installers, build tools, and AI-assisted development tools.

## Quick Start

### For Readers

**Browse specifications:**
```bash
# View the index
cat specs/INDEX.md

# Read the package manager spec
cat specs/core/SPEC-001-package-manager-integration.md

# Query specs programmatically
jq '.specs[] | select(.status == "approved")' specs/REGISTRY.json
```

**Find relevant specs:**
- **By category**: Check subdirectories (core/, bootstrap/, integration/, features/, tooling/)
- **By status**: See INDEX.md for status badges
- **By tag**: Search REGISTRY.json for specific tags

### For Authors

**Create a new spec:**
```bash
# 1. Copy the template
cp specs/TEMPLATE.md specs/core/SPEC-006-your-spec-name.md

# 2. Edit the file, fill in all required fields
vim specs/core/SPEC-006-your-spec-name.md

# 3. Validate the spec
./scripts/validate-spec.py specs/core/SPEC-006-your-spec-name.md

# 4. Move to RFC when ready
./scripts/spec-lifecycle.py SPEC-006 --transition rfc
```

**Update an existing spec:**
```bash
# 1. Edit the spec file
vim specs/core/SPEC-001-package-manager-integration.md

# 2. Update the 'updated' date and version in frontmatter
# 3. Add changelog entry

# 4. Validate
./scripts/validate-spec.py specs/core/SPEC-001-package-manager-integration.md
```

## Directory Structure

```
specs/
├── README.md              # This file
├── TEMPLATE.md           # Template for new specs
├── INDEX.md              # Human-readable index (auto-generated)
├── REGISTRY.json         # Machine-readable registry (auto-generated)
├── BUCK                  # Buck2 build file
│
├── core/                 # Core system specifications (SPEC-001 to SPEC-099)
│   ├── SPEC-001-package-manager-integration.md
│   ├── SPEC-002-use-flags.md
│   ├── SPEC-003-versioning.md
│   ├── SPEC-004-package-sets.md
│   └── SPEC-005-patches.md
│
├── bootstrap/            # Bootstrap system specs (SPEC-100 to SPEC-199)
│   └── SPEC-100-bootstrap-3stage.md
│
├── integration/          # Integration specs (SPEC-200 to SPEC-299)
│   ├── SPEC-200-binary-packages.md
│   └── SPEC-201-source-mirroring.md
│
├── features/             # Feature specs (SPEC-300 to SPEC-399)
│   ├── SPEC-300-eclass-system.md
│   ├── SPEC-301-license-tracking.md
│   └── SPEC-302-eapi-versioning.md
│
└── tooling/              # Tooling specs (SPEC-400 to SPEC-499)
    ├── SPEC-400-spec-lifecycle.md
    └── SPEC-401-validation-tools.md
```

## Specification Format

Each specification is a Markdown file with YAML frontmatter containing metadata:

```yaml
---
id: "SPEC-001"
title: "Package Manager Integration"
status: "approved"
version: "1.2.0"
created: "2024-11-26"
updated: "2024-12-27"
category: "core"
authors:
  - name: "BuckOS Team"
    email: "team@buckos.org"
tags:
  - "package-manager"
  - "buck2"
---

# Package Manager Integration

**Status**: approved | **Version**: 1.2.0 | **Last Updated**: 2024-12-27

## Abstract
...
```

### Required Metadata Fields

All specs MUST include these fields:

- **id**: Unique identifier (SPEC-NNN format)
- **title**: Human-readable title
- **status**: Lifecycle status (draft | rfc | approved | rejected | deprecated)
- **version**: Semantic version (MAJOR.MINOR.PATCH)
- **created**: Creation date (ISO 8601)
- **updated**: Last update date (ISO 8601)
- **category**: Primary category (core | integration | features | bootstrap | tooling)
- **authors**: List of original authors

### Recommended Metadata Fields

Specs SHOULD include:

- **maintainers**: Current maintainers
- **tags**: Additional categorization
- **related**: Links to related specs
- **implementation**: Implementation status
- **compatibility**: Version requirements
- **changelog**: Version history

### Standard Document Structure

All specs SHOULD include these sections:

1. **Abstract**: Brief summary (2-3 sentences)
2. **Motivation**: Why this spec exists, problems solved
3. **Specification**: Detailed technical specification
4. **Examples**: Concrete code examples
5. **Implementation**: Implementation guidance and status
6. **Security Considerations**: Security implications
7. **Alternatives Considered**: Other approaches and why rejected
8. **References**: Links to related specs and resources

See [TEMPLATE.md](TEMPLATE.md) for the complete structure.

## Lifecycle States

Specifications move through well-defined lifecycle states:

```
draft ──────────> rfc ──────────> approved ──────────> deprecated
  │                │                   │
  └────────────────┴───────────────────┴──────────────> rejected
```

### Status Definitions

| Status | Description | Who Can Use |
|--------|-------------|-------------|
| **draft** | Work in progress, not ready for review | Authors only |
| **rfc** | Request for Comments, open for community feedback | Review, but don't implement |
| **approved** | Accepted and canonical, ready for implementation | Everyone - implement this |
| **rejected** | Decided against, kept for historical reference | Don't use |
| **deprecated** | Still valid but scheduled for replacement | Migrate away |

### Transition Rules

- **draft → rfc**: Requires completeness check (all mandatory sections present)
- **rfc → approved**: Requires maintainer approval
- **rfc → rejected**: Requires documented rationale
- **approved → deprecated**: Requires replacement spec ID or sunset plan
- **any → rejected**: Requires documented rationale

## Versioning

Specifications use semantic versioning (MAJOR.MINOR.PATCH):

### Version Bumping Rules

- **MAJOR** (X.0.0): Breaking changes to spec
  - Changes to required fields
  - Removal of features
  - Incompatible API changes
  - Example: 1.5.2 → 2.0.0

- **MINOR** (1.X.0): Backward-compatible additions
  - New optional features
  - New sections
  - Clarifications
  - Status changes
  - Example: 1.3.0 → 1.4.0

- **PATCH** (1.0.X): Fixes and clarifications
  - Typo fixes
  - Example improvements
  - Non-normative changes
  - Example: 1.0.1 → 1.0.2

### Status-Based Versions

- **draft**: 0.x.x (unstable)
- **rfc**: 0.9.x (release candidate)
- **approved**: 1.0.0+ (first stable version)

## Tools and Validation

### Validation

Validate a spec's format and metadata:

```bash
# Validate single spec
./scripts/validate-spec.py specs/core/SPEC-001-package-manager-integration.md

# Validate all specs
./scripts/validate-spec.py specs/**/*.md

# Validate as part of build
buck2 run //scripts:validate-all-specs
```

The validator checks:
- ✓ YAML frontmatter is valid
- ✓ All required fields present
- ✓ Field formats correct (dates, versions, emails)
- ✓ Status values valid
- ✓ Spec ID unique
- ✓ References point to existing specs
- ✓ Required sections present
- ✓ Semantic versioning correct

### Lifecycle Management

Transition specs between lifecycle states:

```bash
# Move to RFC
./scripts/spec-lifecycle.py SPEC-006 --transition rfc \
  --comment "Ready for review"

# Approve spec
./scripts/spec-lifecycle.py SPEC-006 --transition approve \
  --reviewer "maintainer@buckos.org"

# Deprecate spec
./scripts/spec-lifecycle.py SPEC-001 --transition deprecate \
  --reason "Replaced by SPEC-010" \
  --replacement SPEC-010 \
  --sunset-date 2025-06-01

# Reject spec
./scripts/spec-lifecycle.py SPEC-007 --transition reject \
  --reason "Not aligned with project goals"
```

The lifecycle tool:
- Validates the transition is allowed
- Updates status field
- Adds lifecycle event dates
- Increments version appropriately
- Adds changelog entry
- Suggests git commit message

### Index Generation

Generate the index and registry:

```bash
# Generate both INDEX.md and REGISTRY.json
./scripts/generate-spec-index.py

# Generate only markdown index
./scripts/generate-spec-index.py --format markdown --output specs/INDEX.md

# Generate only JSON registry
./scripts/generate-spec-index.py --format json --output specs/REGISTRY.json
```

The generator creates:
- **INDEX.md**: Human-readable index with status badges
- **REGISTRY.json**: Machine-readable registry for AI tools

## Using Specs in Your Project

### Package Managers

Package managers should:

1. **Read REGISTRY.json** to find relevant specs:
```python
import json

with open("/etc/buckos/specs/REGISTRY.json") as f:
    registry = json.load(f)

# Find package manager specs
pkg_mgr_specs = [
    spec for spec in registry["specs"]
    if "package-manager" in spec["tags"]
    and spec["status"] == "approved"
]
```

2. **Check compatibility** before implementing:
```python
for spec in pkg_mgr_specs:
    compat = spec["compatibility"]
    if version_meets(compat["buckos_version"], current_version):
        implement_spec(spec)
```

3. **Only implement approved specs**:
- ✅ Use specs with status="approved"
- ⚠️ Be cautious with status="rfc" (may change)
- ❌ Don't use status="draft" (unstable)
- ❌ Don't use status="deprecated" (being replaced)

### Build Systems

Reference specs in build definitions:

```python
# In BUCK files
package(
    build_rule = "ebuild",
    name = "mypackage",
    # Declare spec compliance
    spec_compliance = [
        "SPEC-001:1.2.0",  # Must comply with this spec version
        "SPEC-002:1.0.0",
    ],
)
```

### AI Tools

AI assistants should:

1. **Query REGISTRY.json** for relevant specs
2. **Filter by status** (only use "approved")
3. **Check compatibility** versions
4. **Follow MUST/SHOULD/MAY** requirements
5. **Cite specs** in responses

Example AI usage:
```python
# AI agent pseudo-code
registry = load_json("/etc/buckos/specs/REGISTRY.json")

# Find USE flag specs
use_flag_specs = [
    s for s in registry["specs"]
    if "use-flags" in s["tags"] and s["status"] == "approved"
]

# Read and implement
spec = read_spec(use_flag_specs[0]["path"])
implement_requirements(spec)
```

## Spec ID Ranges

Spec IDs use ranges for categorization:

| Range | Category | Purpose |
|-------|----------|---------|
| 001-099 | core | Core system specifications |
| 100-199 | bootstrap | Bootstrap system specs |
| 200-299 | integration | Integration specifications |
| 300-399 | features | Feature specifications |
| 400-499 | tooling | Tooling specifications |
| 500-599 | *(reserved)* | Future use |

When creating a new spec, choose the next available ID in the appropriate range.

## Writing Guidelines

### Be Precise and Unambiguous

Use RFC 2119 keywords consistently:

- **MUST**: Absolute requirement
- **MUST NOT**: Absolute prohibition
- **SHOULD**: Recommended but not required
- **SHOULD NOT**: Not recommended but not prohibited
- **MAY**: Truly optional

Example:
```
Implementations MUST validate all input parameters.
Implementations SHOULD cache frequently accessed data.
Implementations MAY provide a plugin system.
```

### Provide Concrete Examples

Every concept should have at least one working example:

```python
# Good: Concrete, runnable example
result = validate_spec("specs/core/SPEC-001-package-manager-integration.md")
print(f"Valid: {result.is_valid}")

# Bad: Abstract pseudocode
result = validate(spec)
check(result)
```

### Consider Implementation

Specs should be implementable:

- ✅ Define clear APIs and data structures
- ✅ Provide test criteria
- ✅ Include reference implementation or examples
- ✅ Document edge cases
- ❌ Don't specify impossible requirements
- ❌ Don't leave critical details ambiguous

### Document Alternatives

Show you've considered other approaches:

```markdown
## Alternatives Considered

### Alternative 1: Store specs in TOML format

**Pros:**
- More structured than YAML
- Better type safety

**Cons:**
- Less human-readable
- Less familiar to developers
- More complex parsing

**Why Rejected:** YAML provides better readability and broader tool support.
```

## Review Process

### For Spec Authors

1. **Create draft spec** from template
2. **Validate** with validation tool
3. **Self-review** using the checklist below
4. **Move to RFC** when ready
5. **Address feedback** from reviewers
6. **Get approval** from maintainers

### For Reviewers

Review checklist:

- [ ] All required metadata fields present
- [ ] All required sections present
- [ ] No ambiguous requirements
- [ ] Examples provided for complex features
- [ ] Security considerations addressed
- [ ] Performance implications discussed
- [ ] Migration path documented (if applicable)
- [ ] Alternatives considered and documented
- [ ] Implementation feasibility verified
- [ ] Test criteria defined
- [ ] Validation script passes

### Getting Help

- **Questions**: Ask in project discussions
- **Review requests**: Tag @buckos-maintainers
- **Issues**: File in project issue tracker

## Examples

### Example 1: Finding Approved Core Specs

```bash
# Using jq
jq -r '.specs[] | select(.category == "core" and .status == "approved") | "\(.id): \(.title)"' \
  specs/REGISTRY.json
```

Output:
```
SPEC-001: Package Manager Integration
SPEC-002: USE Flags
SPEC-003: Versioning
SPEC-004: Package Sets
SPEC-005: Patches
```

### Example 2: Checking Implementation Status

```bash
# Find specs that are not fully implemented
jq -r '.specs[] | select(.implementation.status != "complete") | "\(.id): \(.implementation.completeness)%"' \
  specs/REGISTRY.json
```

### Example 3: Creating a New Spec

```bash
# 1. Determine next available ID
ls specs/core/SPEC-*.md | tail -1
# Output: specs/core/SPEC-005-patches.md
# Next ID: SPEC-006

# 2. Create from template
cp specs/TEMPLATE.md specs/core/SPEC-006-binary-packages.md

# 3. Edit the spec
vim specs/core/SPEC-006-binary-packages.md

# 4. Validate
./scripts/validate-spec.py specs/core/SPEC-006-binary-packages.md

# 5. Add to git
git add specs/core/SPEC-006-binary-packages.md
git commit -m "Add SPEC-006: Binary Packages (draft)"
```

## Installation

The `buckos-specs` package installs all specifications to `/etc/buckos/specs/`:

```bash
# Build the package
buck2 build //packages/linux/system/specs:buckos-specs

# Install (will be in rootfs automatically)
# Files will be at /etc/buckos/specs/
```

Installed files:
- `/etc/buckos/specs/INDEX.md` - Human-readable index
- `/etc/buckos/specs/REGISTRY.json` - Machine-readable registry
- `/etc/buckos/specs/core/SPEC-*.md` - Core specifications
- `/etc/buckos/specs/bootstrap/SPEC-*.md` - Bootstrap specifications
- `/etc/buckos/specs/*/` - All other categories

## FAQ

**Q: What's the difference between specs and docs?**

A: Specifications are formal, versioned, lifecycle-managed documents that define requirements and APIs. Documentation is informal guidance, tutorials, and explanations. Specs say "MUST", docs say "here's how".

**Q: Can I have a spec in multiple categories?**

A: No, each spec has one primary category. Use tags for additional categorization.

**Q: What if my spec depends on another spec that's not approved yet?**

A: List it in `depends_on` and note the dependency in the text. Your spec can't be approved until its dependencies are approved.

**Q: How do I deprecate a spec?**

A: Use the lifecycle tool to transition to deprecated, provide a replacement spec ID or sunset plan, and document migration steps.

**Q: Can I delete a spec?**

A: Deprecated specs should remain for historical reference. After the sunset date, move to `specs/historical/` but don't delete entirely.

**Q: Who approves specs?**

A: Project maintainers approve specs. See the `maintainers` field in CLAUDE.md or README.md.

**Q: How often should specs be updated?**

A: Update when the implementation changes, new features are added, or clarifications are needed. Minor updates can happen frequently, major updates should be infrequent.

**Q: What license are specs under?**

A: Specifications are documentation and typically use CC-BY-4.0. Check individual spec frontmatter.

## References

- [TEMPLATE.md](TEMPLATE.md) - Complete spec template
- [INDEX.md](INDEX.md) - Human-readable spec index
- [REGISTRY.json](REGISTRY.json) - Machine-readable spec registry
- [CLAUDE.md](../CLAUDE.md) - Developer guide
- [RFC 2119](https://tools.ietf.org/html/rfc2119) - Key words for RFCs
- [Semantic Versioning](https://semver.org/) - Version numbering

## Contributing

Contributions to specifications are welcome! To contribute:

1. **Small fixes**: Submit a PR with the fix
2. **New specs**: Create draft, request review, iterate
3. **Major changes**: Discuss in issues first

All contributions should follow the guidelines in this README.

---

**Questions or suggestions?** File an issue or discussion in the project repository.
