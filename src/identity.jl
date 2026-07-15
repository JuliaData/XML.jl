# Structural `==`/`hash` bindings shared by the three tree readers — and across them —
# plus `issamenode`, the positional-identity predicate. The comparison/hash kernels live
# in node.jl; the bindings live here because the Union below needs every reader type
# defined first.

const _TreeNode = Union{Node, LazyNode, FlatNode}

Base.:(==)(a::_TreeNode, b::_TreeNode) = _structural_eq(a, b)
Base.hash(o::_TreeNode, h::UInt) = _structural_hash(o, h)

"""
    issamenode(a, b) -> Bool

Whether `a` and `b` are handles to the same node of the same parsed document — positional
identity, which neither `==` (structural equality of decoded content) nor `===` (egal is
content-based on immutable handles) can express.

Defined for the handle readers `LazyNode` and `FlatNode`. A `Node` is a self-contained
value with no document anchor, so positional identity does not apply to it.
"""
issamenode(a::FlatNode, b::FlatNode) = a.store === b.store && a.i == b.i
issamenode(a::LazyNode, b::LazyNode) = a.data === b.data && a.token === b.token
