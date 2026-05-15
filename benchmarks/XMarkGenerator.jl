"""
    XMarkGenerator

XMark-inspired XML benchmark data generator.  Produces well-formed XML documents modeling an
internet auction site, following the XMark benchmark DTD structure.

    include("xml_generator.jl")
    using .XMarkGenerator

    xml = generate_xmark(1.0)               # return String (~14 MB)
    generate_xmark("out.xml", 5.0)          # write to file (~68 MB)
    generate_xmark(stdout, 0.1; seed=123)   # write to IO   (~1.4 MB)
"""
module XMarkGenerator

using Random

export generate_xmark

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

#-----------------------------------------------------------------# Random data helpers
rand_word(rng) = rand(rng, WORDS)
rand_date(rng) = string(rand(rng, 1999:2025), "/", lpad(rand(rng, 1:12), 2, '0'), "/", lpad(rand(rng, 1:28), 2, '0'))
rand_time(rng) = string(lpad(rand(rng, 0:23), 2, '0'), ":", lpad(rand(rng, 0:59), 2, '0'), ":", lpad(rand(rng, 0:59), 2, '0'))
rand_price(rng) = string(rand(rng, 1:9999), ".", lpad(rand(rng, 0:99), 2, '0'))
rand_phone(rng) = string("+", rand(rng, 1:99), " (", rand(rng, 100:999), ") ", rand(rng, 1000000:9999999))
rand_zip(rng) = string(lpad(rand(rng, 0:99999), 5, '0'))
rand_cc(rng) = join(rand(rng, 1000:9999, 4), " ")
rand_email(rng) = string(lowercase(rand(rng, FIRST_NAMES)), rand(rng, 1:999), "@", lowercase(rand(rng, LAST_NAMES)), ".com")

#-----------------------------------------------------------------# XML writing helpers
function xml_escape_char(io::IO, c::Char)
    if c == '&';     print(io, "&amp;")
    elseif c == '<'; print(io, "&lt;")
    elseif c == '>'; print(io, "&gt;")
    elseif c == '"'; print(io, "&quot;")
    else;            print(io, c)
    end
end

function write_escaped(io::IO, s::AbstractString)
    for c in s
        xml_escape_char(io, c)
    end
end

function write_text_content(rng, io; min_words=10, max_words=50)
    n = rand(rng, min_words:max_words)
    for i in 1:n
        i > 1 && print(io, ' ')
        w = rand_word(rng)
        r = rand(rng)
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

function write_description(rng, io, indent)
    println(io, indent, "<description>")
    if rand(rng) < 0.7
        print(io, indent, "  <text>")
        write_text_content(rng, io; min_words=15, max_words=80)
        println(io, "</text>")
    else
        println(io, indent, "  <parlist>")
        for _ in 1:rand(rng, 2:6)
            print(io, indent, "    <listitem><text>")
            write_text_content(rng, io; min_words=8, max_words=40)
            println(io, "</text></listitem>")
        end
        println(io, indent, "  </parlist>")
    end
    println(io, indent, "</description>")
end

function write_annotation(rng, io, indent, n_people)
    println(io, indent, "<annotation>")
    println(io, indent, "  <author person=\"", string("person",rand(rng, 1:n_people)), "\"/>")
    write_description(rng, io, string(indent, "  "))
    println(io, indent, "  <happiness>", rand(rng, 1:10), "</happiness>")
    println(io, indent, "</annotation>")
end

#-----------------------------------------------------------------# Section writers
function write_item(rng, io, id, n_categories)
    featured = rand(rng) < 0.1 ? " featured=\"yes\"" : ""
    println(io, "      <item id=\"", string("item",id), "\"", featured, ">")
    println(io, "        <location>", rand(rng, CITIES), "</location>")
    println(io, "        <quantity>", rand(rng, 1:50), "</quantity>")
    println(io, "        <name>", rand_word(rng), " ", rand_word(rng), " ", rand_word(rng), "</name>")
    println(io, "        <payment>", rand(rng, PAYMENTS), "</payment>")
    write_description(rng, io, "        ")
    println(io, "        <shipping>", rand(rng, SHIPPING), "</shipping>")
    for _ in 1:rand(rng, 1:3)
        println(io, "        <incategory category=\"", string("category",rand(rng, 1:n_categories)), "\"/>")
    end
    println(io, "        <mailbox>")
    for _ in 1:rand(rng, 0:5)
        println(io, "          <mail>")
        println(io, "            <from>", rand_email(rng), "</from>")
        println(io, "            <to>", rand_email(rng), "</to>")
        println(io, "            <date>", rand_date(rng), "</date>")
        print(io, "            <text>")
        write_text_content(rng, io; min_words=10, max_words=60)
        println(io, "</text>")
        println(io, "          </mail>")
    end
    println(io, "        </mailbox>")
    println(io, "      </item>")
