"""
    XMarkGenerator

XMark-inspired XML benchmark data generator.  Produces well-formed XML documents modeling an
internet auction site, following the XMark benchmark DTD structure.

    include("XMarkGenerator.jl")
    using .XMarkGenerator

    xml = generate_xmark(1.0)               # return String (~14 MB)
    generate_xmark("out.xml", 5.0)          # write to file (~68 MB)
    generate_xmark(stdout, 0.1; seed=123)   # write to IO   (~1.4 MB)
    generate_xmark("twin.xml", 1.0; features=Features(text_every=10))   # opt-in constructions
"""
module XMarkGenerator

using Random

export generate_xmark, Features

"""
    Features(; text_every = 0, attr_every = 0, markup_every = 0, doctype = false)

Constructions the plain document never contains, each off by default, so that the default output is
byte-identical to the document behind the published figures. Placement is deterministic and draws
nothing from the random stream: a document generated with any of these on has the same elements and
attributes as the plain one, in the same order, and differs only where a construction sits.

- `text_every = k`: every k-th word drawn from the vocabulary is replaced by one of `SPECIAL_WORDS`,
  written through the escaping path, so it carries a predefined entity (`R&amp;D`) or a character
  reference (`caf&#233;`; hexadecimal for even code points).
- `attr_every = k`: every k-th `item` and `person` gains a `note` attribute whose value needs
  decoding or XML 1.0 §3.3.3 white-space normalization: a named reference, a character reference, a
  literal tab, a literal newline, or `&quot;`, in rotation (`NOTE_VALUES`).
- `markup_every = k`: every k-th `item` and `person` has its first text child (`location` / `name`)
  written as a CDATA section, followed on the same line by a comment and a processing instruction:
  exactly two nodes more per marked element, and no white-space node added.
- `doctype = true`: the document carries a DOCTYPE holding the element and attribute declarations
  of the schema written here, and no entity declaration.
"""
Base.@kwdef struct Features
    text_every::Int = 0
    attr_every::Int = 0
    markup_every::Int = 0
    doctype::Bool = false
end

# Generation state: the random stream, the requested features, and the number of words drawn so
# far, which places the special words.
mutable struct Gen
    rng::Xoshiro
    feat::Features
    n_word::Int
end

every(k, i) = k > 0 && i % k == 0

#-----------------------------------------------------------------# Word lists
const WORDS = [
    "about", "above", "across", "after", "again", "against", "along", "already", "also",
    "always", "among", "another", "answer", "around", "asked", "away", "back", "because",
    "become", "been", "before", "began", "behind", "being", "below", "between", "body",
    "book", "both", "brought", "build", "built", "business", "came", "cannot", "carry",
    "cause", "certain", "change", "children", "city", "close", "come", "complete", "could",
    "country", "course", "cover", "current", "dark", "days", "deep", "development",
    "different", "direction", "does", "done", "door", "down", "draw", "during", "each",
    "early", "earth", "east", "education", "effort", "eight", "either", "else", "end",
    "enough", "even", "every", "example", "experience", "face", "fact", "family", "feel",
    "field", "find", "first", "five", "follow", "food", "force", "form", "found", "four",
    "from", "full", "gave", "general", "give", "going", "gone", "good", "government",
    "great", "green", "ground", "group", "grow", "half", "hand", "happen", "hard", "have",
    "head", "help", "here", "high", "himself", "hold", "home", "hope", "house", "however",
    "hundred", "idea", "important", "inch", "include", "increase", "island", "just", "keep",
    "kind", "knew", "know", "land", "large", "last", "later", "learn", "left", "less",
    "letter", "life", "light", "like", "line", "list", "little", "live", "long", "look",
    "lost", "made", "main", "make", "many", "mark", "matter", "mean", "might", "mind",
    "miss", "money", "morning", "most", "mother", "move", "much", "music", "must", "name",
    "near", "need", "never", "next", "night", "nothing", "notice", "number", "often",
    "once", "only", "open", "order", "other", "over", "page", "paper", "part", "past",
    "pattern", "people", "perhaps", "period", "person", "picture", "place", "plan", "plant",
    "play", "point", "position", "possible", "power", "present", "problem", "produce",
    "product", "program", "public", "pull", "purpose", "question", "quite", "reach", "read",
    "real", "receive", "record", "remember", "rest", "result", "right", "river", "room",
    "round", "rule", "same", "school", "second", "seem", "sentence", "service", "seven",
    "several", "shall", "short", "should", "show", "side", "since", "sing", "size", "small",
    "social", "some", "song", "soon", "south", "space", "stand", "start", "state", "still",
    "stood", "story", "strong", "study", "such", "sure", "system", "table", "take", "tell",
    "test", "their", "them", "then", "there", "these", "thing", "think", "those", "thought",
    "three", "through", "time", "together", "took", "toward", "travel", "tree", "true",
    "turn", "under", "unit", "until", "upon", "usually", "value", "very", "voice", "walk",
    "want", "watch", "water", "well", "went", "were", "west", "what", "where", "which",
    "while", "white", "whole", "will", "with", "without", "woman", "word", "work", "world",
    "would", "write", "year", "young",
]
const FIRST_NAMES = ["James", "John", "Robert", "Michael", "William", "David", "Richard",
    "Joseph", "Thomas", "Charles", "Mary", "Patricia", "Jennifer", "Linda", "Barbara",
    "Elizabeth", "Susan", "Jessica", "Sarah", "Karen"]
const LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
    "Davis", "Rodriguez", "Martinez", "Wilson", "Anderson", "Taylor", "Thomas", "Hernandez",
    "Moore", "Martin", "Jackson", "Thompson", "White"]
const COUNTRIES = ["United States", "Germany", "France", "Japan", "Australia", "Brazil",
    "Canada", "India", "China", "Mexico", "Argentina", "Spain", "Italy", "United Kingdom",
    "Netherlands", "Sweden", "Norway", "Finland", "Denmark", "Belgium"]
const CITIES = ["New York", "London", "Paris", "Tokyo", "Sydney", "Berlin", "Rome",
    "Madrid", "Amsterdam", "Toronto", "Moscow", "Beijing", "Seoul", "Mumbai", "Cairo",
    "Dublin", "Prague", "Vienna", "Warsaw", "Budapest"]
const STREETS = ["Main", "Oak", "Elm", "Maple", "Pine", "Cedar", "Birch", "Walnut",
    "Cherry", "Ash", "Spruce", "Willow", "Poplar", "Laurel", "Juniper"]
const EDUCATIONS = ["High School", "College", "Graduate", "Associate", "Master", "Doctorate"]
const GENDERS = ["male", "female"]
const PAYMENTS = ["Creditcard", "Money order", "Personal check", "Cash"]
const SHIPPING = ["Will ship only within country", "Will ship internationally",
    "Buyer pays fixed shipping costs", "Free shipping", "See description for shipping"]
const REGIONS = ["africa", "asia", "australia", "europe", "namerica", "samerica"]

# Words the escaping path has to work on: markup characters, which become predefined entities, and
# non-ASCII letters, which become character references. Reached only through `Features.text_every`.
const SPECIAL_WORDS = ["R&D", "AT&T", "Tom & Jerry", "<bold>", "a < b", "x > y", "\"quoted\"",
                       "café", "naïve", "Zoë", "über", "señor", "façade", "€uro", "—", "…"]

# Source text of the `note` attribute of `Features.attr_every`, one shape per marked element in
# rotation: a named reference, character references, a literal tab, a literal newline, `&quot;`.
const NOTE_VALUES = ["Tom &amp; Jerry", "caf&#233; &#x2014; th&#233;", "tab\there",
                     "line one\nline two", "&quot;quoted&quot;"]

