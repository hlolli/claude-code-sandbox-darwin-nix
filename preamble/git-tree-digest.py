#!/usr/bin/env python3
"""
git-tree-digest: token-efficient project tree for LLM context.

Reads tracked files via `git ls-tree`, builds a tree, and applies
adaptive depth expansion within a configurable line budget.

Algorithm: greedily expand directories with the fewest direct children
first (min-heap) until the line budget is reached. Collapsed directories
show their total descendant count so the LLM knows what's inside.
"""

import heapq
import subprocess
import sys


def get_git_files():
    """Return all tracked file paths from git, or None if not in a repo."""
    try:
        result = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
        return [line for line in result.stdout.split("\n") if line]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def get_find_files():
    """Return file paths via find(1), excluding .git directories."""
    result = subprocess.run(
        ["find", ".", "-name", ".git", "-prune", "-o", "-type", "f", "-print"],
        capture_output=True,
        text=True,
        check=True,
    )
    paths = []
    for line in result.stdout.split("\n"):
        if line:
            # Strip leading "./"
            paths.append(line[2:] if line.startswith("./") else line)
    return paths


def build_tree(file_paths):
    """Build a nested dict from file paths. Dirs -> dict, files -> None."""
    root = {}
    for path in file_paths:
        parts = path.split("/")
        node = root
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        leaf = parts[-1]
        if leaf not in node:
            node[leaf] = None
    return root


def count_descendants(node):
    """Count total entries (files + dirs) in the subtree."""
    if node is None:
        return 0
    total = 0
    for child in node.values():
        total += 1
        if child is not None:
            total += count_descendants(child)
    return total


def _navigate(root, path_tuple):
    """Follow path_tuple through the tree, returning the target node."""
    node = root
    for part in path_tuple:
        node = node[part]
    return node


def _follow_single_children(subtree):
    """Collapse single-child directory chains into a merged path.

    Returns (extra_parts, terminal_node) where extra_parts is a list of
    intermediate names traversed and terminal_node is the final node
    (None for a file, dict for a directory with != 1 child).
    """
    extra = []
    node = subtree
    while node is not None and len(node) == 1:
        child_name, child_sub = next(iter(node.items()))
        extra.append(child_name)
        node = child_sub
    return extra, node


def _greedy_expand(root, budget, max_depth):
    """Phase 1: fully expand the cheapest directories first via min-heap."""
    expanded = {()}  # root is always expanded
    heap = []  # (n_direct_children, depth, path_tuple)
    used = len(root)  # top-level entries always shown

    for name, subtree in root.items():
        if subtree is not None:
            heapq.heappush(heap, (len(subtree), 1, (name,)))

    while heap:
        n_children, depth, path_tuple = heapq.heappop(heap)
        if used + n_children > budget:
            continue
        expanded.add(path_tuple)
        used += n_children
        node = _navigate(root, path_tuple)
        if depth < max_depth:
            for name, subtree in node.items():
                if subtree is not None:
                    heapq.heappush(
                        heap, (len(subtree), depth + 1, path_tuple + (name,))
                    )

    return expanded, used


def _partial_expand(root, expanded, used, budget, max_depth):
    """Phase 2: peek into large collapsed dirs with leftover budget."""
    min_peek = 3
    partial = {}  # path_tuple -> n_children_to_show

    collapsed = []

    def collect(node, path_tuple):
        for name, subtree in sorted(node.items()):
            if subtree is None:
                continue
            child_path = path_tuple + (name,)
            if child_path in expanded:
                collect(subtree, child_path)
            elif len(child_path) <= max_depth:
                collapsed.append(child_path)

    collect(root, ())

    remaining = budget - used
    for path_tuple in collapsed:
        if remaining < min_peek + 1:  # +1 for the "... (N more)" line
            break
        node = _navigate(root, path_tuple)
        n_children = len(node)
        show = min(remaining - 1, n_children, 5)
        if show < min_peek:
            continue
        if show >= n_children:
            expanded.add(path_tuple)
            remaining -= n_children
        else:
            partial[path_tuple] = show
            remaining -= show + 1

    return partial


def _render(root, expanded, partial):
    """Walk the tree and produce indented output lines."""
    lines = []

    def walk(node, path_tuple, indent):
        dirs = sorted((k, v) for k, v in node.items() if v is not None)
        files = sorted(k for k, v in node.items() if v is None)
        prefix = "  " * indent

        for name, subtree in dirs:
            child_path = path_tuple + (name,)
            extra, terminal = _follow_single_children(subtree)
            display_name = "/".join([name] + extra)
            terminal_path = child_path + tuple(extra)

            if terminal is None:
                # Chain ended at a file
                lines.append(f"{prefix}{display_name}")
            elif terminal_path in expanded:
                lines.append(f"{prefix}{display_name}/")
                walk(terminal, terminal_path, indent + 1)
            elif terminal_path in partial:
                lines.append(f"{prefix}{display_name}/")
                _render_partial(lines, terminal, indent + 1, partial[terminal_path])
            else:
                n = count_descendants(terminal)
                lines.append(f"{prefix}{display_name}/ ({n} items)")

        for name in files:
            lines.append(f"{prefix}{name}")

    walk(root, (), 0)
    return lines


def _render_partial(lines, node, indent, n_show):
    """Show first n_show children of node, then '... (N more)'."""
    sub_dirs = sorted((k, v) for k, v in node.items() if v is not None)
    sub_files = sorted(k for k, v in node.items() if v is None)
    entries = list(sub_dirs) + [(name, None) for name in sub_files]
    prefix = "  " * indent
    for entry_name, entry_sub in entries[:n_show]:
        if entry_sub is not None:
            extra, terminal = _follow_single_children(entry_sub)
            display_name = "/".join([entry_name] + extra)
            if terminal is None:
                lines.append(f"{prefix}{display_name}")
            else:
                n = count_descendants(terminal)
                lines.append(f"{prefix}{display_name}/ ({n} items)")
        else:
            lines.append(f"{prefix}{entry_name}")
    hidden = len(entries) - n_show
    if hidden > 0:
        lines.append(f"{prefix}... ({hidden} more)")


def generate_tree(root, budget, max_depth):
    """
    Produce an adaptive-depth tree listing.

    Phase 1 -- greedy full expansion:
      A min-heap keyed by (direct_children_count, depth, path) expands
      the cheapest directories first, up to the line budget and max_depth.

    Phase 2 -- partial expansion:
      Collapsed directories whose parent was expanded (and that are within
      max_depth) get a peek: up to a few children are listed, followed by
      "... (N more)". Leftover budget is distributed across candidates in
      tree order.
    """
    expanded, used = _greedy_expand(root, budget, max_depth)
    partial = _partial_expand(root, expanded, used, budget, max_depth)
    return _render(root, expanded, partial)


def main():
    """CLI entry point: parse args, discover files, print the digest."""
    budget = 80
    max_depth = 3
    usage = f"Usage: {sys.argv[0]} [line_budget] [max_depth]"

    if len(sys.argv) > 1:
        try:
            budget = int(sys.argv[1])
        except ValueError:
            print(usage, file=sys.stderr)
            sys.exit(1)
    if len(sys.argv) > 2:
        try:
            max_depth = int(sys.argv[2])
        except ValueError:
            print(usage, file=sys.stderr)
            sys.exit(1)

    paths = get_git_files()
    if paths is None:
        paths = get_find_files()
    if not paths:
        print("(empty directory)")
        return

    root = build_tree(paths)
    for line in generate_tree(root, budget, max_depth):
        print(line)


if __name__ == "__main__":
    main()
