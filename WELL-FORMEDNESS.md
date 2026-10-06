# Well-formedness and validation in XML.jl

XML.jl checks that a document is well-formed, at three levels. It never checks that a document is valid: it is a non-validating processor. This page says what each level rejects, what validation would add, and when an undeclared entity is an error. The README gives the [short version](README.md#well-formedness-and-validation-checks).

## Well-formed and valid

XML 1.0 distinguishes the two. A [well-formed](https://www.w3.org/TR/xml/#sec-well-formed) document follows the XML grammar and its well-formedness constraints. A [valid](https://www.w3.org/TR/xml/#dt-valid) document is well-formed and also conforms to its DTD.

| | well-formedness | validity |
|---|---|---|
| what is checked | the XML syntax and its constraints: matched tags, one root, unique attributes, allowed characters | the document against its DTD: allowed content, required attributes, types, unique IDs |
| who must check | every XML processor | only a validating processor, when the user asks |
| on failure | a [fatal error](https://www.w3.org/TR/xml/#dt-fatal): it must be reported, and normal processing must stop | an [error](https://www.w3.org/TR/xml/#dt-error): it may be reported, and processing may go on |
| what must be read | the document and its internal subset | every declaration, external ones included |

## What XML.jl does not check

XML 1.0 defines two [classes of processors](https://www.w3.org/TR/xml/#proc-types), and XML.jl is a non-validating one. It never checks what `<!ELEMENT>` allows, `#REQUIRED` attributes or the uniqueness of IDs: `<!DOCTYPE doc [<!ATTLIST doc a CDATA #REQUIRED>]><doc/>` is accepted at every level.

| | validating processor | non-validating processor |
|---|---|---|
| well-formedness | must report every violation | must report every violation |
| validity | must report every violation, when the user asks | need not check it |
| what it must read | the whole DTD and every external entity referenced | the document and its whole internal subset |
| internal-subset declarations it must process | all of them | those before the first parameter-entity reference it does not read, or all of them under `standalone="yes"` |

## The three levels

`Node` and `FlatNode` take a `wellformed` keyword with three levels: `:lenient`, `:structural`, the default, and `:strict`. The levels grade the well-formedness check by how much it covers and what it costs. XML 1.0 has no such degrees, and only `:strict` aims at all of its constraints. `:lenient` lets some errors through, to read a fragment or a DTD file on its own. `:structural` does not reread every text and every attribute value. A level rejects its own row and every row above it:

| level | rejects |
|---|---|
| every level, `:lenient` included | mismatched or unclosed tags; an attribute written twice; an entity that refers to itself; an entity expansion beyond 40 levels or 64 MiB; replacement text that is not balanced |
| `:structural`, the default | several root elements or none; text outside the root; an invalid element name; `<` in an attribute value; a misplaced XML declaration or DOCTYPE |
| `:strict` | `--` in a comment; an invalid processing-instruction target; a character outside the allowed range; a reference to an undeclared entity where that rule applies (see [below](#undeclared-entities)), to an unparsed entity, or to an external entity from an attribute value; a parameter-entity reference inside a declaration; a default value that holds `<` |

Every row is a well-formedness rule. The first row comes with building a tree: a reader must know which element each end tag closes, and which value each attribute name holds. The entity rules of that row are checked when the document is read in, by all four readers.

```julia
parse("<a/><b/>", Node)                         # ERROR: not well-formed: multiple root elements (found 2)
parse("<a/><b/>", Node; wellformed = :lenient)  # Document (2 children)
```

What `:strict` costs, by document shape, is in [Table 7](PERFORMANCE-v0.4.md#well-formedness-levels).

## Streaming readers

`Cursor` and `LazyNode` take no `wellformed` keyword and check nothing else: they accept mismatched tags and even a truncated document. When a document must be checked, read it with `Node` or `FlatNode`.

## Undeclared entities

An undeclared entity is not always an error. The [Entity Declared](https://www.w3.org/TR/xml/#wf-entdeclared) constraint applies only to a document without a DTD, to one whose DTD is an internal subset with no parameter-entity reference, or to one declared `standalone="yes"`. Elsewhere, the declaration may be in an external part that XML.jl does not read. The undeclared name is then a [validity error](https://www.w3.org/TR/xml/#vc-entdeclared), and `:strict` accepts the document:

```julia
parse("<r>&nbsp;</r>", Node; wellformed = :strict)
# ERROR: not well-formed: reference to undeclared entity "&nbsp;" (XML 1.0 §4.1)
parse("<!DOCTYPE r SYSTEM \"r.dtd\"><r>&nbsp;</r>", Node; wellformed = :strict)
# Document (2 children); the text keeps "&nbsp;" as written
```

## In short

`:strict` does not validate, and a document it accepts may still be invalid. `:lenient` still rejects the first row of the table of levels.