# The schema of the document written below, for `Features.doctype`: every element and attribute
# it emits, no entity, no default value.
const DOCTYPE = """
<!DOCTYPE site [
<!ELEMENT site (regions, categories, catgraph, people, open_auctions, closed_auctions)>
<!ELEMENT regions (africa, asia, australia, europe, namerica, samerica)>
<!ELEMENT africa (item*)>
<!ELEMENT asia (item*)>
<!ELEMENT australia (item*)>
<!ELEMENT europe (item*)>
<!ELEMENT namerica (item*)>
<!ELEMENT samerica (item*)>
<!ELEMENT item (location, quantity, name, payment, description, shipping, incategory+, mailbox)>
<!ATTLIST item id ID #REQUIRED featured CDATA #IMPLIED note CDATA #IMPLIED>
<!ELEMENT location (#PCDATA)>
<!ELEMENT quantity (#PCDATA)>
<!ELEMENT name (#PCDATA)>
<!ELEMENT payment (#PCDATA)>
<!ELEMENT description (text | parlist)>
<!ELEMENT text (#PCDATA | bold | emph | keyword)*>
<!ELEMENT bold (#PCDATA)>
<!ELEMENT emph (#PCDATA)>
<!ELEMENT keyword (#PCDATA)>
<!ELEMENT parlist (listitem+)>
<!ELEMENT listitem (text)>
<!ELEMENT shipping (#PCDATA)>
<!ELEMENT incategory EMPTY>
<!ATTLIST incategory category IDREF #REQUIRED>
<!ELEMENT mailbox (mail*)>
<!ELEMENT mail (from, to, date, text)>
<!ELEMENT from (#PCDATA)>
<!ELEMENT to (#PCDATA)>
<!ELEMENT date (#PCDATA)>
<!ELEMENT categories (category+)>
<!ELEMENT category (name, description)>
<!ATTLIST category id ID #REQUIRED>
<!ELEMENT catgraph (edge*)>
<!ELEMENT edge EMPTY>
<!ATTLIST edge from IDREF #REQUIRED to IDREF #REQUIRED>
<!ELEMENT people (person*)>
<!ELEMENT person (name, emailaddress, phone?, address?, homepage?, creditcard?, profile?, watches?)>
<!ATTLIST person id ID #REQUIRED note CDATA #IMPLIED>
<!ELEMENT emailaddress (#PCDATA)>
<!ELEMENT phone (#PCDATA)>
<!ELEMENT address (street, city, country, province?, zipcode)>
<!ELEMENT street (#PCDATA)>
<!ELEMENT city (#PCDATA)>
<!ELEMENT country (#PCDATA)>
<!ELEMENT province (#PCDATA)>
<!ELEMENT zipcode (#PCDATA)>
<!ELEMENT homepage (#PCDATA)>
<!ELEMENT creditcard (#PCDATA)>
<!ELEMENT profile (interest*, education?, gender?, business, age?)>
<!ATTLIST profile income CDATA #IMPLIED>
<!ELEMENT interest EMPTY>
<!ATTLIST interest category IDREF #REQUIRED>
<!ELEMENT education (#PCDATA)>
<!ELEMENT gender (#PCDATA)>
<!ELEMENT business (#PCDATA)>
<!ELEMENT age (#PCDATA)>
<!ELEMENT watches (watch*)>
<!ELEMENT watch EMPTY>
<!ATTLIST watch open_auction IDREF #REQUIRED>
<!ELEMENT open_auctions (open_auction*)>
<!ELEMENT open_auction (initial, reserve?, bidder*, current, privacy?, itemref, seller, annotation, quantity, type, interval)>
<!ATTLIST open_auction id ID #REQUIRED>
<!ELEMENT initial (#PCDATA)>
<!ELEMENT reserve (#PCDATA)>
<!ELEMENT bidder (date, time, personref, increase)>
<!ELEMENT time (#PCDATA)>
<!ELEMENT personref EMPTY>
<!ATTLIST personref person IDREF #REQUIRED>
<!ELEMENT increase (#PCDATA)>
<!ELEMENT current (#PCDATA)>
<!ELEMENT privacy (#PCDATA)>
<!ELEMENT itemref EMPTY>
<!ATTLIST itemref item IDREF #REQUIRED>
<!ELEMENT seller EMPTY>
<!ATTLIST seller person IDREF #REQUIRED>
<!ELEMENT annotation (author, description, happiness)>
<!ELEMENT author EMPTY>
<!ATTLIST author person IDREF #REQUIRED>
<!ELEMENT happiness (#PCDATA)>
<!ELEMENT type (#PCDATA)>
<!ELEMENT interval (start, end)>
<!ELEMENT start (#PCDATA)>
<!ELEMENT end (#PCDATA)>
<!ELEMENT closed_auctions (closed_auction*)>
<!ELEMENT closed_auction (seller, buyer, itemref, price, date, quantity, type, annotation?)>
<!ELEMENT buyer EMPTY>
<!ATTLIST buyer person IDREF #REQUIRED>
<!ELEMENT price (#PCDATA)>
]>"""

