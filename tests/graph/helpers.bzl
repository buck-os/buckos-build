"""Shared helpers for BXL graph tests."""

def assert_result(ctx, results, name, condition, msg):
    """Record a PASS/FAIL result."""
    if condition:
        ctx.output.print("PASS: " + name)
        results.append(True)
    else:
        ctx.output.print("FAIL: " + name + " -- " + msg)
        results.append(False)

def starts_with(s, prefix):
    """Check whether string s starts with prefix."""
    return len(s) >= len(prefix) and s[:len(prefix)] == prefix

def get_dep_strings(query, target_pattern):
    """Return a list of strings representing declared deps.

    Inspects: deps (list or select), source, package, actual.
    Each value is converted to string for substring matching.
    For select()-wrapped deps, the stringified select includes all
    branch target labels, so substring matching still works.
    """
    target_set = query.eval(target_pattern)
    dep_strs = []
    for t in target_set:
        deps_attr = t.get_attr("deps")
        if deps_attr != None:
            dep_strs.append(str(deps_attr))
        source_attr = t.get_attr("source")
        if source_attr != None:
            dep_strs.append(str(source_attr))
        package_attr = t.get_attr("package")
        if package_attr != None:
            dep_strs.append(str(package_attr))
        actual_attr = t.get_attr("actual")
        if actual_attr != None:
            dep_strs.append(str(actual_attr))
    return dep_strs

def has_dep_matching(dep_strs, substring):
    """Check whether any dep string contains the given substring."""
    for s in dep_strs:
        if substring in s:
            return True
    return False

def target_exists(query, target_pattern):
    """Return True if the target pattern resolves to at least one target."""
    target_set = query.eval(target_pattern)
    for _t in target_set:
        return True
    return False

def target_has_label(query, target_pattern, label):
    """Check whether a target has a specific label in its labels attr."""
    target_set = query.eval(target_pattern)
    for t in target_set:
        labels = t.get_attr("labels")
        if labels != None:
            for l in labels:
                if l == label:
                    return True
    return False

def summarize(ctx, results):
    """Print summary and return (passed, failed) tuple."""
    passed = 0
    failed = 0
    for r in results:
        if r:
            passed += 1
        else:
            failed += 1
    ctx.output.print("")
    ctx.output.print("{} passed, {} failed, {} total".format(passed, failed, passed + failed))
    return (passed, failed)
