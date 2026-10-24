# Well-formedness and validation in XML.jl

XML.jl checks that a document is well-formed, at three levels. It never checks that a document is valid: it is a non-validating processor. This page says what each level rejects, what validation would add, how the declarations of the internal subset are read, and when an undeclared entity is an error. The README gives the [short version](README.md#well-formedness-and-validation-checks).

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
| every level, `:lenient` included | mismatched or unclosed tags<br>an attribute written twice<br>an entity that refers to itself<br>entities nested more than 40 levels deep<br>declarations that cost more than their bounds (see [below](#what-the-declarations-may-cost))<br>replacement text that is not balanced |
| `:structural`, the default | several root elements or none<br>text outside the root<br>an invalid element name<br>`<` in an attribute value<br>a misplaced XML declaration or DOCTYPE |
| `:strict` | `--` in a comment<br>an invalid processing-instruction target<br>a character outside the allowed range<br>a reference to an undeclared entity where that rule applies (see [below](#undeclared-entities)), to an unparsed entity, or to an external entity from an attribute value<br>a parameter-entity reference inside a declaration<br>a default value that holds `<`<br>an ATTLIST declaration its reader cannot follow (see [below](#declarations-of-the-internal-subset)) |

Every row is a well-formedness rule. The first row comes with building a tree: a reader must know which element each end tag closes, and which value each attribute name holds. The entity rules of that row are checked when the document is read in, by all four readers.

```julia
parse("<a/><b/>", Node)                         # ERROR: not well-formed: multiple root elements (found 2)
parse("<a/><b/>", Node; wellformed = :lenient)  # Document (2 children)
```

What `:strict` costs, by document shape, is in [Table 7](PERFORMANCE-v0.4.md#well-formedness-levels).

## Declarations of the internal subset

XML.jl reads the declarations of the internal subset for what they supply: the values of entities and the default values of attributes. It does not check all of their syntax, even under `:strict`:

- an ENTITY declaration that lacks a required space is read all the same: `<!ENTITYe "x">` declares `e`;
- an ATTLIST declaration that its reader cannot follow, such as one with a missing space or a misspelled keyword, is ignored whole below `:strict`, and supplies no default value; `:strict` refuses it;
- the inside of an enumeration in an ATTLIST, between its parentheses, is not checked;
- ELEMENT and NOTATION declarations are skipped to their `>`, since a non-validating processor does not use them.

In a declaration, a no-break space (U+00A0) reads as white space before a name, and as part of the name after it.

## What the declarations may cost

The declarations of a DOCTYPE can make a small document costly to read: an entity can name another one many times, and a default value is copied into every start tag of its element. Every reader, at every level, refuses a document whose declarations pass two bounds at once on one of two counts:

- the bytes read, those of the document and those of the entity texts it includes, beyond 8 MiB and beyond 100 times the size of the document;
- the size of the document once its declarations are applied, beyond 64 MiB and beyond 100 times its own size.

A large document is thus read whatever its size, as long as its declarations do not make it more than 100 times larger. For example, `<!ENTITY z0 "">`, named ten times by `z1`, itself named ten times by `z2`, and so on up to `z7`, would make a 426-byte document read 44 MB of entity text. It is refused after 8 MiB, although the rewritten document would be no larger. The two counts follow those of [Expat](https://libexpat.github.io/), with its values: 8 MiB and 100 times for what it reads, 64 MiB and 100 times for the memory it allocates.

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