#-----------------------------------------------------------------# Random data helpers
# The draw is always taken, so the random stream is the same with the feature on or off; the
# special word only replaces what was drawn.
function rand_word(g)
    w = rand(g.rng, WORDS)
    k = g.feat.text_every
    k == 0 && return w
    g.n_word += 1
    g.n_word % k == 0 || return w
    xml_text(SPECIAL_WORDS[(g.n_word ÷ k - 1) % length(SPECIAL_WORDS) + 1])
end
rand_date(g) = string(rand(g.rng, 1999:2025), "/", lpad(rand(g.rng, 1:12), 2, '0'), "/", lpad(rand(g.rng, 1:28), 2, '0'))
rand_time(g) = string(lpad(rand(g.rng, 0:23), 2, '0'), ":", lpad(rand(g.rng, 0:59), 2, '0'), ":", lpad(rand(g.rng, 0:59), 2, '0'))
rand_price(g) = string(rand(g.rng, 1:9999), ".", lpad(rand(g.rng, 0:99), 2, '0'))
rand_phone(g) = string("+", rand(g.rng, 1:99), " (", rand(g.rng, 100:999), ") ", rand(g.rng, 1000000:9999999))
rand_zip(g) = string(lpad(rand(g.rng, 0:99999), 5, '0'))
rand_cc(g) = join(rand(g.rng, 1000:9999, 4), " ")
rand_email(g) = string(lowercase(rand(g.rng, FIRST_NAMES)), rand(g.rng, 1:999), "@", lowercase(rand(g.rng, LAST_NAMES)), ".com")

#-----------------------------------------------------------------# XML writing helpers
# The escaping path: markup characters become the predefined entities, and a character outside
# ASCII becomes a character reference, decimal for an odd code point and hexadecimal for an even
# one, so both forms of XML 1.0 §4.1 reach the readers.
function xml_escape_char(io::IO, c::Char)
    if c == '&';     print(io, "&amp;")
    elseif c == '<'; print(io, "&lt;")
    elseif c == '>'; print(io, "&gt;")
    elseif c == '"'; print(io, "&quot;")
    elseif isascii(c); print(io, c)
    else
        cp = UInt32(c)
        iseven(cp) ? print(io, "&#x", string(cp; base = 16), ';') : print(io, "&#", cp, ';')
    end
end

function write_escaped(io::IO, s::AbstractString)
    for c in s
        xml_escape_char(io, c)
    end
end

xml_text(s::AbstractString) = sprint(write_escaped, s)

# The `note` attribute of `Features.attr_every`, or nothing at all.
function note_attr(g, i)
    k = g.feat.attr_every
    every(k, i) || return ""
    string(" note=\"", NOTE_VALUES[(i ÷ k - 1) % length(NOTE_VALUES) + 1], "\"")
end

# A one-line text element. On an element marked by `Features.markup_every` the text is a CDATA
# section and a comment and a processing instruction follow on the same line, so the only
# difference from the plain document is those two nodes.
function write_text_line(g, io, i, what, open, text, close)
    marked = every(g.feat.markup_every, i)
    print(io, open)
    marked ? print(io, "<![CDATA[", text, "]]>") : print(io, text)
    print(io, close)
    marked && print(io, "<!-- ", what, " ", i, ": a comment --><?review ", what, "=\"", i, "\"?>")
    println(io)