end

function write_categories(rng, io, n)
    println(io, "  <categories>")
    for i in 1:n
        println(io, "    <category id=\"", string("category",i), "\">")
        println(io, "      <name>", rand_word(rng), " ", rand_word(rng), "</name>")
        write_description(rng, io, "      ")
        println(io, "    </category>")
    end
    println(io, "  </categories>")
end

function write_catgraph(rng, io, n_edges, n_categories)
    println(io, "  <catgraph>")
    for _ in 1:n_edges
        from = string("category",rand(rng, 1:n_categories))
        to = string("category",rand(rng, 1:n_categories))
        println(io, "    <edge from=\"", from, "\" to=\"", to, "\"/>")
    end
    println(io, "  </catgraph>")
end

function write_people(rng, io, n, n_categories, n_open)
    println(io, "  <people>")
    for i in 1:n
        println(io, "    <person id=\"", string("person",i), "\">")
        println(io, "      <name>", rand(rng, FIRST_NAMES), " ", rand(rng, LAST_NAMES), "</name>")
        println(io, "      <emailaddress>", rand_email(rng), "</emailaddress>")
        if rand(rng) < 0.8
            println(io, "      <phone>", rand_phone(rng), "</phone>")
        end
        if rand(rng) < 0.7
            println(io, "      <address>")
            println(io, "        <street>", rand(rng, 1:9999), " ", rand(rng, STREETS), " St</street>")
            println(io, "        <city>", rand(rng, CITIES), "</city>")
            println(io, "        <country>", rand(rng, COUNTRIES), "</country>")
            if rand(rng) < 0.5
                println(io, "        <province>", rand_word(rng), "</province>")
            end
            println(io, "        <zipcode>", rand_zip(rng), "</zipcode>")
            println(io, "      </address>")
        end
        if rand(rng) < 0.5
            println(io, "      <homepage>http://www.", lowercase(rand(rng, LAST_NAMES)), ".com/~",
                lowercase(rand(rng, FIRST_NAMES)), "</homepage>")
        end
        if rand(rng) < 0.6
            println(io, "      <creditcard>", rand_cc(rng), "</creditcard>")
        end
        if rand(rng) < 0.7
            income = rand(rng) < 0.8 ? string(" income=\"", rand(rng, 10000.0:0.01:250000.0), "\"") : ""
            println(io, "      <profile", income, ">")
            for _ in 1:rand(rng, 0:4)
                println(io, "        <interest category=\"", string("category",rand(rng, 1:n_categories)), "\"/>")
            end
            if rand(rng) < 0.8
                println(io, "        <education>", rand(rng, EDUCATIONS), "</education>")
            end
            if rand(rng) < 0.7
                println(io, "        <gender>", rand(rng, GENDERS), "</gender>")
            end
            println(io, "        <business>", rand_word(rng), "</business>")
            if rand(rng) < 0.8
                println(io, "        <age>", rand(rng, 18:85), "</age>")
            end
            println(io, "      </profile>")
        end
        if n_open > 0 && rand(rng) < 0.3
            println(io, "      <watches>")
            for _ in 1:rand(rng, 1:5)
                println(io, "        <watch open_auction=\"", string("open_auction",rand(rng, 1:n_open)), "\"/>")
            end
            println(io, "      </watches>")
        end
        println(io, "    </person>")
    end
    println(io, "  </people>")
end

