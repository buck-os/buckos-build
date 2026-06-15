#!/usr/bin/env python3
"""
BuckOS Specification Index Generator

Generates INDEX.md (human-readable) and REGISTRY.json (machine-readable)
from all specification files in the specs/ directory.

Usage:
    ./scripts/generate-spec-index.py
    ./scripts/generate-spec-index.py --format markdown --output specs/INDEX.md
    ./scripts/generate-spec-index.py --format json --output specs/REGISTRY.json
"""

import argparse
import json
import re
import sys
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any, Optional

try:
    import yaml
except ImportError:
    print(
        "Error: PyYAML not installed. Install with: pip install PyYAML", file=sys.stderr
    )
    sys.exit(1)


# ============================================================================
# Constants
# ============================================================================

STATUS_BADGES = {
    "approved": "✅",
    "rfc": "🔄",
    "draft": "📝",
    "rejected": "⛔",
    "deprecated": "⚠️",
}

CATEGORY_ORDER = ["core", "bootstrap", "integration", "features", "tooling"]


# ============================================================================
# Data Classes
# ============================================================================


@dataclass
class SpecInfo:
    """Information about a specification"""

    id: str
    title: str
    status: str
    version: str
    category: str
    path: str
    created: str
    updated: str
    authors: List[Dict[str, str]]
    maintainers: Optional[List[str]] = None
    tags: List[str] = field(default_factory=list)
    related: List[str] = field(default_factory=list)
    implementation: Optional[Dict[str, Any]] = None
    compatibility: Optional[Dict[str, Any]] = None
    description: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization"""
        data = asdict(self)
        # Remove None values
        return {k: v for k, v in data.items() if v is not None}


# ============================================================================
# Index Generator Class
# ============================================================================


class IndexGenerator:
    """Generates index files from specifications"""

    def __init__(self, specs_dir: Path):
        self.specs_dir = specs_dir
        self.specs: List[SpecInfo] = []

    def scan_specs(self):
        """Scan all specification files and extract metadata.

        Skips specs/historical/ — that directory is the archive of
        deprecated specs (per specs/README.md) and is intentionally
        excluded from INDEX.md and REGISTRY.json so the active spec set
        stays clean.
        """
        spec_files = sorted(
            p
            for p in self.specs_dir.glob("**/SPEC-*.md")
            if "historical" not in p.relative_to(self.specs_dir).parts
        )

        for spec_file in spec_files:
            try:
                spec_info = self._extract_spec_info(spec_file)
                if spec_info:
                    self.specs.append(spec_info)
            except Exception as e:
                print(f"Warning: Failed to process {spec_file}: {e}", file=sys.stderr)

        # Sort by spec ID
        self.specs.sort(key=lambda s: s.id)

    def _extract_spec_info(self, spec_file: Path) -> Optional[SpecInfo]:
        """Extract spec information from a file"""
        content = spec_file.read_text(encoding="utf-8")

        # Extract YAML frontmatter
        if not content.startswith("---\n"):
            return None

        end_match = re.search(r"\n---\n", content[4:])
        if not end_match:
            return None

        frontmatter_text = content[4 : 4 + end_match.start()]

        try:
            frontmatter = yaml.safe_load(frontmatter_text)
        except yaml.YAMLError:
            return None

        # Extract required fields
        required_fields = [
            "id",
            "title",
            "status",
            "version",
            "category",
            "created",
            "updated",
            "authors",
        ]
        for field in required_fields:
            if field not in frontmatter:
                print(
                    f"Warning: {spec_file} missing required field: {field}",
                    file=sys.stderr,
                )
                return None

        # Calculate relative path from specs directory
        rel_path = spec_file.relative_to(self.specs_dir)

        # Extract description from Abstract section
        description = self._extract_abstract(content[4 + end_match.end() :])

        return SpecInfo(
            id=frontmatter["id"],
            title=frontmatter["title"],
            status=frontmatter["status"],
            version=frontmatter["version"],
            category=frontmatter["category"],
            path=str(rel_path),
            created=frontmatter["created"],
            updated=frontmatter["updated"],
            authors=frontmatter["authors"],
            maintainers=frontmatter.get("maintainers"),
            tags=frontmatter.get("tags", []),
            related=frontmatter.get("related", []),
            implementation=frontmatter.get("implementation"),
            compatibility=frontmatter.get("compatibility"),
            description=description,
        )

    def _extract_abstract(self, markdown: str) -> Optional[str]:
        """Extract abstract text from markdown"""
        abstract_match = re.search(
            r"##\s+Abstract\s*\n\n(.+?)(?=\n##|\Z)", markdown, re.DOTALL
        )
        if abstract_match:
            abstract = abstract_match.group(1).strip()
            # Limit to first 200 characters
            if len(abstract) > 200:
                abstract = abstract[:197] + "..."
            return abstract
        return None

    def generate_markdown_index(self) -> str:
        """Generate human-readable INDEX.md"""
        lines = []

        # Header
        lines.append("# BuckOS Specifications Index")
        lines.append("")
        lines.append(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append("")

        # Summary statistics
        total = len(self.specs)
        by_status = self._group_by_status()
        by_category = self._group_by_category()

        lines.append("## Summary")
        lines.append("")
        lines.append(f"**Total Specifications:** {total}")
        lines.append("")

        lines.append("**By Status:**")
        for status in ["approved", "rfc", "draft", "deprecated", "rejected"]:
            count = len(by_status.get(status, []))
            badge = STATUS_BADGES.get(status, "")
            lines.append(f"- {badge} {status}: {count}")
        lines.append("")

        lines.append("**By Category:**")
        for category in CATEGORY_ORDER:
            count = len(by_category.get(category, []))
            lines.append(f"- {category}: {count}")
        lines.append("")

        # Status legend
        lines.append("## Status Legend")
        lines.append("")
        lines.append("| Status | Badge | Description |")
        lines.append("|--------|-------|-------------|")
        lines.append(
            f"| approved | {STATUS_BADGES['approved']} | Canonical specification, ready for implementation |"
        )
        lines.append(
            f"| rfc | {STATUS_BADGES['rfc']} | Request for Comments, under review |"
        )
        lines.append(
            f"| draft | {STATUS_BADGES['draft']} | Work in progress, not ready for review |"
        )
        lines.append(
            f"| rejected | {STATUS_BADGES['rejected']} | Not accepted, kept for historical reference |"
        )
        lines.append(
            f"| deprecated | {STATUS_BADGES['deprecated']} | Replaced or outdated, scheduled for removal |"
        )
        lines.append("")

        # Specifications by category
        lines.append("## Specifications")
        lines.append("")

        for category in CATEGORY_ORDER:
            category_specs = by_category.get(category, [])
            if not category_specs:
                continue

            # Category header
            lines.append(f"### {category.capitalize()} Specifications")
            lines.append("")

            # Table header
            lines.append("| ID | Title | Status | Version | Updated |")
            lines.append("|--- |-------|--------|---------|---------|")

            # Specs in this category
            for spec in sorted(category_specs, key=lambda s: s.id):
                badge = STATUS_BADGES.get(spec.status, "")
                lines.append(
                    f"| [{spec.id}]({spec.path}) | {spec.title} | "
                    f"{badge} {spec.status} | {spec.version} | {spec.updated} |"
                )

            lines.append("")

        # Quick links
        lines.append("## Quick Links")
        lines.append("")
        lines.append("### Core System Specifications (Approved)")
        lines.append("")

        approved_core = [
            s for s in self.specs if s.category == "core" and s.status == "approved"
        ]
        for spec in approved_core:
            desc = f": {spec.description}" if spec.description else ""
            lines.append(f"- [{spec.id}: {spec.title}]({spec.path}){desc}")

        if approved_core:
            lines.append("")

        # References
        lines.append("## References")
        lines.append("")
        lines.append("- [TEMPLATE.md](TEMPLATE.md) - Template for creating new specs")
        lines.append("- [README.md](README.md) - Guide to the specification system")
        lines.append(
            "- [REGISTRY.json](REGISTRY.json) - Machine-readable spec registry"
        )
        lines.append("")

        # Footer
        lines.append("---")
        lines.append("")
        lines.append(
            "For questions or suggestions about the specification system, "
            "please file an issue in the project repository."
        )
        lines.append("")

        return "\n".join(lines)

    def generate_json_registry(self) -> str:
        """Generate machine-readable REGISTRY.json"""
        registry = {
            "version": "1.0.0",
            "generated": datetime.now().isoformat(),
            "total_specs": len(self.specs),
            "specs": [spec.to_dict() for spec in self.specs],
            "by_category": {},
            "by_status": {},
            "by_tag": {},
        }

        # Group by category
        for category, specs in self._group_by_category().items():
            registry["by_category"][category] = [s.id for s in specs]

        # Group by status
        for status, specs in self._group_by_status().items():
            registry["by_status"][status] = [s.id for s in specs]

        # Group by tag
        for spec in self.specs:
            for tag in spec.tags:
                if tag not in registry["by_tag"]:
                    registry["by_tag"][tag] = []
                registry["by_tag"][tag].append(spec.id)

        return json.dumps(registry, indent=2, ensure_ascii=False)

    def _group_by_category(self) -> Dict[str, List[SpecInfo]]:
        """Group specs by category"""
        result = {}
        for spec in self.specs:
            if spec.category not in result:
                result[spec.category] = []
            result[spec.category].append(spec)
        return result

    def _group_by_status(self) -> Dict[str, List[SpecInfo]]:
        """Group specs by status"""
        result = {}
        for spec in self.specs:
            if spec.status not in result:
                result[spec.status] = []
            result[spec.status].append(spec)
        return result


# ============================================================================
# Main Function
# ============================================================================


def main():
    parser = argparse.ArgumentParser(
        description="Generate BuckOS specification index files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  Generate both INDEX.md and REGISTRY.json:
    %(prog)s

  Generate only markdown index:
    %(prog)s --format markdown --output specs/INDEX.md

  Generate only JSON registry:
    %(prog)s --format json --output specs/REGISTRY.json
        """,
    )
    parser.add_argument(
        "--format",
        choices=["markdown", "json", "both"],
        default="both",
        help="Output format (default: both)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Output file path (required if format is markdown or json)",
    )
    parser.add_argument(
        "--specs-dir",
        type=Path,
        default=Path("specs"),
        help="Path to specs directory (default: specs/)",
    )
    parser.add_argument(
        "--quiet", action="store_true", help="Suppress non-error output"
    )

    args = parser.parse_args()

    # Validate arguments
    if args.format in ["markdown", "json"] and not args.output:
        parser.error("--output required when format is markdown or json")

    # Create generator
    generator = IndexGenerator(args.specs_dir)

    # Scan specs
    if not args.quiet:
        print(f"Scanning specifications in {args.specs_dir}...")
    generator.scan_specs()

    if not args.quiet:
        print(f"Found {len(generator.specs)} specifications")

    # Generate output
    if args.format == "markdown" or args.format == "both":
        markdown = generator.generate_markdown_index()

        if args.format == "markdown":
            output_path = args.output
        else:
            output_path = args.specs_dir / "INDEX.md"

        output_path.write_text(markdown, encoding="utf-8")
        if not args.quiet:
            print(f"Generated {output_path}")

    if args.format == "json" or args.format == "both":
        json_content = generator.generate_json_registry()

        if args.format == "json":
            output_path = args.output
        else:
            output_path = args.specs_dir / "REGISTRY.json"

        output_path.write_text(json_content, encoding="utf-8")
        if not args.quiet:
            print(f"Generated {output_path}")

    if not args.quiet:
        print("Done!")


if __name__ == "__main__":
    main()