end

function write_text_content(g, io; min_words=10, max_words=50)
    n = rand(g.rng, min_words:max_words)
    for i in 1:n
        i > 1 && print(io, ' ')
        w = rand_word(g)
        r = rand(g.rng)
        if r < 0.03
            print(io, "<bold>", w, "</bold>")
        elseif r < 0.06
            print(io, "<emph>", w, "</emph>")
        elseif r < 0.08
            print(io, "<keyword>", w, "</keyword>")
        else
            print(io, w)
        end
    end
end

function write_description(g, io, indent)
    println(io, indent, "<description>")
    if rand(g.rng) < 0.7
        print(io, indent, "  <text>")
        write_text_content(g, io; min_words=15, max_words=80)
        println(io, "</text>")
    else
        println(io, indent, "  <parlist>")
        for _ in 1:rand(g.rng, 2:6)
            print(io, indent, "    <listitem><text>")
            write_text_content(g, io; min_words=8, max_words=40)
            println(io, "</text></listitem>")
        end
        println(io, indent, "  </parlist>")
    end
    println(io, indent, "</description>")
end

function write_annotation(g, io, indent, n_people)
    println(io, indent, "<annotation>")
    println(io, indent, "  <author person=\"", string("person",rand(g.rng, 1:n_people)), "\"/>")
    write_description(g, io, string(indent, "  "))
    println(io, indent, "  <happiness>", rand(g.rng, 1:10), "</happiness>")
    println(io, indent, "</annotation>")
end

#-----------------------------------------------------------------# Section writers
function write_item(g, io, id, n_categories)
    featured = rand(g.rng) < 0.1 ? " featured=\"yes\"" : ""
    println(io, "      <item id=\"", string("item",id), "\"", featured, note_attr(g, id), ">")
    write_text_line(g, io, id, "item", "        <location>", rand(g.rng, CITIES), "</location>")
    println(io, "        <quantity>", rand(g.rng, 1:50), "</quantity>")
    println(io, "        <name>", rand_word(g), " ", rand_word(g), " ", rand_word(g), "</name>")
    println(io, "        <payment>", rand(g.rng, PAYMENTS), "</payment>")
    write_description(g, io, "        ")
    println(io, "        <shipping>", rand(g.rng, SHIPPING), "</shipping>")
    for _ in 1:rand(g.rng, 1:3)
        println(io, "        <incategory category=\"", string("category",rand(g.rng, 1:n_categories)), "\"/>")
    end
    println(io, "        <mailbox>")
    for _ in 1:rand(g.rng, 0:5)
        println(io, "          <mail>")
        println(io, "            <from>", rand_email(g), "</from>")
        println(io, "            <to>", rand_email(g), "</to>")
        println(io, "            <date>", rand_date(g), "</date>")
        print(io, "            <text>")
        write_text_content(g, io; min_words=10, max_words=60)
        println(io, "</text>")
        println(io, "          </mail>")
    end
    println(io, "        </mailbox>")
    println(io, "      </item>")
end

function write_categories(g, io, n)
    println(io, "  <categories>")
    for i in 1:n
        println(io, "    <category id=\"", string("category",i), "\">")
        println(io, "      <name>", rand_word(g), " ", rand_word(g), "</name>")
        write_description(g, io, "      ")
        println(io, "    </category>")
    end
    println(io, "  </categories>")
end

function write_catgraph(g, io, n_edges, n_categories)
    println(io, "  <catgraph>")
    for _ in 1:n_edges
        from = string("category",rand(g.rng, 1:n_categories))
        to = string("category",rand(g.rng, 1:n_categories))
        println(io, "    <edge from=\"", from, "\" to=\"", to, "\"/>")
    end
    println(io, "  </catgraph>")
end