function write_open_auctions(rng, io, n, n_items, n_people)
    println(io, "  <open_auctions>")
    for i in 1:n
        println(io, "    <open_auction id=\"", string("open_auction",i), "\">")
        println(io, "      <initial>", rand_price(rng), "</initial>")
        if rand(rng) < 0.5
            println(io, "      <reserve>", rand_price(rng), "</reserve>")
        end
        for _ in 1:rand(rng, 0:12)
            println(io, "      <bidder>")
            println(io, "        <date>", rand_date(rng), "</date>")
            println(io, "        <time>", rand_time(rng), "</time>")
            println(io, "        <personref person=\"", string("person",rand(rng, 1:n_people)), "\"/>")
            println(io, "        <increase>", rand_price(rng), "</increase>")
            println(io, "      </bidder>")
        end
        println(io, "      <current>", rand_price(rng), "</current>")
        if rand(rng) < 0.3
            println(io, "      <privacy>", rand(rng, ["Yes", "No"]), "</privacy>")
        end
        println(io, "      <itemref item=\"", string("item",rand(rng, 1:n_items)), "\"/>")
        println(io, "      <seller person=\"", string("person",rand(rng, 1:n_people)), "\"/>")
        write_annotation(rng, io, "      ", n_people)
        println(io, "      <quantity>", rand(rng, 1:10), "</quantity>")
        println(io, "      <type>", rand(rng, ["Regular", "Featured"]), "</type>")
        println(io, "      <interval>")
        println(io, "        <start>", rand_date(rng), "</start>")
        println(io, "        <end>", rand_date(rng), "</end>")
        println(io, "      </interval>")
        println(io, "    </open_auction>")
    end
    println(io, "  </open_auctions>")
end

function write_closed_auctions(rng, io, n, n_open, n_items, n_people)
    println(io, "  <closed_auctions>")
    for i in 1:n
        println(io, "    <closed_auction>")
        println(io, "      <seller person=\"", string("person",rand(rng, 1:n_people)), "\"/>")
        println(io, "      <buyer person=\"", string("person",rand(rng, 1:n_people)), "\"/>")
        # Use item IDs that don't overlap with open auctions
        item_id = n_open + i
        item_id = item_id <= n_items ? item_id : rand(rng, 1:n_items)
        println(io, "      <itemref item=\"", string("item",item_id), "\"/>")
        println(io, "      <price>", rand_price(rng), "</price>")
        println(io, "      <date>", rand_date(rng), "</date>")
        println(io, "      <quantity>", rand(rng, 1:10), "</quantity>")
        println(io, "      <type>", rand(rng, ["Regular", "Featured"]), "</type>")
        if rand(rng) < 0.7
            write_annotation(rng, io, "      ", n_people)
        end
        println(io, "    </closed_auction>")
    end
    println(io, "  </closed_auctions>")
end

#-----------------------------------------------------------------# Main entry points
"""
    generate_xmark([io_or_filename], factor; seed=42)

Generate an XMark-style auction XML document.  `factor` scales all entity counts linearly.

Approximate output sizes (may vary slightly):
- `factor=0.1`  → ~1.4 MB
- `factor=1.0`  → ~14 MB
- `factor=2.0`  → ~27 MB
- `factor=5.0`  → ~68 MB
"""
function generate_xmark(io::IO, factor::Real; seed::Int=42)
    factor > 0 || throw(ArgumentError("factor must be positive, got $factor"))
    rng = Xoshiro(seed)

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
    println(io, "<site>")

    # Regions with items
    println(io, "  <regions>")
    item_id = 0
    for region in REGIONS
        println(io, "    <", region, ">")
        for _ in 1:n_per_region
            item_id += 1
            write_item(rng, io, item_id, n_categories)
        end
        println(io, "    </", region, ">")
    end
    println(io, "  </regions>")

    write_categories(rng, io, n_categories)
    write_catgraph(rng, io, n_edges, n_categories)
    write_people(rng, io, n_people, n_categories, n_open)
    write_open_auctions(rng, io, n_open, n_items, n_people)
    write_closed_auctions(rng, io, n_closed, n_open, n_items, n_people)

    println(io, "</site>")
    nothing
end

function generate_xmark(filename::AbstractString, factor::Real; seed::Int=42)
    open(filename, "w") do io
        generate_xmark(io, factor; seed)
    end
    filename
end

function generate_xmark(factor::Real; seed::Int=42)
    io = IOBuffer()
    generate_xmark(io, factor; seed)
    String(take!(io))
end

end # module
