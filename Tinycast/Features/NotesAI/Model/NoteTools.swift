import Foundation

/// The Notes tools as the model sees them; what they say and return is English, as every tool's is.
enum NoteTools {
    static let search = "notes_search"
    static let read = "notes_read"
    static let append = "notes_append"
    static let allNames: Set<String> = [search, read, append]

    static let defaultSearchLimit = 10
    static let maxSearchLimit = 30
    static let maxLines = 2_000
    /// Under the loop's own 32 KB cap per result, so a cut here can still say where to continue.
    static let maxOutputBytes = 28 * 1_024
    static let maxAppendBytes = 64 * 1_024
    static let snippetLength = 160

    static func definitions(canWrite: Bool, origin: String) -> [AITool] {
        var tools = [
            tool(
                search,
                "Search the user's Tinycast Notes — their own Markdown notes, not your memory — by "
                    + "words in titles and text. Returns titles, dates and a matching line.",
                [
                    "query": string("Words to find in note titles and text. Empty lists the newest notes."),
                    "limit": integer("At most this many, default 10, up to 30.")
                ],
                required: [], origin: origin),
            tool(
                read,
                "Read one of the user's Tinycast Notes. Page through a long one with offset and limit.",
                [
                    "note": string("The note's title as notes_search shows it, or its file name."),
                    "offset": integer("First line, from 1."),
                    "limit": integer("How many lines, at most 2000.")
                ],
                required: ["note"], origin: origin)
        ]
        guard canWrite else { return tools }
        tools.append(
            tool(
                append,
                "Add Markdown to the end of one of the user's Tinycast Notes, creating it when no note "
                    + "has that title. Use it for reports and summaries the user asked you to keep. "
                    + "The user is asked first.",
                [
                    "note": string(
                        "Title of the note to add to, as notes_search shows it. A new note with this "
                            + "title is made when none has it."),
                    "text": string("Markdown to add at the end."),
                    "create": .object([
                        "type": .string("boolean"),
                        "description": .string("false fails instead of making a new note. Default true.")
                    ])
                ],
                required: ["note", "text"], origin: origin))
        return tools
    }

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: JSONValue],
        required: [String], origin: String
    ) -> AITool {
        AITool(
            name: name, description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string))
            ]),
            origin: origin, title: name)
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