function write_people(g, io, n, n_categories, n_open)
    println(io, "  <people>")
    for i in 1:n
        println(io, "    <person id=\"", string("person",i), "\"", note_attr(g, i), ">")
        write_text_line(g, io, i, "person", "      <name>",
                        string(rand(g.rng, FIRST_NAMES), " ", rand(g.rng, LAST_NAMES)), "</name>")
        println(io, "      <emailaddress>", rand_email(g), "</emailaddress>")
        if rand(g.rng) < 0.8
            println(io, "      <phone>", rand_phone(g), "</phone>")
        end
        if rand(g.rng) < 0.7
            println(io, "      <address>")
            println(io, "        <street>", rand(g.rng, 1:9999), " ", rand(g.rng, STREETS), " St</street>")
            println(io, "        <city>", rand(g.rng, CITIES), "</city>")
            println(io, "        <country>", rand(g.rng, COUNTRIES), "</country>")
            if rand(g.rng) < 0.5
                println(io, "        <province>", rand_word(g), "</province>")
            end
            println(io, "        <zipcode>", rand_zip(g), "</zipcode>")
            println(io, "      </address>")
        end
        if rand(g.rng) < 0.5
            println(io, "      <homepage>http://www.", lowercase(rand(g.rng, LAST_NAMES)), ".com/~",
                lowercase(rand(g.rng, FIRST_NAMES)), "</homepage>")
        end
        if rand(g.rng) < 0.6
            println(io, "      <creditcard>", rand_cc(g), "</creditcard>")
        end
        if rand(g.rng) < 0.7
            income = rand(g.rng) < 0.8 ? string(" income=\"", rand(g.rng, 10000.0:0.01:250000.0), "\"") : ""
            println(io, "      <profile", income, ">")
            for _ in 1:rand(g.rng, 0:4)
                println(io, "        <interest category=\"", string("category",rand(g.rng, 1:n_categories)), "\"/>")
            end
            if rand(g.rng) < 0.8
                println(io, "        <education>", rand(g.rng, EDUCATIONS), "</education>")
            end
            if rand(g.rng) < 0.7
                println(io, "        <gender>", rand(g.rng, GENDERS), "</gender>")
            end
            println(io, "        <business>", rand_word(g), "</business>")
            if rand(g.rng) < 0.8
                println(io, "        <age>", rand(g.rng, 18:85), "</age>")
            end
            println(io, "      </profile>")
        end
        if n_open > 0 && rand(g.rng) < 0.3
            println(io, "      <watches>")
            for _ in 1:rand(g.rng, 1:5)
                println(io, "        <watch open_auction=\"", string("open_auction",rand(g.rng, 1:n_open)), "\"/>")
            end
            println(io, "      </watches>")
        end
        println(io, "    </person>")
    end
    println(io, "  </people>")
end

function write_open_auctions(g, io, n, n_items, n_people)
    println(io, "  <open_auctions>")
    for i in 1:n
        println(io, "    <open_auction id=\"", string("open_auction",i), "\">")
        println(io, "      <initial>", rand_price(g), "</initial>")
        if rand(g.rng) < 0.5
            println(io, "      <reserve>", rand_price(g), "</reserve>")
        end
        for _ in 1:rand(g.rng, 0:12)
            println(io, "      <bidder>")
            println(io, "        <date>", rand_date(g), "</date>")
            println(io, "        <time>", rand_time(g), "</time>")
            println(io, "        <personref person=\"", string("person",rand(g.rng, 1:n_people)), "\"/>")
            println(io, "        <increase>", rand_price(g), "</increase>")
            println(io, "      </bidder>")
        end
        println(io, "      <current>", rand_price(g), "</current>")
        if rand(g.rng) < 0.3
            println(io, "      <privacy>", rand(g.rng, ["Yes", "No"]), "</privacy>")
        end
        println(io, "      <itemref item=\"", string("item",rand(g.rng, 1:n_items)), "\"/>")
        println(io, "      <seller person=\"", string("person",rand(g.rng, 1:n_people)), "\"/>")
        write_annotation(g, io, "      ", n_people)
        println(io, "      <quantity>", rand(g.rng, 1:10), "</quantity>")
        println(io, "      <type>", rand(g.rng, ["Regular", "Featured"]), "</type>")
        println(io, "      <interval>")
        println(io, "        <start>", rand_date(g), "</start>")
        println(io, "        <end>", rand_date(g), "</end>")
        println(io, "      </interval>")
        println(io, "    </open_auction>")
    end
    println(io, "  </open_auctions>")
