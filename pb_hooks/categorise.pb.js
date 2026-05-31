/// pb_hooks/categorise.pb.js
///
/// After a shopping_item is created, calls Claude Haiku to categorise it and
/// patches the record's category + aisle_order fields.
///
/// Mutates e.record directly so PocketBase includes the correct category in
/// the HTTP response body — the client gets the right section immediately
/// without needing to wait for a separate realtime event.
///
/// The outer try/catch guarantees that Claude errors never propagate up and
/// cause PocketBase to return a 400 to the client.
///
/// Setup: set ANTHROPIC_API_KEY in the PocketBase Docker container, e.g.:
///   environment:
///     ANTHROPIC_API_KEY: sk-ant-...

onRecordAfterCreateSuccess((e) => {
    try {
        // Category → aisle order (mirrors ItemCategory in the Swift client).
        // Defined inside the callback — top-level consts are not reliable in
        // PocketBase's JS hook runtime.
        const CATEGORIES = {
            "Fruit & Veg":            1,
            "Meat & Seafood":         2,
            "Deli":                   3,
            "Bakery":                 4,
            "Dairy & Eggs":           5,
            "Frozen":                 6,
            "Pantry":                 7,
            "Breakfast":              8,
            "Snacks & Confectionery": 9,
            "Drinks":                 10,
            "Condiments & Sauces":    11,
            "Baking":                 12,
            "International":          13,
            "Health & Beauty":        14,
            "Cleaning & Laundry":     15,
            "Household":              16,
            "Pet":                    17,
            "Baby":                   18,
            "Other":                  19,
        }

        const apiKey = $os.getenv("ANTHROPIC_API_KEY")
        if (!apiKey) return  // no key — item stays "Other", no error

        const itemName = e.record.getString("name")
        if (!itemName) return

        const categoryNames = Object.keys(CATEGORIES)
            .filter((c) => c !== "Other")
            .join(", ")

        const prompt =
            "Categorise this grocery item into exactly one Woolworths supermarket aisle.\n" +
            "Item: \"" + itemName + "\"\n\n" +
            "Reply with ONLY the category name, nothing else. Choose from:\n" +
            categoryNames + ", Other"

        let res
        try {
            res = $http.send({
                url:    "https://api.anthropic.com/v1/messages",
                method: "POST",
                headers: {
                    "content-type":      "application/json",
                    "x-api-key":         apiKey,
                    "anthropic-version": "2023-06-01",
                },
                body: JSON.stringify({
                    model:      "claude-haiku-4-5-20251001",
                    max_tokens: 20,
                    messages:   [{ role: "user", content: prompt }],
                }),
                timeout: 15,
            })
        } catch (err) {
            console.error("[categorise] HTTP error for \"" + itemName + "\":", err)
            return
        }

        if (res.statusCode !== 200) {
            console.error("[categorise] API error " + res.statusCode + " for \"" + itemName + "\":", res.raw)
            return
        }

        const text = (
            (res.json && res.json.content && res.json.content[0] && res.json.content[0].text) || ""
        ).trim()

        if (!text || !(text in CATEGORIES)) {
            console.log("[categorise] Unexpected response for \"" + itemName + "\": \"" + text + "\" — leaving as Other")
            return
        }

        // Mutate e.record directly so PocketBase serialises the updated fields
        // into the HTTP response.  The client receives the correct category in
        // the createItem reply itself — no realtime event needed for the person
        // who added the item (SSE still fires the update for partners).
        e.record.set("category",    text)
        e.record.set("aisle_order", CATEGORIES[text])
        $app.save(e.record)

        console.log("[categorise] \"" + itemName + "\" → " + text)

    } catch (err) {
        // Safety net: log but never re-throw so the create response stays 200.
        console.error("[categorise] Unexpected error:", err)
    }
}, "shopping_items")