end

function write_closed_auctions(g, io, n, n_open, n_items, n_people)
    println(io, "  <closed_auctions>")
    for i in 1:n
        println(io, "    <closed_auction>")
        println(io, "      <seller person=\"", string("person",rand(g.rng, 1:n_people)), "\"/>")
        println(io, "      <buyer person=\"", string("person",rand(g.rng, 1:n_people)), "\"/>")
        # Use item IDs that don't overlap with open auctions
        item_id = n_open + i
        item_id = item_id <= n_items ? item_id : rand(g.rng, 1:n_items)
        println(io, "      <itemref item=\"", string("item",item_id), "\"/>")
        println(io, "      <price>", rand_price(g), "</price>")
        println(io, "      <date>", rand_date(g), "</date>")
        println(io, "      <quantity>", rand(g.rng, 1:10), "</quantity>")
        println(io, "      <type>", rand(g.rng, ["Regular", "Featured"]), "</type>")
        if rand(g.rng) < 0.7
            write_annotation(g, io, "      ", n_people)
        end
        println(io, "    </closed_auction>")
    end
    println(io, "  </closed_auctions>")
end

#-----------------------------------------------------------------# Main entry points
"""
    generate_xmark([io_or_filename], factor; seed=42, features=Features())

Generate an XMark-style auction XML document.  `factor` scales all entity counts linearly;
`features` turns on the constructions the plain document never contains (see `Features`).

Approximate output sizes (may vary slightly):
- `factor=0.1`  → ~1.4 MB
- `factor=1.0`  → ~14 MB
- `factor=2.0`  → ~27 MB
- `factor=5.0`  → ~68 MB
"""
function generate_xmark(io::IO, factor::Real; seed::Int=42, features::Features=Features())
    factor > 0 || throw(ArgumentError("factor must be positive, got $factor"))
    g = Gen(Xoshiro(seed), features, 0)

    n_per_region = max(1, round(Int, 500  * factor))
    n_people     = max(1, round(Int, 5000 * factor))
    n_categories = max(1, round(Int, 200  * factor))
    n_open       = max(1, round(Int, 2000 * factor))
    n_closed     = max(1, round(Int, 1500 * factor))
    n_edges      = max(1, round(Int, 1000 * factor))
    n_items      = n_per_region * 6

    # Clamp auctions to available items
    n_open   = min(n_open, n_items)
    n_closed = min(n_closed, max(1, n_items - n_open))

    println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    features.doctype && println(io, DOCTYPE)
    println(io, "<site>")

    # Regions with items
    println(io, "  <regions>")
    item_id = 0
    for region in REGIONS
        println(io, "    <", region, ">")
        for _ in 1:n_per_region
            item_id += 1
            write_item(g, io, item_id, n_categories)
        end
        println(io, "    </", region, ">")
    end
    println(io, "  </regions>")

    write_categories(g, io, n_categories)
    write_catgraph(g, io, n_edges, n_categories)
    write_people(g, io, n_people, n_categories, n_open)
    write_open_auctions(g, io, n_open, n_items, n_people)
    write_closed_auctions(g, io, n_closed, n_open, n_items, n_people)

    println(io, "</site>")
    nothing
end

function generate_xmark(filename::AbstractString, factor::Real; seed::Int=42, features::Features=Features())
    open(filename, "w") do io
        generate_xmark(io, factor; seed, features)
    end
    filename
end

function generate_xmark(factor::Real; seed::Int=42, features::Features=Features())
    io = IOBuffer()
    generate_xmark(io, factor; seed, features)
    String(take!(io))
end

end # module
